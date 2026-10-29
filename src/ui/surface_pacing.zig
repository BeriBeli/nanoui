//! Metal runs at display cadence for active work. Infrequent UI deadlines
//! sleep on one cancellable run-loop timer, not a 1-3 FPS drawable pipeline.
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const std = @import("std");
const pacing = @import("pacing.zig");
const Surface = @import("surface.zig").Surface;
extern "c" const NSRunLoopCommonModes: objc.Object;

pub fn cancelWake(s: *Surface) void {
    if (s.wake_timer) |timer| {
        s.wake_timer = null;
        objc.msg(void, timer, "invalidate", .{});
        objc.release(timer);
    }
}

fn armWake(s: *Surface, now: f64, delay: f32) void {
    const seconds = @max(0.001, (if (s.frame_in_due > 0) s.frame_in_due else now + delay) - cf.CACurrentMediaTime());
    const timer = objc.retain(objc.msg(objc.Object, objc.class("NSTimer"), "timerWithTimeInterval:target:selector:userInfo:repeats:", .{
        seconds, s.nsview, objc.sel("frameTimerFired:"), @as(?objc.Object, null), objc.NO,
    }));
    s.wake_timer = timer;
    const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
    objc.msg(void, loop, "addTimer:forMode:", .{ timer, NSRunLoopCommonModes });
}

pub fn timerFired(obj: objc.Object, _: objc.SEL, timer: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.dead or s.wake_timer != timer) return;
    cancelWake(s);
    if (s.visible()) s.requestFrame() else s.pending = true;
}

pub fn update(s: *Surface, now: f64, hot_changed: bool) void {
    if (s.in_live_resize) return setPaced(s, false);
    const c = &s.ctx;
    const elapsed = (now - s.start_time) - c.caret_moved_at;
    const recent_typing = c.focused_text != null and c.caret_moved_at > 0 and elapsed >= 0 and elapsed < 0.35;
    const more = c.animating or hot_changed or c.input.down or recent_typing or s.scroll.active(now);
    const soon = if (c.frame_in) |fi| fi <= 1.0 / @max(60.0, s.max_fps) else false;
    if (s.display_link != null) {
        if (more or soon) {
            setRate(s, null);
            setPaced(s, true);
        } else if (c.time_driven != .none) {
            setRate(s, if (c.time_driven == .fast) null else 1.0 / 24.0);
            setPaced(s, true);
        } else {
            setPaced(s, false);
            if (c.frame_in) |fi| armWake(s, now, fi);
        }
    } else {
        cancelWake(s);
        if (more or c.time_driven != .none) s.requestFrame() else if (c.frame_in) |fi| armWake(s, now, fi);
    }
    if (!c.animating) {
        s.last_frame_time = 0;
        if (s.frame_log) |*fl| fl.last_t = 0;
    }
}

pub fn setRate(s: *Surface, seconds: ?f32) void {
    const link = s.display_link orelse return;
    const fps: f32 = if (seconds) |v| (if (v < 0.009) 0 else std.math.clamp(1 / @max(v, 0.001), 1, 60)) else 0;
    if (fps == s.link_fps) return;
    const faster = (fps == 0 and s.link_fps > 0) or (fps > s.link_fps and s.link_fps > 0);
    if (fps == 0 and s.link_fps > 0) {
        if (s.frame_log) |*fl| fl.last_t = 0;
    }
    s.link_fps = fps;
    if (s.paced and faster) objc.msg(void, link, "setPaused:", .{objc.YES});
    objc.msg(void, link, "setPreferredFrameRateRange:", .{pacing.range(fps, s.max_fps)});
    if (s.paced and faster) objc.msg(void, link, "setPaused:", .{objc.NO});
}

pub fn setPaced(s: *Surface, on: bool) void {
    cancelWake(s);
    if (s.paced == on) return;
    s.paced = on;
    if (!on) if (s.frame_log) |*fl| {
        fl.last_t = 0;
    };
    if (s.display_link) |link| objc.msg(void, link, "setPaused:", .{!on});
}
