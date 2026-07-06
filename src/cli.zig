const std = @import("std");
const yazap = @import("yazap");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Args = struct {
    uri_source: []const u8,
    uri: std.Uri,
    headers: []const []const u8,
    output: ?[]const u8,
};

pub fn parse(init: std.process.Init, gpa: std.mem.Allocator) !Args {
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
        "Path the result will saved to. If it's a directory file name will be get from URI file name part",
    );
    output_opt.setValuePlaceholder("STRING");
    output_opt.setProperty(.takes_value);

    try root_cmd.addArg(headers_opt);
    try root_cmd.addArg(output_opt);
    try root_cmd.addArg(uri_opt);

    const matches = try app.parseProcess(init.io, init.minimal.args);

    const source = matches.getSingleValue("URI").?;
    const uri = try std.Uri.parse(source);

    return .{
        .uri_source = source,
        .uri = uri,
        .headers = matches.getMultiValues("header") orelse &[_][]const u8{},
        .output = matches.getSingleValue("output"),
    };
}
