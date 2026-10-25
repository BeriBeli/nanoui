//! Bounded whole-grapheme coverage and owned lookup keys. This chooses one
//! cmap-capable face; it does not promise color glyphs, CFF, or ZWJ shaping.
const std = @import("std");
pub const cached_bytes = 256;
pub const max_cluster_bytes = 16384;
pub const max_entries = 1024;
pub const MissingReason = enum { none, invalid_utf8, cluster_limit, missing_glyph, probe_limit, resource_limit, io, invalid_font, out_of_memory };
pub const Key = struct {
    primary: u32,
    weight: u16,
    italic: bool,
    generation: u64,
    len: u16,
    text: [cached_bytes]u8 = @splat(0),
};
pub const Result = struct { face: ?u32, reason: MissingReason = .none };

pub fn key(primary: ?u32, text: []const u8, weight: u16, italic: bool, generation: u64) ?Key {
    if (text.len > cached_bytes) return null;
    var result: Key = .{ .primary = primary orelse std.math.maxInt(u32), .weight = weight, .italic = italic, .generation = generation, .len = @intCast(text.len) };
    @memcpy(result.text[0..text.len], text);
    return result;
}

pub fn validate(text: []const u8) MissingReason {
    if (text.len > max_cluster_bytes) return .cluster_limit;
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return .invalid_utf8;
    return .none;
}

/// Controls/default ignorables do not require their own visible cmap glyph.
/// Combining accents, emoji modifiers, and all visible bases still do. A
/// successful check does not imply a ZWJ ligature exists in the shaping tables.
pub fn requiresGlyph(cp: u21) bool {
    return switch (cp) {
        0...0x1f,
        0x7f...0x9f,
        0x34f,
        0x61c,
        0x200b...0x200f,
        0x202a...0x202e,
        0x2060...0x206f,
        0xfe00...0xfe0f,
        0xfeff,
        0xe0100...0xe01ef,
        => false,
        else => true,
    };
}

/// Caller validates UTF-8 and the byte limit once before trying faces.
/// Generic Font is also used by a no-filesystem Fake in leaf tests.
pub fn covers(face: anytype, text: []const u8) bool {
    var view = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (view.nextCodepoint()) |cp| {
        if (!requiresGlyph(cp)) continue;
        const glyph = face.glyphIndex(cp);
        if (glyph == 0) return false;
        if (@hasField(@TypeOf(face.*), "num_glyphs")) {
            if (glyph >= face.num_glyphs) return false;
        }
    }
    return true;
}
