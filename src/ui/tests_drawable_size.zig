//! A Metal display link may supply a drawable acquired before the layer's
//! size changed. Never display the new layout stretched from that old target.
const std = @import("std");
const objc = @import("../objc.zig");
const metal = @import("metal.zig");
const t = std.testing;

test "a supplied drawable from before resize is rejected without consuming the next frame" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var renderer = try metal.Renderer.init();
    defer renderer.deinit();
    renderer.resize(.{ .w = 1, .h = 1 }, 1);
    const stale = objc.msg(?objc.Object, renderer.layer, "nextDrawable", .{}) orelse return error.NoPrivateDrawable;
    const texture = objc.msg(objc.Object, stale, "texture", .{});
    try t.expectEqual(@as(usize, 1), objc.msg(usize, texture, "width", .{}));
    renderer.resize(.{ .w = 64, .h = 32 }, 1);
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        @as(usize, 10), @as(usize, 1), @as(usize, 1), objc.NO,
    });
    const atlas = objc.msg(objc.Object, renderer.device, "newTextureWithDescriptor:", .{desc});
    defer objc.release(atlas);
    const instances = [_]metal.Instance{.{ .rect = .{ 0, 0, 64, 32 }, .color = .{ 0, 0, 1, 1 } }};
    renderer.given_drawable = stale;
    const rejected = renderer.drawLogged(&instances, atlas, .{ .w = 64, .h = 32 }, .white, null, 0);
    renderer.waitIdle();
    try t.expect(!rejected.presented);
    try t.expect(renderer.given_drawable == null);
    for (0..6) |_| {
        renderer.given_drawable = objc.msg(?objc.Object, renderer.layer, "nextDrawable", .{}) orelse return error.NoPrivateDrawable;
        const accepted = renderer.drawLogged(&instances, atlas, .{ .w = 64, .h = 32 }, .white, null, 0);
        renderer.waitIdle();
        try t.expect(accepted.presented);
    }
}

pub fn surfaceRetry(comptime present: anytype) !void {
    const Surface = @import("surface.zig").Surface;
    const text = @import("text.zig");
    const frame = @import("frame.zig");
    const ui = @import("ui.zig");
    const pool = objc.Pool.push();
    defer pool.pop();
    var s: Surface = .{ .gpa = t.allocator, .window = undefined, .nsview = undefined, .text_queue = undefined, .renderer = try metal.Renderer.init(), .text = undefined, .ctx = undefined, .view = undefined, .size = .{ .w = 64, .h = 32 }, .scale = 1 };
    defer s.renderer.deinit();
    defer if (s.atlas_texture) |tex| objc.release(tex);
    defer s.instances.deinit(t.allocator);
    s.text = if (text.portable) .init(t.allocator) else .init(t.allocator, s.renderer.device);
    defer s.text.deinit();
    s.text.setScale(1);
    s.ctx = .init(t.allocator, &s.text);
    defer s.ctx.deinit();
    const Scene = struct {
        fn view(_: *u8, c: *ui.Context) void {
            ui.text(c, "A", .{});
        }
    };
    var state: u8 = 0;
    s.view = .init(&state, Scene.view);
    _ = frame.run(&s.ctx, s.view, &s.text, &s.instances, s.size, s.scale, .light, 1.0 / 60.0, 1);
    s.renderer.resize(.{ .w = 1, .h = 1 }, 1);
    s.renderer.given_drawable = objc.msg(?objc.Object, s.renderer.layer, "nextDrawable", .{}) orelse return error.NoPrivateDrawable;
    s.renderer.resize(s.size, s.scale);
    const rec = std.mem.zeroes(@import("frame_log.zig").Record);
    try t.expect(!present(&s, 1, 0, 1.0 / 60.0, true, rec));
    try t.expect(s.pending_sync);
    const sync = s.pending_sync;
    s.pending_sync = false;
    s.renderer.given_drawable = objc.msg(?objc.Object, s.renderer.layer, "nextDrawable", .{}) orelse return error.NoPrivateDrawable;
    try t.expect(present(&s, 2, 0, 1.0 / 60.0, sync, rec));
    s.renderer.waitIdle();
    try t.expect(!s.pending_sync);
    try t.expect(s.last_present_target > 0);
}
