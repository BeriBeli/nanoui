const std = @import("std");
const ui = @import("nanoui").ui;
const Mode = @import("options.zig").Mode;

pub const State = struct {
    mode: Mode = .idle,
    step: u64 = 0,
    wheel_rows: u64 = 0,
    inputs: u64 = 0,
    input_pending_since: ?f64 = null,
    field: ui.TextBuffer = .{},

    pub fn view(self: *State, c: *ui.Context) void {
        if (self.mode == .input) c.wants_wheel = true;
        if (self.mode == .input and (c.input.pressed or c.input.ops.len != 0 or c.input.scroll.y != 0)) {
            self.inputs += 1;
            if (self.input_pending_since == null) self.input_pending_since = ui.clock.now();
            if (c.input.scroll.y < 0) self.wheel_rows +|= 1;
            if (c.input.scroll.y > 0) self.wheel_rows -|= 1;
        }
        const bg: ui.Color = if (self.mode == .full and self.step % 2 == 1) .hex(0x203549) else .hex(0x101a25);
        ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 12, .background = bg, .clip = true });
        defer ui.end(c);
        ui.text(c, "NANOUI / X11 FORWARDING", .{ .size = 22, .weight = .bold, .color = .hex(0xdce8f5) });
        ui.textf(c, .{ .size = 14, .color = .hex(0x9aafc5) }, "Workload: {s}   |   CPU raster + GTK 3   |   Report on stdout", .{@tagName(self.mode)});
        if (self.mode == .input) {
            ui.text(c, "Click the field and type. Scroll here or press Ack. Watch the counter respond.", .{ .size = 14, .color = .hex(0xdce8f5) });
            ui.key(c, "input-field");
            _ = ui.textField(c, &self.field, .{ .placeholder = "Type to test forwarding and IME", .width = .fill });
            if (ui.button(c, "Ack", .{}).clicked) c.changed = true;
            ui.textf(c, .{ .size = 20, .color = .hex(0x65d4aa), .mono = true }, "Acknowledged events: {d}", .{self.inputs});
        }
        ui.column(c, .{ .width = .fill, .height = .fill, .background = .hex(0x0b121b), .clip = true });
        defer ui.end(c);
        if (self.mode == .full) {
            // Deterministic changing tiles: unlike a solid fill, exercise SSH
            // compression with a less compressible, repeatable payload.
            const w = @max(1, (c.size.w - 40) / 40);
            const h = @max(1, (c.size.h - 110) / 24);
            for (0..24) |y| for (0..40) |x| {
                var n: u64 = self.step *% 0x9e3779b97f4a7c15 +% (y * 40 + x);
                n = (n ^ (n >> 30)) *% 0xbf58476d1ce4e5b9;
                n = (n ^ (n >> 27)) *% 0x94d049bb133111eb;
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = @as(f32, @floatFromInt(x)) * w, .y = @as(f32, @floatFromInt(y)) * h }, .width = .{ .px = w + 1 }, .height = .{ .px = h + 1 }, .background = .hex(@truncate(n ^ (n >> 31))) }, .none, null);
            };
        } else {
            const rows: usize = @intFromFloat(@min(100, @max(1, (c.size.h - 140) / 20)));
            const offset = if (self.mode == .scroll) self.step else self.wheel_rows;
            for (0..rows) |i| {
                ui.key(c, c.print("row-{d}", .{i}));
                ui.textf(c, .{ .size = 14, .mono = true, .color = if (i % 5 == 0) .hex(0x65d4aa) else .hex(0xb6c7da) }, "{d:0>8}  INFO  host=centos79  task=render  abcdefghijklmnopqrstuvwxyz  0123456789", .{offset + i});
            }
            // The header and text remain unchanged in small mode. Damage stays
            // near this 32x24 patch, with no changing statistics elsewhere.
            if (self.mode == .small) _ = c.leaf(.{ .absolute = true, .offset = .{ .x = c.size.w - 100, .y = 4 }, .width = .{ .px = 32 }, .height = .{ .px = 24 }, .background = if (self.step % 2 == 1) .hex(0xffbe65) else .hex(0x268a74) }, .none, null);
        }
    }
};

test "input is acknowledged and workloads render offscreen without animation" {
    var s: State = .{ .mode = .input };
    defer s.field.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, State.view), .{ .width = 1100, .height = 720, .scale = 1 });
    defer t.deinit();
    try t.clickText("Type to test forwarding and IME");
    t.textOps(&.{.{ .insert = "hello" }});
    try std.testing.expectEqualStrings("hello", s.field.text());
    try std.testing.expect(s.inputs > 0 and s.input_pending_since != null);
    for ([_]Mode{ .idle, .small, .scroll, .full }) |mode| {
        s.mode = mode;
        s.step += 1;
        t.frame();
        try std.testing.expect(!t.ctx.animating);
    }
}

test "idle leaves pixels unchanged and small workload damages only its patch" {
    var s: State = .{ .mode = .small };
    defer s.field.deinit();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, State.view), .{ .width = 1100, .height = 720, .scale = 1 });
    defer t.deinit();
    t.settle(0);
    var backing: ui.CpuDamage.Surface = .{};
    defer backing.deinit(std.testing.allocator);
    const Adapter = struct {
        fn draw(tester: *ui.Tester, cpu: *ui.CpuDamage.Surface) !ui.CpuDamage.Damage {
            return (try cpu.render(std.testing.allocator, tester.instances.items, tester.text.atlas.mask(), tester.text.images.pictures(), .{
                .width = 1100,
                .height = 720,
                .scale = 1,
                .clear = ui.gpu.color4(tester.theme.background),
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
