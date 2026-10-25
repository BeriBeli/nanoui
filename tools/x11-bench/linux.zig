//! App-owned GTK instrumentation. No renderer or dependency modifications.
const std = @import("std");
const nano = @import("nanoui");
const ui = nano.ui;
const config = @import("options.zig");
const State = @import("workload.zig").State;
const metrics = @import("metrics.zig");
const Histogram = metrics.Histogram;

extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;

pub fn configure() !void {
    if (setenv("GDK_BACKEND", "x11", 1) != 0 or setenv("NANOUI_GTK", "3", 1) != 0) return error.ConfigureBackend;
}

const Api = struct {
    lib: std.DynLib,
    connect: *const fn (*anyopaque, [*:0]const u8, *const anyopaque, ?*anyopaque, ?*anyopaque, c_uint) callconv(.c) c_ulong,
    disconnect: *const fn (*anyopaque, c_ulong) callconv(.c) void,
    ref: *const fn (*anyopaque) callconv(.c) *anyopaque,
    unref: *const fn (*anyopaque) callconv(.c) void,
    frame_clock: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    display: *const fn () callconv(.c) ?*anyopaque,
    x11_type: *const fn () callconv(.c) usize,
    is_type: *const fn (*anyopaque, usize) callconv(.c) c_int,
    sync: *const fn (*anyopaque) callconv(.c) void,
    timeout: *const fn (c_uint, *const fn (?*anyopaque) callconv(.c) c_int, ?*anyopaque) callconv(.c) c_uint,
    remove: *const fn (c_uint) callconv(.c) c_int,
    major: *const fn () callconv(.c) c_uint,
    minor: *const fn () callconv(.c) c_uint,
    micro: *const fn () callconv(.c) c_uint,
    cairo_version: *const fn () callconv(.c) [*:0]const u8,
    glib_major: *const c_uint,
    glib_minor: *const c_uint,
    glib_micro: *const c_uint,

    fn init() !Api {
        var lib = try std.DynLib.open("libgtk-3.so.0");
        errdefer lib.close();
        var a: Api = undefined;
        a.lib = lib;
        inline for (.{ .{ "connect", "g_signal_connect_data" }, .{ "disconnect", "g_signal_handler_disconnect" }, .{ "ref", "g_object_ref" }, .{ "unref", "g_object_unref" }, .{ "frame_clock", "gtk_widget_get_frame_clock" }, .{ "display", "gdk_display_get_default" }, .{ "x11_type", "gdk_x11_display_get_type" }, .{ "is_type", "g_type_check_instance_is_a" }, .{ "sync", "gdk_display_sync" }, .{ "timeout", "g_timeout_add" }, .{ "remove", "g_source_remove" }, .{ "major", "gtk_get_major_version" }, .{ "minor", "gtk_get_minor_version" }, .{ "micro", "gtk_get_micro_version" }, .{ "cairo_version", "cairo_version_string" }, .{ "glib_major", "glib_major_version" }, .{ "glib_minor", "glib_minor_version" }, .{ "glib_micro", "glib_micro_version" } }) |p| {
            @field(a, p[0]) = lib.lookup(@FieldType(Api, p[0]), p[1]) orelse return error.GtkInstrumentationSymbol;
        }
        return a;
    }
};

const Samples = struct {
    requests: u64 = 0,
    coalesced_requests: u64 = 0,
    paint_cycles: u64 = 0,
    build: Histogram = .{},
    layout: Histogram = .{},
    paint: Histogram = .{},
    cadence: Histogram = .{},
    request_latency: Histogram = .{},
    input_latency: Histogram = .{},
    sync_latency: Histogram = .{},
    pending: ?f64 = null,
    last_paint: ?f64 = null,
};

const Result = struct {
    mode: config.Mode,
    elapsed_seconds: f64,
    cpu_seconds: f64,
    cpu_percent_one_core: f64,
    requests: u64,
    coalesced_requests: u64,
    unpainted_request: bool,
    gtk_paint_cycles: u64,
    gtk_paint_cycles_per_second: f64,
    input_events: u64,
    sampled_build_ms: Histogram.Report,
    sampled_layout_ms: Histogram.Report,
    sampled_display_list_ms: Histogram.Report,
    after_paint_interval_ms: Histogram.Report,
    request_to_after_paint_ms: Histogram.Report,
    input_dispatch_to_after_paint_ms: Histogram.Report,
    x_server_sync_ms: Histogram.Report,
    backing_width: u32,
    backing_height: u32,
    scale: f32,
    backing_valid: bool,
};

const Run = struct {
    app: *nano.App,
    window: ?*nano.Window,
    state: *State,
    api: Api,
    options: config.Options,
    clock: *anyopaque,
    display: *anyopaque,
    timer: c_uint = 0,
    signal: c_ulong = 0,
    stage: usize = 0,
    measuring: bool = false,
    complete: bool = false,
    phase_start: f64 = 0,
    cpu_start: f64 = 0,
    next_request: f64 = 0,
    last_frame: u64 = 0,
    input_start: u64 = 0,
    samples: Samples = .{},
    results: [4]Result = undefined,
    result_count: usize = 0,

    const modes = [_]config.Mode{ .idle, .small, .scroll, .full };

    fn begin(self: *Run) void {
        const now = ui.clock.now();
        self.phase_start = now;
        self.cpu_start = metrics.cpuSeconds();
        self.next_request = now;
        self.samples = .{};
        self.state.input_pending_since = null;
        self.input_start = self.state.inputs;
        self.state.mode = if (self.options.mode == .suite) modes[self.stage] else self.options.mode;
        std.debug.print("{s}: {s}\n", .{ @tagName(self.state.mode), if (self.measuring) "measuring" else "warmup" });
        // A single entry frame, never a periodic redraw during idle/input.
        if (self.window) |w| w.redraw();
    }

    fn armTimer(self: *Run) !void {
        const interval = if (self.state.mode == .idle or self.state.mode == .input) 1000 else @max(1, 500 / self.options.fps);
        self.timer = self.api.timeout(interval, tick, self);
        if (self.timer == 0) return error.TimerCreation;
    }

    fn onClose(ctx: *anyopaque, _: *nano.Window) void {
        const self: *Run = @ptrCast(@alignCast(ctx));
        self.window = null;
    }

    fn afterPaint(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *Run = @ptrCast(@alignCast(data.?));
        const w = self.window orelse return;
        const surface = w.surface orelse return;
        if (!self.measuring or self.last_frame == surface.ctx.frame or !surface.cpu.valid or surface.stale or surface.cpu.bytes.len == 0) return;
        self.last_frame = surface.ctx.frame;
        const now = ui.clock.now();
        const s = &self.samples;
        s.paint_cycles += 1;
        const stats = surface.ctx.stats;
        s.build.add(stats.build_ms);
        s.layout.add(stats.layout_ms);
        s.paint.add(stats.paint_ms);
        if (s.last_paint) |last| s.cadence.add((now - last) * 1000);
        s.last_paint = now;
        if (s.pending) |at| s.request_latency.add((now - at) * 1000);
        s.pending = null;
        if (self.state.input_pending_since) |at| s.input_latency.add((now - at) * 1000);
        self.state.input_pending_since = null;
        if (self.options.sync) {
            self.api.sync(self.display);
            s.sync_latency.add((ui.clock.now() - now) * 1000);
        }
    }

    fn record(self: *Run, now: f64) void {
        const surface = self.window.?.surface.?;
        const elapsed = now - self.phase_start;
        const cpu = metrics.cpuSeconds() - self.cpu_start;
        const s = &self.samples;
        self.results[self.result_count] = .{
            .mode = self.state.mode,
            .elapsed_seconds = elapsed,
            .cpu_seconds = cpu,
            .cpu_percent_one_core = cpu / elapsed * 100,
            .requests = s.requests,
            .coalesced_requests = s.coalesced_requests,
            .unpainted_request = s.pending != null,
            .gtk_paint_cycles = s.paint_cycles,
            .gtk_paint_cycles_per_second = @as(f64, @floatFromInt(s.paint_cycles)) / elapsed,
            .input_events = self.state.inputs - self.input_start,
            .sampled_build_ms = s.build.report(),
            .sampled_layout_ms = s.layout.report(),
            .sampled_display_list_ms = s.paint.report(),
            .after_paint_interval_ms = s.cadence.report(),
            .request_to_after_paint_ms = s.request_latency.report(),
            .input_dispatch_to_after_paint_ms = s.input_latency.report(),
            .x_server_sync_ms = s.sync_latency.report(),
            .backing_width = @intCast(surface.cpu.width),
            .backing_height = @intCast(surface.cpu.height),
            .scale = surface.scale,
            .backing_valid = surface.cpu.bytes.len > 0 and surface.cpu.valid and !surface.stale,
        };
        self.result_count += 1;
    }

    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Run = @ptrCast(@alignCast(data.?));
        const w = self.window orelse {
            self.timer = 0;
            return 0;
        };
        const now = ui.clock.now();
        const duration: f64 = @floatFromInt(if (self.measuring) self.options.seconds else self.options.warmup);
        if (now - self.phase_start >= duration) {
            if (!self.measuring) {
                self.measuring = true;
            } else {
                self.record(now);
                self.stage += 1;
                if (self.options.mode != .suite or self.stage == modes.len) {
                    self.complete = true;
                    self.timer = 0;
                    self.app.quit();
                    return 0;
                }
                self.measuring = self.options.warmup == 0;
            }
            self.timer = 0;
            self.begin();
            self.armTimer() catch {
                self.app.quit();
            };
            return 0;
        }
        if (self.state.mode == .idle or self.state.mode == .input or now < self.next_request) return 1;
        // No catch-up burst or unbounded queue when the forwarding link stalls.
        const period = 1 / @as(f64, @floatFromInt(self.options.fps));
        self.next_request += period;
        if (self.next_request <= now) self.next_request = now + period;
        self.state.step += 1;
        if (self.measuring) {
            self.samples.requests += 1;
            if (self.samples.pending != null) self.samples.coalesced_requests += 1 else self.samples.pending = now;
        }
        w.redraw();
        return 1;
    }
};

pub fn run(init: std.process.Init, app: *nano.App, window: *nano.Window, state: *State, options: config.Options) !void {
    var api = try Api.init();
    defer api.lib.close();
    const display = api.display() orelse return error.NoDisplay;
    if (api.is_type(display, api.x11_type()) == 0) return error.RequiresX11Backend;
    const surface = window.surface orelse return error.NoGtkSurface;
    const clock = api.frame_clock(surface.area) orelse return error.NoGtkFrameClock;
    _ = api.ref(clock);
    defer api.unref(clock);
    var r: Run = .{ .app = app, .window = window, .state = state, .api = api, .options = options, .clock = clock, .display = display, .measuring = options.warmup == 0 };
    window.on_close = .{ .ctx = &r, .func = Run.onClose };
    defer if (r.window) |w| {
        w.on_close = null;
    };
    r.signal = api.connect(clock, "after-paint", @ptrCast(&Run.afterPaint), &r, null, 0);
    if (r.signal == 0) return error.FrameClockSignal;
    defer api.disconnect(clock, r.signal);
    r.begin();
    try r.armTimer();
    defer if (r.timer != 0) {
        _ = api.remove(r.timer);
    };
    try app.run();
    const report = .{
        .schema = 1,
        .tool = "nanoui-x11-bench",
        .nanoui_version = nano.version,
        .complete = r.complete,
        .backend = "GTK3/X11/CPU",
        .sync_after_paint = options.sync,
        .gtk = .{ api.major(), api.minor(), api.micro() },
        .glib = .{ api.glib_major.*, api.glib_minor.*, api.glib_micro.* },
        .cairo = std.mem.span(api.cairo_version()),
        .display = init.environ_map.get("DISPLAY") orelse "",
        .ssh_forwarded = init.environ_map.get("SSH_CONNECTION") != null,
        .options = options,
        .scope = "Application-side GTK after-paint; no client-visible latency or wire-byte measurement. Display-list samples exclude CPU raster and Cairo. Sync adds X server round trips. Quantiles use 1ms upper bins; values over 2s use max.",
        .results = r.results[0..r.result_count],
    };
    const json = try std.json.Stringify.valueAlloc(init.gpa, report, .{ .whitespace = .indent_2 });
    defer init.gpa.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    if (!r.complete) return error.BenchmarkInterrupted;
    for (r.results[0..r.result_count]) |result| {
        const changing = result.mode == .small or result.mode == .scroll or result.mode == .full;
        if (!result.backing_valid or (changing and result.gtk_paint_cycles == 0)) return error.NoPaintEvidence;
    }
}
