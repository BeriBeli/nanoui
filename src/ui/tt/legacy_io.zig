//! Letty: libc file paths for kernels without statx; bounded font reads.
const std = @import("std");
const builtin = @import("builtin");
const linux = builtin.os.tag == .linux and !builtin.abi.isAndroid();
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
extern "c" fn lt_open([*:0]const u8) c_int;
extern "c" fn lt_length(c_int) i64;
extern "c" fn lt_pread(c_int, [*]u8, usize, u64) isize;
extern "c" fn lt_close(c_int) void;
extern "c" fn lt_scan_fonts([*:0]const u8, ?*anyopaque, *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void) void;
pub const scan = lt_scan_fonts;
pub const File = struct {
    fd: if (linux) c_int else std.Io.File,
    pub fn open(a: std.mem.Allocator, path: []const u8) !File {
        if (!linux) return .{ .fd = try std.Io.Dir.cwd().openFile(io(), path, .{}) };
        const z = try a.dupeSentinel(u8, path, 0);
        defer a.free(z);
        const fd = lt_open(z);
        if (fd < 0) return error.OpenFailed;
        return .{ .fd = fd };
    }
    pub fn close(f: File) void {
        if (linux) lt_close(f.fd) else f.fd.close(io());
    }
    pub fn length(f: File) !usize {
        if (!linux) {
            const size = try f.fd.length(io());
            if (size > 256 << 20) return error.FontSize;
            return @intCast(size);
        }
        const n = lt_length(f.fd);
        if (n < 0 or n > 256 << 20) return error.FontSize;
        return @intCast(n);
    }
    pub fn readAll(f: File, b: []u8, off: usize) !usize {
        if (!linux) {
            const count = try f.fd.readPositionalAll(io(), b, off);
            if (count != b.len) return error.ShortRead;
            return count;
        }
        var at: usize = 0;
        while (at < b.len) {
            const n = lt_pread(f.fd, b[at..].ptr, b.len - at, off + at);
            if (n <= 0) return error.ShortRead;
            at += @intCast(n);
        }
        return at;
    }
};
pub fn readFile(a: std.mem.Allocator, p: []const u8) ![]u8 {
    const f = try File.open(a, p);
    defer f.close();
    const data = try a.alloc(u8, try f.length());
    errdefer a.free(data);
    _ = try f.readAll(data, 0);
    return data;
}
