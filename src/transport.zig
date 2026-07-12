pub const Transport = @This();
const std = @import("std");
const http = std.http;
const build_options = @import("build_options");
const proxy = @import("proxy.zig");

const MAX_REDIRECTS = 10;
const DEFAULT_REDIRECT_BEHAVIOR = http.Client.Request.RedirectBehavior.init(MAX_REDIRECTS);
const DEFAULT_USER_AGENT = std.fmt.comptimePrint("zget/{s}", .{build_options.version});

gpa: std.mem.Allocator,
http_client: std.http.Client,
extra_headers: std.ArrayList(http.Header),
proxy_config: proxy.Config,

pub fn init(gpa: std.mem.Allocator, io: std.Io, proxy_config: proxy.Config) Transport {
    var http_client = std.http.Client{
        .allocator = gpa,
        .io = io,
    };
    proxy_config.apply(&http_client);

    return Transport{
        .gpa = gpa,
        .http_client = http_client,
        .extra_headers = .empty,
        .proxy_config = proxy_config,
    };
}

pub fn deinit(self: *Transport) void {
    self.extra_headers.deinit(self.gpa);
    self.http_client.deinit();
}

pub fn get(self: *Transport, uri: std.Uri, headers: []const []const u8, warnings: *std.Io.Writer) http.Client.RequestError!http.Client.Request {
    try ensureTlsReady(&self.http_client);

    const host = try uri.getHostAlloc(self.gpa);
    if (self.proxy_config.shouldBypassProxy(host.bytes)) {
        self.http_client.http_proxy = null;
        self.http_client.https_proxy = null;
    } else {
        self.proxy_config.apply(&self.http_client);
    }

    self.extra_headers.clearRetainingCapacity();
    var user_agent: http.Client.Request.Headers.Value = .{ .override = DEFAULT_USER_AGENT };
    for (headers) |s| {
        if (parseHeader(s)) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "user-agent")) {
                user_agent = .omit;
            }
            try self.extra_headers.append(self.gpa, header);
        } else {
            warnIgnoredHeader(warnings, s);
        }
    }

    return self.http_client.request(.GET, uri, .{
        .redirect_behavior = DEFAULT_REDIRECT_BEHAVIOR,
        .extra_headers = self.extra_headers.items,
        .headers = .{
            .user_agent = user_agent,
        },
    });
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
