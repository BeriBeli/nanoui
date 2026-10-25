//! Immutable content-addressed font snapshots, confined to the UI thread.
//! Leases outlive individual Db allocators. The last release returns all bytes;
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
/// External consumers may borrow only while holding this additional lease.
/// A source not backed by this pool must use its own copying constructor.
pub fn retain(data: []const u8, digest: [32]u8) ?*Source {
    const source = entries.get(digest) orelse return null;
    if (source.refs == std.math.maxInt(usize) or source.bytes.ptr != data.ptr or source.bytes.len != data.len) return null;
    source.refs += 1;
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
test "equal font snapshots share across owners and leases survive owner release" {
    const one = try internOwned(try gpa.dupe(u8, "immutable font"));
    const two = try internOwned(try gpa.dupe(u8, "immutable font"));
    try std.testing.expect(one == two);
    try std.testing.expectEqual(@as(usize, 14), bytes());
    const lease = retain(one.bytes, one.digest).?;
    release(one);
    release(two);
    try std.testing.expectEqualStrings("immutable font", lease.bytes);
    release(lease);
    try std.testing.expectEqual(@as(usize, 0), bytes());
}
test "changed content cannot alias a previously published font snapshot" {
    const old = try internOwned(try gpa.dupe(u8, "old font"));
    const new = try internOwned(try gpa.dupe(u8, "new font"));
    try std.testing.expect(old != new);
    try std.testing.expect(retain("old font", old.digest) == null);
    release(old);
    try std.testing.expectEqualStrings("new font", new.bytes);
    release(new);
    try std.testing.expectEqual(@as(usize, 0), bytes());
}
