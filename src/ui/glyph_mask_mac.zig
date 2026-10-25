//! Bounded CoreText rasterization into a monochrome ink mask. This preserves
//! color-glyph luminance details, not their color: white highlights become no
//! ink, dark eyes become dense ink, and colored surfaces retain grey shading.
//! origin is a translation in bitmap PIXELS, applied before point scaling.
const std = @import("std");
const builtin = @import("builtin");
const cf = @import("cf.zig");
const objc = @import("../objc.zig");
pub const max_side = 1024;
pub const max_pixels = 1024 * 1024;
pub const max_scratch_bytes = max_pixels * 4;
pub const Error = error{ UnsupportedPlatform, InvalidGlyphGeometry, GlyphTooLarge, OutOfMemory, ColorSpaceUnavailable, BitmapContextUnavailable };
const bgra_premultiplied_srgb: u32 = 0x2002; // 32-bit little endian | premultiplied-first
extern "c" fn CGContextTranslateCTM(cf.CGContextRef, f64, f64) void;
extern "c" fn CGContextSetRGBFillColor(cf.CGContextRef, f64, f64, f64, f64) void;
extern "c" fn CGContextFlush(cf.CGContextRef) void;
extern "c" fn CTFontDrawGlyphs(cf.CTFontRef, [*]const u16, [*]const objc.CGPoint, usize, cf.CGContextRef) void;
fn pixels(w: u32, h: u32, scale: f64, origin: objc.CGPoint) Error!usize {
    if (w == 0 or h == 0 or !std.math.isFinite(scale) or scale <= 0 or !std.math.isFinite(origin.x) or !std.math.isFinite(origin.y)) return error.InvalidGlyphGeometry;
    if (w > max_side or h > max_side) return error.GlyphTooLarge;
    const count = @as(usize, w) * @as(usize, h);
    if (count > max_pixels) return error.GlyphTooLarge;
    return count;
}
/// Input is premultiplied BGRA. Integer weights sum to 256: a white pixel's
/// luminance equals its alpha, including partial coverage. Saturation protects
/// against any unexpected CoreGraphics rounding outside premultiplied bounds.
fn ink(b: u8, g: u8, r: u8, a: u8) u8 {
    const luminance = (54 * @as(u32, r) + 183 * @as(u32, g) + 19 * @as(u32, b) + 128) >> 8;
    return a -| @as(u8, @intCast(luminance));
}
/// Returns owned row-major w*h bytes. Does not release or mutate font; caller
/// frees the mask with gpa. Scratch is at most 4MiB, result at most 1MiB.
pub fn draw(gpa: std.mem.Allocator, font: cf.CTFontRef, g: u16, w: u32, h: u32, scale: f64, origin: objc.CGPoint) Error![]u8 {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const count = try pixels(w, h, scale, origin);
    const bgra = try gpa.alloc(u8, count * 4);
    defer gpa.free(bgra);
    @memset(bgra, 0);
    const mask = try gpa.alloc(u8, count);
    errdefer gpa.free(mask);
    const pool = objc.Pool.push();
    defer pool.pop();
    const space = cf.CGColorSpaceCreateWithName(cf.kCGColorSpaceSRGB) orelse return error.ColorSpaceUnavailable;
    defer cf.CGColorSpaceRelease(space);
    const ctx = cf.CGBitmapContextCreate(bgra.ptr, w, h, 8, @as(usize, w) * 4, space, bgra_premultiplied_srgb) orelse return error.BitmapContextUnavailable;
    defer cf.CGContextRelease(ctx);
    cf.CGContextSetShouldAntialias(ctx, true);
    cf.CGContextSetShouldSmoothFonts(ctx, false);
    cf.CGContextSetAllowsFontSubpixelPositioning(ctx, true);
    cf.CGContextSetShouldSubpixelPositionFonts(ctx, true);
    // Ordinary outline glyphs use black ink; intrinsic-color glyphs draw their
    // own colors. A white fill here would erase ordinary glyphs in conversion.
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextTranslateCTM(ctx, origin.x, origin.y);
    cf.CGContextScaleCTM(ctx, scale, scale);
    const glyphs = [1]u16{g};
    const positions = [1]objc.CGPoint{.{}};
    CTFontDrawGlyphs(font, &glyphs, &positions, 1, ctx);
    CGContextFlush(ctx);
    for (mask, 0..) |*value, i| value.* = ink(bgra[4 * i], bgra[4 * i + 1], bgra[4 * i + 2], bgra[4 * i + 3]);
    return mask;
}

// Native fixtures use CoreText/CG only, with no window or user state.
extern "c" fn CTFontCreateWithName(cf.CFStringRef, f64, ?*const anyopaque) ?cf.CTFontRef;
extern "c" fn CTFontCopyPostScriptName(cf.CTFontRef) ?cf.CFStringRef;
extern "c" fn CTFontGetGlyphsForCharacters(cf.CTFontRef, [*]const u16, [*]u16, cf.CFIndex) bool;
extern "c" fn CTFontGetBoundingRectsForGlyphs(cf.CTFontRef, u32, [*]const u16, ?[*]objc.CGRect, cf.CFIndex) objc.CGRect;
extern "c" fn CFStringGetCString(cf.CFStringRef, [*]u8, cf.CFIndex, u32) bool;
fn testFont(name: []const u8) !cf.CTFontRef {
    const string = cf.CFStringCreateWithBytes(null, name.ptr, @intCast(name.len), cf.utf8_encoding, false) orelse return error.OutOfMemory;
    defer cf.CFRelease(string);
    return CTFontCreateWithName(string, 72, null) orelse error.TestFontUnavailable;
}
const Geometry = struct { glyph: u16, w: u32, h: u32, origin: objc.CGPoint, scale: f64 };
fn testGeometry(font: cf.CTFontRef, character: u16) !Geometry {
    const characters = [1]u16{character};
    var glyphs: [1]u16 = undefined;
    if (!CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1) or glyphs[0] == 0) return error.TestGlyphUnavailable;
    const bounds = CTFontGetBoundingRectsForGlyphs(font, 0, &glyphs, null, 1);
    if (bounds.size.width <= 0 or bounds.size.height <= 0) return error.TestEmptyGlyph;
    const scale = 1.5;
    const x0 = @floor(bounds.origin.x * scale);
    const y0 = @floor(bounds.origin.y * scale);
    return .{ .glyph = glyphs[0], .scale = scale, .w = @intFromFloat(@ceil((bounds.origin.x + bounds.size.width) * scale) - x0 + 4), .h = @intFromFloat(@ceil((bounds.origin.y + bounds.size.height) * scale) - y0 + 4), .origin = .{ .x = 2 - x0, .y = 2 - y0 } };
}
test "premultiplied color-to-ink conversion preserves highlights dark details and partial alpha" {
    try std.testing.expectEqual(@as(u8, 0), ink(255, 255, 255, 255));
    try std.testing.expectEqual(@as(u8, 0), ink(73, 73, 73, 73));
    try std.testing.expectEqual(@as(u8, 255), ink(0, 0, 0, 255));
    try std.testing.expectEqual(@as(u8, 73), ink(0, 0, 0, 73));
    try std.testing.expectEqual(@as(u8, 0), ink(0, 0, 0, 0));
    const yellow = ink(0, 200, 255, 255);
    try std.testing.expect(yellow > 0 and yellow < 128);
    try std.testing.expectEqual(@as(u8, 0), ink(255, 255, 255, 30));
}
test "geometry rejects invalid and over-budget allocations" {
    try std.testing.expectError(error.InvalidGlyphGeometry, pixels(0, 3, 1, .{}));
    try std.testing.expectError(error.InvalidGlyphGeometry, pixels(3, 3, 0, .{}));
    try std.testing.expectError(error.InvalidGlyphGeometry, pixels(3, 3, std.math.inf(f64), .{}));
    try std.testing.expectError(error.InvalidGlyphGeometry, pixels(3, 3, 1, .{ .x = std.math.nan(f64) }));
    try std.testing.expectError(error.GlyphTooLarge, pixels(1025, 1, 1, .{}));
    try std.testing.expectEqual(@as(usize, max_pixels), try pixels(1024, 1024, 1, .{}));
}
test "actual AppleColorEmoji smile has interior tonal detail rather than an alpha silhouette" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = objc.Pool.push();
    defer pool.pop();
    const font = try testFont("AppleColorEmoji");
    defer cf.CFRelease(font);
    const name = CTFontCopyPostScriptName(font) orelse return error.TestFontUnavailable;
    defer cf.CFRelease(name);
    var name_bytes: [128]u8 = undefined;
    try std.testing.expect(CFStringGetCString(name, &name_bytes, name_bytes.len, cf.utf8_encoding));
    try std.testing.expectEqualStrings("AppleColorEmoji", std.mem.sliceTo(&name_bytes, 0));
    const geometry = try testGeometry(font, 0x263a); // single-BMP smiling face, no shaping shortcut for a ZWJ sequence
    const mask = try draw(std.testing.allocator, font, geometry.glyph, geometry.w, geometry.h, geometry.scale, geometry.origin);
    defer std.testing.allocator.free(mask);
    var levels: [256]bool = @splat(false);
    var interior_levels: [256]bool = @splat(false);
    var nonzero: usize = 0;
    var light_ink: usize = 0;
    var dark_ink: usize = 0;
    for (mask, 0..) |value, i| {
        levels[value] = true;
        if (value > 0) nonzero += 1;
        const x = i % geometry.w;
        const y = i / geometry.w;
        if (x >= geometry.w / 4 and x < geometry.w * 3 / 4 and y >= geometry.h / 4 and y < geometry.h * 3 / 4) {
            interior_levels[value] = true;
            if (value >= 8 and value < 140) light_ink += 1;
            if (value > 180) dark_ink += 1;
        }
    }
    var distinct: usize = 0;
    var interior_distinct: usize = 0;
    for (levels) |seen| if (seen) {
        distinct += 1;
    };
    for (interior_levels) |seen| if (seen) {
        interior_distinct += 1;
    };
    std.debug.print("EMOJI INK smile {d}x{d}, levels={d}, interior_levels={d}, body={d}, details={d}\n", .{ geometry.w, geometry.h, distinct, interior_distinct, light_ink, dark_ink });
    try std.testing.expect(nonzero > mask.len / 10);
    try std.testing.expect(distinct >= 32 and interior_distinct >= 8);
    // The central half excludes the outer face boundary: an alpha-only filled
    // silhouette has no light body ink here; a circle-only outline has no body.
    try std.testing.expect(light_ink >= 32 and dark_ink >= 8);
}
test "ordinary black outline glyph retains a nonempty antialiased ink mask" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const font = try testFont("Times-Roman");
    defer cf.CFRelease(font);
    const geometry = try testGeometry(font, 'A');
    const mask = try draw(std.testing.allocator, font, geometry.glyph, geometry.w, geometry.h, geometry.scale, geometry.origin);
    defer std.testing.allocator.free(mask);
    var dense: usize = 0;
    var empty: usize = 0;
    for (mask) |value| {
        if (value > 200) dense += 1;
        if (value == 0) empty += 1;
    }
    try std.testing.expect(dense > 20 and empty > 20);
}
