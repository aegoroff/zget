const std = @import("std");
const cli = @import("cli.zig");
const download = @import("download.zig");
const errors = @import("errors.zig");
const proxy = @import("proxy.zig");
const transport = @import("transport.zig");
const http = std.http;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
        errors.report(&stderr_writer.interface, err);
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
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

    const parsed = try cli.parse(init, gpa);
    switch (parsed) {
        .version => {
            try cli.printVersion(stdout);
            return;
        },
        .run => |args| try executeDownload(init, gpa, stdout, stderr, args),
    }
}

fn executeDownload(
    init: std.process.Init,
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    args: cli.Args,
) !void {
    const output_plan = try download.planOutput(gpa, init.io, args.output, args.uri);
    // if set -O - (that sets result to stdout like wget) then log to stderr
    const summary = if (output_plan == .stdout) stderr else stdout;

    try summary.print("URI: {s}\n", .{args.uri_source});

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
    try summary.print("Content-type: {s}\n", .{content_type});

    if (response.head.status != http.Status.ok) {
        try summary.print("Http response: {d}\n", .{@intFromEnum(response.head.status)});
        return errors.ZgetError.HttpError;
    }

    const content_size_bytes = response.head.content_length orelse 0;
    if (content_size_bytes > 0) {
        try summary.print("Content-size: {0Bi:.2} ({0} bytes)\n", .{content_size_bytes});
    }

    const output_target = try download.outputTargetFromPlan(
        gpa,
        output_plan,
        args.uri,
        response.head.content_disposition,
    );

    switch (output_target) {
        .stdout => try download.streamToWriter(
            init.io,
            gpa,
            summary,
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
                summary,
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
