pub const Transport = @This();
const std = @import("std");
const http = std.http;

gpa: std.mem.Allocator,
http_client: std.http.Client,

pub fn init(gpa: std.mem.Allocator, io: std.Io) Transport {
    return Transport{
        .gpa = gpa,
        .http_client = std.http.Client{
            .allocator = gpa,
            .io = io,
        },
    };
}

pub fn get(self: *Transport, uri: std.Uri, headers: []const []const u8) http.Client.RequestError!http.Client.Request {
    var req_options: std.http.Client.RequestOptions = undefined;
    if (headers.len > 0) {
        var extra_headers = std.ArrayList(std.http.Header){};
        for (headers) |s| {
            var pair = std.mem.splitScalar(u8, s, ':');
            const h = trim(pair.next());
            const v = trim(pair.next());
            if (h != null and v != null) {
                try extra_headers.append(self.gpa, .{ .name = h.?, .value = v.? });
            }
        }
        req_options = .{
            .extra_headers = extra_headers.items,
        };
    } else {
        req_options = .{};
    }

    return self.http_client.request(.GET, uri, req_options);
}

fn trim(s: ?[]const u8) ?[]const u8 {
    const slice = s orelse {
        return s;
    };
    return std.mem.trim(u8, slice, " ");
}

test "trim not needed" {
    const i: ?[]const u8 = "1234";
    try std.testing.expectEqualStrings("1234", trim(i) orelse "");
}

test "trim null" {
    try std.testing.expectEqual(@as(?[]const u8, null), trim(null));
}

test "trim null with whitespaces" {
    const i: ?[]const u8 = " 1234 ";
    try std.testing.expectEqualStrings("1234", trim(i) orelse "");
}
