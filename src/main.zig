const std = @import("std");
const cli = @import("cli.zig");
const download = @import("download.zig");
const errors = @import("errors.zig");
const proxy = @import("proxy.zig");
const transport = @import("transport.zig");
const http = std.http;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch {};
    }

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer {
        stderr.flush() catch {};
    }

    const args = try cli.parse(init, gpa);

    const output_target = try download.resolveOutput(gpa, init.io, args.output, args.uri);
    const log = if (output_target == .stdout) stderr else stdout;

    try log.print("URI: {s}\n", .{args.uri_source});

    const proxy_config = try proxy.Config.init(gpa, init.environ_map, args.proxy);
    var client = transport.Transport.init(gpa, init.io, proxy_config);
    defer client.deinit();
    var req = try client.get(args.uri, args.headers);
    defer req.deinit();

    try req.sendBodiless();

    var header_buffer = try std.ArrayList(u8).initCapacity(gpa, 65536);
    header_buffer.expandToCapacity();
    var response = try req.receiveHead(header_buffer.items);

    const content_type = response.head.content_type orelse "text/plain";
    try log.print("Content-type: {s}\n", .{content_type});

    if (response.head.status != http.Status.ok) {
        try log.print("Http response: {d}\n", .{@intFromEnum(response.head.status)});
        return errors.ZgetError.HttpError;
    }

    const content_size_bytes = response.head.content_length orelse 0;
    if (content_size_bytes > 0) {
        try log.print("Content-size: {0Bi:.2} ({0} bytes)\n", .{content_size_bytes});
    }

    switch (output_target) {
        .stdout => try download.streamToWriter(
            init.io,
            gpa,
            stderr,
            &response,
            stdout,
            content_size_bytes,
        ),
        .file => |target| {
            var file = try download.createFile(init.io, target);
            defer file.close(init.io);

            try download.streamToFile(
                init.io,
                gpa,
                stdout,
                &response,
                &file,
                content_size_bytes,
            );
        },
    }
}

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("cli.zig");
    _ = @import("download.zig");
    _ = @import("errors.zig");
    _ = @import("progress.zig");
    _ = @import("proxy.zig");
    _ = @import("transport.zig");
}
