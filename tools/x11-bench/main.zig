const std = @import("std");
const nano = @import("nanoui");
const config = @import("options.zig");
const State = @import("workload.zig").State;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = config.Options.parse(args) catch |err| {
        std.debug.print("Invalid arguments: {s}\n{s}", .{ @errorName(err), config.help });
        return err;
    };
    if (options.help) {
        try std.Io.File.stdout().writeStreamingAll(init.io, config.help);
        return;
    }
    var state: State = .{ .mode = if (options.mode == .suite) .idle else options.mode };
    if (options.snapshot) |path| {
        // Build directly with the portable Tester: no AppKit, Metal, GTK,
        // display connection or window is needed for these functional checks.
        var tester: nano.ui.Tester = undefined;
        try tester.init(init.gpa, .init(&state, State.view), .{ .width = @floatFromInt(options.width), .height = @floatFromInt(options.height), .scale = 1, .theme = .dark_theme });
        defer tester.deinit();
        tester.settle(0);
        try tester.runScript(options.script);
        try tester.screenshot(path);
        return;
    }
    if (@import("builtin").os.tag != .linux) return error.UseLinuxForX11Measurements;
    try @import("linux.zig").configure();
    const app = try nano.App.create(init, .{ .name = "nanoui X11 Benchmark" });
    defer app.destroy();
    app.cpu_only = true;
    const window = try app.newWindow(.{ .title = "nanoui X11 Benchmark", .width = @floatFromInt(options.width), .height = @floatFromInt(options.height), .theme = .dark_theme, .content = .{ .view = .init(&state, State.view) } });
    if (@import("builtin").os.tag == .linux) {
        try @import("linux.zig").run(init, app, window, &state, options);
    } else return error.UseLinuxForX11Measurements;
}

test {
    _ = @import("options.zig");
    _ = @import("metrics.zig");
    _ = @import("workload.zig");
}
