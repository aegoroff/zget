const std = @import("std");
const clap = @import("clap");
const http = std.http;

pub fn main() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch {};
    }

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-O, --output <str>     Path the result will saved to. If it's a directory file name will be get from URI file name part.
        \\-H, --header <str>...  Additional HTTP header(s).
        \\ <str>                 Uri to download.
    );

    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = arena.allocator(),
    }) catch |err| {
        // Report useful error and exit
        diag.report(stdout, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(stdout, clap.Help, &params, .{});
    }

    const source = if (res.positionals.len == 1) res.positionals[0] else {
        return clap.help(stdout, clap.Help, &params, .{});
    };

    try stdout.print("URI: {s}\n", .{source.?});
    const uri = try std.Uri.parse(source.?);

    const file_name = std.fs.path.basename(uri.path.percent_encoded);
    // Calculate target file path
    var target = res.args.output orelse file_name;

    var optional_d: ?std.fs.Dir = undefined;
    if (std.fs.path.isAbsolute(target)) {
        optional_d = std.fs.openDirAbsolute(target, .{}) catch null;
    } else {
        optional_d = std.fs.cwd().openDir(target, .{}) catch null;
    }
    if (optional_d != null) {
        optional_d.?.close();
        target = try std.fs.path.join(arena.allocator(), &[_][]const u8{ target, file_name });
    }

    if (target.len == 0) {
        // if no file name from URI and nothing set using cli option
        // treat this as error
        return ZgetError.ResultFileNotSet;
    }
    // Calculate target file path completed

    var http_client = std.http.Client{
        .allocator = arena.allocator(),
    };
    var extra_headers = std.ArrayList(std.http.Header){};
    for (res.args.header) |s| {
        var pair = std.mem.splitScalar(u8, s, ':');
        const h = trim(pair.next());
        const v = trim(pair.next());
        if (h != null and v != null) {
            try extra_headers.append(arena.allocator(), .{ .name = h.?, .value = v.? });
        }
    }

    var req = try http_client.request(.GET, uri, .{
        .extra_headers = extra_headers.items,
    });
    defer req.deinit();

    try req.sendBodiless();

    var header_buffer = try std.ArrayList(u8).initCapacity(arena.allocator(), 65536);
    header_buffer.expandToCapacity();
    var response = try req.receiveHead(header_buffer.items);

    const content_type = response.head.content_type orelse "text/plain";
    try stdout.print("Content-type: {s}\n", .{content_type});

    if (response.head.status != http.Status.ok) {
        try stdout.print("Http response: {d}\n", .{@intFromEnum(response.head.status)});
        return ZgetError.HttpError;
    }

    const content_size_bytes = response.head.content_length orelse 0;
    if (content_size_bytes > 0) {
        const args = .{ content_size_bytes, content_size_bytes };
        try stdout.print("Content-size: {Bi:.2} ({d} bytes)\n", args);
    }

    const file_options = std.fs.File.CreateFlags{ .read = false };
    var file: std.fs.File = undefined;
    if (std.mem.eql(u8, target, file_name)) {
        file = try std.fs.cwd().createFile(file_name, file_options);
    } else if (std.fs.path.isAbsolute(target)) {
        file = try std.fs.createFileAbsolute(target, file_options);
    } else {
        file = try std.fs.cwd().createFile(target, file_options);
    }
    defer file.close();

    const read_buf_len = 16 * 4096;
    var file_buffer: [read_buf_len]u8 = undefined;
    var file_writer = file.writer(&file_buffer);
    const file_interface = &file_writer.interface;
    defer {
        file_interface.flush() catch {};
    }

    const read_buf = try arena.allocator().alloc(u8, read_buf_len);
    const max_errors = 10;
    var errors: i16 = 0;
    var read_bytes: usize = 0;
    var progress = std.Progress.start(.{ .root_name = "%", .estimated_total_items = 100 });
    defer progress.end();
    var bytes_progress = progress.start("bytes", @intCast(content_size_bytes));
    defer bytes_progress.end();
    var speed_progress = progress.start("MiB/sec", 0);
    defer speed_progress.end();
    var timer = try std.time.Timer.start();
    defer {
        const elapsed = timer.read();
        stdout.print("Time taken: {D:0}\n", .{elapsed}) catch {};
    }
    var reader = response.reader(read_buf);
    while (true) {
        const read = reader.stream(file_interface, .limited(read_buf_len)) catch |err| {
            switch (err) {
                error.EndOfStream => {
                    break;
                },
                else => |e| {
                    try stdout.print("Error: {}\n", .{e});
                    if (errors < max_errors) {
                        errors += 1;
                        continue;
                    } else {
                        break;
                    }
                },
            }
        };
        read_bytes += read;
        const elapsed = timer.read() / 1000000000;
        if (elapsed > 0) {
            const kbytes = read_bytes / 1024;
            const speed = (kbytes / 1024) / elapsed;
            speed_progress.setCompletedItems(@intCast(speed));
        }

        progress.setCompletedItems(percent(usize, read_bytes, @intCast(content_size_bytes)));
        bytes_progress.setCompletedItems(read_bytes);
    }
}

const ZgetError = error{ ResultFileNotSet, HttpError };

fn percent(comptime T: type, completed: T, total: T) T {
    const v = div(T, completed, total);
    return @intFromFloat(v * 100);
}

fn div(comptime T: type, completed: T, total: T) f32 {
    const x = @as(f32, @floatFromInt(completed));
    const y = @as(f32, @floatFromInt(total));
    if (y == 0) {
        return 0;
    }
    return x / y;
}

fn trim(s: ?[]const u8) ?[]const u8 {
    const slice = s orelse {
        return s;
    };
    return std.mem.trim(u8, slice, " ");
}

test "trim not needed" {
    const i: ?[]const u8 = "1234";
    try std.testing.expectEqualStrings("1234", trim(i) orelse "");
}

test "trim null" {
    try std.testing.expectEqual(@as(?[]const u8, null), trim(null));
}

test "trim null with whitespaces" {
    const i: ?[]const u8 = " 1234 ";
    try std.testing.expectEqualStrings("1234", trim(i) orelse "");
}

test "percent 0" {
    const expected: usize = 0;
    try std.testing.expectEqual(expected, percent(usize, 10, 0));
}

test "percent 1" {
    const expected: usize = 1;
    try std.testing.expectEqual(expected, percent(usize, 10, 1000));
}

test "percent 10" {
    const expected: usize = 10;
    try std.testing.expectEqual(expected, percent(usize, 100, 1000));
}

test "percent 25" {
    const expected: usize = 25;
    try std.testing.expectEqual(expected, percent(usize, 250, 1000));
}

test "percent 70" {
    const expected: usize = 70;
    try std.testing.expectEqual(expected, percent(usize, 700, 1000));
}

test "percent 70 (int)" {
    const expected: i32 = 70;
    try std.testing.expectEqual(expected, percent(i32, 700, 1000));
}
