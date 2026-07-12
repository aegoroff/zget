const std = @import("std");
const cli = @import("cli.zig");
const download = @import("download.zig");
const errors = @import("errors.zig");
const proxy = @import("proxy.zig");
const timeout = @import("timeout.zig");
const transport = @import("transport.zig");
const checksum = @import("checksum.zig");
const http = std.http;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err == error.ChecksumMismatch) {
            std.process.exit(1);
        }
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
    const io_timeout: std.Io.Timeout = if (args.timeout_seconds) |seconds|
        timeout.fromSeconds(seconds)
    else
        .none;

    const output_plan = try download.planOutput(gpa, init.io, args.output, args.uri);
    // if set -O - (that sets result to stdout like wget) then log to stderr
    const summary = if (output_plan == .stdout) stderr else stdout;
    const warnings: ?*std.Io.Writer = if (args.quiet) null else stderr;

    if (!args.quiet) {
        try summary.print("URI: {s}\n", .{args.uri_source});
    }

    const proxy_config = try proxy.Config.init(gpa, init.environ_map, args.proxy);
    var client = transport.Transport.init(
        gpa,
        init.io,
        proxy_config,
        args.timeout_seconds,
        args.no_check_certificate,
        args.max_redirects,
    );
    defer client.deinit();
    var req = try client.get(args.uri, args.headers, warnings);
    defer req.deinit();

    try req.sendBodiless();

    var header_buffer = try std.ArrayList(u8).initCapacity(gpa, 65536);
    header_buffer.expandToCapacity();
    var response = try timeout.receiveHeadWithTimeout(
        init.io,
        &req,
        header_buffer.items,
        io_timeout,
    );

    if (!args.quiet) {
        const content_type = response.head.content_type orelse "text/plain";
        try summary.print("Content-type: {s}\n", .{content_type});
    }

    if (response.head.status != http.Status.ok) {
        if (!args.quiet) {
            try summary.print("Http response: {d}\n", .{@intFromEnum(response.head.status)});
        }
        return errors.ZgetError.HttpError;
    }

    const content_size_bytes = response.head.content_length orelse 0;
    if (!args.quiet and content_size_bytes > 0) {
        try summary.print("Content-size: {0Bi:.2} ({0} bytes)\n", .{content_size_bytes});
    }

    const output_target = try download.outputTargetFromPlan(
        gpa,
        output_plan,
        args.uri,
        response.head.content_disposition,
    );

    const checksum_opts = checksum.Options{
        .algorithm = args.checksum,
        .expected = args.validate_digest,
        .quiet = args.quiet,
    };

    switch (output_target) {
        .stdout => try download.streamToWriter(
            init.io,
            gpa,
            summary,
            &response,
            stdout,
            content_size_bytes,
            io_timeout,
            checksum_opts,
            warnings,
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
                io_timeout,
                checksum_opts,
                warnings,
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
    _ = @import("timeout.zig");
    _ = @import("checksum.zig");
    _ = @import("tls_connect.zig");
}
