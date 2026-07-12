const std = @import("std");
const errors = @import("errors.zig");

pub const Digest = [32]u8;

pub const Algorithm = enum {
    sha256,
    blake3,
};

pub fn parse(raw: []const u8) errors.ZgetError!Algorithm {
    if (std.ascii.eqlIgnoreCase(raw, "sha256")) return .sha256;
    if (std.ascii.eqlIgnoreCase(raw, "blake3")) return .blake3;
    return error.InvalidChecksum;
}

pub fn print(writer: *std.Io.Writer, algorithm: Algorithm, digest: Digest) !void {
    const label = switch (algorithm) {
        .sha256 => "SHA256",
        .blake3 => "BLAKE3",
    };
    try writer.print("{s}: ", .{label});
    for (digest) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.print("\n", .{});
}

pub fn digestFromBlake3(hasher: *const std.crypto.hash.Blake3) Digest {
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

test "parse accepts supported algorithms case-insensitively" {
    try std.testing.expectEqual(Algorithm.sha256, try parse("sha256"));
    try std.testing.expectEqual(Algorithm.sha256, try parse("SHA256"));
    try std.testing.expectEqual(Algorithm.blake3, try parse("blake3"));
    try std.testing.expectEqual(Algorithm.blake3, try parse("BLAKE3"));
}

test "parse rejects unsupported algorithms" {
    try std.testing.expectError(error.InvalidChecksum, parse("md5"));
    try std.testing.expectError(error.InvalidChecksum, parse(""));
}

test "print writes lowercase hex digest" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    var digest: Digest = undefined;
    @memset(&digest, 0);
    digest[0] = 0xab;
    digest[31] = 0xcd;

    try print(&writer, .sha256, digest);
    try std.testing.expectEqualStrings(
        "SHA256: ab000000000000000000000000000000000000000000000000000000000000cd\n",
        writer.buffered(),
    );

    writer.end = 0;
    try print(&writer, .blake3, digest);
    try std.testing.expectEqualStrings(
        "BLAKE3: ab000000000000000000000000000000000000000000000000000000000000cd\n",
        writer.buffered(),
    );
}
