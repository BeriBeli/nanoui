//! Preflight offsets before the portable reader's u32 offset arithmetic. This
//! checks the tables used for style/cmap selection, not complete font validity.
const std = @import("std");
const font = @import("font.zig");
fn be16(data: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, data[at..][0..2], .big);
}
fn be32(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .big);
}
fn fits(data: []const u8, offset: usize, count: usize) bool {
    return offset <= data.len and count <= data.len - offset;
}
pub fn tables(data: []const u8, index: u32) font.Error!font.Tables {
    const t = try font.Tables.read(data, index);
    inline for (.{ .{ "head", 54 }, .{ "hhea", 36 }, .{ "hmtx", 4 }, .{ "maxp", 6 }, .{ "cmap", 4 }, .{ "loca", 2 }, .{ "glyf", 0 } }) |field| {
        if (!fits(data, @field(t, field[0]), field[1])) return error.Truncated;
    }
    if (t.os2 != 0 and !fits(data, t.os2, 64)) return error.Truncated;
    if (t.name != 0 and !fits(data, t.name, @max(6, t.name_len))) return error.Truncated;
    if (t.kern != 0 and !fits(data, t.kern, 10)) return error.Truncated;
    return t;
}
pub fn cmap(data: []const u8, t: font.Tables) font.Error!void {
    const at: usize = t.cmap;
    const count = be16(data, at + 2);
    if (!fits(data, at + 4, @as(usize, count) * 8)) return error.Truncated;
    for (0..count) |i| {
        const rec = at + 4 + 8 * i;
        const platform = be16(data, rec);
        const encoding = be16(data, rec + 2);
        const sub = at + @as(usize, be32(data, rec + 4));
        if (!fits(data, sub, 2)) return error.Truncated;
        // Font.pickCmap reads every record's offset before its platform test.
        if (platform != 0 and !(platform == 3 and (encoding == 1 or encoding == 10))) continue;
        switch (be16(data, sub)) {
            4 => {
                if (!fits(data, sub, 16)) return error.Truncated;
                const len = be16(data, sub + 2);
                const segments = be16(data, sub + 6);
                if (segments == 0 or segments % 2 != 0 or len < 16 + @as(usize, segments) * 4 or !fits(data, sub, len)) return error.Truncated;
            },
            12 => {
                if (!fits(data, sub, 16)) return error.Truncated;
                const groups = be32(data, sub + 12);
                const len = be32(data, sub + 4);
                if (groups > 65536 or len < 16 + @as(usize, groups) * 12 or !fits(data, sub, len)) return error.Truncated;
                var previous: ?u32 = null;
                for (0..groups) |g| {
                    const group = sub + 16 + 12 * g;
                    const first = be32(data, group);
                    const last = be32(data, group + 4);
                    const glyph = be32(data, group + 8);
                    if (first > last or last > 0x10ffff or (previous != null and first <= previous.?) or @as(u64, glyph) + last - first > 65535) return error.NotAFont;
                    previous = last;
                }
            },
            else => {},
        }
    }
}
