//! Persistent CPU backing across volatile textures, filters and grouped drawing.
const std = @import("std");
const testing = std.testing;
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const damage = @import("damage.zig");
const glass = @import("glass.zig");
const empty_mask: raster.Mask = .{ .pixels = &.{}, .size = 0 };

test "persistent CPU surface redraws in-place texture updates and removal" {
    var surface: damage.Surface = .{};
    defer surface.deinit(testing.allocator);
    var pixels = [_]u8{ 0, 0, 255, 255 };
    const textures = [_]gpu.Texture{.{ .width = 1, .height = 1, .bgra = &pixels }};
    const pictures: raster.Pictures = .{ .textures = &textures };
    const image: gpu.Instance = .{
        .rect = .{ 0, 0, 1, 1 },
        .color = .{ 1, 1, 1, 1 },
        .uv = .{ 0, 0, 1, 1 },
        .kind = gpu.Kind.texture,
    };
    const frame: damage.Frame = .{ .width = 1, .height = 1, .scale = 1, .clear = .{ 0, 0, 0, 1 } };
    _ = try surface.render(testing.allocator, &.{image}, empty_mask, pictures, frame);
    try testing.expectEqualSlices(u8, &pixels, surface.bytes);
    pixels = .{ 255, 0, 0, 255 };
    const updated = try surface.render(testing.allocator, &.{image}, empty_mask, pictures, frame);
    try testing.expect(updated.damage == .full);
    try testing.expectEqualSlices(u8, &pixels, surface.bytes);
    const removed = try surface.render(testing.allocator, &.{}, empty_mask, .{}, frame);
    try testing.expect(removed.damage == .full);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, surface.bytes);
    const idle = try surface.render(testing.allocator, &.{}, empty_mask, .{}, frame);
    try testing.expect(idle.damage == .none);
}

test "persistent CPU glass redraw matches full backdrop after local changes" {
    var surface: damage.Surface = .{};
    defer surface.deinit(testing.allocator);
    const frame: damage.Frame = .{ .width = 64, .height = 48, .scale = 1, .clear = .{ 0, 0, 0, 1 } };
    var scene = [_]gpu.Instance{
        .{ .rect = .{ 0, 0, 64, 48 }, .color = .{ 0.1, 0.2, 0.6, 1 } },
        .{ .rect = .{ 12, 12, 4, 24 }, .color = .{ 1, 0, 0, 1 } },
        glass.instance(glass.material(.{}, 40, 32, false, 1), .{ 16, 8, 40, 32 }, 8, .{ 0, 0, 64, 48 }, 1),
    };
    var reference: [64 * 48 * 4]u8 = undefined;
    for (0..3) |pass| {
        if (pass == 1) scene[1].color = .{ 0, 1, 0, 1 };
        const instances = if (pass == 2) scene[0..2] else &scene;
        const result = try surface.render(testing.allocator, instances, empty_mask, .{}, frame);
        try testing.expect(result.damage == .full);
        raster.draw(.{ .bytes = &reference, .width = 64, .height = 48 }, instances, empty_mask, .{}, 1, .black);
        try testing.expectEqualSlices(u8, &reference, surface.bytes);
    }
}

test "group opacity updates and removal equal a complete CPU frame" {
    const a = std.testing.allocator;
    var cpu: damage.Surface = .{};
    defer cpu.deinit(a);
    const frame: damage.Frame = .{ .width = 64, .height = 48, .scale = 1, .clear = .{ 1, 1, 1, 1 } };
    var scene = [_]gpu.Instance{
        .{ .rect = .{ 0, 0, 64, 48 }, .color = .{ 1, 1, 1, 1 }, .kind = gpu.Kind.layer_begin },
        .{ .rect = .{ 8, 6, 32, 24 }, .color = .{ 1, 0, 0, 1 } },
        .{ .rect = .{ 22, 14, 32, 24 }, .color = .{ 0, 0, 1, 1 } },
        .{ .rect = .{ 0, 0, 64, 48 }, .color = .{ 1, 1, 1, 0.5 }, .kind = gpu.Kind.layer_end },
    };
    const reference = try a.alloc(u8, 64 * 48 * 4);
    defer a.free(reference);
    const mask: raster.Mask = .{ .pixels = &.{}, .size = 0 };
    for (0..3) |step| {
        scene[2].rect[0] += 3;
        const stream: []const gpu.Instance = if (step < 2) &scene else scene[1..3];
        const r = try cpu.render(a, stream, mask, .{}, frame);
        try std.testing.expect(r.damage == .full);
        raster.draw(.{ .bytes = reference, .width = 64, .height = 48 }, stream, mask, .{}, 1, .{ .r = 1, .g = 1, .b = 1 });
        try std.testing.expectEqualSlices(u8, reference, cpu.bytes);
    }
}

test "damage rejects nonfinite transform pulse and velocity fields" {
    const a = std.testing.allocator;
    var cpu: damage.Surface = .{};
    defer cpu.deinit(a);
    const frame: damage.Frame = .{ .width = 64, .height = 48, .scale = 1, .clear = .{ 1, 1, 1, 1 } };
    inline for (.{ "xf", "pulse", "vel" }) |field| {
        var i: gpu.Instance = .{ .rect = .{ 8, 6, 32, 24 }, .color = .{ 1, 0, 0, 1 } };
        @field(i, field)[0] = std.math.nan(f32);
        try std.testing.expectError(error.InvalidGeometry, cpu.render(a, &.{i}, .{ .pixels = &.{}, .size = 0 }, .{}, frame));
        try std.testing.expect(!cpu.valid);
    }
}
