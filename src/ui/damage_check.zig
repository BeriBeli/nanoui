//! Pixel-level comparison with the SAME full CPU renderer, no window or model
//! oracle. Synthetic atlas texels exercise blending/sampling (not font shaping).
const std = @import("std");
const cpu = @import("damage.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const types = @import("types.zig");
const Want = enum { full, rect, none };
const Fixture = struct {
    gpa: std.mem.Allocator,
    surface: cpu.Surface = .{},
    reference: []u8 = &.{},
    mask_pixels: [4]u8 = .{ 0, 255, 128, 255 },
    image_pixels: [16]u8 = .{ 0, 0, 255, 255, 0, 128, 0, 128, 64, 0, 0, 64, 60, 90, 120, 180 },
    frame: cpu.Frame = .{ .width = 180, .height = 140, .scale = 1.25, .clear = .{ 0.1, 0.15, 0.2, 1 } },
    count: usize = 0,
    fn deinit(f: *Fixture) void {
        f.surface.deinit(f.gpa);
        f.gpa.free(f.reference);
    }
    fn compare(f: *Fixture, instances: []const gpu.Instance, want: Want, label: []const u8) !cpu.Result {
        const mask: raster.Mask = .{ .pixels = &f.mask_pixels, .size = 2 };
        const images: raster.Pictures = .{ .pixels = &f.image_pixels, .size = 2 };
        const result = try f.surface.render(f.gpa, instances, mask, images, f.frame);
        const len = @as(usize, f.frame.width) * f.frame.height * 4;
        if (f.reference.len != len) {
            f.gpa.free(f.reference);
            f.reference = &.{};
            f.reference = try f.gpa.alloc(u8, len);
        }
        const clear: types.Color = .{ .r = f.frame.clear[0], .g = f.frame.clear[1], .b = f.frame.clear[2], .a = f.frame.clear[3] };
        raster.draw(.{ .bytes = f.reference, .width = f.frame.width, .height = f.frame.height }, instances, mask, images, f.frame.scale, clear);
        const correct_kind = switch (want) {
            .none => result.damage == .none,
            .full => result.damage == .full,
            .rect => result.damage == .rect,
        };
        const same = std.mem.eql(u8, f.reference, f.surface.bytes);
        if (!same or !correct_kind) {
            std.debug.print("FAIL UI CPU damage {s}: pixel_equal={} expected={s} got={s}\n", .{ label, same, @tagName(want), @tagName(result.damage) });
            return error.CpuDamagePixelMismatch;
        }
        try f.check(true, label);
        return result;
    }
    fn check(f: *Fixture, ok: bool, label: []const u8) !void {
        std.debug.print("{s} UI CPU damage {s}\n", .{ if (ok) "PASS" else "FAIL", label });
        if (!ok) return error.CpuDamageCheck;
        f.count += 1;
    }
};
fn scene() [9]gpu.Instance {
    return .{
        .{ .rect = .{ 0, 0, 144, 112 }, .color = .{ 0.12, 0.18, 0.22, 1 } },
        .{ .rect = .{ 24, 20, 80, 50 }, .color = .{ 0, 0, 0, 0.4 }, .kind = gpu.Kind.shadow, .border_width = 4, .radius = 9 },
        .{ .rect = .{ 20, 14, 96, 72 }, .color = .{ 0.8, 0.5, 0.2, 0.6 }, .radius = 10, .border_width = 1, .border_color = .{ 0.2, 0.9, 0.6, 0.7 }, .clip = .{ 19, 12, 118, 88 }, .clip_round = gpu.clipRound(13, 15) },
        .{ .rect = .{ 28, 24, 18, 22 }, .color = .{ 0.8, 0.9, 0.6, 0.8 }, .kind = gpu.Kind.text, .uv = .{ 0, 0, 1, 1 }, .clip = .{ 20, 14, 116, 86 }, .clip_round = gpu.clipRound(10, 9) },
        .{ .rect = .{ 66, 26, 34, 24 }, .color = .{ 1, 1, 1, 0.7 }, .kind = gpu.Kind.image, .uv = .{ 0, 0, 1, 1 }, .radius = 6, .clip = .{ 20, 14, 116, 86 }, .clip_round = gpu.clipRound(10, 15) },
        .{ .rect = .{ 26, 24, 56, 24 }, .color = .{ 0.1, 0.4, 0.9, 0.25 } },
        .{ .rect = .{ 46, 24, 2, 22 }, .color = .{ 0.9, 0.95, 1, 0.8 } },
        .{ .rect = .{ 28, 54, 48, 12 }, .color = .{ 0.9, 0.7, 0.1, 0.4 }, .radius = 2 },
        .{ .rect = .{ 20, 14, 96, 72 }, .color = .{ 0.4, 0.1, 0.8, 0.18 }, .radius = 10, .clip = .{ 20, 14, 116, 86 }, .clip_round = gpu.clipRound(10, 15) },
    };
}
pub fn run(gpa: std.mem.Allocator) !usize {
    var f: Fixture = .{ .gpa = gpa };
    defer f.deinit();
    var instances = scene();
    _ = try f.compare(&instances, .full, "initial persistent pixels equal complete CPU draw");
    const idle = try f.compare(&instances, .none, "unchanged frame does zero raster work");
    try f.check(idle.damage == .none, "idle performs no clear or instance replay");
    instances[6].rect[0] += 4;
    const cursor = try f.compare(&instances, .rect, "cursor move preserves all overlapping translucent rounded layers");
    try f.check(@as(usize, cursor.damage.rect.width) * cursor.damage.rect.height < @as(usize, f.frame.width) * f.frame.height, "cursor update clears a subregion and replays all intersecting current instances");
    instances[5].rect[2] -= 11;
    _ = try f.compare(&instances, .rect, "selection shrink clears removed coverage");
    instances[7].color = .{ 0.6, 0.2, 0.8, 0.65 };
    _ = try f.compare(&instances, .rect, "search overlay tint updates physical pixels");
    instances[8].rect[0] += 3;
    instances[8].clip_round = gpu.clipRound(12, 1 | 4);
    _ = try f.compare(&instances, .rect, "overlay and asymmetric round clip keep original clip geometry");
    instances[1].border_width = 7;
    _ = try f.compare(&instances, .rect, "shadow blur includes old and new halo extents");
    instances[2].border_color = .{ 0.8, 0.1, 0.5, 0.4 };
    instances[2].border_width = 3;
    _ = try f.compare(&instances, .rect, "border fields participate in pixel damage");
    instances[4].uv = .{ 0.25, 0, 0.75, 1 };
    _ = try f.compare(&instances, .rect, "image crop UV changes are repainted");
    std.mem.swap(gpu.Instance, &instances[3], &instances[5]);
    _ = try f.compare(&instances, .rect, "translucent paint order change recomposites current stream");
    _ = try f.compare(instances[0..8], .rect, "overlay removal erases old pixels and restores lower layers");
    instances = scene();
    _ = try f.compare(&instances, .rect, "overlay insertion restores ordered alpha composition");
    for (instances[3..8]) |*instance| instance.rect[1] -= 9;
    _ = try f.compare(&instances, .rect, "scroll moves glyph image selection search and cursor together");
    instances[1].kind = gpu.Kind.shadow_out;
    _ = try f.compare(&instances, .rect, "knockout shadow halo updates retained pixels");
    instances[1].xf = .{ 0.6, 0, 64, 52 };
    instances[2].xf = .{ 0.4, 0, 66, 50 };
    instances[3].xf = .{ -0.5, 0, 37, 35 };
    instances[4].xf = .{ 0.3, 0, 83, 38 };
    _ = try f.compare(&instances, .rect, "rotated glyphs images quads and shadows include all changed corners");
    instances[2].xf[0] = -0.6;
    _ = try f.compare(&instances, .rect, "transform-only changes erase old rotated coverage");
    instances[2].pulse = .{ 0.5, 0.4, 1, 0 };
    instances[2].vel = .{ 3, 4, 0, 0 };
    _ = try f.compare(&instances, .rect, "pulse and velocity participate in damage comparison");
    f.mask_pixels[0] = 230;
    f.frame.glyph_generation += 1;
    _ = try f.compare(&instances, .full, "in-place glyph atlas generation forces complete repaint");
    f.image_pixels[0] = 100;
    f.frame.image_generation += 1;
    _ = try f.compare(&instances, .full, "in-place image atlas generation forces complete repaint");
    f.frame.theme_generation += 1;
    _ = try f.compare(&instances, .full, "theme identity invalidates retained backing");
    f.frame.clear = .{ 0.2, 0.1, 0.05, 1 };
    _ = try f.compare(&instances, .full, "clear color change forces complete repaint");
    f.frame.scale = 1.75;
    _ = try f.compare(&instances, .full, "fractional DPI scale change forces complete repaint");
    f.frame.width = 212;
    f.frame.height = 166;
    _ = try f.compare(&instances, .full, "resize replaces backing and repaints all pixels");
    @memset(f.surface.bytes, 0x5a);
    f.surface.invalidate();
    _ = try f.compare(&instances, .full, "lost CPU backing invalidates and rebuilds correct pixels");
    @memset(f.surface.bytes, 0x9c);
    f.surface.presentationFailed();
    _ = try f.compare(&instances, .full, "present failure invalidates optimistic damage state");
    const exposure = f.surface.pixels();
    try f.check(std.mem.eql(u8, exposure.bytes, f.reference), "exposure reads current persistent pixels after changes");
    _ = try f.compare(&instances, .none, "exposure reuse leaves unchanged CPU pixels untouched");
    instances[6].rect = .{ -0.4, -0.6, 3.8, 4.1 };
    instances[6].clip = .{ -1, -1, 2.6, 2.8 };
    _ = try f.compare(&instances, .rect, "fractional negative edge clips match complete raster at framebuffer boundary");
    const before_bad = f.frame;
    var bad = f.frame;
    bad.scale = std.math.nan(f32);
    const rejected = if (f.surface.render(gpa, &instances, .{ .pixels = &f.mask_pixels, .size = 2 }, .{}, bad)) |_| false else |err| err == error.InvalidFrame;
    try f.check(rejected and !f.surface.valid, "invalid render marks retained backing unusable");
    f.frame = before_bad;
    _ = try f.compare(&instances, .full, "valid frame after draw rejection completely rebuilds backing");
    // Atlas SIZE invalidation independent of its generation, then restore it.
    const sized = try f.surface.render(gpa, &instances, .{ .pixels = f.mask_pixels[0..1], .size = 1 }, .{ .pixels = &f.image_pixels, .size = 2 }, f.frame);
    try f.check(sized.damage == .full, "glyph atlas dimensions invalidate even with unchanged generation");
    _ = try f.compare(&instances, .full, "restored atlas size returns exact complete pixels");
    var failure = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var empty: cpu.Surface = .{};
    defer empty.deinit(failure.allocator());
    const oom = if (empty.render(failure.allocator(), &instances, .{ .pixels = &f.mask_pixels, .size = 2 }, .{}, f.frame)) |_| false else |err| err == error.OutOfMemory;
    try f.check(oom and !empty.valid and empty.bytes.len == 0, "backing allocation failure cannot present stale pixels");
    return f.count;
}
test "persistent scissored CPU output exactly matches complete raster" {
    _ = try run(std.testing.allocator);
}
