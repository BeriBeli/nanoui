const std = @import("std");
const ui = @import("ui.zig");
const State = struct {
    step: u64 = 0,
    fn view(self: *@This(), c: *ui.Context) void {
        ui.column(c, .{ .width = .fill, .height = .fill, .background = .hex(0x101a25) });
        defer ui.end(c);
        ui.text(c, "Stable forwarding workload", .{});
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 100, .y = 60 }, .width = .{ .px = 32 }, .height = .{ .px = 24 }, .background = if (self.step % 2 == 1) .hex(0xffbe65) else .hex(0x268a74) }, .none, null);
    }
};
test "idle leaves pixels unchanged and small workload damages only its patch" {
    if (comptime !@import("text.zig").portable) return error.SkipZigTest;
    var s: State = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, State.view), .{ .width = 1100, .height = 720, .scale = 1 });
    defer t.deinit();
    t.settle(0);
    var backing: @import("damage.zig").Surface = .{};
    defer backing.deinit(std.testing.allocator);
    const Adapter = struct {
        fn draw(tester: *ui.Tester, cpu: *@import("damage.zig").Surface) !@import("damage.zig").Damage {
            return (try cpu.render(std.testing.allocator, tester.instances.items, tester.text.atlas.mask(), tester.text.images.pictures(), .{
                .width = 1100,
                .height = 720,
                .scale = 1,
                .clear = @import("gpu.zig").color4(tester.theme.background),
                .glyph_generation = tester.text.atlas.generation,
                .image_generation = tester.text.images.generation,
            })).damage;
        }
    };
    try std.testing.expect(try Adapter.draw(&t, &backing) == .full);
    t.frame();
    try std.testing.expect(try Adapter.draw(&t, &backing) == .none);
    s.step += 1;
    t.frame();
    const small = (try Adapter.draw(&t, &backing)).rect;
    try std.testing.expect(small.width <= 36 and small.height <= 28);
}
