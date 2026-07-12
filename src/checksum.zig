const std = @import("std");
const errors = @import("errors.zig");

pub const Digest = [32]u8;
pub const hash_buf_len = 16 * 4096;
pub const digest_hex_len = 64;

pub const Algorithm = enum {
    sha256,
    blake3,
};

pub const Options = struct {
    algorithm: ?Algorithm = null,
    expected: ?Digest = null,
    quiet: bool = false,

    pub fn shouldHash(self: Options) bool {
        if (self.algorithm == null) return false;
        return !self.quiet or self.expected != null;
    }

    pub fn shouldPrint(self: Options) bool {
        return self.algorithm != null and !self.quiet;
    }
};

const Sha256Hashed = std.Io.Writer.Hashed(std.crypto.hash.sha2.Sha256);
const Blake3Hashed = std.Io.Writer.Hashed(std.crypto.hash.Blake3);

const HashedWriter = union(Algorithm) {
    sha256: Sha256Hashed,
    blake3: Blake3Hashed,

    fn writer(self: *HashedWriter) *std.Io.Writer {
        return switch (self.*) {
            .sha256 => |*hashing| &hashing.writer,
            .blake3 => |*hashing| &hashing.writer,
        };
    }

    fn finalize(self: *HashedWriter) !Digest {
        return switch (self.*) {
            .sha256 => |*hashing| blk: {
                try hashing.writer.flush();
                break :blk hashing.hasher.finalResult();
            },
            .blake3 => |*hashing| blk: {
                try hashing.writer.flush();
                break :blk digestFromBlake3(&hashing.hasher);
            },
        };
    }
};

pub const Stream = struct {
    options: Options,
    dest: *std.Io.Writer,
    hashed: ?HashedWriter = null,

    pub fn init(dest: *std.Io.Writer, hash_buf: []u8, options: Options) Stream {
        var stream = Stream{
            .options = options,
            .dest = dest,
        };
        if (options.shouldHash()) {
            const alg = options.algorithm.?;
            stream.hashed = switch (alg) {
                .sha256 => .{
                    .sha256 = std.Io.Writer.hashed(
                        dest,
                        std.crypto.hash.sha2.Sha256.init(.{}),
                        hash_buf,
                    ),
                },
                .blake3 => .{
                    .blake3 = std.Io.Writer.hashed(
                        dest,
                        std.crypto.hash.Blake3.init(.{}),
                        hash_buf,
                    ),
                },
            };
        }
        return stream;
    }

    pub fn writer(self: *Stream) *std.Io.Writer {
        if (self.hashed) |*active| return active.writer();
        return self.dest;
    }

    pub fn finish(self: *Stream, summary: *std.Io.Writer, warnings: ?*std.Io.Writer) !void {
        const alg = self.options.algorithm orelse return;
        if (!self.options.shouldHash()) return;

        const digest = try self.hashed.?.finalize();

        if (self.options.expected) |expected| {
            if (!std.mem.eql(u8, &expected, &digest)) {
                if (warnings) |warn_writer| warnMismatch(warn_writer, alg, expected, digest);
                return error.ChecksumMismatch;
            }
        }

        if (self.options.shouldPrint()) {
            try print(summary, alg, digest);
        }
    }
};

pub fn parse(raw: []const u8) errors.ZgetError!Algorithm {
    if (std.ascii.eqlIgnoreCase(raw, "sha256")) return .sha256;
    if (std.ascii.eqlIgnoreCase(raw, "blake3")) return .blake3;
    return error.InvalidChecksum;
}

pub fn parseDigest(raw: []const u8) errors.ZgetError!Digest {
    if (raw.len != digest_hex_len) return error.InvalidValidateDigest;
    var digest: Digest = undefined;
    for (0..@sizeOf(Digest)) |i| {
        digest[i] = std.fmt.parseInt(u8, raw[i * 2 ..][0..2], 16) catch return error.InvalidValidateDigest;
    }
    return digest;
}

pub fn print(writer: *std.Io.Writer, algorithm: Algorithm, digest: Digest) !void {
    try writer.print("{s}: ", .{label(algorithm)});
    try writeHex(writer, digest);
    try writer.print("\n", .{});
}

pub fn warnMismatch(
    writer: *std.Io.Writer,
    algorithm: Algorithm,
    expected: Digest,
    actual: Digest,
) void {
    writer.print("warning: {s} checksum mismatch (expected ", .{label(algorithm)}) catch {};
    writeHex(writer, expected) catch {};
    writer.print(", got ", .{}) catch {};
    writeHex(writer, actual) catch {};
    writer.print(")\n", .{}) catch {};
}

fn label(algorithm: Algorithm) []const u8 {
    return switch (algorithm) {
        .sha256 => "SHA256",
        .blake3 => "BLAKE3",
    };
}

fn writeHex(writer: *std.Io.Writer, digest: Digest) !void {
    for (digest) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
}

fn digestFromBlake3(hasher: *const std.crypto.hash.Blake3) Digest {
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

test "parseDigest accepts lowercase and uppercase hex" {
    const hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const expected = try parseDigest(hex);
    var upper_hex: [digest_hex_len]u8 = undefined;
    for (hex, 0..) |c, i| {
        upper_hex[i] = std.ascii.toUpper(c);
    }
    try std.testing.expectEqual(expected, try parseDigest(hex));
    try std.testing.expectEqual(expected, try parseDigest(upper_hex[0..]));
}

test "parseDigest rejects invalid values" {
    try std.testing.expectError(error.InvalidValidateDigest, parseDigest("abc"));
    try std.testing.expectError(error.InvalidValidateDigest, parseDigest("g" ** 64));
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

test "Stream passes through dest when checksum is disabled" {
    var dest_buffer: [16]u8 = undefined;
    var dest = std.Io.Writer.fixed(&dest_buffer);
    var hash_buf: [hash_buf_len]u8 = undefined;

    var stream = Stream.init(&dest, hash_buf[0..], .{
        .algorithm = .sha256,
        .quiet = true,
    });
    try std.testing.expect(stream.writer() == &dest);
    try stream.finish(&dest, null);
}

test "Stream hashes written bytes" {
    var dest_buffer: [64]u8 = undefined;
    var dest = std.Io.Writer.fixed(&dest_buffer);
    var summary_buffer: [128]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_buffer);
    var hash_buf: [hash_buf_len]u8 = undefined;

    var stream = Stream.init(&dest, hash_buf[0..], .{ .algorithm = .sha256 });
    const writer = stream.writer();
    try writer.writeAll("abc");
    try stream.finish(&summary, null);

    try std.testing.expectEqualStrings("abc", dest.buffered());
    try std.testing.expectEqualStrings(
        "SHA256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n",
        summary.buffered(),
    );
}

test "Stream validates digest and warns on mismatch" {
    var dest_buffer: [64]u8 = undefined;
    var dest = std.Io.Writer.fixed(&dest_buffer);
    var summary_buffer: [128]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_buffer);
    var warning_buffer: [256]u8 = undefined;
    var warnings = std.Io.Writer.fixed(&warning_buffer);
    var hash_buf: [hash_buf_len]u8 = undefined;

    const expected = [_]u8{0} ** 32;
    var stream = Stream.init(&dest, hash_buf[0..], .{
        .algorithm = .sha256,
        .expected = expected,
    });
    try stream.writer().writeAll("abc");
    try std.testing.expectError(error.ChecksumMismatch, stream.finish(&summary, &warnings));

    try std.testing.expect(std.mem.startsWith(u8, warnings.buffered(), "warning: SHA256 checksum mismatch"));
}

test "Stream validates digest quietly and fails without output on mismatch" {
    var dest_buffer: [64]u8 = undefined;
    var dest = std.Io.Writer.fixed(&dest_buffer);
    var summary_buffer: [128]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_buffer);
    var hash_buf: [hash_buf_len]u8 = undefined;

    const expected = [_]u8{0} ** 32;
    var stream = Stream.init(&dest, hash_buf[0..], .{
        .algorithm = .sha256,
        .expected = expected,
        .quiet = true,
    });
    try stream.writer().writeAll("abc");
    try std.testing.expectError(error.ChecksumMismatch, stream.finish(&summary, null));

    try std.testing.expectEqualStrings("", summary.buffered());
}

test "Stream validates matching digest quietly without output" {
    var dest_buffer: [64]u8 = undefined;
    var dest = std.Io.Writer.fixed(&dest_buffer);
    var summary_buffer: [128]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_buffer);
    var hash_buf: [hash_buf_len]u8 = undefined;

    const expected = try parseDigest("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    var stream = Stream.init(&dest, hash_buf[0..], .{
        .algorithm = .sha256,
        .expected = expected,
        .quiet = true,
    });
    try stream.writer().writeAll("abc");
    try stream.finish(&summary, null);

    try std.testing.expectEqualStrings("", summary.buffered());
}
