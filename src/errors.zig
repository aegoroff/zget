const std = @import("std");

pub const ZgetError = error{
    HttpError,
    EmptyProxyUrl,
    UnsupportedProxyScheme,
    UnsupportedUriScheme,
    UriMissingHost,
    CertificateBundleLoadFailure,
    UnsupportedCompressionMethod,
    TlsInitializationFailed,
    InvalidTimeout,
    InvalidMaxRedirects,
    InvalidChecksum,
    InvalidValidateDigest,
    ValidateRequiresChecksum,
    ChecksumMismatch,
    OutputDirectoryNotFound,
};

pub fn message(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.HttpError => "HTTP request failed",
        error.EmptyProxyUrl => "Proxy URL is empty",
        error.UnsupportedProxyScheme => "Unsupported proxy scheme (only http and https are supported)",
        error.UnsupportedUriScheme => "Unsupported URI scheme (only http and https are supported)",
        error.UriMissingHost => "URI is missing a host name",
        error.CertificateBundleLoadFailure => "Failed to load TLS certificate bundle",
        error.UnsupportedCompressionMethod => "Unsupported Content-Encoding: compress",
        error.TlsInitializationFailed => "TLS initialization failed",
        error.InvalidTimeout => "Timeout must be a positive number of seconds",
        error.InvalidMaxRedirects => "Max redirects must be a number from 0 to 65534",
        error.InvalidChecksum => "Unsupported checksum type (only sha256 and blake3 are supported)",
        error.InvalidValidateDigest => "Validate digest must be 64 hexadecimal characters",
        error.ValidateRequiresChecksum => "--validate requires --checksum",
        error.ChecksumMismatch => "Downloaded content checksum does not match",
        error.OutputDirectoryNotFound => "Output directory does not exist",

        error.ConnectionRefused => "Connection refused",
        error.Timeout => "Connection timed out",
        error.ConnectionTimedOut => "Connection timed out",
        error.NetworkUnreachable => "Network is unreachable",
        error.HostUnreachable => "Host is unreachable",
        error.ConnectionResetByPeer => "Connection reset by peer",
        error.UnknownHostName => "Could not resolve host name",
        error.InvalidHostName => "Invalid host name in URI",
        error.UnexpectedCharacter => "Invalid URI",
        error.InvalidFormat => "Invalid URI format",
        error.InvalidPort => "Invalid port in URI",

        error.HttpChunkInvalid => "Invalid HTTP response chunk",
        error.HttpChunkTruncated => "HTTP response ended unexpectedly",
        error.HttpHeadersOversize => "HTTP response headers are too large",
        error.HttpRequestTruncated => "HTTP response headers ended unexpectedly",

        error.AccessDenied => "Permission denied",
        error.PermissionDenied => "Permission denied",
        error.FileNotFound => "File or directory not found",
        error.IsDir => "Output path is a directory",
        error.NoSpaceLeft => "No space left on device",
        error.DiskQuota => "Disk quota exceeded",
        error.OutOfMemory => "Out of memory",

        else => null,
    };
}

pub fn report(stderr: *std.Io.Writer, err: anyerror) void {
    if (message(err)) |text| {
        stderr.print("error: {s}\n", .{text}) catch {};
    } else {
        stderr.print("error: {s}\n", .{@errorName(err)}) catch {};
    }
    stderr.flush() catch {};
}

test "message maps project errors" {
    try std.testing.expectEqualStrings(
        "Unsupported URI scheme (only http and https are supported)",
        message(error.UnsupportedUriScheme).?,
    );
}

test "message maps network errors" {
    try std.testing.expectEqualStrings(
        "Connection refused",
        message(error.ConnectionRefused).?,
    );
}

test "message returns null for unknown errors" {
    const TestError = error{SomethingOdd};
    try std.testing.expect(message(TestError.SomethingOdd) == null);
}
