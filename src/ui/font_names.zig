//! Own theme family names independently of config arenas and frame strings.
const std = @import("std");
const Families = @import("font_families.zig").Families;
pub const Names = struct {
    storage: Families = .{},
    family: ?[]const u8 = null,
    mono: ?[]const u8 = null,
    pub fn deinit(self: *Names, gpa: std.mem.Allocator) void {
        self.storage.deinit(gpa);
        self.* = .{};
    }
    fn equal(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }
    pub fn set(self: *Names, gpa: std.mem.Allocator, family: ?[]const u8, mono: ?[]const u8) !bool {
        if (equal(self.family, family) and equal(self.mono, mono)) return false;
        var names: [2][]const u8 = undefined;
        var count: usize = 0;
        if (family) |name| {
            names[count] = name;
            count += 1;
        }
        if (mono) |name| {
            names[count] = name;
            count += 1;
        }
        _ = try self.storage.set(gpa, names[0..count]);
        self.family = if (family != null) self.storage.items[0] else null;
        self.mono = if (mono != null) self.storage.items[if (family != null) @as(usize, 1) else 0] else null;
        return true;
    }
};
test "equal family reload owns bytes after source destruction and role swap invalidates" {
    const a = std.testing.allocator;
    var value: Names = .{};
    defer value.deinit(a);
    var bytes = "Sample".*;
    try std.testing.expect(try value.set(a, &bytes, &bytes));
    @memset(&bytes, 'x');
    try std.testing.expectEqualStrings("Sample", value.family.?);
    try std.testing.expect(!try value.set(a, "Sample", "Sample"));
    try std.testing.expect(try value.set(a, null, "Sample"));
    try std.testing.expect(try value.set(a, "Sample", null));
    try std.testing.expectEqualStrings("Sample", value.family.?);
    try std.testing.expect(value.mono == null);
}
