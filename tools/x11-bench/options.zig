const std = @import("std");
pub const Mode = enum { suite, idle, small, scroll, full, input };
pub const Options = struct {
    mode: Mode = .suite,
    seconds: u32 = 10,
    warmup: u32 = 2,
    fps: u32 = 30,
    width: u32 = 1100,
    height: u32 = 720,
    sync: bool = false,
    help: bool = false,
    snapshot: ?[]const u8 = null,
    script: []const u8 = "",

    pub fn parse(args: []const []const u8) !Options {
        var o: Options = .{};
        for (args[1..]) |arg| {
            if (std.mem.eql(u8, arg, "--help")) {
                o.help = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--sync")) {
                o.sync = true;
                continue;
            }
            // Only these offscreen flags are supported by this tool.
            if (std.mem.startsWith(u8, arg, "--nanoui-snapshot=")) {
                o.snapshot = arg[18..];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--nanoui-script=")) {
                o.script = arg[16..];
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--mode=")) {
                o.mode = std.meta.stringToEnum(Mode, arg[7..]) orelse return error.InvalidMode;
                continue;
            }
            var found = false;
            inline for (.{ "seconds", "warmup", "fps", "width", "height" }) |field| {
                const prefix = "--" ++ field ++ "=";
                if (std.mem.startsWith(u8, arg, prefix)) {
                    @field(o, field) = std.fmt.parseInt(u32, arg[prefix.len..], 10) catch return error.InvalidNumber;
                    found = true;
                }
            }
            if (!found) return error.UnknownOption;
        }
        if (o.seconds < 1 or o.seconds > 300 or o.warmup > 30 or o.fps < 1 or o.fps > 120 or o.width < 640 or o.width > 3840 or o.height < 360 or o.height > 2160) return error.OutOfRange;
        return o;
    }
};

pub const help =
    \\nanoui X11 forwarding benchmark (Linux GTK 3 / CPU)
    \\  --mode=suite|idle|small|scroll|full|input   default: suite (first four)
    \\  --seconds=10 --warmup=2 --fps=30 --width=1100 --height=720
    \\  --sync    synchronize with X server after each GTK after-paint
    \\            (diagnostic; adds a round trip, compare separate runs)
    \\Writes one JSON report to stdout; progress goes to stderr.
    \\Input: click the field, type, scroll or click Ack; no input is stored in JSON.
    \\GTK after-paint is an application-side boundary, not client-visible latency.
    \\Offscreen screenshots are functional checks, never X11 performance results.
    \\
;

test "reject invalid, overflowing and unknown benchmark options" {
    try std.testing.expectError(error.OutOfRange, Options.parse(&.{ "bench", "--fps=0" }));
    try std.testing.expectError(error.InvalidNumber, Options.parse(&.{ "bench", "--seconds=999999999999" }));
    try std.testing.expectError(error.InvalidMode, Options.parse(&.{ "bench", "--mode=no" }));
    try std.testing.expectError(error.UnknownOption, Options.parse(&.{ "bench", "--nanoui-hidden" }));
    const o = try Options.parse(&.{ "bench", "--mode=scroll", "--sync", "--fps=60" });
    try std.testing.expect(o.mode == .scroll and o.sync and o.fps == 60);
}
