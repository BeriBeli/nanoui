//! Real private NSView/layer callbacks; no visible window or system input.
const std = @import("std");
const objc = @import("../objc.zig");
const ui = @import("ui.zig");
const Surface = @import("surface.zig").Surface;
const Window = @import("../window.zig").Window;
const text = @import("text.zig");
const t = std.testing;

fn scale(_: objc.Object, _: objc.SEL) callconv(.c) f64 {
    return 1;
}
fn screen(_: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    return null;
}
fn focused(_: objc.Object, _: objc.SEL) callconv(.c) objc.BOOL {
    return objc.YES;
}
const Scene = struct {
    surface: *Surface,
    builds: usize = 0,
    transactions: usize = 0,
    resize_during_build: bool = false,
    fn view(self: *Scene, c: *ui.Context) void {
        self.builds += 1;
        self.transactions += @intFromBool(self.surface.renderer.in_transaction);
        ui.text(c, "Resize", .{});
        if (self.resize_during_build) {
            self.resize_during_build = false;
            objc.msg(void, self.surface.nsview, "setFrameSize:", .{objc.CGSize{ .width = 128, .height = 64 }});
        }
    }
};

test "layer resize commits fresh layout in its transaction and the final size needs no input" {
    const pool = objc.Pool.push();
    defer pool.pop();
    const wc = objc.defineClass(.{ .name = "NanoUIResizeTestWindow", .superclass = "NSObject", .methods = &.{
        .{ .name = "backingScaleFactor", .imp = &scale, .types = "d@:" },
        .{ .name = "screen", .imp = &screen, .types = "@@:" },
        .{ .name = "isKeyWindow", .imp = &focused, .types = "c@:" },
    } });
    const win = objc.msg(objc.Object, wc, "new", .{});
    defer objc.release(win);
    var window: Window = .{ .app = undefined, .nswindow = win, .delegate = undefined };
    const vc = objc.defineClass(.{ .name = "NanoUIResizeTestView", .superclass = "NSView", .methods = &@import("surface_events.zig").methods });
    const view = objc.msg(objc.Object, objc.msg(objc.Object, vc, "alloc", .{}), "initWithFrame:", .{objc.CGRect{ .size = .{ .width = 64, .height = 32 } }});
    defer objc.release(view);
    var s: Surface = .{ .gpa = t.allocator, .window = &window, .nsview = view, .text_queue = undefined, .renderer = try @import("metal.zig").Renderer.init(), .text = undefined, .ctx = undefined, .view = undefined, .is_visible = true, .size = .{ .w = 64, .h = 32 }, .scale = 1 };
    defer s.renderer.deinit();
    defer if (s.atlas_texture) |tex| objc.release(tex);
    defer s.instances.deinit(t.allocator);
    s.text = if (text.portable) .init(t.allocator) else .init(t.allocator, s.renderer.device);
    defer s.text.deinit();
    s.text.setScale(1);
    s.ctx = .init(t.allocator, &s.text);
    defer s.ctx.deinit();
    var scene: Scene = .{ .surface = &s };
    s.view = .init(&scene, Scene.view);
    objc.setZig(view, &s);
    defer objc.setZig(view, null);
    const layer = s.renderer.layer;
    objc.msg(void, view, "setLayer:", .{layer});
    objc.msg(void, view, "setWantsLayer:", .{objc.YES});
    objc.msg(void, layer, "setDelegate:", .{view});
    defer objc.msg(void, layer, "setDelegate:", .{@as(?objc.Object, null)});
    objc.msg(void, layer, "setNeedsDisplayOnBoundsChange:", .{objc.YES});
    s.renderer.resize(s.size, 1);
    const link = objc.retain(objc.msg(objc.Object, view, "displayLinkWithTarget:selector:", .{ view, objc.sel("displayLinkFired:") }));
    defer objc.release(link);
    defer objc.msg(void, link, "invalidate", .{});
    s.display_link = link;
    objc.msg(void, link, "setPaused:", .{objc.YES});
    defer if (@hasField(Surface, "wake_timer")) @import("surface_pacing.zig").cancelWake(&s);
    const log = try s.recordFrames(t.allocator);
    defer log.deinit();
    defer s.renderer.waitIdle();
    // The baseline must fail here, before messaging an absent selector.
    try t.expect(objc.msg(objc.BOOL, view, "respondsToSelector:", .{objc.sel("displayLayer:")}));
    objc.msg(void, view, "viewWillStartLiveResize", .{});
    for ([_]f64{ 80, 192, 96, 256, 64 }) |width| {
        const before = scene.builds;
        objc.msg(void, view, "setFrameSize:", .{objc.CGSize{ .width = width, .height = width / 2 }});
        try t.expectEqual(before, scene.builds); // resize waits for its layer transaction
        objc.msg(void, layer, "displayIfNeeded", .{});
        s.renderer.waitIdle();
        try t.expect(scene.builds > before);
        try t.expectEqual(scene.builds, scene.transactions);
        try t.expect(log.records.items.len > 0);
        try t.expect(log.records.items[log.records.items.len - 1].sync);
        try t.expectEqual(@as(f32, @floatCast(width)), s.ctx.size.w);
        try t.expect(!s.pending_sync);
        try t.expect(objc.msg(objc.BOOL, link, "isPaused", .{}));
    }
    const before_end = scene.builds;
    objc.msg(void, view, "viewDidEndLiveResize", .{});
    s.renderer.waitIdle();
    try t.expect(scene.builds > before_end);
    try t.expectEqual(scene.builds, scene.transactions);
    try t.expect(!s.in_live_resize and !s.renderer.in_transaction);
    // A native callback resizing midway through a build must not present
    // those instances at the new viewport size, even once.
    const presented = log.records.items.len;
    scene.resize_during_build = true;
    objc.msg(void, layer, "setNeedsDisplay", .{});
    objc.msg(void, layer, "displayIfNeeded", .{});
    s.renderer.waitIdle();
    try t.expectEqual(presented, log.records.items.len);
    try t.expect(s.pending_sync and s.full_pending);
    objc.msg(void, layer, "setNeedsDisplay", .{});
    objc.msg(void, layer, "displayIfNeeded", .{});
    s.renderer.waitIdle();
    try t.expect(log.records.items.len > presented);
    try t.expectEqual(@as(f32, 128), s.ctx.size.w);
    try t.expect(!s.pending_sync);
}
