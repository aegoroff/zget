pub const Transport = @This();
const std = @import("std");
const http = std.http;

const MAX_REDIRECTS = 10;
const DEFAULT_REDIRECT_BEHAVIOR = http.Client.Request.RedirectBehavior.init(MAX_REDIRECTS);

gpa: std.mem.Allocator,
http_client: std.http.Client,
extra_headers: std.ArrayList(http.Header),

pub fn init(gpa: std.mem.Allocator, io: std.Io) Transport {
    return Transport{
        .gpa = gpa,
        .http_client = std.http.Client{
            .allocator = gpa,
            .io = io,
        },
        .extra_headers = .empty,
    };
}

pub fn deinit(self: *Transport) void {
    self.extra_headers.deinit(self.gpa);
    self.http_client.deinit();
}

pub fn get(self: *Transport, uri: std.Uri, headers: []const []const u8) http.Client.RequestError!http.Client.Request {
    self.extra_headers.clearRetainingCapacity();
    for (headers) |s| {
        if (parseHeader(s)) |header| {
            try self.extra_headers.append(self.gpa, header);
        }
    }

    return self.http_client.request(.GET, uri, .{
        .redirect_behavior = DEFAULT_REDIRECT_BEHAVIOR,
        .extra_headers = self.extra_headers.items,
    });
}

fn parseHeader(raw: []const u8) ?http.Header {
    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return null;
    const name = std.mem.trim(u8, raw[0..colon], " ");
    const value = std.mem.trim(u8, raw[colon + 1 ..], " ");
    if (name.len == 0 or value.len == 0) return null;
    return .{ .name = name, .value = value };
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
