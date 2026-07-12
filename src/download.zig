const std = @import("std");
const http = std.http;
const errors = @import("errors.zig");
const progress = @import("progress.zig");
const timeout = @import("timeout.zig");
const checksum = @import("checksum.zig");

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

fn progressTotalBytes(content_length: u64, encoding: http.ContentEncoding) u64 {
    if (encoding != .identity) return 0;
    return content_length;
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

pub fn fileNameFromUri(gpa: std.mem.Allocator, uri: std.Uri) !?[]const u8 {
    const base = std.fs.path.basename(uri.path.percent_encoded);
    if (!isUsableFileName(base)) return null;
    if (std.mem.indexOfScalar(u8, base, '%') == null) return base;
    return try percentDecodeAlloc(gpa, base);
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
    if (try fileNameFromUri(gpa, uri)) |name| return name;

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

    if (try fileNameFromUri(gpa, uri)) |file_name| {
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
    read_timeout: std.Io.Timeout,
    checksum_opts: checksum.Options,
    warnings: ?*std.Io.Writer,
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
    const reader = response.readerDecompressing(read_buf, &decompress, decompress_buf);

    var hash_writer_buf: [checksum.hash_buf_len]u8 = undefined;
    var checksum_stream = checksum.Stream.init(dest, hash_writer_buf[0..], checksum_opts);
    const stream_dest = checksum_stream.writer();

    const progress_total_bytes = progressTotalBytes(content_size_bytes, encoding);

    var tracker: ?progress.Tracker = null;
    if (!checksum_opts.quiet) {
        tracker = progress.Tracker.start(io, progress_total_bytes);
    }
    defer if (tracker) |*t| {
        t.printSummary(io, summary);
        t.end();
    };

    var read_errors: i16 = 0;
    while (true) {
        const read = timeout.streamWithIdleTimeout(io, reader, stream_dest, READ_BUF_LEN, read_timeout) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                error.Timeout => return err,
                error.ReadFailed => {
                    if (response.request.connection) |conn| {
                        if (conn.stream_reader.err) |stream_err| return stream_err;
                    }
                    return response.bodyErr() orelse error.ReadFailed;
                },
                else => |e| {
                    if (!checksum_opts.quiet) {
                        try summary.print("Error: {}\n", .{e});
                    }
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
        if (tracker) |*t| {
            t.record(io, read, @intCast(progress_total_bytes));
        }
    }

    try checksum_stream.finish(summary, warnings);
}

pub fn streamToFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    summary: *std.Io.Writer,
    response: *std.http.Client.Response,
    file: *std.Io.File,
    content_size_bytes: u64,
    read_timeout: std.Io.Timeout,
    checksum_opts: checksum.Options,
    warnings: ?*std.Io.Writer,
) !void {
    const file_buffer = try gpa.alloc(u8, READ_BUF_LEN);
    var file_writer = file.writer(io, file_buffer);
    const file_interface = &file_writer.interface;
    defer {
        file_interface.flush() catch {};
    }

    try streamToWriter(
        io,
        gpa,
        summary,
        response,
        file_interface,
        content_size_bytes,
        read_timeout,
        checksum_opts,
        warnings,
    );
}

test "afterStreamReadError retries until limit" {
    try std.testing.expect(afterStreamReadError(0) == .retry);
    try std.testing.expect(afterStreamReadError(MAX_ERRORS - 1) == .retry);
    try std.testing.expect(afterStreamReadError(MAX_ERRORS) == .fail);
}

test "progressTotalBytes ignores compressed content length" {
    try std.testing.expectEqual(@as(u64, 0), progressTotalBytes(1024, .gzip));
    try std.testing.expectEqual(@as(u64, 1024), progressTotalBytes(1024, .identity));
}

test "fileNameFromUri rejects directory paths" {
    const root = try std.Uri.parse("https://example.com/");
    try std.testing.expect((try fileNameFromUri(std.testing.allocator, root)) == null);

    const with_file = try std.Uri.parse("https://example.com/file.txt");
    try std.testing.expectEqualStrings("file.txt", (try fileNameFromUri(std.testing.allocator, with_file)).?);
}

test "fileNameFromUri decodes percent-encoded names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uri = try std.Uri.parse("https://example.com/my%20file.zip");
    const name = try fileNameFromUri(arena, uri);
    try std.testing.expectEqualStrings("my file.zip", name.?);
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

test "planOutput uses uri filename in current directory" {
    const uri = try std.Uri.parse("https://example.com/data.json");
    const plan = try planOutput(std.testing.allocator, std.testing.io, null, uri);
    try std.testing.expect(plan == .file);
    try std.testing.expectEqualStrings("data.json", plan.file);
}

test "planOutput uses explicit output over uri filename" {
    const uri = try std.Uri.parse("https://example.com/data.json");
    const plan = try planOutput(std.testing.allocator, std.testing.io, "custom.bin", uri);
    try std.testing.expect(plan == .file);
    try std.testing.expectEqualStrings("custom.bin", plan.file);
}

test "planOutput treats missing output path as file name" {
    const uri = try std.Uri.parse("https://example.com/file.txt");
    const plan = try planOutput(std.testing.allocator, std.testing.io, "missing-dir/out.bin", uri);
    try std.testing.expect(plan == .file);
    try std.testing.expectEqualStrings("missing-dir/out.bin", plan.file);
}

test "planOutput joins existing directory with uri filename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir_path_buffer: [128]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const uri = try std.Uri.parse("https://example.com/archive.tar.gz");
    const plan = try planOutput(arena, std.testing.io, dir_path, uri);
    try std.testing.expect(plan == .file);
    try std.testing.expect(std.mem.endsWith(u8, plan.file, "archive.tar.gz"));
    try std.testing.expect(std.mem.startsWith(u8, plan.file, dir_path));
}

test "planOutput pending when output is existing directory and uri has no filename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_path_buffer: [128]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const uri = try std.Uri.parse("https://example.com/");
    const plan = try planOutput(std.testing.allocator, std.testing.io, dir_path, uri);
    try std.testing.expect(plan == .pending);
    try std.testing.expectEqualStrings(dir_path, plan.pending.directory.?);
}

test "finalizePendingOutput joins directory with content disposition filename" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir_path_buffer: [128]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const uri = try std.Uri.parse("https://example.com/");
    const disposition = "attachment; filename=\"pkg.zip\"";
    const path = try finalizePendingOutput(arena, .{ .directory = dir_path }, uri, disposition);
    try std.testing.expect(std.mem.endsWith(u8, path, "pkg.zip"));
    try std.testing.expect(std.mem.startsWith(u8, path, dir_path));
}

test "outputTargetFromPlan resolves pending directory output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dir_path_buffer: [128]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const uri = try std.Uri.parse("https://example.com/");
    const plan = try planOutput(arena, std.testing.io, dir_path, uri);
    const target = try outputTargetFromPlan(arena, plan, uri, null);
    try std.testing.expect(target == .file);
    try std.testing.expect(std.mem.endsWith(u8, target.file, DEFAULT_FILE_NAME));
    try std.testing.expect(std.mem.startsWith(u8, target.file, dir_path));
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
