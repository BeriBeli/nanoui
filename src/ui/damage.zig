//! Persistent BGRA CPU backing. The same raster kernels draw full and damaged
//! frames; damage is a write scissor, never a mutation of rounded-clip geometry.
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const raster = @import("raster.zig");
pub const tracking = @import("damage_tracker.zig");
pub const Frame = tracking.Frame;
pub const Damage = tracking.Damage;
pub const Tracker = tracking.GpuTracker(gpu.Instance);
pub const Result = struct { damage: Damage };
pub fn check(gpa: std.mem.Allocator) !usize {
    return @import("damage_check.zig").run(gpa);
}
pub const Surface = struct {
    bytes: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    tracker: Tracker = .{},
    /// 256MiB BGRA ceiling, separate from the 8MiB instance comparison cache.
    max_pixels: usize = 64 * 1024 * 1024,
    valid: bool = false,
    // Backdrop filters depend on pixels outside a changed instance's bounds;
    // frame textures can mutate their borrowed pixels without a new instance.
    volatile_frame: bool = false,

    pub fn deinit(self: *Surface, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        self.tracker.deinit(gpa);
        self.* = .{};
    }
    pub fn invalidate(self: *Surface) void {
        self.valid = false;
        self.tracker.invalidate();
    }
    pub fn presentationFailed(self: *Surface) void {
        self.invalidate();
    }
    pub fn pixels(self: *const Surface) gpu.Pixels {
        return .{ .bytes = self.bytes, .width = self.width, .height = self.height };
    }
    /// Generations must change on in-place atlas mutation/reset. Actual atlas
    /// dimensions are included here even when a caller forgot to change them.
    /// Every failure invalidates the expected backing state. No partial pixels
    /// may be presented until the next successful (full) render.
    pub fn render(self: *Surface, gpa: std.mem.Allocator, instances: []const gpu.Instance, mask: raster.Mask, pictures: raster.Pictures, frame_in: Frame) !Result {
        errdefer self.invalidate();
        var frame = frame_in;
        frame.glyph_size = mask.size;
        frame.image_size = pictures.size;
        if (!frame.valid() or frame.width == 0 or frame.height == 0) return error.InvalidFrame;
        const count = std.math.mul(usize, frame.width, frame.height) catch return error.FrameTooLarge;
        if (count > self.max_pixels) return error.FrameTooLarge;
        const byte_count = std.math.mul(usize, count, 4) catch return error.FrameTooLarge;
        if (@as(u64, mask.size) * mask.size > mask.pixels.len or @as(u64, pictures.size) * pictures.size > pictures.pixels.len / 4) return error.InvalidAtlas;
        // Tracker falls back to full for invalid metadata; the raster itself
        // cannot safely process NaN/invalid integer conversions, so reject it.
        const adapter = tracking.GpuAdapter(gpu.Instance);
        for (instances) |instance| _ = try adapter.bounds(instance, frame);
        if (frame.width != self.width or frame.height != self.height or self.bytes.len != byte_count) {
            // Free before grow, including failure, to bound transient backing
            // allocation and avoid accidentally exposing pixels at old size.
            gpa.free(self.bytes);
            self.bytes = &.{};
            self.width = 0;
            self.height = 0;
            self.invalidate();
            self.bytes = try gpa.alloc(u8, byte_count);
            self.width = frame.width;
            self.height = frame.height;
        }
        var volatile_frame = false;
        for (instances) |instance| {
            if (instance.kind == gpu.Kind.glass or instance.kind == gpu.Kind.texture or instance.kind == gpu.Kind.layer_begin) {
                volatile_frame = true;
                break;
            }
        }
        if (!self.valid or self.volatile_frame or volatile_frame) self.tracker.invalidate();
        const dirty = self.tracker.update(gpa, instances, frame);
        const clear: types.Color = .{ .r = frame.clear[0], .g = frame.clear[1], .b = frame.clear[2], .a = frame.clear[3] };
        switch (dirty) {
            .none => {},
            .full => raster.drawRegion(self.pixels(), instances, mask, pictures, frame.scale, clear, .{ 0, 0, self.width, self.height }),
            .rect => |r| raster.drawRegion(self.pixels(), instances, mask, pictures, frame.scale, clear, .{ r.x, r.y, r.right(), r.bottom() }),
        }
        self.valid = true;
        self.volatile_frame = volatile_frame;
        return .{ .damage = dirty };
    }
};
