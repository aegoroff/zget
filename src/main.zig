const std = @import("std");
const assert = std.debug.assert;
const maxInt = std.math.maxInt;

pub fn main() !void {
    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    const allocator = std.heap.c_allocator;
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const stdin_file = std.io.getStdIn().reader();
    try stdin_file.streamUntilDelimiter(buffer.writer(), '\n', null);

    try stdout.print("URI: {s}\n", .{buffer.items});
    const uri = try std.Uri.parse(buffer.items);

    var http_client = std.http.Client{
        .allocator = allocator,
    };
    var headers = std.http.Headers{ .allocator = allocator };
    defer headers.deinit();
    try headers.append("accept", "*/*");

    var req = try http_client.request(.GET, uri, headers, .{});
    defer req.deinit();

    try req.start();
    try req.wait();
    const content_type = req.response.headers.getFirstValue("Content-Type") orelse "text/plain";
    const content_size = req.response.headers.getFirstValue("Content-Length") orelse "N/A";
    try stdout.print("Content-type: {s}\n", .{content_type});
    try stdout.print("Content-size: {s}\n", .{content_size});
    try bw.flush();

    var file_path = std.fs.path.basename(uri.path);
    if (file_path.len == 0) {
        file_path = "hello.html";
    }
    const file = try std.fs.cwd().createFile(
        file_path,
        .{ .read = false },
    );
    defer file.close();

    while (true) {
        var buf = try allocator.alloc(u8, 4096);
        defer allocator.free(buf);
        const read = try req.reader().read(buf);
        if (read == 0) {
            break;
        }
        try file.writeAll(buf[0..read]);
    }

    try bw.flush(); // don't forget to flush!
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
