//! A synchronous input frame already includes any queued redraw's state.
pub fn consume(comptime Backend: type, pending: *c_uint) void {
    if (pending.* == 0) return;
    const id = pending.*;
    pending.* = 0;
    _ = Backend.api.g_source_remove(id);
}

test "synchronous input consumes one pending redraw without cancelling a new request" {
    const std = @import("std");
    const Backend = struct {
        var removed: c_uint = 0;
        var calls: usize = 0;
        const api = struct {
            fn g_source_remove(id: c_uint) c_int {
                removed = id;
                calls += 1;
                return 1;
            }
        };
    };
    var pending: c_uint = 42;
    consume(Backend, &pending);
    try std.testing.expectEqual(@as(c_uint, 42), Backend.removed);
    try std.testing.expectEqual(@as(c_uint, 0), pending);
    consume(Backend, &pending);
    try std.testing.expectEqual(@as(usize, 1), Backend.calls);
    pending = 43;
    consume(Backend, &pending);
    try std.testing.expectEqual(@as(c_uint, 43), Backend.removed);
    try std.testing.expectEqual(@as(usize, 2), Backend.calls);
}
