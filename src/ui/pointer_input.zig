//! Internal native pointer normalization and physical gesture ownership.
const std = @import("std");
const Button = @import("input.zig").Button;
/// Physical presses outlive a UI gesture (a context menu clears Input.down).
/// Backends must still deliver each owned release once to raw input consumers.
pub const Buttons = struct {
    pressed: [3]bool = @splat(false),

    pub fn press(self: *Buttons, button: Button) void {
        self.pressed[@backingInt(button)] = true;
    }

    pub fn release(self: *Buttons, button: Button) bool {
        const down = &self.pressed[@backingInt(button)];
        if (!down.*) return false;
        down.* = false;
        return true;
    }
};

/// GDK uses 2 for middle and 3 for right; Input uses upstream enum tags.
pub fn gtkButton(button: u32) ?Button {
    return switch (button) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => null,
    };
}
test "GTK mouse buttons normalize to the shared right/middle contract" {
    try std.testing.expectEqual(@as(?Button, .right), gtkButton(3));
    try std.testing.expectEqual(@as(?Button, .middle), gtkButton(2));
    try std.testing.expectEqual(@as(?Button, null), gtkButton(9));
}

/// AppKit can report a slow discrete wheel detent as 0.1. Keep each
/// nonzero detent responsive while retaining OS acceleration above one.
/// Precise devices must keep their fractional logical-pixel displacement.
pub fn macosScrollDelta(delta: f32, precise: bool) f32 {
    if (!std.math.isFinite(delta)) return 0;
    if (precise or delta == 0) return delta;
    return if (delta > 0) @max(1, delta) else @min(-1, delta);
}
test "AppKit discrete detents have a minimum step without amplifying precise input" {
    try std.testing.expectEqual(@as(f32, 1), macosScrollDelta(0.1, false));
    try std.testing.expectEqual(@as(f32, -1), macosScrollDelta(-0.1, false));
    try std.testing.expectEqual(@as(f32, 2.5), macosScrollDelta(2.5, false));
    try std.testing.expectEqual(@as(f32, 0), macosScrollDelta(0, false));
    try std.testing.expectEqual(@as(f32, 0.1), macosScrollDelta(0.1, true));
    try std.testing.expectEqual(@as(f32, -0.1), macosScrollDelta(-0.1, true));
}
