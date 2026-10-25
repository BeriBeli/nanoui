//! Grid runs retain application-provided grapheme/cell boundaries.
const std = @import("std");
pub const Feature = @import("font_features.zig").Feature;
pub const max_bytes = 16384;
pub const max_cells = 4096;
pub const max_glyphs = 4096;
pub const Cell = struct { byte_start: u32, byte_end: u32, col: u32, width: u8 };
pub const Source = struct { bytes: []const u8, index: u32, digest: [32]u8 };
/// Points relative to the run's grid origin; y is up from the baseline.
pub const Shaped = struct { glyph: u32, index: u32, x: f32, y: f32 };
pub const Request = struct {
    source: Source,
    text: []const u8,
    cells: []const Cell,
    features: []const Feature,
    physical_px: f32,
    scale: f32,
    cell_width: f32,
};
pub const Shaper = struct {
    context: *anyopaque,
    shape: *const fn (*anyopaque, std.mem.Allocator, Request) anyerror![]Shaped,
    deinit: ?*const fn (*anyopaque, std.mem.Allocator) void = null,
};
pub fn validate(s: []const u8, cells: []const Cell, cw: f32) !void {
    if (s.len > max_bytes or cells.len > max_cells) return error.GridRunLimit;
    if (!std.math.isFinite(cw) or cw <= 0 or cw > 4096) return error.InvalidGridWidth;
    if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
    var end: u32 = 0;
    var col: u32 = 0;
    for (cells) |cell| {
        if (cell.byte_start != end or cell.byte_end <= cell.byte_start or cell.byte_end > s.len or
            cell.col != col or (cell.width != 1 and cell.width != 2)) return error.InvalidGridCells;
        if (s[cell.byte_start] & 0xc0 == 0x80 or
            (cell.byte_end < s.len and s[cell.byte_end] & 0xc0 == 0x80)) return error.InvalidGridCells;
        end = cell.byte_end;
        col += cell.width;
    }
    if (end != s.len) return error.InvalidGridCells;
}
pub fn owner(cells: []const Cell, byte: u32) !usize {
    var lo: usize = 0;
    var hi = cells.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cells[mid].byte_end <= byte) lo = mid + 1 else hi = mid;
    }
    if (lo == cells.len or cells[lo].byte_start > byte) return error.InvalidGlyphCluster;
    return lo;
}
pub fn width(cells: []const Cell, cw: f32) f32 {
    if (cells.len == 0) return 0;
    const last = cells[cells.len - 1];
    return @as(f32, @floatFromInt(last.col + last.width)) * cw;
}
/// Reuses the existing two-frame owned layout cache, including grid geometry.
pub fn layout(self: anytype, s: []const u8, style: anytype, cells: []const Cell, cw: f32) !@TypeOf(self.layout(s, style)) {
    try validate(s, cells, cw);
    var hash = std.hash.Wyhash.init(0x4752494454455854);
    hash.update(std.mem.asBytes(&cw));
    for (cells) |cell| {
        // Hash fields individually: struct padding is deliberately irrelevant.
        hash.update(std.mem.asBytes(&cell.byte_start));
        hash.update(std.mem.asBytes(&cell.byte_end));
        hash.update(std.mem.asBytes(&cell.col));
        hash.update(&.{cell.width});
    }
    const key = @TypeOf(self.*).key(s, style, hash.final());
    if (self.cached(key)) |cached| return cached;
    const result = try self.shapeGrid(s, style, cells, cw);
    const count = result.glyphs.len;
    const kept = self.keep(key, result);
    if (count > 0 and kept.glyphs.len == 0) return error.OutOfMemory;
    return kept;
}
