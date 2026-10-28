//! Opaque fill optimization parity with clipped, rotated and circular quads.
const std = @import("std");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const bounds = raster.bounds;
const quad = raster.quad;
const quadScalar = raster.quadScalar;

test "opaque interior fill matches scalar blending including fractional clipped edges" {
    const a = std.testing.allocator;
    const actual = try a.alloc(u8, 160 * 100 * 4);
    defer a.free(actual);
    const expected = try a.alloc(u8, actual.len);
    defer a.free(expected);
    const out: gpu.Pixels = .{ .bytes = actual, .width = 160, .height = 100 };
    const reference: gpu.Pixels = .{ .bytes = expected, .width = 160, .height = 100 };
    for ([_]f32{ 0.75, 1, 1.25, 2 }) |scale| for ([_]f32{ 0, 3.25, 20, -12 }) |radius| for ([_]f32{ 0, 1.3 }) |border| for (0..11) |variant| {
        const i: gpu.Instance = .{
            .rect = if (variant == 1) .{ -9.3, -4.7, 112.8, 67.2 } else if (variant == 2) .{ 7.3, 5.7, 4.2, 3.3 } else .{ 7.3, 5.7, 112.8, 67.2 },
            .color = .{ if (variant == 3) 0.0019607842 else 0.94, 0.12745097, 0.6, if (variant >= 8) 0 else if (variant == 4) 0.6 else 1 },
            .radius = radius,
            .xf = if (variant == 10) .{ 0.6, 0, 60, 40 } else .{ 0, 0, 0, 0 },
            .border_width = border,
            .border_color = .{ 0.8, 0.2, 0.1, if (variant == 8) 0 else 0.7 },
            .clip = .{ 2.4, 3.8, 126.7, 84.9 },
            .clip_round = if (variant == 5) gpu.clipRound(9, 15) else 0,
        };
        const b = bounds(out, &i, scale) orelse continue;
        const clipped: [4]usize = if (variant == 6) .{ @max(b[0], 36), @max(b[1], 24), @min(b[2], 86), @min(b[3], 51) } else if (variant == 7) .{ b[0], b[1], @min(b[2], b[0] + 1), b[3] } else b;
        if (clipped[2] <= clipped[0] or clipped[3] <= clipped[1]) continue;
        for (actual, 0..) |*v, at| v.* = @truncate(at * 37);
        @memcpy(expected, actual);
        quad(out, &i, scale, clipped);
        quadScalar(reference, &i, scale, clipped);
        try std.testing.expectEqualSlices(u8, expected, actual);
    };
}
