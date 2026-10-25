//! Minimal synthetic TrueType cmap/style fixtures for selector/ownership tests.
//! These contain no drawn outlines and make no raster/shaping support claim.
const std = @import("std");
pub const Face = struct { family: []const u8, weight: u16 = 400, italic: bool = false, codepoints: []const u21 };
pub const Blob = struct {
    data: [8192]u8 = @splat(0),
    len: usize = 0,
    fn u16be(b: *Blob, at: usize, value: u16) void {
        std.mem.writeInt(u16, b.data[at..][0..2], value, .big);
    }
    fn u32be(b: *Blob, at: usize, value: u32) void {
        std.mem.writeInt(u32, b.data[at..][0..4], value, .big);
    }
    fn record(b: *Blob, dir: usize, i: usize, tag: *const [4]u8, off: usize, len: usize) void {
        const at = dir + 12 + i * 16;
        @memcpy(b.data[at..][0..4], tag);
        b.u32be(at + 8, @intCast(off));
        b.u32be(at + 12, @intCast(len));
    }
    fn face(b: *Blob, at: usize, spec: Face) void {
        std.debug.assert(spec.family.len <= 63 and spec.codepoints.len <= 64);
        const head = at + 192;
        const hhea = head + 64;
        const hmtx = hhea + 48;
        const maxp = hmtx + 8;
        const loca = maxp + 8;
        const glyf = loca + 264;
        const os2 = glyf + 8;
        const name = os2 + 80;
        const cmap = name + 160;
        b.u32be(at, 0x10000);
        b.u16be(at + 4, 9);
        b.record(at, 0, "head", head, 54);
        b.record(at, 1, "hhea", hhea, 36);
        b.record(at, 2, "hmtx", hmtx, 8);
        b.record(at, 3, "maxp", maxp, 6);
        b.record(at, 4, "loca", loca, 264);
        b.record(at, 5, "glyf", glyf, 8);
        b.record(at, 6, "OS/2", os2, 80);
        b.record(at, 7, "name", name, 160);
        b.record(at, 8, "cmap", cmap, 28 + 12 * spec.codepoints.len);
        b.u16be(head + 18, 1000);
        b.u16be(hhea + 4, 800);
        b.u16be(hhea + 6, @bitCast(@as(i16, -200)));
        b.u16be(hhea + 34, 1);
        b.u16be(hmtx, 600);
        b.u16be(maxp + 4, @intCast(spec.codepoints.len + 1));
        b.u16be(os2 + 4, spec.weight);
        b.u16be(os2 + 62, @intFromBool(spec.italic));
        b.u16be(name + 2, 1);
        b.u16be(name + 4, 18);
        b.u16be(name + 6, 3);
        b.u16be(name + 8, 1);
        b.u16be(name + 12, 1);
        b.u16be(name + 14, @intCast(spec.family.len * 2));
        for (spec.family, 0..) |ch, i| b.u16be(name + 18 + i * 2, ch);
        b.u16be(cmap + 2, 1);
        b.u16be(cmap + 4, 3);
        b.u16be(cmap + 6, 10);
        b.u32be(cmap + 8, 12);
        b.u16be(cmap + 12, 12);
        b.u32be(cmap + 16, @intCast(16 + 12 * spec.codepoints.len));
        b.u32be(cmap + 24, @intCast(spec.codepoints.len));
        for (spec.codepoints, 0..) |cp, i| {
            if (i != 0) std.debug.assert(cp > spec.codepoints[i - 1]);
            const group = cmap + 28 + i * 12;
            b.u32be(group, cp);
            b.u32be(group + 4, cp);
            b.u32be(group + 8, @intCast(i + 1));
        }
        b.len = cmap + 28 + 12 * spec.codepoints.len;
    }
    pub fn init(spec: Face) Blob {
        var b: Blob = .{};
        b.face(0, spec);
        return b;
    }
    pub fn collection(a: Face, c: Face) Blob {
        var b: Blob = .{};
        @memcpy(b.data[0..4], "ttcf");
        b.u32be(4, 0x10000);
        b.u32be(8, 2);
        b.u32be(12, 32);
        b.face(32, a);
        const second = std.mem.alignForward(usize, b.len, 4);
        b.u32be(16, @intCast(second));
        b.face(second, c);
        return b;
    }
    pub fn write(b: *const Blob, tmp: *std.testing.TmpDir, name: []const u8) ![:0]u8 {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = b.data[0..b.len] });
        return try tmp.dir.realPathFileAlloc(std.testing.io, name, std.testing.allocator);
    }
};
