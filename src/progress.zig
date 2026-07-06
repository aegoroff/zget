const std = @import("std");

pub fn percent(comptime T: type, completed: T, total: T) usize {
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

const MIBS_PER_SEC: []const u8 = "MiB/sec";
const KIBS_PER_SEC: []const u8 = "KiB/sec";
const BYTES_PER_SEC: []const u8 = "bytes/sec";

pub const Tracker = struct {
    root: std.Progress.Node,
    bytes: std.Progress.Node,
    speed: std.Progress.Node,
    started_at: std.Io.Timestamp,
    read_bytes: usize = 0,

    pub fn start(io: std.Io, content_size_bytes: u64) Tracker {
        var root = std.Progress.start(io, .{ .root_name = "%", .estimated_total_items = 100 });
        const bytes = root.start("bytes", @intCast(content_size_bytes));
        const speed = root.start(MIBS_PER_SEC, 0);
        return .{
            .root = root,
            .bytes = bytes,
            .speed = speed,
            .started_at = std.Io.Clock.real.now(io),
        };
    }

    pub fn end(self: *Tracker) void {
        self.speed.end();
        self.bytes.end();
        self.root.end();
    }

    pub fn record(self: *Tracker, io: std.Io, nbytes: usize, content_size_bytes: usize) void {
        self.read_bytes += nbytes;
        const now = std.Io.Clock.real.now(io);
        const duration = self.started_at.durationTo(now);
        const elapsed: usize = @intCast(duration.toSeconds());

        if (elapsed > 0) {
            var speed = self.read_bytes / (1024 * 1024) / elapsed;
            if (speed == 0) {
                speed = self.read_bytes / 1024 / elapsed;
                if (speed == 0) {
                    speed = self.read_bytes / elapsed;
                    self.speed.setName(BYTES_PER_SEC);
                } else {
                    self.speed.setName(KIBS_PER_SEC);
                }
            } else {
                self.speed.setName(MIBS_PER_SEC);
            }
            self.speed.setCompletedItems(@intCast(speed));
        }

        self.root.setCompletedItems(percent(usize, self.read_bytes, content_size_bytes));
        self.bytes.setCompletedItems(self.read_bytes);
    }

    pub fn printSummary(self: *const Tracker, io: std.Io, stdout: *std.Io.Writer) void {
        const now = std.Io.Clock.real.now(io);
        const duration = self.started_at.durationTo(now);
        const nanos: u64 = @intCast(duration.nanoseconds);
        var micros: usize = @divTrunc(nanos, 1000);
        stdout.print("Time taken: ", .{}) catch {};
        duration.format(stdout) catch {};
        stdout.print("\n", .{}) catch {};
        if (micros == 0) {
            micros = 1;
        }
        const speed = self.read_bytes * std.time.ms_per_s * 1000 / micros;
        stdout.print("Read: {0} bytes\n", .{self.read_bytes}) catch {};
        stdout.print("Speed: {0Bi:.2}/sec\n", .{speed}) catch {};
    }
};

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
