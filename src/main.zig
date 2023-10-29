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
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source = if (res.positionals.len == 1) res.positionals[0] else {
        return clap.help(stdout, clap.Help, &params, .{});
    };

    try stdout.print("URI: {s}\n", .{source});
    const uri = try std.Uri.parse(source);

    const file_name = std.fs.path.basename(uri.path);
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
    var headers = std.http.Headers{ .allocator = arena.allocator() };
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

    var req = try http_client.request(.GET, uri, headers, .{ .max_redirects = 16 });
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

    const file_options = .{ .read = false };
    var file = if (std.mem.eql(u8, target, file_name)) try std.fs.cwd().createFile(file_name, file_options) else try std.fs.createFileAbsolute(target, file_options);
    defer file.close();

    var buf = try arena.allocator().alloc(u8, 16 * 4096);
    const max_errors = 10;
    var errors: i16 = 0;

    var progresser = try Progresser.init(content_size_bytes);
    defer progresser.end();
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
        progresser.bump(read);
        if (read == 0) {
            break;
        }
        try file.writeAll(buf[0..read]);
    }
}

const ZgetError = error{ResultFileNotSet};

const Progresser = struct {
    percent_progress: *std.Progress.Node,
    bytes_progress: std.Progress.Node,
    speed_progress: std.Progress.Node,
    timer: std.time.Timer,
    progress: std.Progress,
    completed_bytes: usize,
    total_bytes: usize,

    fn init(total_bytes: usize) !Progresser {
        var progress = std.Progress{};
        var percent_progress = progress.start("Downloading", 100);
        var bytes_progress = percent_progress.start("Read", total_bytes);
        var speed_progress = bytes_progress.start("Speed", 0);
        var result = Progresser{
            .total_bytes = total_bytes,
            .completed_bytes = 0,
            .progress = progress,
            .percent_progress = percent_progress,
            .bytes_progress = bytes_progress,
            .speed_progress = speed_progress,
            .timer = try std.time.Timer.start(),
        };

        result.percent_progress.setUnit(" %");
        result.bytes_progress.setUnit(" bytes");
        result.speed_progress.setUnit(" KiB/sec");
        return result;
    }

    fn bump(self: *Progresser, portion: usize) void {
        self.completed_bytes += portion;
        const elapsed = self.timer.read() / 1000000000;
        if (elapsed > 0) {
            const speed = (self.completed_bytes / 1024) / elapsed;
            self.speed_progress.setCompletedItems(speed);
        }

        self.percent_progress.setCompletedItems(percent(usize, self.completed_bytes, self.total_bytes));
        self.bytes_progress.setCompletedItems(self.completed_bytes);
        self.progress.maybeRefresh();
    }

    fn end(self: *Progresser) void {
        self.bytes_progress.end();
        self.speed_progress.end();
        self.percent_progress.end();
    }
};

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
