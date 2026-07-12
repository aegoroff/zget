const std = @import("std");
const http = std.http;

const errors = @import("errors.zig");

pub const CliOptions = struct {
    no_proxy: bool = false,
    proxy_user: ?[]const u8 = null,
    proxy_password: ?[]const u8 = null,
};

pub const Config = struct {
    use_proxy: bool = true,
    no_proxy_entries: []const []const u8 = &.{},
    http_proxy: ?*http.Client.Proxy = null,
    https_proxy: ?*http.Client.Proxy = null,

    pub fn init(
        gpa: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        cli: CliOptions,
    ) !Config {
        var config: Config = .{
            .use_proxy = !cli.no_proxy,
        };
        if (!config.use_proxy) return config;

        config.no_proxy_entries = try parseNoProxyList(gpa, getEnvInsensitive(environ_map, "no_proxy"));

        const proxy_user = cli.proxy_user;
        const proxy_password = cli.proxy_password orelse "";

        if (getEnvInsensitive(environ_map, "http_proxy")) |url| {
            config.http_proxy = try createProxy(gpa, url, proxy_user, proxy_password);
        }
        if (getEnvInsensitive(environ_map, "https_proxy")) |url| {
            config.https_proxy = try createProxy(gpa, url, proxy_user, proxy_password);
        }

        return config;
    }

    pub fn apply(self: *const Config, client: *http.Client) void {
        if (!self.use_proxy) {
            client.http_proxy = null;
            client.https_proxy = null;
            return;
        }

        client.http_proxy = self.http_proxy;
        client.https_proxy = self.https_proxy;
    }

    pub fn shouldBypassProxy(self: *const Config, host: []const u8) bool {
        if (!self.use_proxy) return true;
        return hostMatchesNoProxy(host, self.no_proxy_entries);
    }
};

fn getEnvInsensitive(map: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const keys = map.keys();
    const values = map.values();
    for (keys, values) |key, value| {
        if (std.ascii.eqlIgnoreCase(key, name)) return value;
    }
    return null;
}

fn parseNoProxyList(gpa: std.mem.Allocator, value: ?[]const u8) ![]const []const u8 {
    const raw = value orelse return &.{};
    if (raw.len == 0) return &.{};

    var entries = std.ArrayList([]const u8).empty;
    errdefer entries.deinit(gpa);

    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        try entries.append(gpa, trimmed);
    }

    return try entries.toOwnedSlice(gpa);
}

fn createProxy(
    gpa: std.mem.Allocator,
    url: []const u8,
    proxy_user: ?[]const u8,
    proxy_password: []const u8,
) !*http.Client.Proxy {
    if (url.len == 0) return errors.ZgetError.EmptyProxyUrl;

    const uri = std.Uri.parse(url) catch try std.Uri.parseAfterScheme("http", url);
    const protocol = http.Client.Protocol.fromUri(uri) orelse return errors.ZgetError.UnsupportedProxyScheme;
    const raw_host = try uri.getHostAlloc(gpa);

    const authorization = if (proxy_user) |user|
        try makeBasicAuthorization(gpa, user, proxy_password)
    else if (uri.user != null or uri.password != null) a: {
        const value = try gpa.alloc(u8, http.Client.basic_authorization.valueLengthFromUri(uri));
        assert(http.Client.basic_authorization.value(uri, value).len == value.len);
        break :a value;
    } else null;

    const proxy = try gpa.create(http.Client.Proxy);
    proxy.* = .{
        .protocol = protocol,
        .host = raw_host,
        .authorization = authorization,
        .port = uriPort(uri, protocol),
        .supports_connect = true,
    };
    return proxy;
}

fn makeBasicAuthorization(
    gpa: std.mem.Allocator,
    user: []const u8,
    password: []const u8,
) ![]const u8 {
    const value_len = http.Client.basic_authorization.valueLength(user.len, password.len);
    const value = try gpa.alloc(u8, value_len);

    var credentials: [http.Client.basic_authorization.max_user_len + 1 + http.Client.basic_authorization.max_password_len]u8 = undefined;
    var credentials_writer = std.Io.Writer.fixed(&credentials);
    try credentials_writer.writeAll(user);
    try credentials_writer.writeByte(':');
    try credentials_writer.writeAll(password);

    var out = std.Io.Writer.fixed(value);
    try out.print("Basic {b64}", .{credentials_writer.buffered()});
    return out.buffered();
}

fn uriPort(uri: std.Uri, protocol: http.Client.Protocol) u16 {
    return uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };
}

/// wget's sufmatch from src/host.c
fn hostMatchesPattern(host: []const u8, pattern: []const u8) bool {
    const host_len: i32 = @intCast(host.len);
    const pattern_len: i32 = @intCast(pattern.len);
    if (host_len < pattern_len) return false;

    var pattern_index: i32 = pattern_len;
    var host_index: i32 = host_len;
    while (pattern_index >= 0 and host_index >= 0) {
        const pattern_byte: u8 = if (pattern_index < pattern_len)
            pattern[@intCast(pattern_index)]
        else
            0;
        const host_byte: u8 = if (host_index < host_len)
            host[@intCast(host_index)]
        else
            0;
        if (std.ascii.toLower(pattern_byte) != std.ascii.toLower(host_byte)) break;
        pattern_index -= 1;
        host_index -= 1;
    }

    return pattern_index == -1 and (host_index == -1 or host[@intCast(host_index)] == '.' or pattern[0] == '.');
}

fn hostMatchesNoProxy(host: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (hostMatchesPattern(host, pattern)) return true;
    }
    return false;
}

const assert = std.debug.assert;

test "no_proxy matches exact domain" {
    const patterns = [_][]const u8{"mit.edu"};
    try std.testing.expect(hostMatchesNoProxy("mit.edu", &patterns));
}

test "no_proxy matches subdomain" {
    const patterns = [_][]const u8{"mit.edu"};
    try std.testing.expect(hostMatchesNoProxy("www.mit.edu", &patterns));
    try std.testing.expect(hostMatchesNoProxy("www.subdomain.mit.edu", &patterns));
}

test "no_proxy dot-prefixed matches subdomain only" {
    const patterns = [_][]const u8{".mit.edu"};
    try std.testing.expect(!hostMatchesNoProxy("mit.edu", &patterns));
    try std.testing.expect(hostMatchesNoProxy("www.mit.edu", &patterns));
    try std.testing.expect(hostMatchesNoProxy("www.subdomain.mit.edu", &patterns));
}

test "no_proxy matching is case insensitive" {
    const patterns = [_][]const u8{"MiT.EdU"};
    try std.testing.expect(hostMatchesNoProxy("www.mit.edu", &patterns));
}

test "parseNoProxyList splits and trims entries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const raw = " localhost, .example.com ,foo ";
    const entries = try parseNoProxyList(arena, raw);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("localhost", entries[0]);
    try std.testing.expectEqualStrings(".example.com", entries[1]);
    try std.testing.expectEqualStrings("foo", entries[2]);
}

test "load disables proxy with no-proxy flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environ = std.process.Environ.empty;
    var map = try std.process.Environ.createMap(environ, arena);
    defer map.deinit();
    try map.put("http_proxy", "http://proxy.example:8080");

    const config = try Config.init(arena, &map, .{ .no_proxy = true });
    try std.testing.expect(!config.use_proxy);
    try std.testing.expect(config.http_proxy == null);
}

test "load reads http and https proxy from environment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environ = std.process.Environ.empty;
    var map = try std.process.Environ.createMap(environ, arena);
    defer map.deinit();
    try map.put("http_proxy", "http://proxy.example:8080");
    try map.put("https_proxy", "http://proxy.example:8443");

    const config = try Config.init(arena, &map, .{});
    try std.testing.expect(config.use_proxy);
    try std.testing.expect(config.http_proxy != null);
    try std.testing.expect(config.https_proxy != null);
    try std.testing.expectEqual(@as(u16, 8080), config.http_proxy.?.port);
    try std.testing.expectEqual(@as(u16, 8443), config.https_proxy.?.port);
}

test "load reads uppercase proxy environment variables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environ = std.process.Environ.empty;
    var map = try std.process.Environ.createMap(environ, arena);
    defer map.deinit();
    try map.put("HTTP_PROXY", "http://proxy.example:8080");
    try map.put("HTTPS_PROXY", "http://proxy.example:8443");
    try map.put("NO_PROXY", "localhost,.example.com");

    const config = try Config.init(arena, &map, .{});
    try std.testing.expect(config.use_proxy);
    try std.testing.expect(config.http_proxy != null);
    try std.testing.expect(config.https_proxy != null);
    try std.testing.expectEqual(@as(usize, 2), config.no_proxy_entries.len);
    try std.testing.expectEqualStrings("localhost", config.no_proxy_entries[0]);
    try std.testing.expectEqualStrings(".example.com", config.no_proxy_entries[1]);
}

test "getEnvInsensitive matches mixed-case keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environ = std.process.Environ.empty;
    var map = try std.process.Environ.createMap(environ, arena);
    defer map.deinit();
    try map.put("Http_Proxy", "http://proxy.example:3128");

    try std.testing.expectEqualStrings(
        "http://proxy.example:3128",
        getEnvInsensitive(&map, "http_proxy").?,
    );
}

test "load applies proxy-user credentials" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const environ = std.process.Environ.empty;
    var map = try std.process.Environ.createMap(environ, arena);
    defer map.deinit();
    try map.put("http_proxy", "http://proxy.example:8080");

    const config = try Config.init(arena, &map, .{
        .proxy_user = "alice",
        .proxy_password = "secret",
    });
    const authorization = config.http_proxy.?.authorization.?;
    try std.testing.expect(std.mem.startsWith(u8, authorization, "Basic "));
}
