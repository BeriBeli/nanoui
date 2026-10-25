//! Borrowed per-run OpenType overrides. Owners validate and retain the slice.
const std = @import("std");
pub const Feature = extern struct { tag: [4]u8, value: u32 };
pub fn hash(features: []const Feature) u64 {
    // Order-independent: duplicate tags are rejected by the application.
    var result: u64 = 0;
    for (features) |feature| {
        var h = std.hash.Wyhash.init(0x46454154);
        h.update(&feature.tag);
        h.update(std.mem.asBytes(&feature.value));
        result ^= h.final();
    }
    return result;
}
