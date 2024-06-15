const std = @import("std");
const clap = @import("clap");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

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

    try stdout.print("URI: {s}\n", .{source});
    const uri = try std.Uri.parse(source);

    const file_name = std.fs.path.basename(uri.path.raw);
    // Calculate target file path
    var target = res.args.output orelse file_name;
    var optional_d = std.fs.openDirAbsolute(target, .{}) catch null;
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
    var headers: []std.http.Header = undefined;
    for (res.args.header, 0..) |s, i| {
        var pair = std.mem.splitScalar(u8, s, ':');
        const h = trim(pair.next()) orelse {
            continue;
        };
        const v = trim(pair.next()) orelse {
            continue;
        };
        headers[i] = .{ .name = h, .value = v };
    }

    //http_client.open(method: http.Method, uri: Uri, options: RequestOptions)
    var header_buffer: [4096]u8 = undefined;
    var req = try http_client.open(.GET, uri, .{ .server_header_buffer = &header_buffer, .extra_headers = headers });
    defer req.deinit();

    try req.send();
    try req.wait();
    const content_type = req.response.content_type orelse "text/plain";
    try stdout.print("Content-type: {s}\n", .{content_type});

    const content_size_bytes = req.response.content_length orelse 0;
    if (content_size_bytes > 0) {
        try stdout.print("Content-size: {:.2} ({d} bytes)\n", .{ std.fmt.fmtIntSizeBin(content_size_bytes), content_size_bytes });
    }

    const file_options = .{ .read = false };
    var file = if (std.mem.eql(u8, target, file_name)) try std.fs.cwd().createFile(file_name, file_options) else try std.fs.createFileAbsolute(target, file_options);
    defer file.close();

    var buf = try arena.allocator().alloc(u8, 16 * 4096);
    const max_errors = 10;
    var errors: i16 = 0;
    var read_bytes: usize = 0;
    var progress = std.Progress{};
    var percent_progress = progress.start("Downloading", 100);
    defer percent_progress.end();
    percent_progress.setUnit(" %");
    var bytes_progress = percent_progress.start("Read", content_size_bytes);
    defer bytes_progress.end();
    bytes_progress.setUnit(" bytes");
    var speed_progress = bytes_progress.start("Speed", 0);
    defer speed_progress.end();
    speed_progress.setUnit(" KiB/sec");
    var timer = try std.time.Timer.start();
    while (true) {
        const read = req.reader().read(buf) catch |err| {
            try stdout.print("Error: {}\n", .{err});
            if (errors < max_errors) {
                errors += 1;
                continue;
            } else {
                break;
            }
        };
        read_bytes += read;
        const elapsed = timer.read() / 1000000000;
        if (elapsed > 0) {
            const kbytes = read_bytes / 1024;
            var value = kbytes;
            if (kbytes > 1024) {
                value = kbytes / 1024;
                speed_progress.setUnit(" MiB/sec");
            }
            const speed = value / elapsed;
            speed_progress.setCompletedItems(speed);
        }

        percent_progress.setCompletedItems(percent(usize, read_bytes, content_size_bytes));
        bytes_progress.setCompletedItems(read_bytes);
        progress.maybeRefresh();
        if (read == 0) {
            break;
        }
        try file.writeAll(buf[0..read]);
    }
}

const ZgetError = error{ResultFileNotSet};

fn percent(comptime T: type, completed: T, total: T) T {
    const x = @as(f32, @floatFromInt(completed));
    const y = @as(f32, @floatFromInt(total));
    if (y == 0) {
        return 0;
    }
    return @intFromFloat((x / y) * 100);
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
