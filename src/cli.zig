const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");

const errors = @import("errors.zig");
const proxy = @import("proxy.zig");

pub const DEFAULT_MAX_REDIRECTS: u16 = 10;

pub const Args = struct {
    uri_source: []const u8,
    uri: std.Uri,
    headers: []const []const u8,
    output: ?[]const u8,
    proxy: proxy.CliOptions,
    timeout_seconds: ?u32,
    no_check_certificate: bool,
    max_redirects: u16,
    quiet: bool,
};

pub const CliResult = union(enum) {
    run: Args,
    version,
};

pub fn printVersion(writer: *std.Io.Writer) !void {
    try writer.print("zget {s}\n", .{build_options.version});
}

pub fn parse(init: std.process.Init, gpa: std.mem.Allocator) !CliResult {
    const query = std.Target.Query.fromTarget(&builtin.target);

    const app_descr_template =
        \\Zget {s} ({s}), a non-interactive network retriever implemented in Zig
        \\Copyright (C) 2025-2026 Alexander Egorov. All rights reserved.
    ;
    const app_descr = try std.fmt.allocPrint(
        gpa,
        app_descr_template,
        .{ build_options.version, @tagName(query.cpu_arch.?) },
    );

    var app = yazap.App.init(gpa, "zget", app_descr);
    defer app.deinit();

    var root_cmd = app.rootCommand();
    root_cmd.setProperty(.help_on_empty_args);
    root_cmd.setProperty(.positional_arg_required);
    const headers_opt = yazap.Arg.multiValuesOption(
        "header",
        'H',
        "Additional HTTP header(s)",
        1,
    );
    const uri_opt = yazap.Arg.positional("URI", "Uri to download", null);

    var output_opt = yazap.Arg.singleValueOption(
        "output",
        'O',
        "Path the result will saved to. If it's a directory file name will be get from URI file name part. Use '-' to write to stdout",
    );
    output_opt.setValuePlaceholder("STRING");
    output_opt.setProperty(.takes_value);

    const no_proxy_opt = yazap.Arg.booleanOption(
        "no-proxy",
        null,
        "Don't use proxies, even if the appropriate *_proxy environment variable is defined",
    );
    const proxy_user_opt = yazap.Arg.singleValueOption(
        "proxy-user",
        null,
        "Username for authentication on a proxy server",
    );
    const proxy_password_opt = yazap.Arg.singleValueOption(
        "proxy-password",
        null,
        "Password for authentication on a proxy server",
    );
    const version_opt = yazap.Arg.booleanOption(
        "version",
        'V',
        "Print version information and exit",
    );
    const quiet_opt = yazap.Arg.booleanOption(
        "quiet",
        'q',
        "Quiet (no output)",
    );
    var timeout_opt = yazap.Arg.singleValueOption(
        "timeout",
        null,
        "Connection and read timeout in seconds",
    );
    timeout_opt.setValuePlaceholder("SECONDS");
    timeout_opt.setProperty(.takes_value);
    const no_check_certificate_opt = yazap.Arg.booleanOption(
        "no-check-certificate",
        null,
        "Don't verify the peer's TLS certificate chain",
    );
    var max_redirect_opt = yazap.Arg.singleValueOption(
        "max-redirect",
        null,
        "Maximum number of HTTP redirects to follow",
    );
    max_redirect_opt.setValuePlaceholder("COUNT");
    max_redirect_opt.setProperty(.takes_value);

    try root_cmd.addArg(headers_opt);
    try root_cmd.addArg(output_opt);
    try root_cmd.addArg(no_proxy_opt);
    try root_cmd.addArg(proxy_user_opt);
    try root_cmd.addArg(proxy_password_opt);
    try root_cmd.addArg(version_opt);
    try root_cmd.addArg(quiet_opt);
    try root_cmd.addArg(timeout_opt);
    try root_cmd.addArg(no_check_certificate_opt);
    try root_cmd.addArg(max_redirect_opt);
    try root_cmd.addArg(uri_opt);

    const raw_argv = try init.minimal.args.toSlice(gpa);
    const argv = try normalizeOutputDashArgv(gpa, raw_argv[1..]);
    if (wantsVersion(argv)) return .version;

    const matches = try app.parseFrom(init.io, argv);

    const source = matches.getSingleValue("URI").?;
    const uri = try std.Uri.parse(source);

    const timeout_seconds = if (matches.getSingleValue("timeout")) |value|
        try parseTimeoutSeconds(value)
    else
        null;

    const max_redirects = if (matches.getSingleValue("max-redirect")) |value|
        try parseMaxRedirects(value)
    else
        DEFAULT_MAX_REDIRECTS;

    return .{ .run = .{
        .uri_source = source,
        .uri = uri,
        .headers = matches.getMultiValues("header") orelse &[_][]const u8{},
        .output = matches.getSingleValue("output"),
        .proxy = .{
            .no_proxy = matches.containsArg("no-proxy"),
            .proxy_user = matches.getSingleValue("proxy-user"),
            .proxy_password = matches.getSingleValue("proxy-password"),
        },
        .timeout_seconds = timeout_seconds,
        .no_check_certificate = matches.containsArg("no-check-certificate"),
        .max_redirects = max_redirects,
        .quiet = matches.containsArg("quiet"),
    } };
}

fn parseMaxRedirects(raw: []const u8) errors.ZgetError!u16 {
    const count = std.fmt.parseInt(u16, raw, 10) catch return error.InvalidMaxRedirects;
    if (count == std.math.maxInt(u16)) return error.InvalidMaxRedirects;
    return count;
}

fn parseTimeoutSeconds(raw: []const u8) errors.ZgetError!u32 {
    const seconds = std.fmt.parseInt(u32, raw, 10) catch return error.InvalidTimeout;
    if (seconds == 0) return error.InvalidTimeout;
    return seconds;
}

fn wantsVersion(argv: []const [:0]const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) return true;
    }
    return false;
}

fn isOutputOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "--output");
}

/// yazap treats a standalone `-` as an option token; wget uses `-O -` for stdout.
fn normalizeOutputDashArgv(gpa: std.mem.Allocator, argv: []const [:0]const u8) ![]const [:0]const u8 {
    if (argv.len == 0) return argv;

    var normalized = try std.ArrayList([:0]const u8).initCapacity(gpa, argv.len);
    errdefer normalized.deinit(gpa);

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (isOutputOption(arg) and index + 1 < argv.len and std.mem.eql(u8, argv[index + 1], "-")) {
            const merged = try std.fmt.allocPrintSentinel(gpa, "{s}=-", .{arg}, 0);
            try normalized.append(gpa, merged);
            index += 1;
            continue;
        }
        try normalized.append(gpa, arg);
    }

    return try normalized.toOwnedSlice(gpa);
}

test "wantsVersion detects version flags" {
    const version_argv = [_][:0]const u8{"--version"};
    try std.testing.expect(wantsVersion(&version_argv));

    const short_argv = [_][:0]const u8{"-V"};
    try std.testing.expect(wantsVersion(&short_argv));

    const download_argv = [_][:0]const u8{"https://example.com"};
    try std.testing.expect(!wantsVersion(&download_argv));
}

test "normalizeOutputDashArgv rewrites -O -" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = [_][:0]const u8{ "-O", "-", "https://example.com" };
    const normalized = try normalizeOutputDashArgv(arena, &argv);
    try std.testing.expectEqual(@as(usize, 2), normalized.len);
    try std.testing.expectEqualStrings("-O=-", normalized[0]);
    try std.testing.expectEqualStrings("https://example.com", normalized[1]);
}

test "normalizeOutputDashArgv rewrites --output -" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = [_][:0]const u8{ "--output", "-", "https://example.com" };
    const normalized = try normalizeOutputDashArgv(arena, &argv);
    try std.testing.expectEqual(@as(usize, 2), normalized.len);
    try std.testing.expectEqualStrings("--output=-", normalized[0]);
    try std.testing.expectEqualStrings("https://example.com", normalized[1]);
}

test "parseMaxRedirects accepts zero and positive values" {
    try std.testing.expectEqual(@as(u16, 0), try parseMaxRedirects("0"));
    try std.testing.expectEqual(@as(u16, 10), try parseMaxRedirects("10"));
}

test "parseMaxRedirects rejects invalid values" {
    try std.testing.expectError(error.InvalidMaxRedirects, parseMaxRedirects("abc"));
    try std.testing.expectError(error.InvalidMaxRedirects, parseMaxRedirects("65535"));
}

test "parseTimeoutSeconds accepts positive values" {
    try std.testing.expectEqual(@as(u32, 30), try parseTimeoutSeconds("30"));
}

test "parseTimeoutSeconds rejects zero" {
    try std.testing.expectError(error.InvalidTimeout, parseTimeoutSeconds("0"));
}

test "parseTimeoutSeconds rejects non-numeric values" {
    try std.testing.expectError(error.InvalidTimeout, parseTimeoutSeconds("abc"));
}

test "normalizeOutputDashArgv leaves other args unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = [_][:0]const u8{ "-O", "out.txt", "https://example.com" };
    const normalized = try normalizeOutputDashArgv(arena, &argv);
    try std.testing.expectEqualSlices([:0]const u8, &argv, normalized);
}
