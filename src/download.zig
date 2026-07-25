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
    if (std.mem.eql(u8, name, ".")) return false;
    if (std.mem.eql(u8, name, "..")) return false;
    // Defense in depth: reject any remaining path separators after basename.
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    return true;
}

/// Last path component treating both `/` and `\` as separators.
/// Remote-supplied names may use either, independent of the host OS.
fn remoteFileNameBase(path: []const u8) []const u8 {
    return std.fs.path.basenameWindows(path);
}

pub fn fileNameFromUri(gpa: std.mem.Allocator, uri: std.Uri) !?[]const u8 {
    // Decode the path BEFORE taking the basename: an encoded separator (e.g.
    // `%2F`) must become a real `/` first so basename strips the directory
    // part, instead of surviving into the output filename (path traversal).
    const decoded_path = try decodeIfEncoded(gpa, uri.path.percent_encoded);
    const base = remoteFileNameBase(decoded_path);
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

fn decodeIfEncoded(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '%') == null) return name;
    return try percentDecodeAlloc(gpa, name);
}

pub fn parseContentDispositionFileName(
    gpa: std.mem.Allocator,
    disposition: []const u8,
) !?[]const u8 {
    if (findContentDispositionParam(disposition, "filename*")) |value| {
        if (parseFilenameStar(value)) |encoded| {
            // RFC 5987 `filename*` is percent-encoded: decode BEFORE basename so
            // an encoded path separator (`%2F` / `%5C`) is stripped rather than
            // decoded into a real separator after the directory part was kept.
            const decoded = try decodeIfEncoded(gpa, encoded);
            const base = remoteFileNameBase(decoded);
            if (isUsableFileName(base)) return base;
        }
    }

    if (findContentDispositionParam(disposition, "filename")) |value| {
        if (parseContentDispositionValue(value)) |name| {
            // RFC 6266 `filename` is a quoted-string, NOT percent-encoded, so a
            // literal `%` in the name must be preserved unchanged.
            const base = remoteFileNameBase(name);
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
    if (content_disposition) |disposition| {
        if (try parseContentDispositionFileName(gpa, disposition)) |name| return name;
    }

    if (try fileNameFromUri(gpa, uri)) |name| return name;

    return DEFAULT_FILE_NAME;
}

fn hasTrailingSeparator(path: []const u8) bool {
    if (path.len == 0) return false;
    return std.fs.path.isSep(path[path.len - 1]);
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and std.fs.path.isSep(path[end - 1])) end -= 1;
    return path[0..end];
}

fn isExistingDirectory(io: std.Io, path: []const u8) bool {
    const trimmed = trimTrailingSeparators(path);
    if (trimmed.len == 0) return false;

    var optional_d: ?std.Io.Dir = null;
    if (std.fs.path.isAbsolute(trimmed)) {
        optional_d = std.Io.Dir.openDirAbsolute(io, trimmed, .{}) catch null;
    } else {
        optional_d = std.Io.Dir.cwd().openDir(io, trimmed, .{}) catch null;
    }
    if (optional_d) |dir| {
        dir.close(io);
        return true;
    }
    return false;
}

fn isDirectoryOutput(io: std.Io, path: []const u8) bool {
    if (hasTrailingSeparator(path)) return true;
    return isExistingDirectory(io, path);
}

fn requireExistingDirectory(io: std.Io, path: []const u8) errors.ZgetError![]const u8 {
    const trimmed = trimTrailingSeparators(path);
    if (trimmed.len == 0 or !isExistingDirectory(io, path)) {
        return error.OutputDirectoryNotFound;
    }
    return trimmed;
}

pub fn expandOutputPath(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    raw: []const u8,
) ![]const u8 {
    if (raw.len == 0 or raw[0] != '~') return raw;
    if (raw.len > 1 and raw[1] != '/') return raw;

    const home = environ.get("HOME") orelse return raw;
    if (raw.len == 1) return try gpa.dupe(u8, home);
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ home, raw[1..] });
}

pub fn planOutput(
    io: std.Io,
    output_opt: ?[]const u8,
) !OutputPlan {
    if (output_opt) |output| {
        if (std.mem.eql(u8, output, "-")) return .stdout;
        if (isDirectoryOutput(io, output)) {
            const directory = try requireExistingDirectory(io, output);
            return .{ .pending = .{ .directory = directory } };
        }
        return .{ .file = output };
    }

    // No explicit output: defer filename resolution until response headers are
    // available so Content-Disposition and the post-redirect URI take priority.
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
        const read = timeout.stream(io, reader, stream_dest, READ_BUF_LEN, read_timeout) catch |err| {
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

test "fileNameFromUri strips encoded path separators" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `%2F` decodes to `/` before basename, so the directory part is stripped
    // rather than producing an output name containing a path separator.
    const uri = try std.Uri.parse("https://example.com/a%2Fb.txt");
    const name = try fileNameFromUri(arena, uri);
    try std.testing.expectEqualStrings("b.txt", name.?);
}

test "parseContentDispositionFileName quoted value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const disposition = "attachment; filename=\"report.pdf\"";
    try std.testing.expectEqualStrings("report.pdf", (try parseContentDispositionFileName(arena, disposition)).?);
}

test "parseContentDispositionFileName unquoted value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const disposition = "attachment; filename=report.pdf";
    try std.testing.expectEqualStrings("report.pdf", (try parseContentDispositionFileName(arena, disposition)).?);
}

test "parseContentDispositionFileName filename star" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const disposition = "attachment; filename*=UTF-8''report%20final.pdf";
    try std.testing.expectEqualStrings("report final.pdf", (try parseContentDispositionFileName(arena, disposition)).?);
}

test "parseContentDispositionFileName strips encoded path separators (filename*)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `%2F` must decode to `/` BEFORE basename, so the directory part is
    // stripped instead of escaping the output directory.
    const disposition = "attachment; filename*=UTF-8''..%2F..%2Fsecret";
    try std.testing.expectEqualStrings("secret", (try parseContentDispositionFileName(arena, disposition)).?);
}

test "parseContentDispositionFileName preserves literal percent in filename" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Non-star `filename` is a literal quoted-string (RFC 6266); `%` is not an
    // escape and must be preserved.
    const disposition = "attachment; filename=\"100%25done.pdf\"";
    try std.testing.expectEqualStrings("100%25done.pdf", (try parseContentDispositionFileName(arena, disposition)).?);
}

test "parseContentDispositionFileName does not decode percent in filename" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `%2F` must stay literal in non-star `filename` — decoding after basename
    // would turn this into a path traversal (`../evil`).
    const disposition = "attachment; filename=\"..%2Fevil\"";
    try std.testing.expectEqualStrings("..%2Fevil", (try parseContentDispositionFileName(arena, disposition)).?);
}

test "parseContentDispositionFileName strips backslash separators in filename" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Literal `\` must be treated as a separator even on POSIX hosts.
    const disposition = "attachment; filename=\"..\\..\\secret\"";
    try std.testing.expectEqualStrings("secret", (try parseContentDispositionFileName(arena, disposition)).?);
}

test "parseContentDispositionFileName strips encoded backslash separators (filename*)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const disposition = "attachment; filename*=UTF-8''..%5C..%5Csecret";
    try std.testing.expectEqualStrings("secret", (try parseContentDispositionFileName(arena, disposition)).?);
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

test "resolveFileName prefers content disposition over uri basename" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const uri = try std.Uri.parse("https://example.com/data.json");
    const disposition = "attachment; filename=\"report.pdf\"";
    const name = try resolveFileName(arena, uri, disposition);
    try std.testing.expectEqualStrings("report.pdf", name);
}

test "resolveFileName falls back to uri basename without content disposition" {
    const uri = try std.Uri.parse("https://example.com/data.json");
    const name = try resolveFileName(std.testing.allocator, uri, null);
    try std.testing.expectEqualStrings("data.json", name);
}

test "planOutput pending when output omitted" {
    const plan = try planOutput(std.testing.io, null);
    try std.testing.expect(plan == .pending);
    try std.testing.expect(plan.pending.directory == null);
}

test "planOutput uses explicit output as file" {
    const plan = try planOutput(std.testing.io, "custom.bin");
    try std.testing.expect(plan == .file);
    try std.testing.expectEqualStrings("custom.bin", plan.file);
}

test "planOutput treats missing output path as file name" {
    const plan = try planOutput(std.testing.io, "missing-dir/out.bin");
    try std.testing.expect(plan == .file);
    try std.testing.expectEqualStrings("missing-dir/out.bin", plan.file);
}

test "planOutput rejects missing directory when output ends with separator" {
    try std.testing.expectError(
        error.OutputDirectoryNotFound,
        planOutput(std.testing.io, "missing-dir/"),
    );
}

test "expandOutputPath expands home directory prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environ = std.process.Environ.empty;
    var map = try std.process.Environ.createMap(environ, arena);
    defer map.deinit();
    try map.put("HOME", "/home/test");

    const expanded = try expandOutputPath(arena, &map, "~/downloads/");
    try std.testing.expectEqualStrings("/home/test/downloads/", expanded);
}

test "planOutput pending when output is existing directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_path_buffer: [128]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_path_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    const plan = try planOutput(std.testing.io, dir_path);
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
    const plan = try planOutput(std.testing.io, dir_path);
    const target = try outputTargetFromPlan(arena, plan, uri, null);
    try std.testing.expect(target == .file);
    try std.testing.expect(std.mem.endsWith(u8, target.file, DEFAULT_FILE_NAME));
    try std.testing.expect(std.mem.startsWith(u8, target.file, dir_path));
}

test "planOutput stdout for -O -" {
    const plan = try planOutput(std.testing.io, "-");
    try std.testing.expect(plan == .stdout);
}

test "finalizePendingOutput uses index.html fallback" {
    const uri = try std.Uri.parse("https://example.com/");
    const path = try finalizePendingOutput(std.testing.allocator, .{ .directory = null }, uri, null);
    try std.testing.expectEqualStrings(DEFAULT_FILE_NAME, path);
}
