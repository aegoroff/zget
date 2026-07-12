const std = @import("std");
const http = std.http;
const errors = @import("errors.zig");
const progress = @import("progress.zig");

const READ_BUF_LEN = 16 * 4096;
const MAX_ERRORS: i16 = 10;
const DEFAULT_FILE_NAME = "index.html";

const AfterStreamReadError = enum {
    retry,
    fail,
};

fn afterStreamReadError(read_errors: i16) AfterStreamReadError {
    if (read_errors < MAX_ERRORS) return .retry;
    return .fail;
}

pub const OutputTarget = union(enum) {
    stdout,
    file: []const u8,
};

pub const OutputPlan = union(enum) {
    stdout,
    file: []const u8,
    pending: PendingOutput,
};

pub const PendingOutput = struct {
    /// Existing directory from `-O`, or `null` to write into the current directory.
    directory: ?[]const u8,
};

fn isUsableFileName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "/")) return false;
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    return true;
}

pub fn fileNameFromUri(uri: std.Uri) ?[]const u8 {
    const base = std.fs.path.basename(uri.path.percent_encoded);
    if (!isUsableFileName(base)) return null;
    return base;
}

fn findContentDispositionParam(disposition: []const u8, param_name: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, disposition, ';');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const name = std.mem.trim(u8, trimmed[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(name, param_name)) continue;
        return std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
    }
    return null;
}

fn parseQuotedFileName(value: []const u8) ?[]const u8 {
    if (value.len < 2 or value[0] != '"') return null;

    var index: usize = 1;
    const start = index;
    while (index < value.len) {
        if (value[index] == '"') return value[start..index];
        if (value[index] == '\\' and index + 1 < value.len) {
            index += 2;
            continue;
        }
        index += 1;
    }
    return null;
}

fn parseUnquotedFileName(value: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const trimmed = std.mem.trim(u8, value[0..end], " \t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn parseContentDispositionValue(value: []const u8) ?[]const u8 {
    if (value.len == 0) return null;
    if (value[0] == '"') return parseQuotedFileName(value);
    return parseUnquotedFileName(value);
}

fn parseFilenameStar(value: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, value, "''") orelse return null;
    const encoded = std.mem.trim(u8, value[marker + 2 ..], " \t");
    if (encoded.len == 0) return null;
    return encoded;
}

fn percentDecodeAlloc(gpa: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var stack_buf: [2048]u8 = undefined;
    const workspace: []u8 = if (encoded.len <= stack_buf.len)
        stack_buf[0..encoded.len]
    else
        try gpa.alloc(u8, encoded.len);
    const decoded = std.Uri.percentDecodeBackwards(workspace, encoded);
    return try gpa.dupe(u8, decoded);
}

pub fn parseContentDispositionFileName(disposition: []const u8) ?[]const u8 {
    if (findContentDispositionParam(disposition, "filename*")) |value| {
        if (parseFilenameStar(value)) |encoded| {
            const base = std.fs.path.basename(encoded);
            if (isUsableFileName(base)) return base;
        }
    }

    if (findContentDispositionParam(disposition, "filename")) |value| {
        if (parseContentDispositionValue(value)) |name| {
            const base = std.fs.path.basename(name);
            if (isUsableFileName(base)) return base;
        }
    }

    return null;
}

pub fn resolveFileName(
    gpa: std.mem.Allocator,
    uri: std.Uri,
    content_disposition: ?[]const u8,
) ![]const u8 {
    if (fileNameFromUri(uri)) |name| return name;

    if (content_disposition) |disposition| {
        if (findContentDispositionParam(disposition, "filename*")) |value| {
            if (parseFilenameStar(value)) |encoded| {
                const decoded = try percentDecodeAlloc(gpa, encoded);
                const base = std.fs.path.basename(decoded);
                if (isUsableFileName(base)) return base;
            }
        }

        if (findContentDispositionParam(disposition, "filename")) |value| {
            if (parseContentDispositionValue(value)) |name| {
                const base = std.fs.path.basename(name);
                if (isUsableFileName(base)) return base;
            }
        }
    }

    return DEFAULT_FILE_NAME;
}

fn isExistingDirectory(io: std.Io, path: []const u8) bool {
    var optional_d: ?std.Io.Dir = null;
    if (std.fs.path.isAbsolute(path)) {
        optional_d = std.Io.Dir.openDirAbsolute(io, path, .{}) catch null;
    } else {
        optional_d = std.Io.Dir.cwd().openDir(io, path, .{}) catch null;
    }
    if (optional_d) |dir| {
        dir.close(io);
        return true;
    }
    return false;
}

pub fn planOutput(
    gpa: std.mem.Allocator,
    io: std.Io,
    output_opt: ?[]const u8,
    uri: std.Uri,
) !OutputPlan {
    if (output_opt) |output| {
        if (std.mem.eql(u8, output, "-")) return .stdout;
    }

    if (fileNameFromUri(uri)) |file_name| {
        if (output_opt) |output| {
            if (isExistingDirectory(io, output)) {
                return .{ .file = try std.fs.path.join(gpa, &[_][]const u8{ output, file_name }) };
            }
            return .{ .file = output };
        }
        return .{ .file = file_name };
    }

    if (output_opt) |output| {
        if (isExistingDirectory(io, output)) {
            return .{ .pending = .{ .directory = output } };
        }
        return .{ .file = output };
    }

    return .{ .pending = .{ .directory = null } };
}

pub fn finalizePendingOutput(
    gpa: std.mem.Allocator,
    pending: PendingOutput,
    uri: std.Uri,
    content_disposition: ?[]const u8,
) ![]const u8 {
    const file_name = try resolveFileName(gpa, uri, content_disposition);
    if (pending.directory) |directory| {
        return try std.fs.path.join(gpa, &[_][]const u8{ directory, file_name });
    }
    return file_name;
}

pub fn outputTargetFromPlan(
    gpa: std.mem.Allocator,
    plan: OutputPlan,
    uri: std.Uri,
    content_disposition: ?[]const u8,
) !OutputTarget {
    return switch (plan) {
        .stdout => .stdout,
        .file => |path| .{ .file = path },
        .pending => |pending| .{
            .file = try finalizePendingOutput(gpa, pending, uri, content_disposition),
        },
    };
}

pub fn createFile(io: std.Io, path: []const u8) !std.Io.File {
    const file_options = std.Io.File.CreateFlags{ .read = false };
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, file_options);
    }
    return std.Io.Dir.cwd().createFile(io, path, file_options);
}

pub fn streamToWriter(
    io: std.Io,
    gpa: std.mem.Allocator,
    summary: *std.Io.Writer,
    response: *std.http.Client.Response,
    dest: *std.Io.Writer,
    content_size_bytes: u64,
) !void {
    const read_buf = try gpa.alloc(u8, READ_BUF_LEN);

    const encoding = response.head.content_encoding;
    if (encoding == .compress) return errors.ZgetError.UnsupportedCompressionMethod;

    const decompress_buf_len = encoding.minBufferCapacity();
    const decompress_buf: []u8 = if (decompress_buf_len == 0)
        &.{}
    else
        try gpa.alloc(u8, decompress_buf_len);

    var decompress: http.Decompress = undefined;
    var reader = response.readerDecompressing(read_buf, &decompress, decompress_buf);

    var tracker = progress.Tracker.start(io, content_size_bytes);
    defer {
        tracker.printSummary(io, summary);
        tracker.end();
    }

    var read_errors: i16 = 0;
    while (true) {
        const read = reader.stream(dest, .limited(READ_BUF_LEN)) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return response.bodyErr().?,
                else => |e| {
                    try summary.print("Error: {}\n", .{e});
                    switch (afterStreamReadError(read_errors)) {
                        .retry => {
                            read_errors += 1;
                            continue;
                        },
                        .fail => return e,
                    }
                },
            }
        };
        tracker.record(io, read, @intCast(content_size_bytes));
    }
}

pub fn streamToFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    summary: *std.Io.Writer,
    response: *std.http.Client.Response,
    file: *std.Io.File,
    content_size_bytes: u64,
) !void {
    var file_buffer: [READ_BUF_LEN]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const file_interface = &file_writer.interface;
    defer {
        file_interface.flush() catch {};
    }

    try streamToWriter(io, gpa, summary, response, file_interface, content_size_bytes);
}

test "afterStreamReadError retries until limit" {
    try std.testing.expect(afterStreamReadError(0) == .retry);
    try std.testing.expect(afterStreamReadError(MAX_ERRORS - 1) == .retry);
    try std.testing.expect(afterStreamReadError(MAX_ERRORS) == .fail);
}

test "fileNameFromUri rejects directory paths" {
    const root = try std.Uri.parse("https://example.com/");
    try std.testing.expect(fileNameFromUri(root) == null);

    const with_file = try std.Uri.parse("https://example.com/file.txt");
    try std.testing.expectEqualStrings("file.txt", fileNameFromUri(with_file).?);
}

test "parseContentDispositionFileName quoted value" {
    const disposition = "attachment; filename=\"report.pdf\"";
    try std.testing.expectEqualStrings("report.pdf", parseContentDispositionFileName(disposition).?);
}

test "parseContentDispositionFileName unquoted value" {
    const disposition = "attachment; filename=report.pdf";
    try std.testing.expectEqualStrings("report.pdf", parseContentDispositionFileName(disposition).?);
}

test "parseContentDispositionFileName filename star" {
    const disposition = "attachment; filename*=UTF-8''report%20final.pdf";
    try std.testing.expectEqualStrings("report%20final.pdf", parseContentDispositionFileName(disposition).?);
}

test "resolveFileName falls back to index.html" {
    const uri = try std.Uri.parse("https://example.com/");
    const name = try resolveFileName(std.testing.allocator, uri, null);
    try std.testing.expectEqualStrings(DEFAULT_FILE_NAME, name);
}

test "resolveFileName uses content disposition when uri has no name" {
    const uri = try std.Uri.parse("https://example.com/");
    const disposition = "attachment; filename=\"data.bin\"";
    const name = try resolveFileName(std.testing.allocator, uri, disposition);
    try std.testing.expectEqualStrings("data.bin", name);
}

test "resolveFileName decodes filename star" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uri = try std.Uri.parse("https://example.com/");
    const disposition = "attachment; filename*=UTF-8''report%20final.pdf";
    const name = try resolveFileName(arena, uri, disposition);
    try std.testing.expectEqualStrings("report final.pdf", name);
}

test "planOutput stdout for -O -" {
    const uri = try std.Uri.parse("https://example.com/file.txt");
    const plan = try planOutput(std.testing.allocator, std.testing.io, "-", uri);
    try std.testing.expect(plan == .stdout);
}

test "planOutput file for explicit path" {
    const uri = try std.Uri.parse("https://example.com/file.txt");
    const plan = try planOutput(std.testing.allocator, std.testing.io, "out.txt", uri);
    try std.testing.expect(plan == .file);
    try std.testing.expectEqualStrings("out.txt", plan.file);
}

test "planOutput pending when uri has no filename" {
    const uri = try std.Uri.parse("https://example.com/");
    const plan = try planOutput(std.testing.allocator, std.testing.io, null, uri);
    try std.testing.expect(plan == .pending);
    try std.testing.expect(plan.pending.directory == null);
}

test "finalizePendingOutput uses index.html fallback" {
    const uri = try std.Uri.parse("https://example.com/");
    const path = try finalizePendingOutput(std.testing.allocator, .{ .directory = null }, uri, null);
    try std.testing.expectEqualStrings(DEFAULT_FILE_NAME, path);
}
