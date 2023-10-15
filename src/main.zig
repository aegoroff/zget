const std = @import("std");
const clap = @import("clap");

pub fn main() !void {
    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout = std.io.getStdOut().writer();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Display this help and exit.
        \\-u, --uri <str>        Uri to download.
        \\-H, --header <str>...  Additional HTTP header(s).
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
    }) catch |err| {
        // Report useful error and exit
        diag.report(stdout, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(stdout, clap.Help, &params, .{});
    }

    const allocator = std.heap.c_allocator;

    const source = res.args.uri orelse {
        return clap.help(stdout, clap.Help, &params, .{});
    };
    try stdout.print("URI: {s}\n", .{source});
    const uri = try std.Uri.parse(source);

    var http_client = std.http.Client{
        .allocator = allocator,
    };
    var headers = std.http.Headers{ .allocator = allocator };
    defer headers.deinit();
    for (res.args.header) |s| {
        var pair = std.mem.splitScalar(u8, s, ':');
        const h = trim(pair.next()) orelse {
            continue;
        };
        const v = trim(pair.next()) orelse {
            continue;
        };
        try headers.append(h, v);
    }

    var req = try http_client.request(.GET, uri, headers, .{});
    defer req.deinit();

    try req.start();
    try req.wait();
    const content_type = req.response.headers.getFirstValue("Content-Type") orelse "text/plain";
    try stdout.print("Content-type: {s}\n", .{content_type});

    const content_size = req.response.headers.getFirstValue("Content-Length") orelse "N/A";
    const content_size_bytes = std.fmt.parseInt(usize, content_size, 10) catch 0;
    if (content_size_bytes > 0) {
        try stdout.print("Content-size: {:.2} ({d} bytes)\n", .{ std.fmt.fmtIntSizeBin(content_size_bytes), content_size_bytes });
    }

    var file_path = std.fs.path.basename(uri.path);
    if (file_path.len == 0) {
        file_path = "hello.html";
    }
    const file = try std.fs.cwd().createFile(
        file_path,
        .{ .read = false },
    );
    defer file.close();

    var buf = try allocator.alloc(u8, 16 * 4096);
    defer allocator.free(buf);
    const max_errors = 10;
    var errors: i16 = 0;
    var read_bytes: usize = 0;
    var progress = std.Progress{};
    var percent_progress = progress.start("Downloading", 100);
    percent_progress.setUnit(" %");
    var bytes_progress = percent_progress.start("Read", content_size_bytes);
    bytes_progress.setUnit(" bytes");
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
        percent_progress.setCompletedItems(percent(usize, read_bytes, content_size_bytes));
        bytes_progress.setCompletedItems(read_bytes);
        progress.maybeRefresh();
        if (read == 0) {
            break;
        }
        try file.writeAll(buf[0..read]);
    }
    percent_progress.end();
    bytes_progress.end();
}

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
