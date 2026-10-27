//! AppKit pointer tracking and accessibility preferences.
const objc = @import("../objc.zig");

pub fn update(obj: objc.Object, tracking: *?objc.Object) void {
    objc.msgSuper(void, obj, objc.class("NSView"), "updateTrackingAreas", .{});
    if (tracking.*) |t| {
        objc.msg(void, obj, "removeTrackingArea:", .{t});
        objc.release(t);
    }
    // Entered and exited, moved, always active, in the visible rect.
    const opts: objc.NSUInteger = 0x01 | 0x02 | 0x80 | 0x200;
    const area = objc.msg(objc.Object, objc.alloc("NSTrackingArea"), "initWithRect:options:owner:userInfo:", .{
        objc.CGRect{}, opts, obj, @as(?objc.Object, null),
    });
    objc.msg(void, obj, "addTrackingArea:", .{area});
    tracking.* = area;
}

/// System Settings, Accessibility, Display, Reduce motion.
pub fn reduceMotion() bool {
    const ws = objc.msg(objc.Object, objc.class("NSWorkspace"), "sharedWorkspace", .{});
    return objc.msg(objc.BOOL, ws, "accessibilityDisplayShouldReduceMotion", .{});
}
