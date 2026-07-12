const std = @import("std");
const errors = @import("errors.zig");

pub const Digest = [32]u8;
pub const hash_buf_len = 16 * 4096;

pub const Algorithm = enum {
    sha256,
    blake3,
};

pub const Stream = struct {
    algorithm: ?Algorithm,
    dest: *std.Io.Writer,
    sha256_writer: ?std.Io.Writer.Hashed(std.crypto.hash.sha2.Sha256) = null,
    blake3_writer: ?std.Io.Writer.Hashed(std.crypto.hash.Blake3) = null,

    pub fn init(
        dest: *std.Io.Writer,
        hash_buf: []u8,
        quiet: bool,
        algorithm: ?Algorithm,
    ) Stream {
        var stream = Stream{
            .algorithm = if (quiet) null else algorithm,
            .dest = dest,
        };
        if (stream.algorithm) |alg| {
            switch (alg) {
                .sha256 => {
                    stream.sha256_writer = std.Io.Writer.hashed(
                        dest,
                        std.crypto.hash.sha2.Sha256.init(.{}),
                        hash_buf,
                    );
                },
                .blake3 => {
                    stream.blake3_writer = std.Io.Writer.hashed(
                        dest,
                        std.crypto.hash.Blake3.init(.{}),
                        hash_buf,
                    );
                },
            }
        }
        return stream;
    }

    pub fn writer(self: *Stream) *std.Io.Writer {
        if (self.algorithm) |alg| {
            switch (alg) {
                .sha256 => if (self.sha256_writer) |*hashing| return &hashing.writer,
                .blake3 => if (self.blake3_writer) |*hashing| return &hashing.writer,
            }
        }
        return self.dest;
    }

    pub fn finish(self: *Stream, summary: *std.Io.Writer) !void {
        const alg = self.algorithm orelse return;
        switch (alg) {
            .sha256 => if (self.sha256_writer) |*hashing| {
                try hashing.writer.flush();
                try print(summary, .sha256, hashing.hasher.finalResult());
            },
            .blake3 => if (self.blake3_writer) |*hashing| {
                try hashing.writer.flush();
                try print(summary, .blake3, digestFromBlake3(&hashing.hasher));
            },
        }
    }
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

    var stream = Stream.init(&dest, hash_buf[0..], true, .sha256);
    try std.testing.expect(stream.writer() == &dest);
    try stream.finish(&dest);
}

test "Stream hashes written bytes" {
    var dest_buffer: [64]u8 = undefined;
    var dest = std.Io.Writer.fixed(&dest_buffer);
    var summary_buffer: [128]u8 = undefined;
    var summary = std.Io.Writer.fixed(&summary_buffer);
    var hash_buf: [hash_buf_len]u8 = undefined;

    var stream = Stream.init(&dest, hash_buf[0..], false, .sha256);
    const writer = stream.writer();
    try writer.writeAll("abc");
    try stream.finish(&summary);

    try std.testing.expectEqualStrings("abc", dest.buffered());
    try std.testing.expectEqualStrings(
        "SHA256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n",
        summary.buffered(),
    );
}
