const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;
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
        const h = pair.next() orelse {
            continue;
        };
        const v = pair.next() orelse {
            continue;
        };
        const hs = std.mem.trim(u8, h, " ");
        const vs = std.mem.trim(u8, v, " ");
        try headers.append(hs, vs);
    }

    var req = try http_client.request(.GET, uri, headers, .{});
    defer req.deinit();

    try req.start();
    try req.wait();
    const content_type = req.response.headers.getFirstValue("Content-Type") orelse "text/plain";
    const content_size = req.response.headers.getFirstValue("Content-Length") orelse "N/A";
    try stdout.print("Content-type: {s}\n", .{content_type});
    try stdout.print("Content-size: {s}\n", .{content_size});

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
    while (true) {
        const read = try req.reader().read(buf);
        if (read == 0) {
            break;
        }
        try file.writeAll(buf[0..read]);
    }
}

pub fn parseUsize(buf: []const u8, radix: u8) !usize {
    var x: u64 = 0;

    for (buf) |c| {
        const digit = charToDigit(c);

        if (digit >= radix) {
            return error.InvalidChar;
        }

        // x *= radix
        var ov = @mulWithOverflow(x, radix);
        if (ov[1] != 0) return error.OverFlow;

        // x += digit
        ov = @addWithOverflow(ov[0], digit);
        if (ov[1] != 0) return error.OverFlow;
        x = ov[0];
    }

    return x;
}

fn charToDigit(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'Z' => c - 'A' + 10,
        'a'...'z' => c - 'a' + 10,
        else => maxInt(u8),
    };
}

test "parse usize" {
    const result = try parseUsize("1234", 10);
    try std.testing.expect(result == 1234);
}
