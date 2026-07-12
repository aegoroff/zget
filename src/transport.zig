pub const Transport = @This();
const std = @import("std");
const http = std.http;
const builtin = @import("builtin");
const build_options = @import("build_options");
const proxy = @import("proxy.zig");

const timeout = @import("timeout.zig");

const HostName = std.Io.net.HostName;
const Io = std.Io;

const DEFAULT_USER_AGENT = std.fmt.comptimePrint("zget/{s}", .{build_options.version});

/// Mirrors `http.Client.Connection.Tls` memory layout so std can manage the connection.
const TlsConnection = struct {
    client: std.crypto.tls.Client,
    connection: http.Client.Connection,
};

const TlsVerifyMode = enum {
    strict,
    insecure,
};

gpa: std.mem.Allocator,
http_client: std.http.Client,
extra_headers: std.ArrayList(http.Header),
proxy_config: proxy.Config,
io_timeout: std.Io.Timeout,
no_check_certificate: bool,
redirect_behavior: http.Client.Request.RedirectBehavior,

pub fn init(
    gpa: std.mem.Allocator,
    io: std.Io,
    proxy_config: proxy.Config,
    timeout_seconds: ?u32,
    no_check_certificate: bool,
    max_redirects: u16,
) Transport {
    var http_client = std.http.Client{
        .allocator = gpa,
        .io = io,
    };
    proxy_config.apply(&http_client);

    const io_timeout: std.Io.Timeout = if (timeout_seconds) |seconds|
        timeout.fromSeconds(seconds)
    else
        .none;

    return Transport{
        .gpa = gpa,
        .http_client = http_client,
        .extra_headers = .empty,
        .proxy_config = proxy_config,
        .io_timeout = io_timeout,
        .no_check_certificate = no_check_certificate,
        .redirect_behavior = http.Client.Request.RedirectBehavior.init(max_redirects),
    };
}

pub fn deinit(self: *Transport) void {
    self.extra_headers.deinit(self.gpa);
    self.http_client.deinit();
}

pub fn get(self: *Transport, uri: std.Uri, headers: []const []const u8, warnings: ?*std.Io.Writer) http.Client.RequestError!http.Client.Request {
    if (self.no_check_certificate) {
        if (warnings) |writer| warnInsecureTls(writer);
    }
    try ensureTlsReady(&self.http_client);

    const host = try uri.getHostAlloc(self.gpa);
    if (self.proxy_config.shouldBypassProxy(host.bytes)) {
        self.http_client.http_proxy = null;
        self.http_client.https_proxy = null;
    } else {
        self.proxy_config.apply(&self.http_client);
    }

    const request_options = blk: {
        self.extra_headers.clearRetainingCapacity();
        var user_agent: http.Client.Request.Headers.Value = .{ .override = DEFAULT_USER_AGENT };
        for (headers) |s| {
            if (parseHeader(s)) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
                    user_agent = .omit;
                }
                try self.extra_headers.append(self.gpa, header);
            } else if (warnings) |writer| {
                warnIgnoredHeader(writer, s);
            }
        }

        break :blk http.Client.RequestOptions{
            .redirect_behavior = self.redirect_behavior,
            .extra_headers = self.extra_headers.items,
            .headers = .{
                .user_agent = user_agent,
            },
            .connection = try acquireInsecureConnection(self, uri, host, warnings),
        };
    };

    return timeout.request(&self.http_client, .GET, uri, request_options, self.io_timeout);
}

fn acquireInsecureConnection(
    self: *Transport,
    uri: std.Uri,
    host: HostName,
    warnings: ?*std.Io.Writer,
) http.Client.RequestError!?*http.Client.Connection {
    if (!self.no_check_certificate) return null;

    const protocol = http.Client.Protocol.fromUri(uri) orelse return null;
    if (protocol != .tls) return null;

    if (self.http_client.https_proxy != null or self.http_client.http_proxy != null) {
        if (warnings) |writer| warnProxyInsecureUnsupported(writer);
        return null;
    }

    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
    return insecureTlsConnectionWithTimeout(
        &self.http_client,
        host,
        port,
        self.io_timeout,
    );
}

fn insecureTlsConnectionWithTimeout(
    http_client: *http.Client,
    host: HostName,
    port: u16,
    io_timeout: Io.Timeout,
) (http.Client.ConnectTcpError || error{Timeout})!*http.Client.Connection {
    if (io_timeout == .none) return createInsecureConnection(http_client, host, port);

    const io = http_client.io;
    const SelectResult = union(enum) {
        ready: http.Client.ConnectTcpError!*http.Client.Connection,
        expired: void,
    };

    var select_buffer: [2]SelectResult = undefined;
    var select = Io.Select(SelectResult).init(io, &select_buffer);
    select.async(.ready, createInsecureConnection, .{ http_client, host, port });
    select.async(.expired, sleepForTimeout, .{ io, io_timeout });

    const first = try select.await();
    switch (first) {
        .ready => |result| {
            select.cancelDiscard();
            return try result;
        },
        .expired => {
            _ = select.cancel();
            return error.Timeout;
        },
    }
}

fn sleepForTimeout(io: Io, io_timeout: Io.Timeout) void {
    Io.Timeout.sleep(io_timeout, io) catch {};
}

fn tlsClientOptions(
    http_client: *http.Client,
    remote_host: []const u8,
    mode: TlsVerifyMode,
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

fn tlsAllocLen(http_client: *http.Client, host_len: usize) usize {
    const tls_read_buffer_len = http_client.tls_buffer_size + http_client.read_buffer_size;
    return @sizeOf(TlsConnection) + host_len + tls_read_buffer_len + http_client.tls_buffer_size +
        http_client.write_buffer_size + http_client.tls_buffer_size;
}

fn createInsecureConnection(
    http_client: *http.Client,
    remote_host: HostName,
    port: u16,
) http.Client.ConnectTcpError!*http.Client.Connection {
    const io = http_client.io;
    const stream = try remote_host.connect(io, port, .{ .mode = .stream });
    errdefer stream.close(io);
    return createTlsConnection(http_client, remote_host, port, stream, .insecure);
}

fn createTlsConnection(
    http_client: *http.Client,
    remote_host: HostName,
    port: u16,
    stream: std.Io.net.Stream,
    mode: TlsVerifyMode,
) http.Client.ConnectTcpError!*http.Client.Connection {
    if (http.Client.disable_tls) return error.TlsInitializationFailed;

    const io = http_client.io;
    const gpa = http_client.allocator;
    const alloc_size = tlsAllocLen(http_client, remote_host.bytes.len);
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

fn warnInsecureTls(writer: *std.Io.Writer) void {
    writer.print("warning: TLS certificate verification is disabled\n", .{}) catch {};
}

fn warnProxyInsecureUnsupported(writer: *std.Io.Writer) void {
    writer.print(
        "warning: --no-check-certificate is not supported with an HTTPS proxy; certificate verification remains enabled\n",
        .{},
    ) catch {};
}

fn ensureTlsReady(client: *http.Client) !void {
    if (http.Client.disable_tls) return;

    const io = client.io;
    {
        try client.ca_bundle_lock.lockShared(io);
        defer client.ca_bundle_lock.unlockShared(io);
        if (client.now != null) return;
    }

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => return error.CertificateBundleLoadFailure,
    };
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

fn parseHeader(raw: []const u8) ?http.Header {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return null;
    const name = std.mem.trim(u8, raw[0..colon], " ");
    const value = std.mem.trim(u8, raw[colon + 1 ..], " ");
    if (name.len == 0 or value.len == 0) return null;
    return .{ .name = name, .value = value };
}

pub fn warnIgnoredHeader(writer: *std.Io.Writer, raw: []const u8) void {
    writer.print("warning: ignoring malformed header: {s}\n", .{raw}) catch {};
}

test "warnIgnoredHeader writes warning" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    warnIgnoredHeader(&writer, "BadHeader");
    try std.testing.expectEqualStrings("warning: ignoring malformed header: BadHeader\n", writer.buffered());
}

test "parseHeader simple" {
    const header = parseHeader("User-Agent: zget/1.0").?;
    try std.testing.expectEqualStrings("User-Agent", header.name);
    try std.testing.expectEqualStrings("zget/1.0", header.value);
}

test "parseHeader trims whitespace" {
    const header = parseHeader("  Authorization :  Bearer token  ").?;
    try std.testing.expectEqualStrings("Authorization", header.name);
    try std.testing.expectEqualStrings("Bearer token", header.value);
}

test "parseHeader value with colon" {
    const header = parseHeader("Authorization: Bearer xxx:yyy").?;
    try std.testing.expectEqualStrings("Authorization", header.name);
    try std.testing.expectEqualStrings("Bearer xxx:yyy", header.value);
}

test "parseHeader missing colon" {
    try std.testing.expect(parseHeader("NoColonHere") == null);
}

test "parseHeader empty value" {
    try std.testing.expect(parseHeader("Header-Name:") == null);
}

test "default user agent includes app name and version" {
    try std.testing.expectEqualStrings("zget/" ++ build_options.version, DEFAULT_USER_AGENT);
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
