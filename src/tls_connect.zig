const std = @import("std");
const http = std.http;
const builtin = @import("builtin");

const HostName = std.Io.net.HostName;
const Io = std.Io;

/// Mirrors `http.Client.Connection.Tls` memory layout so std can manage the connection.
const TlsConnection = struct {
    client: std.crypto.tls.Client,
    connection: http.Client.Connection,
};

pub const VerifyMode = enum {
    strict,
    insecure,
};

pub fn tlsClientOptions(
    http_client: *http.Client,
    remote_host: []const u8,
    mode: VerifyMode,
    read_buffer: []u8,
    write_buffer: []u8,
    entropy: *const [std.crypto.tls.Client.Options.entropy_len]u8,
) std.crypto.tls.Client.Options {
    return switch (mode) {
        .strict => .{
            .host = .{ .explicit = remote_host },
            .ca = .{ .bundle = .{
                .gpa = http_client.allocator,
                .io = http_client.io,
                .lock = &http_client.ca_bundle_lock,
                .bundle = &http_client.ca_bundle,
            } },
            .ssl_key_log = http_client.ssl_key_log,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .entropy = entropy,
            .realtime_now = http_client.now.?,
            .allow_truncation_attacks = true,
        },
        .insecure => .{
            // Keep SNI for servers like GitHub; skip CA chain verification only.
            .host = .{ .explicit = remote_host },
            .ca = .no_verification,
            .ssl_key_log = http_client.ssl_key_log,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .entropy = entropy,
            .realtime_now = http_client.now.?,
            .allow_truncation_attacks = true,
        },
    };
}

fn allocLen(http_client: *http.Client, host_len: usize) usize {
    const tls_read_buffer_len = http_client.tls_buffer_size + http_client.read_buffer_size;
    return @sizeOf(TlsConnection) + host_len + tls_read_buffer_len + http_client.tls_buffer_size +
        http_client.write_buffer_size + http_client.tls_buffer_size;
}

pub fn createInsecureConnection(
    http_client: *http.Client,
    remote_host: HostName,
    port: u16,
) http.Client.ConnectTcpError!*http.Client.Connection {
    const io = http_client.io;
    const stream = try remote_host.connect(io, port, .{ .mode = .stream });
    errdefer stream.close(io);
    return createTlsConnection(http_client, remote_host, port, stream, .insecure);
}

pub fn createTlsConnection(
    http_client: *http.Client,
    remote_host: HostName,
    port: u16,
    stream: std.Io.net.Stream,
    mode: VerifyMode,
) http.Client.ConnectTcpError!*http.Client.Connection {
    if (http.Client.disable_tls) return error.TlsInitializationFailed;

    const io = http_client.io;
    const gpa = http_client.allocator;
    const alloc_size = allocLen(http_client, remote_host.bytes.len);
    const base = try gpa.alignedAlloc(u8, .of(TlsConnection), alloc_size);
    errdefer gpa.free(base);

    const host_buffer = base[@sizeOf(TlsConnection)..][0..remote_host.bytes.len];
    const tls_read_buffer_len = http_client.tls_buffer_size + http_client.read_buffer_size;
    const tls_read_buffer = host_buffer.ptr[host_buffer.len..][0..tls_read_buffer_len];
    const tls_write_buffer = tls_read_buffer.ptr[tls_read_buffer.len..][0..http_client.tls_buffer_size];
    const socket_write_buffer = tls_write_buffer.ptr[tls_write_buffer.len..][0..http_client.write_buffer_size];
    const socket_read_buffer = socket_write_buffer.ptr[socket_write_buffer.len..][0..http_client.tls_buffer_size];
    std.debug.assert(base.ptr + alloc_size == socket_read_buffer.ptr + socket_read_buffer.len);
    @memcpy(host_buffer, remote_host.bytes);

    const tls: *TlsConnection = @ptrCast(base);
    var random_buffer: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&random_buffer);

    tls.connection = .{
        .client = http_client,
        .stream_writer = stream.writer(io, tls_write_buffer),
        .stream_reader = stream.reader(io, socket_read_buffer),
        .pool_node = .{},
        .port = port,
        .host_len = @intCast(remote_host.bytes.len),
        .proxied = false,
        .closing = false,
        .protocol = .tls,
    };

    tls.client = try initTlsClient(
        &tls.connection.stream_reader.interface,
        &tls.connection.stream_writer.interface,
        tlsClientOptions(
            http_client,
            remote_host.bytes,
            mode,
            tls_read_buffer,
            socket_write_buffer,
            &random_buffer,
        ),
    );

    http_client.connection_pool.addUsed(io, &tls.connection);
    return &tls.connection;
}

fn initTlsClient(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: std.crypto.tls.Client.Options,
) http.Client.ConnectTcpError!std.crypto.tls.Client {
    return std.crypto.tls.Client.init(reader, writer, options) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        else => error.TlsInitializationFailed,
    };
}

pub fn warnInsecureTls(writer: *std.Io.Writer) void {
    writer.print("warning: TLS certificate verification is disabled\n", .{}) catch {};
}

pub fn warnProxyInsecureUnsupported(writer: *std.Io.Writer) void {
    writer.print(
        "warning: --no-check-certificate is not supported with an HTTPS proxy; certificate verification remains enabled\n",
        .{},
    ) catch {};
}

test "tlsClientOptions uses no verification in insecure mode" {
    if (builtin.os.tag == .freestanding) return error.SkipZigTest;

    var http_client = http.Client{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .now = std.Io.Clock.real.now(std.testing.io),
    };
    defer http_client.deinit();

    var read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    @memset(&entropy, 0xAA);

    const options = tlsClientOptions(
        &http_client,
        "example.com",
        .insecure,
        &read_buffer,
        &write_buffer,
        &entropy,
    );

    switch (options.host) {
        .explicit => |host| try std.testing.expectEqualStrings("example.com", host),
        else => try std.testing.expect(false),
    }
    try std.testing.expect(options.ca == .no_verification);
}

test "tlsClientOptions verifies host and ca bundle in strict mode" {
    if (builtin.os.tag == .freestanding) return error.SkipZigTest;

    var http_client = http.Client{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .now = std.Io.Clock.real.now(std.testing.io),
    };
    defer http_client.deinit();

    var read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    @memset(&entropy, 0xAA);

    const options = tlsClientOptions(
        &http_client,
        "example.com",
        .strict,
        &read_buffer,
        &write_buffer,
        &entropy,
    );

    switch (options.host) {
        .explicit => |host| try std.testing.expectEqualStrings("example.com", host),
        else => try std.testing.expect(false),
    }
    switch (options.ca) {
        .bundle => |bundle| try std.testing.expect(bundle.bundle == &http_client.ca_bundle),
        else => try std.testing.expect(false),
    }
}
