//! Convert physical CPU damage to GTK logical invalidation. Exposure still
//! paints the complete backing through GTK's clip, including undamaged pixels.
const std = @import("std");
const gtk = @import("gtk.zig");
const damage = @import("../ui/damage.zig");
pub const Rect = struct { x: c_int, y: c_int, width: c_int, height: c_int };
pub fn logical(r: damage.tracking.Rect, scale: f32) Rect {
    const factor: f64 = @floatCast(@max(1, scale));
    const x: c_int = @intFromFloat(@floor(@as(f64, @floatFromInt(r.x)) / factor));
    const y: c_int = @intFromFloat(@floor(@as(f64, @floatFromInt(r.y)) / factor));
    const right: c_int = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.right())) / factor));
    const bottom: c_int = @intFromFloat(@ceil(@as(f64, @floatFromInt(r.bottom())) / factor));
    return .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
}
pub fn queue(area: *gtk.Widget, dirty: damage.Damage, scale: f32) void {
    queueUsing(.{ .gtk_widget_queue_draw = gtk.api.gtk_widget_queue_draw, .gtk_widget_queue_draw_area = gtk.v3.gtk_widget_queue_draw_area }, area, dirty, scale);
}
fn queueUsing(api: anytype, area: *gtk.Widget, dirty: damage.Damage, scale: f32) void {
    switch (dirty) {
        .none => {},
        .full => api.gtk_widget_queue_draw(area),
        .rect => |r| {
            const rect = logical(r, scale);
            api.gtk_widget_queue_draw_area(area, rect.x, rect.y, rect.width, rect.height);
        },
    }
}
test "physical damage rounds outward at GTK scale" {
    try std.testing.expectEqual(Rect{ .x = 3, .y = 5, .width = 7, .height = 9 }, logical(.{ .x = 3, .y = 5, .width = 7, .height = 9 }, 1));
    try std.testing.expectEqual(Rect{ .x = 1, .y = 2, .width = 4, .height = 5 }, logical(.{ .x = 3, .y = 5, .width = 7, .height = 9 }, 2));
}

test "unchanged frames do not invalidate GTK and partial frames keep their damage" {
    const Mock = struct {
        var full_count: usize = 0;
        var rect_count: usize = 0;
        var last: Rect = undefined;
        fn full(_: *gtk.Widget) callconv(.c) void {
            full_count += 1;
        }
        fn rect(_: *gtk.Widget, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void {
            rect_count += 1;
            last = .{ .x = x, .y = y, .width = width, .height = height };
        }
    };
    const api = .{ .gtk_widget_queue_draw = Mock.full, .gtk_widget_queue_draw_area = Mock.rect };
    var owned: u8 = 0;
    const area: *gtk.Widget = @ptrCast(&owned);
    queueUsing(api, area, .none, 1);
    try std.testing.expectEqual(@as(usize, 0), Mock.full_count + Mock.rect_count);
    queueUsing(api, area, .{ .rect = .{ .x = 9, .y = 15, .width = 12, .height = 24 } }, 2);
    try std.testing.expectEqual(Rect{ .x = 4, .y = 7, .width = 7, .height = 13 }, Mock.last);
    try std.testing.expectEqual(@as(usize, 0), Mock.full_count);
    queueUsing(api, area, .full, 1);
    try std.testing.expectEqual(@as(usize, 1), Mock.full_count);
    try std.testing.expectEqual(@as(usize, 1), Mock.rect_count);
}
