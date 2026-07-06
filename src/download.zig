const std = @import("std");
const errors = @import("errors.zig");
const progress = @import("progress.zig");

const READ_BUF_LEN = 16 * 4096;
const MAX_ERRORS: i16 = 10;

pub fn resolvePath(
    gpa: std.mem.Allocator,
    io: std.Io,
    output_opt: ?[]const u8,
    uri: std.Uri,
) ![]const u8 {
    const file_name = std.fs.path.basename(uri.path.percent_encoded);
    var target = output_opt orelse file_name;

    var optional_d: ?std.Io.Dir = null;
    if (std.fs.path.isAbsolute(target)) {
        optional_d = std.Io.Dir.openDirAbsolute(io, target, .{}) catch null;
    } else {
        optional_d = std.Io.Dir.cwd().openDir(io, target, .{}) catch null;
    }
    if (optional_d != null) {
        optional_d.?.close(io);
        target = try std.fs.path.join(gpa, &[_][]const u8{ target, file_name });
    }

    if (target.len == 0) {
        return errors.ZgetError.ResultFileNotSet;
    }

    return target;
}

pub fn createFile(io: std.Io, path: []const u8) !std.Io.File {
    const file_options = std.Io.File.CreateFlags{ .read = false };
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, file_options);
    }
    return std.Io.Dir.cwd().createFile(io, path, file_options);
}

pub fn streamToFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
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

    const read_buf = try gpa.alloc(u8, READ_BUF_LEN);
    var tracker = progress.Tracker.start(io, content_size_bytes);
    defer {
        tracker.printSummary(io, stdout);
        tracker.end();
    }

    var read_errors: i16 = 0;
    var reader = response.reader(read_buf);
    while (true) {
        const read = reader.stream(file_interface, .limited(READ_BUF_LEN)) catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => |e| {
                    try stdout.print("Error: {}\n", .{e});
                    if (read_errors < MAX_ERRORS) {
                        read_errors += 1;
                        continue;
                    } else {
                        break;
                    }
                },
            }
        };
        tracker.record(io, read, @intCast(content_size_bytes));
    }
}
