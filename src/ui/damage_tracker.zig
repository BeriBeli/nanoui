//! Bounded damage for an ordered, value-only draw stream; no scene IDs or history.
//! A dirty rectangle is in PHYSICAL pixels. Clear it, then replay ALL intersecting
//! current instances in paint order, with every write scissored to the rectangle.
//! Filtering instances without scissoring writes is incorrect for alpha overlays.
//! Call invalidate() if drawing/presentation fails or the backing pixels are lost.
const std = @import("std");

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    pub fn right(self: Rect) u32 {
        return self.x + self.width;
    }
    pub fn bottom(self: Rect) u32 {
        return self.y + self.height;
    }
    pub fn contains(self: Rect, x: u32, y: u32) bool {
        return x >= self.x and y >= self.y and x < self.right() and y < self.bottom();
    }
    pub fn intersects(self: Rect, other: Rect) bool {
        return self.x < other.right() and self.right() > other.x and self.y < other.bottom() and self.bottom() > other.y;
    }
    pub fn united(self: Rect, other: Rect) Rect {
        const x = @min(self.x, other.x);
        const y = @min(self.y, other.y);
        return .{ .x = x, .y = y, .width = @max(self.right(), other.right()) - x, .height = @max(self.bottom(), other.bottom()) - y };
    }
};
pub const Damage = union(enum) { none, rect: Rect, full };
pub const Frame = struct {
    width: u32,
    height: u32,
    scale: f32 = 1,
    clear: [4]f32 = .{ 0, 0, 0, 1 },
    /// Increment even if an atlas is updated in place without changing its size.
    glyph_generation: u64 = 0,
    glyph_size: u32 = 0,
    image_size: u32 = 0,
    image_generation: u64 = 0,
    theme_generation: u64 = 0,
    /// Increment on exposure/backing-store loss; ordinary redraw requests need not.
    backing_generation: u64 = 0,
    pub fn valid(self: Frame) bool {
        if (!std.math.isFinite(self.scale) or self.scale <= 0) return false;
        for (self.clear) |v| if (!std.math.isFinite(v)) return false;
        return true;
    }
    fn same(self: Frame, other: Frame) bool {
        return self.glyph_size == other.glyph_size and self.image_size == other.image_size and self.width == other.width and self.height == other.height and self.scale == other.scale and equalFloats(self.clear, other.clear) and self.glyph_generation == other.glyph_generation and self.image_generation == other.image_generation and self.theme_generation == other.theme_generation and self.backing_generation == other.backing_generation;
    }
};
pub const Limits = struct {
    instances: usize = 65536,
    /// Retained cache bytes, excluding the caller-owned current draw stream.
    cache_bytes: usize = 8 * 1024 * 1024,
};
fn equalFloats(a: anytype, b: @TypeOf(a)) bool {
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

/// Adapter contract: equal(a,b) must compare every pixel-affecting field without
/// padding, and bounds(instance,frame) returns conservative clipped pixel bounds
/// or an error. Instance must own no borrowed storage (gpu.Instance is value-only).
/// Ordering is significant: comparing stream positions never assumes node IDs.
pub fn Tracker(comptime Instance: type, comptime Adapter: type) type {
    return struct {
        const Self = @This();
        previous: []Instance = &.{},
        previous_len: usize = 0,
        frame: Frame = .{ .width = 0, .height = 0 },
        ready: bool = false,
        limits: Limits = .{},
        pub fn deinit(self: *Self, a: std.mem.Allocator) void {
            if (self.previous.len != 0) a.free(self.previous);
            self.previous = &.{};
            self.previous_len = 0;
            self.ready = false;
        }
        pub fn invalidate(self: *Self) void {
            self.ready = false;
        }
        pub fn cachedBytes(self: *const Self) usize {
            return self.previous.len * @sizeOf(Instance);
        }
        pub fn cachedInstances(self: *const Self) usize {
            return self.previous_len;
        }
        /// No allocations beyond explicit cache limits. OOM, invalid geometry,
        /// excessive counts and oversized instances conservatively return full.
        /// Successful update commits the expected backing state; invalidate if
        /// the caller subsequently cannot render/present that frame.
        pub fn update(self: *Self, a: std.mem.Allocator, current: []const Instance, frame: Frame) Damage {
            const max_count = if (@sizeOf(Instance) == 0) 0 else self.limits.cache_bytes / @sizeOf(Instance);
            if (!frame.valid() or current.len > self.limits.instances or current.len > max_count) {
                self.deinit(a);
                return .full;
            }
            var dirty: ?Rect = null;
            var full = !self.ready or !frame.same(self.frame);
            // Validate the whole current stream even on first paint; invalid
            // geometry must never become an accepted reference for later frames.
            for (current, 0..) |instance, index| {
                const new_bounds = checkedBounds(instance, frame) catch {
                    self.deinit(a);
                    return .full;
                };
                if (!full and (index >= self.previous_len or !Adapter.equal(self.previous[index], instance))) {
                    if (new_bounds) |b| add(&dirty, b);
                    if (index < self.previous_len) {
                        const old_bounds = checkedBounds(self.previous[index], self.frame) catch {
                            full = true;
                            continue;
                        };
                        if (old_bounds) |b| add(&dirty, b);
                    }
                }
            }
            if (!full and current.len < self.previous_len) {
                for (self.previous[current.len..self.previous_len]) |old| {
                    const bounds = checkedBounds(old, self.frame) catch {
                        full = true;
                        break;
                    };
                    if (bounds) |b| add(&dirty, b);
                }
            }
            if (current.len > self.previous.len or self.previous.len > max_count or self.previous.len > self.limits.instances) {
                // Free before grow: even transient tracker-owned allocations do
                // not exceed cache_bytes. This loses only the already-used old
                // comparison reference; the damage decision is complete above.
                if (self.previous.len != 0) a.free(self.previous);
                self.previous = &.{};
                self.previous_len = 0;
                self.previous = a.alloc(Instance, current.len) catch {
                    self.ready = false;
                    return .full;
                };
            }
            @memcpy(self.previous[0..current.len], current);
            self.previous_len = current.len;
            self.frame = frame;
            self.ready = true;
            if (full) return .full;
            if (dirty) |rect| {
                if (rect.x == 0 and rect.y == 0 and rect.width == frame.width and rect.height == frame.height) return .full;
                return .{ .rect = rect };
            }
            return .none;
        }
        fn checkedBounds(instance: Instance, frame: Frame) !?Rect {
            const result = try Adapter.bounds(instance, frame);
            if (result) |rect| {
                if (rect.x > frame.width or rect.y > frame.height or rect.width > frame.width - rect.x or rect.height > frame.height - rect.y) return error.InvalidAdapterBounds;
            }
            return result;
        }
        fn add(dirty: *?Rect, rect: Rect) void {
            if (rect.width == 0 or rect.height == 0) return;
            dirty.* = if (dirty.*) |old| old.united(rect) else rect;
        }
    };
}

/// Matches nanoui gpu.Instance fields, without importing/linking its UI runtime.
/// Bounds conservatively enclose raster.zig's rounded pixel-center convention,
/// including a shadow's 3*blur growth, clipping, and fractional/DPI edges.
pub fn GpuAdapter(comptime Instance: type) type {
    // An upstream draw field must be reviewed explicitly rather than silently
    // becoming invisible to damage comparison when nanoui changes its layout.
    if (std.meta.fieldNames(Instance).len != 12 or @sizeOf(Instance) != 144) @compileError("review GpuAdapter for changed gpu.Instance layout");
    return struct {
        pub fn equal(a: Instance, b: Instance) bool {
            inline for (.{ "rect", "color", "border_color", "uv", "clip", "xf", "pulse", "vel" }) |field| {
                if (!equalFloats(@field(a, field), @field(b, field))) return false;
            }
            inline for (.{ "radius", "border_width", "kind", "clip_round" }) |field| {
                if (@field(a, field) != @field(b, field)) return false;
            }
            return true;
        }
        pub fn bounds(instance: Instance, frame: Frame) !?Rect {
            if (!frame.valid()) return error.InvalidFrame;
            inline for (.{ "rect", "color", "border_color", "uv", "clip", "xf", "pulse", "vel" }) |field| {
                for (@field(instance, field)) |v| if (!std.math.isFinite(v)) return error.InvalidGeometry;
            }
            inline for (.{ "radius", "border_width", "kind", "clip_round" }) |field| {
                if (!std.math.isFinite(@field(instance, field))) return error.InvalidGeometry;
            }
            const grow: f32 = if (instance.kind == 2 or instance.kind == 5) @max(0, instance.border_width * 3) else 0;
            if (!std.math.isFinite(grow)) return error.InvalidGeometry;
            var rx0 = instance.rect[0] - grow;
            var ry0 = instance.rect[1] - grow;
            var rx1 = instance.rect[0] + instance.rect[2] + grow;
            var ry1 = instance.rect[1] + instance.rect[3] + grow;
            if (instance.xf[0] != 0) {
                const ca = @cos(instance.xf[0]);
                const sa = @sin(instance.xf[0]);
                const px = instance.xf[2];
                const py = instance.xf[3];
                const xs = [4]f32{ rx0, rx1, rx0, rx1 };
                const ys = [4]f32{ ry0, ry0, ry1, ry1 };
                rx0 = std.math.inf(f32);
                ry0 = std.math.inf(f32);
                rx1 = -std.math.inf(f32);
                ry1 = -std.math.inf(f32);
                for (xs, ys) |x, y| {
                    const dx = x - px;
                    const dy = y - py;
                    const tx = px + ca * dx - sa * dy;
                    const ty = py + sa * dx + ca * dy;
                    if (!std.math.isFinite(tx) or !std.math.isFinite(ty)) return error.InvalidGeometry;
                    rx0 = @min(rx0, tx);
                    ry0 = @min(ry0, ty);
                    rx1 = @max(rx1, tx);
                    ry1 = @max(ry1, ty);
                }
            }
            if (!std.math.isFinite(rx0) or !std.math.isFinite(ry0) or !std.math.isFinite(rx1) or !std.math.isFinite(ry1)) return error.InvalidGeometry;
            const x0 = @max(rx0, instance.clip[0]);
            const y0 = @max(ry0, instance.clip[1]);
            const x1 = @min(rx1, instance.clip[2]);
            const y1 = @min(ry1, instance.clip[3]);
            if (x1 <= x0 or y1 <= y0) return null;
            const px0 = pixel(x0, frame.scale, frame.width, false);
            const py0 = pixel(y0, frame.scale, frame.height, false);
            const px1 = pixel(x1, frame.scale, frame.width, true);
            const py1 = pixel(y1, frame.scale, frame.height, true);
            if (px1 <= px0 or py1 <= py0) return null;
            return .{ .x = px0, .y = py0, .width = px1 - px0, .height = py1 - py0 };
        }
        fn pixel(point: f32, scale: f32, limit: u32, up: bool) u32 {
            const scaled: f64 = point * scale;
            const rounded = if (up) @ceil(scaled) else @floor(scaled);
            return @intFromFloat(std.math.clamp(rounded, 0, @as(f64, @floatFromInt(limit))));
        }
    };
}
pub fn GpuTracker(comptime Instance: type) type {
    return Tracker(Instance, GpuAdapter(Instance));
}
