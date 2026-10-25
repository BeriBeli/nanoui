//! Small owned cascade list; configuration arenas may be replaced immediately.
const std = @import("std");
pub const Families = struct {
    items: []const []const u8 = &.{},
    pub fn deinit(self: *Families, gpa: std.mem.Allocator) void {
        for (self.items) |name| gpa.free(name);
        if (self.items.len > 0) gpa.free(self.items);
        self.* = .{};
    }
    pub fn set(self: *Families, gpa: std.mem.Allocator, names: []const []const u8) !bool {
        if (names.len > 32) return error.TooManyFontFamilies;
        var equal = names.len == self.items.len;
        if (equal) for (names, self.items) |a, b| if (!std.mem.eql(u8, a, b)) {
            equal = false;
            break;
        };
        if (equal) return false;
        const next = try gpa.alloc([]const u8, names.len);
        errdefer gpa.free(next);
        var count: usize = 0;
        errdefer for (next[0..count]) |name| gpa.free(name);
        for (names, 0..) |name, i| {
            if (name.len == 0 or name.len > 256 or std.mem.indexOfScalar(u8, name, 0) != null or
                !std.unicode.utf8ValidateSlice(name)) return error.InvalidFontFamily;
            next[i] = try gpa.dupe(u8, name);
            count += 1;
        }
        self.deinit(gpa);
        if (names.len == 0) gpa.free(next) else self.items = next;
        return true;
    }
};
