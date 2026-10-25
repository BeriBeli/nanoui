//! CoreText OpenType settings and explicit-before-system fallback cascades.
//! All returned fonts are +1 owned, including the empty-input retain fast path.
//! Caller retains ownership of base and every borrowed feature/family byte.
//! Only macOS links CoreText; other targets return UnsupportedPlatform.
const std = @import("std");
const builtin = @import("builtin");
const cf = @import("cf.zig");
pub const Feature = @import("font_features.zig").Feature;
pub const max_features = 32;
pub const max_fallbacks = 16;
pub const max_default_cascade = 48;
pub const max_cascade = 64;
pub const Error = error{
    UnsupportedPlatform,
    TooManyFontFeatures,
    InvalidFontFeature,
    DuplicateFontFeature,
    TooManyFontFallbacks,
    InvalidFontFallback,
    CoreFoundationAllocationFailed,
    CoreTextDescriptorFailed,
    CoreTextFontFailed,
    CoreTextDefaultCascadeFailed,
    InvalidDefaultCascade,
};
pub const CascadeStats = struct {
    explicit: usize = 0,
    defaults: usize = 0,
    defaults_available: usize = 0,
    truncated: bool = false,
};
pub const Result = struct { font: cf.CTFontRef, cascade: CascadeStats };
const Array = *opaque {};
const Descriptor = *opaque {};
const Number = *opaque {};
const Transform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };
const number_sint64: cf.CFIndex = 4; // kCFNumberSInt64Type, CFNumber.h
extern "c" const kCFTypeArrayCallBacks: opaque {};
extern "c" const kCTFontFeatureSettingsAttribute: cf.CFStringRef;
extern "c" const kCTFontOpenTypeFeatureTag: cf.CFStringRef;
extern "c" const kCTFontOpenTypeFeatureValue: cf.CFStringRef;
extern "c" const kCTFontFamilyNameAttribute: cf.CFStringRef;
extern "c" const kCTFontTraitsAttribute: cf.CFStringRef;
extern "c" const kCTFontCascadeListAttribute: cf.CFStringRef;
extern "c" fn CFArrayCreate(?*anyopaque, [*]const ?*const anyopaque, cf.CFIndex, *const anyopaque) ?Array;
extern "c" fn CFArrayGetCount(Array) cf.CFIndex;
extern "c" fn CFArrayGetValueAtIndex(Array, cf.CFIndex) ?*const anyopaque;
extern "c" fn CFNumberCreate(?*anyopaque, cf.CFIndex, *const anyopaque) ?Number;
extern "c" fn CTFontCopyFontDescriptor(cf.CTFontRef) ?Descriptor;
extern "c" fn CTFontCopyTraits(cf.CTFontRef) ?cf.CFDictionaryRef;
extern "c" fn CTFontDescriptorCreateWithAttributes(cf.CFDictionaryRef) ?Descriptor;
extern "c" fn CTFontDescriptorCreateCopyWithAttributes(Descriptor, cf.CFDictionaryRef) ?Descriptor;
extern "c" fn CTFontCreateCopyWithAttributes(cf.CTFontRef, f64, ?*const Transform, Descriptor) ?cf.CTFontRef;
extern "c" fn CTFontCopyDefaultCascadeListForLanguages(cf.CTFontRef, ?Array) ?Array;

/// Convenience wrapper. Hosts needing truncation diagnostics use applyDetailed.
pub fn apply(base: cf.CTFontRef, features: []const Feature, fallbacks: []const []const u8) Error!cf.CTFontRef {
    return (try applyDetailed(base, features, fallbacks)).font;
}
pub fn applyDetailed(base: cf.CTFontRef, features: []const Feature, fallbacks: []const []const u8) Error!Result {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
    try validate(features, fallbacks);
    if (features.len == 0 and fallbacks.len == 0) return .{ .font = @ptrCast(cf.CFRetain(base)), .cascade = .{} };
    const pool = @import("../objc.zig").Pool.push();
    defer pool.pop();
    return applyMac(base, features, fallbacks);
}
fn validate(features: []const Feature, fallbacks: []const []const u8) Error!void {
    if (features.len > max_features) return error.TooManyFontFeatures;
    if (fallbacks.len > max_fallbacks) return error.TooManyFontFallbacks;
    for (features, 0..) |feature, i| {
        for (feature.tag) |ch| if (ch < 0x20 or ch > 0x7e or ch == '\'' or ch == '"' or ch == ',' or ch == '=') return error.InvalidFontFeature;
        for (features[0..i]) |prior| if (std.mem.eql(u8, &feature.tag, &prior.tag)) return error.DuplicateFontFeature;
    }
    for (fallbacks) |name| {
        if (name.len > 255 or std.mem.trim(u8, name, " \t").len == 0 or !std.unicode.utf8ValidateSlice(name)) return error.InvalidFontFallback;
        for (name) |ch| if (ch == 0 or ch == '\r' or ch == '\n') return error.InvalidFontFallback;
    }
}
fn string(bytes: []const u8) Error!cf.CFStringRef {
    return cf.CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), cf.utf8_encoding, false) orelse error.CoreFoundationAllocationFailed;
}
fn dictionary(keys: []const ?*const anyopaque, values: []const ?*const anyopaque) Error!cf.CFDictionaryRef {
    return cf.CFDictionaryCreate(null, keys.ptr, values.ptr, @intCast(keys.len), &cf.kCFTypeDictionaryKeyCallBacks, &cf.kCFTypeDictionaryValueCallBacks) orelse error.CoreFoundationAllocationFailed;
}
/// Array retains dictionaries; each dictionary retains its tag and value.
fn settings(features: []const Feature) Error!Array {
    var values: [max_features]?*const anyopaque = @splat(null);
    var count: usize = 0;
    defer for (values[0..count]) |value| cf.CFRelease(@constCast(value.?));
    for (features) |feature| {
        const tag = try string(&feature.tag);
        defer cf.CFRelease(tag);
        // OpenType values are uint32, CFNumber integers are signed. Widen first
        // so 0xffffffff remains 4294967295, never -1.
        const integer: i64 = feature.value;
        const number = CFNumberCreate(null, number_sint64, &integer) orelse return error.CoreFoundationAllocationFailed;
        defer cf.CFRelease(number);
        const value = try dictionary(&.{ kCTFontOpenTypeFeatureTag, kCTFontOpenTypeFeatureValue }, &.{ tag, number });
        values[count] = value;
        count += 1;
    }
    return CFArrayCreate(null, &values, @intCast(count), &kCFTypeArrayCallBacks) orelse error.CoreFoundationAllocationFailed;
}
fn familyDescriptor(name: []const u8, feature_array: ?Array, traits: cf.CFDictionaryRef) Error!Descriptor {
    const family = try string(name);
    defer cf.CFRelease(family);
    const attrs = if (feature_array) |array|
        try dictionary(&.{ kCTFontFamilyNameAttribute, kCTFontTraitsAttribute, kCTFontFeatureSettingsAttribute }, &.{ family, traits, array })
    else
        try dictionary(&.{ kCTFontFamilyNameAttribute, kCTFontTraitsAttribute }, &.{ family, traits });
    defer cf.CFRelease(attrs);
    return CTFontDescriptorCreateWithAttributes(attrs) orelse error.CoreTextDescriptorFailed;
}
fn cascadeStats(explicit: usize, available: usize) CascadeStats {
    return .{ .explicit = explicit, .defaults = @min(available, max_default_cascade), .defaults_available = available, .truncated = available > max_default_cascade };
}
fn cascade(base: cf.CTFontRef, fallbacks: []const []const u8, feature_array: ?Array, stats: *CascadeStats) Error!Array {
    const defaults = CTFontCopyDefaultCascadeListForLanguages(base, null) orelse return error.CoreTextDefaultCascadeFailed;
    defer cf.CFRelease(defaults);
    const available = CFArrayGetCount(defaults);
    if (available < 0) return error.InvalidDefaultCascade;
    stats.* = cascadeStats(fallbacks.len, @intCast(available));
    var values: [max_cascade]?*const anyopaque = @splat(null);
    var count: usize = 0;
    defer for (values[0..count]) |value| cf.CFRelease(@constCast(value.?));
    const traits = CTFontCopyTraits(base) orelse return error.CoreTextDescriptorFailed;
    defer cf.CFRelease(traits);
    for (fallbacks) |family| {
        values[count] = try familyDescriptor(family, feature_array, traits);
        count += 1;
    }
    const feature_attrs = if (feature_array) |array| try dictionary(&.{kCTFontFeatureSettingsAttribute}, &.{array}) else null;
    defer if (feature_attrs) |attrs| cf.CFRelease(attrs);
    for (0..stats.defaults) |i| {
        const descriptor: Descriptor = @ptrCast(@constCast(CFArrayGetValueAtIndex(defaults, @intCast(i)) orelse return error.InvalidDefaultCascade));
        values[count] = if (feature_attrs) |attrs|
            CTFontDescriptorCreateCopyWithAttributes(descriptor, attrs) orelse return error.CoreTextDescriptorFailed
        else
            cf.CFRetain(descriptor);
        count += 1;
    }
    return CFArrayCreate(null, &values, @intCast(count), &kCFTypeArrayCallBacks) orelse error.CoreFoundationAllocationFailed;
}
fn applyMac(base: cf.CTFontRef, features: []const Feature, fallbacks: []const []const u8) Error!Result {
    const feature_array = if (features.len > 0) try settings(features) else null;
    defer if (feature_array) |array| cf.CFRelease(array);
    var stats: CascadeStats = .{};
    const cascade_array = if (fallbacks.len > 0) try cascade(base, fallbacks, feature_array, &stats) else null;
    defer if (cascade_array) |array| cf.CFRelease(array);
    var keys: [2]?*const anyopaque = @splat(null);
    var values: [2]?*const anyopaque = @splat(null);
    var count: usize = 0;
    if (feature_array) |array| {
        keys[count] = kCTFontFeatureSettingsAttribute;
        values[count] = array;
        count += 1;
    }
    if (cascade_array) |array| {
        keys[count] = kCTFontCascadeListAttribute;
        values[count] = array;
        count += 1;
    }
    const attrs = try dictionary(keys[0..count], values[0..count]);
    defer cf.CFRelease(attrs);
    const original = CTFontCopyFontDescriptor(base) orelse return error.CoreTextDescriptorFailed;
    defer cf.CFRelease(original);
    const descriptor = CTFontDescriptorCreateCopyWithAttributes(original, attrs) orelse return error.CoreTextDescriptorFailed;
    defer cf.CFRelease(descriptor);
    const font = CTFontCreateCopyWithAttributes(base, 0, null, descriptor) orelse return error.CoreTextFontFailed;
    return .{ .font = font, .cascade = stats };
}

// Isolated fixtures: CoreText and CF only, no AppKit window, input or user state.
extern "c" fn CTFontCreateWithName(cf.CFStringRef, f64, ?*const Transform) ?cf.CTFontRef;
extern "c" fn CTFontGetSize(cf.CTFontRef) f64;
extern "c" const kCTFontSymbolicTrait: cf.CFStringRef;
extern "c" fn CTFontGetSymbolicTraits(cf.CTFontRef) u32;
extern "c" fn CTFontCreateCopyWithSymbolicTraits(cf.CTFontRef, f64, ?*const Transform, u32, u32) ?cf.CTFontRef;
extern "c" fn CTFontCreateWithFontDescriptor(Descriptor, f64, ?*const Transform) ?cf.CTFontRef;
extern "c" fn CTFontCopyFeatureSettings(cf.CTFontRef) ?Array;
extern "c" fn CTFontDescriptorCopyAttribute(Descriptor, cf.CFStringRef) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(cf.CFDictionaryRef, *const anyopaque) ?*anyopaque;
extern "c" fn CFStringGetCString(cf.CFStringRef, [*]u8, cf.CFIndex, u32) bool;
extern "c" fn CFNumberGetValue(Number, cf.CFIndex, *anyopaque) bool;
fn testFont() !cf.CTFontRef {
    const name = try string("Times-Roman");
    defer cf.CFRelease(name);
    return CTFontCreateWithName(name, 18, null) orelse error.TestFontUnavailable;
}
test "feature and family validation is bounded before CoreFoundation allocation" {
    try validate(&.{ .{ .tag = "liga".*, .value = 0 }, .{ .tag = "ss01".*, .value = 3 } }, &.{"Noto Sans CJK SC"});
    try std.testing.expectError(error.DuplicateFontFeature, validate(&.{ .{ .tag = "liga".*, .value = 0 }, .{ .tag = "liga".*, .value = 1 } }, &.{}));
    try std.testing.expectError(error.InvalidFontFeature, validate(&.{.{ .tag = "li\x00a".*, .value = 0 }}, &.{}));
    try std.testing.expectError(error.InvalidFontFallback, validate(&.{}, &.{""}));
    const many: [17][]const u8 = @splat("A");
    try std.testing.expectError(error.TooManyFontFallbacks, validate(&.{}, &many));
}
test "empty overrides return an independently owned retain without consuming input" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const base = try testFont();
    const copy = try apply(base, &.{}, &.{});
    try std.testing.expect(copy == base);
    cf.CFRelease(base);
    defer cf.CFRelease(copy);
    try std.testing.expectEqual(@as(f64, 18), CTFontGetSize(copy));
}
test "OpenType settings retain exact tag and uint32 values with independent CF lifetimes" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const features = [_]Feature{ .{ .tag = "liga".*, .value = 0 }, .{ .tag = "calt".*, .value = 1 }, .{ .tag = "ss01".*, .value = 3 }, .{ .tag = "cv02".*, .value = 0xffffffff } };
    const array = try settings(&features);
    defer cf.CFRelease(array);
    try std.testing.expectEqual(@as(cf.CFIndex, 4), CFArrayGetCount(array));
    for (features, 0..) |feature, i| {
        const dict: cf.CFDictionaryRef = @ptrCast(@constCast(CFArrayGetValueAtIndex(array, @intCast(i)).?));
        const tag: cf.CFStringRef = @ptrCast(CFDictionaryGetValue(dict, kCTFontOpenTypeFeatureTag).?);
        var bytes: [5]u8 = undefined;
        try std.testing.expect(CFStringGetCString(tag, &bytes, bytes.len, cf.utf8_encoding));
        try std.testing.expectEqualSlices(u8, &feature.tag, bytes[0..4]);
        const number: Number = @ptrCast(CFDictionaryGetValue(dict, kCTFontOpenTypeFeatureValue).?);
        var value: i64 = -1;
        try std.testing.expect(CFNumberGetValue(number, number_sint64, &value));
        try std.testing.expectEqual(@as(i64, feature.value), value);
    }
}
test "font copy combines full feature settings with custom-first bounded system fallback" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = @import("../objc.zig").Pool.push();
    defer pool.pop();
    const base = try testFont();
    defer cf.CFRelease(base);
    const families = [_][]const u8{ "Menlo", "Helvetica" };
    const result = try applyDetailed(base, &.{ .{ .tag = "liga".*, .value = 0 }, .{ .tag = "ss01".*, .value = 3 } }, &families);
    defer cf.CFRelease(result.font);
    try std.testing.expectEqual(@as(f64, 18), CTFontGetSize(result.font));
    try std.testing.expectEqual(@as(usize, 2), result.cascade.explicit);
    try std.testing.expect(result.cascade.defaults <= max_default_cascade);
    try std.testing.expectEqual(result.cascade.defaults_available > max_default_cascade, result.cascade.truncated);
    const desc = CTFontCopyFontDescriptor(result.font) orelse return error.TestUnexpectedResult;
    defer cf.CFRelease(desc);
    const settings_attr = CTFontDescriptorCopyAttribute(desc, kCTFontFeatureSettingsAttribute) orelse return error.TestUnexpectedResult;
    defer cf.CFRelease(settings_attr);
    const cascade_attr = CTFontDescriptorCopyAttribute(desc, kCTFontCascadeListAttribute) orelse return error.TestUnexpectedResult;
    defer cf.CFRelease(cascade_attr);
    const list: Array = @ptrCast(cascade_attr);
    try std.testing.expectEqual(@as(cf.CFIndex, @intCast(families.len + result.cascade.defaults)), CFArrayGetCount(list));
    for (families, 0..) |family, i| {
        const item: Descriptor = @ptrCast(@constCast(CFArrayGetValueAtIndex(list, @intCast(i)).?));
        const raw = CTFontDescriptorCopyAttribute(item, kCTFontFamilyNameAttribute) orelse return error.TestUnexpectedResult;
        defer cf.CFRelease(raw);
        var bytes: [256]u8 = undefined;
        try std.testing.expect(CFStringGetCString(@ptrCast(raw), &bytes, bytes.len, cf.utf8_encoding));
        try std.testing.expectEqualStrings(family, std.mem.sliceTo(&bytes, 0));
    }
    // Native normalization may translate OpenType tags to AAT tuples; a copy
    // still must retain nondefault disabled-ligature settings in this font.
    const normalized = CTFontCopyFeatureSettings(result.font) orelse return error.TestUnexpectedResult;
    defer cf.CFRelease(normalized);
    try std.testing.expect(CFArrayGetCount(normalized) > 0);
    // Base remains valid and has unchanged size after all helper temporaries.
    try std.testing.expectEqual(@as(f64, 18), CTFontGetSize(base));
}

test "cascade truncation accounting is bounded and never hides dropped system entries" {
    const bounded = cascadeStats(max_fallbacks, 200);
    try std.testing.expectEqual(@as(usize, 48), bounded.defaults);
    try std.testing.expectEqual(@as(usize, 64), bounded.explicit + bounded.defaults);
    try std.testing.expectEqual(@as(usize, 200), bounded.defaults_available);
    try std.testing.expect(bounded.truncated);
    const complete = cascadeStats(2, 17);
    try std.testing.expectEqual(@as(usize, 17), complete.defaults);
    try std.testing.expect(!complete.truncated);
}

test "explicit fallback inherits bold italic traits with and without feature declarations" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    const pool = @import("../objc.zig").Pool.push();
    defer pool.pop();
    const plain = try testFont();
    defer cf.CFRelease(plain);
    const bold_italic: u32 = 3; // kCTFontItalicTrait | kCTFontBoldTrait
    const base = CTFontCreateCopyWithSymbolicTraits(plain, 0, null, bold_italic, bold_italic) orelse return error.TestFontUnavailable;
    defer cf.CFRelease(base);
    try std.testing.expectEqual(bold_italic, CTFontGetSymbolicTraits(base) & bold_italic);
    const declared = [_]Feature{.{ .tag = "liga".*, .value = 0 }};
    for ([_][]const Feature{ &.{}, &declared }) |features| {
        const result = try applyDetailed(base, features, &.{"Menlo"});
        defer cf.CFRelease(result.font);
        try std.testing.expectEqual(bold_italic, CTFontGetSymbolicTraits(result.font) & bold_italic);
        const desc = CTFontCopyFontDescriptor(result.font) orelse return error.TestUnexpectedResult;
        defer cf.CFRelease(desc);
        const raw = CTFontDescriptorCopyAttribute(desc, kCTFontCascadeListAttribute) orelse return error.TestUnexpectedResult;
        defer cf.CFRelease(raw);
        const list: Array = @ptrCast(raw);
        try std.testing.expect(CFArrayGetCount(list) > 0);
        const first: Descriptor = @ptrCast(@constCast(CFArrayGetValueAtIndex(list, 0).?));
        const traits = CTFontDescriptorCopyAttribute(first, kCTFontTraitsAttribute) orelse return error.TestUnexpectedResult;
        defer cf.CFRelease(traits);
        const symbolic: Number = @ptrCast(CFDictionaryGetValue(@ptrCast(traits), kCTFontSymbolicTrait) orelse return error.TestUnexpectedResult);
        var value: i64 = 0;
        try std.testing.expect(CFNumberGetValue(symbolic, number_sint64, &value));
        try std.testing.expectEqual(@as(i64, bold_italic), value & bold_italic);
        const resolved = CTFontCreateWithFontDescriptor(first, 18, null) orelse return error.TestFontUnavailable;
        defer cf.CFRelease(resolved);
        try std.testing.expectEqual(bold_italic, CTFontGetSymbolicTraits(resolved) & bold_italic);
    }
}
