//! Immutable content-addressed font snapshots, confined to the UI thread.
//! Snapshots are shared by independent Db allocators. The last release returns all bytes;
//! there is no idle cache, path-based staleness, or file I/O on retain/release.
const std = @import("std");
const gpa = std.heap.page_allocator;
pub const Source = struct {
    bytes: []const u8,
    digest: [32]u8,
    refs: usize = 1,
};
var entries: std.AutoHashMapUnmanaged([32]u8, *Source) = .empty;
var live_bytes: usize = 0;
pub fn bytes() usize {
    return live_bytes;
}
/// Consumes a page-allocator buffer on success AND failure. Fresh reads still
/// observe changes to a file; only equal immutable contents share storage.
pub fn internOwned(data: []u8) !*Source {
    errdefer gpa.free(data);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    if (entries.get(digest)) |source| {
        if (!std.mem.eql(u8, source.bytes, data)) return error.DigestCollision;
        if (source.refs == std.math.maxInt(usize)) return error.TooManyReferences;
        source.refs += 1;
        gpa.free(data);
        return source;
    }
    const source = try gpa.create(Source);
    errdefer gpa.destroy(source);
    source.* = .{ .bytes = data, .digest = digest };
    try entries.put(gpa, digest, source);
    live_bytes += data.len;
    return source;
}
pub fn release(source: *Source) void {
    std.debug.assert(source.refs > 0);
    source.refs -= 1;
    if (source.refs != 0) return;
    const removed = entries.remove(source.digest);
    std.debug.assert(removed);
    live_bytes -= source.bytes.len;
    gpa.free(source.bytes);
    gpa.destroy(source);
    if (entries.count() == 0) {
        entries.deinit(gpa);
        entries = .empty;
    }
}
test "equal font snapshots survive independent database owner release" {
    const one = try internOwned(try gpa.dupe(u8, "immutable font"));
    const two = try internOwned(try gpa.dupe(u8, "immutable font"));
    try std.testing.expect(one == two);
    try std.testing.expectEqual(@as(usize, 14), bytes());
    release(one);
    try std.testing.expectEqualStrings("immutable font", two.bytes);
    release(two);
    try std.testing.expectEqual(@as(usize, 0), bytes());
}
test "changed content cannot alias a previously published font snapshot" {
    const old = try internOwned(try gpa.dupe(u8, "old font"));
    const new = try internOwned(try gpa.dupe(u8, "new font"));
    try std.testing.expect(old != new);
    release(old);
    try std.testing.expectEqualStrings("new font", new.bytes);
    release(new);
    try std.testing.expectEqual(@as(usize, 0), bytes());
}
