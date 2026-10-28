//! Native backdrop hosting behind a transparent Metal surface.
const objc = @import("../objc.zig");
const Surface = @import("surface.zig").Surface;

pub fn attachBackdrop(self: *Surface, stage_view: objc.Object) void {
    const host_class = objc.defineClass(.{
        .name = "NanoUIHostView",
        .superclass = "NSView",
        .methods = &.{.{ .name = "isFlipped", .imp = &@import("surface_events.zig").yes, .types = "c@:" }},
    });
    const b = objc.msg(objc.CGRect, self.nsview, "bounds", .{});
    const host = objc.msg(objc.Object, objc.msg(objc.Object, host_class, "alloc", .{}), "initWithFrame:", .{b});
    objc.msg(void, host, "setWantsLayer:", .{objc.YES});
    objc.msg(void, host, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
    objc.msg(void, self.nsview, "retain", .{});
    defer objc.msg(void, self.nsview, "release", .{});
    objc.msg(void, self.window.nswindow, "setContentView:", .{host});
    objc.msg(void, stage_view, "setFrame:", .{b});
    objc.msg(void, stage_view, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
    objc.msg(void, self.nsview, "setFrame:", .{b});
    objc.msg(void, self.nsview, "setAutoresizingMask:", .{@as(objc.NSUInteger, 2 | 16)});
    objc.msg(void, host, "addSubview:", .{stage_view});
    objc.msg(void, host, "addSubview:", .{self.nsview});
    if (self.ctx.focus != 0) _ = objc.msg(objc.BOOL, self.window.nswindow, "makeFirstResponder:", .{self.nsview});
    objc.release(host);
    self.setTransparent(true);
    self.hosted = true;
    self.geometry_changed = true;
}
