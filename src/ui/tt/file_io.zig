//! Font I/O for the x86_64 Linux 3.10/glibc 2.17 target. Zig 0.17's
//! file.length uses statx even there; use the versioned libc boundary.
const std = @import("std");
const builtin = @import("builtin");
const legacy = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64 and builtin.abi == .gnu;
const Native = struct {
    extern "c" fn open([*:0]const u8, c_int, ...) c_int;
    extern "c" fn __fxstat(c_int, c_int, *Stat) c_int;
    const Stat = extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        pad: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atim: std.c.timespec,
        mtim: std.c.timespec,
        ctim: std.c.timespec,
        reserved: [3]i64,
    };
};

pub const File = struct {
    fd: if (legacy) c_int else std.Io.File,
    io: std.Io,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !File {
        if (!legacy) return .{ .fd = try std.Io.Dir.cwd().openFile(io, path, .{}), .io = io };
        const z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(z);
        const fd = Native.open(z, 0x80000); // O_RDONLY | O_CLOEXEC, Linux ABI.
        if (fd < 0) return error.OpenFailed;
        return .{ .fd = fd, .io = io };
    }
    pub fn close(f: File) void {
        if (legacy) {
            _ = std.c.close(f.fd);
        } else f.fd.close(f.io);
    }
    pub fn length(f: File) !usize {
        const size: u64 = if (legacy) blk: {
            var st: Native.Stat = undefined;
            if (Native.__fxstat(1, f.fd, &st) != 0 or (st.mode & 0o170000) != 0o100000 or st.size < 0) return error.InvalidFontFile;
            break :blk @intCast(st.size);
        } else try f.fd.length(f.io);
        if (size > 256 << 20) return error.FontTooLarge;
        return @intCast(size);
    }
    pub fn readPositionalAll(f: File, bytes: []u8, offset: u64) !void {
        if (!legacy) {
            if (try f.fd.readPositionalAll(f.io, bytes, offset) != bytes.len) return error.ShortRead;
            return;
        }
        var at: usize = 0;
        while (at < bytes.len) {
            if (offset > std.math.maxInt(i64) - at) return error.InvalidOffset;
            const count = std.c.pread(f.fd, bytes[at..].ptr, bytes.len - at, @intCast(offset + at));
            if (count < 0 and std.c.errno(count) == .INTR) continue;
            if (count <= 0) return error.ShortRead;
            at += @intCast(count);
        }
    }
};

pub fn readFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = try File.open(gpa, io, path);
    defer f.close();
    const bytes = try gpa.alloc(u8, try f.length());
    errdefer gpa.free(bytes);
    try f.readPositionalAll(bytes, 0);
    return bytes;
}

pub fn scan(path: []const u8, ctx: *anyopaque, found: *const fn (*anyopaque, []const u8) void) void {
    var budget: usize = 100000;
    scanDir(path, ctx, found, 0, &budget);
}

fn scanDir(path: []const u8, ctx: *anyopaque, found: *const fn (*anyopaque, []const u8) void, depth: usize, budget: *usize) void {
    if (depth >= 8 or path.len >= 4095 or budget.* == 0) return;
    var buffer: [4096]u8 = undefined;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const dir = std.c.opendir(@ptrCast(&buffer)) orelse return;
    defer _ = std.c.closedir(dir);
    while (budget.* > 0) {
        const entry = std.c.readdir(dir) orelse break;
        budget.* -= 1;
        const name = std.mem.sliceTo(&entry.name, 0);
        if (name.len == 0 or name[0] == '.' or path.len + name.len + 2 >= buffer.len) continue;
        buffer[path.len] = '/';
        @memcpy(buffer[path.len + 1 ..][0..name.len], name);
        const len = path.len + 1 + name.len;
        buffer[len] = 0;
        if (entry.type == 4) scanDir(buffer[0..len], ctx, found, depth + 1, budget) else if (entry.type == 8 or entry.type == 10 or entry.type == 0) {
            if (std.ascii.endsWithIgnoreCase(name, ".ttf") or std.ascii.endsWithIgnoreCase(name, ".otf") or std.ascii.endsWithIgnoreCase(name, ".ttc")) found(ctx, buffer[0..len]);
        }
    }
}

test "font reads preserve offsets, reject short reads and own their buffers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "fixture.ttf", .data = "0123456789" });
    const path = try tmp.dir.realPathFileAlloc(io, "fixture.ttf", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const bytes = try readFile(std.testing.allocator, io, path);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("0123456789", bytes);
    const f = try File.open(std.testing.allocator, io, path);
    defer f.close();
    var part: [3]u8 = undefined;
    try f.readPositionalAll(&part, 4);
    try std.testing.expectEqualStrings("456", &part);
    try std.testing.expectError(error.ShortRead, f.readPositionalAll(&part, 9));
}
