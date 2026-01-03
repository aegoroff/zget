const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");
const transport = @import("transport.zig");
const http = std.http;

pub fn main() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer {
        stdout.flush() catch {};
    }

    const allocator = std.heap.c_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const query = std.Target.Query.fromTarget(&builtin.target);

    const app_descr_template =
        \\Zget {s} ({s}), a non-interactive network retriever implemented in Zig
        \\Copyright (C) 2025 Alexander Egorov. All rights reserved.
    ;
    const app_descr = try std.fmt.allocPrint(
        arena.allocator(),
        app_descr_template,
        .{ build_options.version, @tagName(query.cpu_arch.?) },
    );

    var app = yazap.App.init(arena.allocator(), "zget", app_descr);
    defer app.deinit();

    var root_cmd = app.rootCommand();
    root_cmd.setProperty(.help_on_empty_args);
    root_cmd.setProperty(.positional_arg_required);
    const headers_opt = yazap.Arg.multiValuesOption(
        "header",
        'H',
        "Additional HTTP header(s)",
        512,
    );
    const uri_opt = yazap.Arg.positional("URI", "Uri to download", null);

    var output_opt = yazap.Arg.singleValueOption(
        "output",
        'O',
        "Path the result will saved to. If it's a directory file name will be get from URI file name part",
    );
    output_opt.setValuePlaceholder("STRING");
    output_opt.setProperty(.takes_value);

    try root_cmd.addArg(headers_opt);
    try root_cmd.addArg(output_opt);
    try root_cmd.addArg(uri_opt);

    const argv = try std.process.argsAlloc(arena.allocator());
    const matches = try app.parseFrom(argv[1..]);

    const source = matches.getSingleValue("URI");

    try stdout.print("URI: {s}\n", .{source.?});
    const uri = try std.Uri.parse(source.?);

    const file_name = std.fs.path.basename(uri.path.percent_encoded);
    // Calculate target file path
    var target = matches.getSingleValue("output") orelse file_name;

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

    var client = transport.Transport.init(arena.allocator());

    const headers = matches.getMultiValues("header") orelse &[_][]const u8{};
    var req = try client.get(uri, headers);

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
        try stdout.print("Content-size: {0Bi:.2} ({0} bytes)\n", .{content_size_bytes});
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
        const speed = read_bytes / (elapsed / 1000); // bytes / per microsecond
        stdout.print("Read: {0} bytes\n", .{read_bytes}) catch {};
        stdout.print("Speed: {0Bi:.2}/sec\n", .{speed * 1000000}) catch {};
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

fn percent(comptime T: type, completed: T, total: T) usize {
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

test {
    @import("std").testing.refAllDecls(@This());
}
