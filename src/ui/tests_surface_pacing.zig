//! Slow UI deadlines must not leave an interactive Metal layer at 1-3 FPS.
const std = @import("std");
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;
const cf = @import("cf.zig");
const pacing = @import("pacing.zig");
const t = std.testing;

extern "c" const NSDefaultRunLoopMode: objc.Object;
fn wakeTimer(obj: objc.Object, selector: objc.SEL, timer: objc.Object) callconv(.c) void {
    if (@hasField(Surface, "wake_timer")) @import("surface_pacing.zig").timerFired(obj, selector, timer);
}

test "an infrequent UI deadline sleeps off the Metal link and input wakes at display cadence" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cls = objc.defineClass(.{ .name = "NanoUIPacingTestTarget", .superclass = "NSView", .methods = &.{
        .{ .name = "frameTimerFired:", .imp = &wakeTimer, .types = "v@:@" },
    } });
    const target = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithFrame:", .{objc.CGRect{}});
    defer objc.release(target);
    var s: Surface = .{ .gpa = t.allocator, .window = undefined, .nsview = target, .text_queue = undefined, .renderer = try @import("metal.zig").Renderer.init(), .text = undefined, .ctx = undefined, .view = undefined, .is_visible = true, .in_frame = true, .max_fps = 120 };
    objc.setZig(target, &s);
    defer objc.setZig(target, null);
    defer s.renderer.deinit();
    s.ctx = .init(t.allocator, &s.text);
    defer s.ctx.deinit();
    const link = objc.retain(objc.msg(objc.Object, target, "displayLinkWithTarget:selector:", .{ target, objc.sel("frameTimerFired:") }));
    defer objc.release(link);
    defer objc.msg(void, link, "invalidate", .{});
    s.display_link = link;
    objc.msg(void, link, "setPaused:", .{objc.YES});
    defer if (@hasField(Surface, "wake_timer")) {
        if (s.wake_timer) |timer| {
            objc.msg(void, timer, "invalidate", .{});
            objc.release(timer);
        }
    };
    const now = cf.CACurrentMediaTime();
    s.start_time = now;
    s.ctx.frame_in = 0.4;
    s.frame_in_due = now + 0.4;
    s.updatePacing(now, false);
    try t.expect(objc.msg(objc.BOOL, link, "isPaused", .{}));
    if (@hasField(Surface, "wake_timer")) {
        const timer = s.wake_timer orelse return error.MissingDeadline;
        try t.expect(objc.msg(objc.BOOL, timer, "isValid", .{}));
        const date = objc.msg(objc.Object, timer, "fireDate", .{});
        const delay = objc.msg(f64, date, "timeIntervalSinceNow", .{});
        try t.expect(std.math.isFinite(delay));
    }
    s.ctx.input.down = true;
    s.requestFrame();
    try t.expect(!objc.msg(objc.BOOL, link, "isPaused", .{}));
    try t.expect(s.full_pending);
    const range = objc.msg(pacing.Range, link, "preferredFrameRateRange", .{});
    try t.expectEqual(@as(f32, 120), range.preferred);
    if (@hasField(Surface, "wake_timer")) try t.expect(s.wake_timer == null);
    s.ctx.input.down = false;
    s.ctx.frame_in = 0.001;
    s.updatePacing(now, false);
    try t.expect(!objc.msg(objc.BOOL, link, "isPaused", .{}));
    if (@hasField(Surface, "wake_timer")) try t.expect(s.wake_timer == null);
    s.ctx.frame_in = 0.4;
    s.ctx.time_driven = .fast;
    s.updatePacing(now, false);
    try t.expect(!objc.msg(objc.BOOL, link, "isPaused", .{}));
    const gpu_range = objc.msg(pacing.Range, link, "preferredFrameRateRange", .{});
    try t.expectEqual(@as(f32, 120), gpu_range.preferred);
    s.ctx.time_driven = .none;
    s.ctx.frame_in = null;
    s.updatePacing(now, false);
    try t.expect(objc.msg(objc.BOOL, link, "isPaused", .{}));
    if (@hasField(Surface, "wake_timer")) try t.expect(s.wake_timer == null);
    s.full_pending = false;
    s.ctx.frame_in = 0.02;
    s.frame_in_due = cf.CACurrentMediaTime() + 0.02;
    s.updatePacing(cf.CACurrentMediaTime(), false);
    const limit = cf.CACurrentMediaTime() + 1;
    const loop = objc.msg(objc.Object, objc.class("NSRunLoop"), "mainRunLoop", .{});
    while (!s.full_pending and cf.CACurrentMediaTime() < limit) {
        const date = objc.msg(objc.Object, objc.class("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.05)});
        _ = objc.msg(objc.BOOL, loop, "runMode:beforeDate:", .{ NSDefaultRunLoopMode, date });
    }
    try t.expect(s.full_pending);
    try t.expect(!objc.msg(objc.BOOL, link, "isPaused", .{}));
    if (@hasField(Surface, "wake_timer")) try t.expect(s.wake_timer == null);
}
