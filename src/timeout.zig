const std = @import("std");
const http = std.http;
const tls_connect = @import("tls_connect.zig");

const Io = std.Io;
const HostName = std.Io.net.HostName;

pub fn fromSeconds(seconds: u32) Io.Timeout {
    return .{
        .duration = .{
            .raw = Io.Duration.fromSeconds(seconds),
            .clock = .real,
        },
    };
}

fn sleepForTimeout(io: Io, timeout: Io.Timeout) void {
    Io.Timeout.sleep(timeout, io) catch {};
}

pub fn insecureTlsConnectionWithTimeout(
    http_client: *http.Client,
    host: HostName,
    port: u16,
    timeout: Io.Timeout,
) (http.Client.ConnectTcpError || error{Timeout})!*http.Client.Connection {
    if (timeout == .none) return tls_connect.createInsecureConnection(http_client, host, port);

    const io = http_client.io;
    const SelectResult = union(enum) {
        ready: http.Client.ConnectTcpError!*http.Client.Connection,
        expired: void,
    };

    var select_buffer: [2]SelectResult = undefined;
    var select = Io.Select(SelectResult).init(io, &select_buffer);
    select.async(.ready, tls_connect.createInsecureConnection, .{ http_client, host, port });
    select.async(.expired, sleepForTimeout, .{ io, timeout });

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

pub fn requestWithConnectTimeout(
    client: *http.Client,
    method: http.Method,
    uri: std.Uri,
    options: http.Client.RequestOptions,
    timeout: Io.Timeout,
) http.Client.RequestError!http.Client.Request {
    const io = client.io;
    if (timeout == .none) return client.request(method, uri, options);

    const SelectResult = union(enum) {
        ready: http.Client.RequestError!http.Client.Request,
        expired: void,
    };

    var select_buffer: [2]SelectResult = undefined;
    var select = Io.Select(SelectResult).init(io, &select_buffer);
    select.async(.ready, http.Client.request, .{ client, method, uri, options });
    select.async(.expired, sleepForTimeout, .{ io, timeout });

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

pub const IdleTimeoutError = Io.Reader.StreamError || error{Timeout};

pub fn receiveHeadWithTimeout(
    io: Io,
    req: *http.Client.Request,
    header_buffer: []u8,
    timeout: Io.Timeout,
) (http.Client.Request.ReceiveHeadError || error{Timeout})!http.Client.Response {
    if (timeout == .none) return req.receiveHead(header_buffer);

    const SelectResult = union(enum) {
        ready: http.Client.Request.ReceiveHeadError!http.Client.Response,
        expired: void,
    };

    var select_buffer: [2]SelectResult = undefined;
    var select = Io.Select(SelectResult).init(io, &select_buffer);
    select.async(.ready, http.Client.Request.receiveHead, .{ req, header_buffer });
    select.async(.expired, sleepForTimeout, .{ io, timeout });

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

pub fn streamWithIdleTimeout(
    io: Io,
    reader: *Io.Reader,
    dest: *Io.Writer,
    limit: usize,
    timeout: Io.Timeout,
) IdleTimeoutError!usize {
    if (timeout == .none) return reader.stream(dest, .limited(limit));

    const SelectResult = union(enum) {
        ready: Io.Reader.StreamError!usize,
        expired: void,
    };

    var select_buffer: [2]SelectResult = undefined;
    var select = Io.Select(SelectResult).init(io, &select_buffer);
    select.async(.ready, streamLimited, .{ reader, dest, limit });
    select.async(.expired, sleepForTimeout, .{ io, timeout });

    const first = select.await() catch {
        select.cancelDiscard();
        return error.ReadFailed;
    };
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

fn streamLimited(reader: *Io.Reader, dest: *Io.Writer, limit: usize) Io.Reader.StreamError!usize {
    return reader.stream(dest, .limited(limit));
}

test "fromSeconds builds a duration timeout" {
    const timeout = fromSeconds(30);
    try std.testing.expect(timeout == .duration);
    try std.testing.expectEqual(@as(i64, 30), timeout.duration.raw.toSeconds());
    try std.testing.expect(timeout.duration.clock == .real);
}
