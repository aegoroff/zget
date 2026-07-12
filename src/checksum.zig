const std = @import("std");
const errors = @import("errors.zig");

pub const Algorithm = enum {
    sha256,
};

pub fn parse(raw: []const u8) errors.ZgetError!Algorithm {
    if (std.ascii.eqlIgnoreCase(raw, "sha256")) return .sha256;
    return error.InvalidChecksum;
}

pub fn printSha256(writer: *std.Io.Writer, digest: [32]u8) !void {
    try writer.print("SHA256: ", .{});
    for (digest) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.print("\n", .{});
}

test "parse accepts sha256 case-insensitively" {
    try std.testing.expectEqual(Algorithm.sha256, try parse("sha256"));
    try std.testing.expectEqual(Algorithm.sha256, try parse("SHA256"));
}

test "parse rejects unsupported algorithms" {
    try std.testing.expectError(error.InvalidChecksum, parse("md5"));
    try std.testing.expectError(error.InvalidChecksum, parse(""));
}

test "printSha256 writes lowercase hex digest" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var digest: [32]u8 = undefined;
    @memset(&digest, 0);
    digest[0] = 0xab;
    digest[31] = 0xcd;

    try printSha256(&writer, digest);
    try std.testing.expectEqualStrings(
        "SHA256: ab000000000000000000000000000000000000000000000000000000000000cd\n",
        writer.buffered(),
    );
}
