//! Reclaim exceptional frame peaks at a safe frame boundary, after two seconds
//! of low demand. Normal frames keep their warm capacity and allocation path.
const std = @import("std");
const floor = 8 * 1024 * 1024;
pub const State = struct {
    deadline: ?f64 = null,
    low_peak: usize = 0,
    trims: usize = 0,
    pub fn begin(self: *State, arena: *std.heap.ArenaAllocator, time: f64) void {
        if (self.deadline) |deadline| if (time >= deadline) {
            const target = @max(floor, self.low_peak *| 2);
            if (target < arena.queryCapacity() / 2) {
                _ = arena.reset(.{ .retain_with_limit = target });
                self.trims += 1;
                self.deadline = null;
                return;
            }
            self.deadline = null;
        };
        _ = arena.reset(.retain_capacity);
    }
    /// Call after painting. The returned delay uses the existing cancellable
    /// one-shot frame scheduler, so a quiet app does not need polling frames.
    pub fn finish(self: *State, arena: *const std.heap.ArenaAllocator, time: f64) ?f32 {
        const capacity = arena.queryCapacity();
        if (capacity <= floor) {
            self.deadline = null;
            return null;
        }
        var used: usize = 0;
        var node = arena.state.used_list;
        while (node) |current| : (node = current.next) used +|= current.end_index;
        if (used >= capacity / 4) {
            self.deadline = null;
            return null;
        }
        if (self.deadline == null) {
            self.deadline = time + 2;
            self.low_peak = used;
        } else self.low_peak = @max(self.low_peak, used);
        return @floatCast(@max(0.001, self.deadline.? - time));
    }
};
test "exceptional arena capacity shrinks only after cooldown and at a frame boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{};
    const big = try arena.allocator().alloc(u8, 32 * 1024 * 1024);
    @memset(big, 1);
    try std.testing.expect(state.finish(&arena, 0) == null);
    state.begin(&arena, 0.1);
    const active = try arena.allocator().dupe(u8, "live current frame");
    try std.testing.expect(state.finish(&arena, 0.1) != null);
    try std.testing.expectEqualStrings("live current frame", active);
    try std.testing.expectEqual(@as(usize, 0), state.trims);
    state.begin(&arena, 1);
    _ = try arena.allocator().alloc(u8, 64);
    _ = state.finish(&arena, 1);
    state.begin(&arena, 2.2);
    try std.testing.expect(arena.queryCapacity() <= floor);
    try std.testing.expectEqual(@as(usize, 1), state.trims);
    try std.testing.expect(state.finish(&arena, 2.2) == null);
}
test "repeated high demand cancels shrinking and ordinary frames retain warm storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: State = .{};
    _ = try arena.allocator().alloc(u8, 32 * 1024 * 1024);
    state.begin(&arena, 0);
    _ = try arena.allocator().alloc(u8, 32);
    _ = state.finish(&arena, 0);
    state.begin(&arena, 1);
    _ = try arena.allocator().alloc(u8, 32 * 1024 * 1024);
    try std.testing.expect(state.finish(&arena, 1) == null);
    state.begin(&arena, 5);
    try std.testing.expectEqual(@as(usize, 0), state.trims);
}
