//! GTK font DPI maps points to logical units, independently of device scale.
const std = @import("std");
pub fn pointsToLogical(dpi: f64) f32 {
    const valid = if (std.math.isFinite(dpi) and dpi > 0 and dpi <= 768) dpi else 96;
    return @floatCast(valid / 72);
}
test "font points follow GTK DPI independently of backing pixel scale" {
    try std.testing.expectApproxEqAbs(@as(f32, 96.0 / 72.0), pointsToLogical(96), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 120.0 / 72.0), pointsToLogical(120), 0.0001);
    for ([_]f64{ -1, 0, std.math.nan(f64), std.math.inf(f64), 1e20 }) |dpi|
        try std.testing.expectEqual(pointsToLogical(96), pointsToLogical(dpi));
}
