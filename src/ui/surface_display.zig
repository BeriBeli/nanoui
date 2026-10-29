//! Window geometry and its new pixels must commit in the same CA transaction.
//! CADisplayLink paces animation; it never reserves a drawable ahead of resize.
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;
const pacing = @import("surface_pacing.zig");

pub fn linkFired(obj: objc.Object, _: objc.SEL, link: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.dead or s.in_frame or s.in_live_resize) return;
    const target = objc.msg(f64, link, "targetTimestamp", .{});
    const duration = objc.msg(f64, link, "duration", .{});
    const due = s.ctx.frame_in != null and target >= s.frame_in_due - 0.001;
    if (!s.full_pending and !due and !s.ctx.animating and !s.geometry_changed and !s.retained_ready and !s.pending_sync and s.ctx.time_driven == .none) {
        s.updatePacing(target, false);
    } else if (!s.full_pending and !due and !s.ctx.animating and !s.geometry_changed and (s.retained_ready or (!s.pending_sync and s.ctx.time_driven != .none))) {
        s.redrawRetained(target, duration);
    } else s.frameAt(.link, target, duration);
}

pub fn layerDisplay(obj: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.dead) return;
    if (s.in_frame) {
        s.pending_sync = true;
        return s.requestFrame();
    }
    pacing.setPaced(s, false);
    s.renderer.setInTransaction(true);
    // finishFrame resets the transaction before any deferred destruction.
    s.frame();
}

pub fn liveResizeStart(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewWillStartLiveResize", .{});
    const s = objc.getZig(Surface, obj) orelse return;
    s.in_live_resize = true;
    pacing.setPaced(s, false);
}

pub fn liveResizeEnd(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "viewDidEndLiveResize", .{});
    const s = objc.getZig(Surface, obj) orelse return;
    s.in_live_resize = false;
    s.updateGeometry();
    // The final size must appear even when there is no further input.
    layerDisplay(obj, objc.sel("displayLayer:"), s.renderer.layer);
}

pub fn setFrameSize(obj: objc.Object, _: objc.SEL, size: objc.CGSize) callconv(.c) void {
    const old = objc.msg(objc.CGRect, obj, "frame", .{}).size;
    if (old.width == size.width and old.height == size.height) return;
    objc.msgSuper(void, obj, objc.class("NSView"), "setFrameSize:", .{size});
    const s = objc.getZig(Surface, obj) orelse return;
    s.updateGeometry();
    if (s.visible()) objc.msg(void, s.renderer.layer, "setNeedsDisplay", .{}) else s.frame();
}

pub fn backingChanged(obj: objc.Object, _: objc.SEL) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    s.updateGeometry();
    layerDisplay(obj, objc.sel("displayLayer:"), s.renderer.layer);
}
