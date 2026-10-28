//! Native UI on Linux: a GtkDrawingArea that shows frames the CPU renderer
//! draws (cairo puts them on screen, at the monitor's scale), fed the
//! pointer, the wheel, keys and an input method's text. Frames run on
//! input and while something animates (a tick callback); idle, nothing runs.
const std = @import("std");
const gtk = @import("gtk.zig");
const ui = @import("../ui/ui.zig");
const types = @import("../ui/types.zig");
const gpu = @import("../ui/gpu.zig");
const damage = @import("../ui/damage.zig");
const presentation = @import("presentation.zig");
const input = @import("input.zig");
const InputHandler = input.Handler(gtk);
const text = @import("../ui/text.zig");
const frame_mod = @import("../ui/frame.zig");
const ctx_mod = @import("../ui/context.zig");
const clock = @import("../ui/clock.zig");
const Theme = @import("../ui/theme.zig").Theme;
const Context = ctx_mod.Context;
const Window = @import("window.zig").Window;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    area: *gtk.Widget,
    im: *anyopaque,
    text: text.TextSystem,
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(gpu.Instance) = .empty,
    cpu: damage.Surface = .{},
    previous_theme: ?Theme = null,
    theme_generation: u64 = 0,
    /// Instances changed since the pixels were drawn.
    stale: bool = true,
    size: types.Size = .{},
    scale: f32 = 1,
    last_frame_time: f64 = 0,
    start_time: f64,
    tick: c_uint = 0,
    idle: c_uint = 0,
    present_idle: c_uint = 0,
    /// A frame asked for later (`frameIn`).
    later: c_uint = 0,
    theme_override: ?Theme = null,
    cursor: ctx_mod.Cursor = .arrow,
    input_state: input.State = .{},
    /// A shortcut may close the window while an owned input event is in flight.
    dead: bool = false,
    /// The press that started a double or triple click was already sent.
    pressed: bool = false,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        errdefer gpa.destroy(self);
        const g = &gtk.api;
        const area = g.gtk_drawing_area_new();
        self.* = .{
            .gpa = gpa,
            .window = window,
            .area = area,
            .im = g.gtk_im_multicontext_new(),
            .text = .init(gpa),
            .ctx = undefined,
            .view = view,
            .theme_override = theme_override,
            .start_time = clock.now(),
        };
        self.ctx = .init(gpa, &self.text);
        gtk.v3.gtk_widget_set_can_focus(area, 1);
        gtk.v3.gtk_widget_add_events(area, gtk.pointer_motion_mask | gtk.button_press_mask | gtk.button_release_mask | gtk.key_press_mask | (1 << 11) | gtk.leave_notify_mask | gtk.focus_change_mask | gtk.scroll_mask | gtk.smooth_scroll_mask);
        gtk.connect(area, "draw", @ptrCast(&onDraw), self);
        gtk.connect(area, "size-allocate", @ptrCast(&onSize), self);
        gtk.connect(area, "button-press-event", @ptrCast(&onPress), self);
        gtk.connect(area, "button-release-event", @ptrCast(&onRelease), self);
        gtk.connect(area, "motion-notify-event", @ptrCast(&onMotion), self);
        gtk.connect(area, "leave-notify-event", @ptrCast(&onLeave), self);
        gtk.connect(area, "scroll-event", @ptrCast(&onScroll), self);
        gtk.connect(area, "key-press-event", @ptrCast(&onKey), self);
        gtk.connect(area, "key-release-event", @ptrCast(&onKeyRelease), self);
        gtk.connect(area, "focus-in-event", @ptrCast(&onFocusIn), self);
        gtk.connect(area, "focus-out-event", @ptrCast(&onFocusOut), self);
        gtk.connect(area, "realize", @ptrCast(&onRealize), self);
        gtk.connect(self.im, "commit", @ptrCast(&onCommit), self);
        gtk.connect(self.im, "preedit-changed", @ptrCast(&onPreedit), self);
        gtk.v3.gtk_container_add(window.gtkwindow.?, area);
        return self;
    }

    pub fn destroy(self: *Surface) void {
        const g = &gtk.api;
        if (self.tick != 0) g.gtk_widget_remove_tick_callback(self.area, self.tick);
        if (self.idle != 0) _ = g.g_source_remove(self.idle);
        if (self.present_idle != 0) _ = g.g_source_remove(self.present_idle);
        if (self.later != 0) _ = g.g_source_remove(self.later);
        self.tick = 0;
        self.idle = 0;
        self.present_idle = 0;
        self.later = 0;
        if (self.input_state.draining) {
            self.dead = true;
            return;
        }
        g.g_object_unref(self.im);
        self.instances.deinit(self.gpa);
        self.input_state.deinit(self.gpa);
        self.cpu.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        self.gpa.destroy(self);
    }

    pub fn inputAlive(self: *Surface) bool {
        return !self.dead;
    }
    pub fn finishInput(self: *Surface) void {
        if (self.dead) self.destroy();
    }

    pub fn inputFailed(_: *Surface, err: anyerror) void {
        std.log.err("nanoui: input delivery failed: {s}", .{@errorName(err)});
    }
    pub fn readClipboard(self: *Surface) !?[]u8 {
        return @import("desktop.zig").clipboard.readText(self.gpa);
    }

    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        return if (@import("desktop.zig").isDark()) Theme.dark_theme else Theme.light;
    }

    /// Builds, lays out and paints a frame; it is drawn when GTK draws.
    pub fn frame(self: *Surface) void {
        if (self.dead or self.size.w <= 0 or self.size.h <= 0) return;
        @import("frame_schedule.zig").consume(gtk, &self.idle);
        const c = &self.ctx;
        const screen = gtk.v3.gtk_widget_get_screen(self.area);
        c.points_to_logical = @import("typography.zig").pointsToLogical(gtk.v3.gdk_screen_get_resolution(screen));
        const now = clock.now();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        if (self.dead) return;
        if (c.focused_text) |ft| {
            const caret = ft.caret_rect;
            const rect: gtk.Rectangle = .{ .x = @intFromFloat(caret.x), .y = @intFromFloat(caret.y), .width = @intFromFloat(@max(1, caret.w)), .height = @intFromFloat(@max(1, caret.h)) };
            gtk.api.gtk_im_context_set_cursor_location(self.im, &rect);
        }
        self.stale = true;
        if (self.present_idle == 0) self.present_idle = gtk.api.g_idle_add(onPresent, self);
        self.updateCursor();
        const more = c.animating or r.hot_changed;
        if (more and self.tick == 0) {
            self.tick = gtk.api.gtk_widget_add_tick_callback(self.area, onTick, self, null);
        } else if (!more and self.later == 0) if (c.frame_in) |s| {
            // Something changes now and then: one frame, that much later.
            self.later = gtk.api.g_timeout_add(@intFromFloat(@max(1, s * 1000)), onLater, self);
        };
        if (!c.animating) self.last_frame_time = 0;
    }

    /// A frame soon, for changes from outside the view (a process's output).
    pub fn requestFrame(self: *Surface) void {
        if (self.idle == 0) self.idle = gtk.api.g_idle_add(onIdle, self);
    }

    fn onLater(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.later = 0;
        self.frame();
        return 0;
    }

    fn onIdle(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.idle = 0;
        const has_input = self.input_state.head < self.input_state.events.items.len;
        InputHandler.drain(self);
        if (!has_input) self.frame();
        return 0;
    }

    fn onTick(_: *gtk.Widget, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.frame();
        if (self.ctx.animating) return 1;
        self.tick = 0;
        return 0;
    }

    // Coalesce CPU rasterization, preserving synchronous input/IME consumption.
    // Invalidate only changed pixels instead of the entire remote X11 window.
    fn onPresent(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Surface = @ptrCast(@alignCast(data));
        self.present_idle = 0;
        if (self.stale) if (self.render()) |dirty| presentation.queue(self.area, dirty, self.scale);
        return 0;
    }

    /// Draws the instances into the pixels, sized to the widget.
    fn render(self: *Surface) ?damage.Damage {
        const wf = @max(1, @round(self.size.w * self.scale));
        const hf = @max(1, @round(self.size.h * self.scale));
        // 2^32 is exact in f32; maxInt(u32) cannot be coerced to f32.
        if (!std.math.isFinite(wf) or !std.math.isFinite(hf) or wf >= 0x1p32 or hf >= 0x1p32) {
            self.cpu.invalidate();
            return null;
        }
        var pictures = self.text.images.pictures();
        pictures.textures = self.ctx.textures.items;
        if (self.previous_theme == null or !std.meta.eql(self.previous_theme.?, self.ctx.theme)) {
            self.theme_generation +%= 1;
            self.previous_theme = self.ctx.theme;
        }
        const result = self.cpu.render(self.gpa, self.instances.items, self.text.atlas.mask(), pictures, .{
            .width = @intFromFloat(wf),
            .height = @intFromFloat(hf),
            .scale = self.scale,
            .clear = gpu.color4(self.ctx.theme.background),
            .glyph_generation = self.text.atlas.generation,
            .image_generation = self.text.images.generation,
            .theme_generation = self.theme_generation,
        }) catch return null;
        self.stale = false;
        return result.damage;
    }

    fn updateCursor(self: *Surface) void {
        const want: ctx_mod.Cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
        if (want == self.cursor) return;
        self.cursor = want;
        const g = &gtk.api;
        const win = gtk.v3.gtk_widget_get_window(self.area) orelse return;
        const name: [*:0]const u8 = switch (want) {
            .arrow => "default",
            .hand => "pointer",
            .text => "text",
            .resize_left_right => "col-resize",
            .resize_up_down => "row-resize",
            .open_hand => "grab",
            .closed_hand => "grabbing",
            .not_allowed => "not-allowed",
            .crosshair => "crosshair",
        };
        const cursor = gtk.v3.gdk_cursor_new_from_name(g.gdk_display_get_default(), name);
        gtk.v3.gdk_window_set_cursor(win, cursor);
        if (cursor) |obj| g.g_object_unref(obj);
    }

    fn setMouse(self: *Surface, e: *gtk.Event) void {
        var x: f64 = 0;
        var y: f64 = 0;
        _ = gtk.v3.gdk_event_get_coords(e, &x, &y);
        self.ctx.input.mouse = .{ .x = @floatCast(x), .y = @floatCast(y) };
        var state: c_uint = 0;
        _ = gtk.v3.gdk_event_get_state(e, &state);
        self.ctx.input.shift = state & gtk.shift_mask != 0;
        self.ctx.input.cmd = false;
        self.ctx.input.ctrl = state & gtk.control_mask != 0;
        self.ctx.input.alt = state & (1 << 3) != 0;
    }
};

fn of(data: ?*anyopaque) *Surface {
    return @ptrCast(@alignCast(data));
}

fn onRealize(_: *gtk.Widget, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    s.cpu.invalidate();
    s.stale = true;
    gtk.v3.gtk_im_context_set_client_window(s.im, gtk.v3.gtk_widget_get_window(s.area));
}

fn onDraw(_: *gtk.Widget, cr: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    const g = &gtk.api;
    if (s.stale or !s.cpu.valid or s.cpu.bytes.len == 0) {
        const dirty = s.render() orelse return 0;
        // An exposure can arrive before the presentation idle. Do not lose
        // changed pixels outside that exposure's clip.
        presentation.queue(s.area, dirty, s.scale);
    }
    const pixels = s.cpu.pixels();
    if (pixels.bytes.len == 0) return 0;
    // Exposure reuses CURRENT persistent CPU pixels without rerasterizing.
    // ARGB32 on a little-endian machine is BGRA: the renderer's order.
    const surf = g.cairo_image_surface_create_for_data(pixels.bytes.ptr, 0, @intCast(pixels.width), @intCast(pixels.height), @intCast(pixels.width * 4));
    defer g.cairo_surface_destroy(surf);
    if (g.cairo_surface_status(surf) != 0) {
        s.cpu.presentationFailed();
        s.stale = true;
        return 0;
    }
    g.cairo_surface_set_device_scale(surf, s.scale, s.scale);
    g.cairo_set_source_surface(cr, surf, 0, 0);
    g.cairo_paint(cr);
    if (g.cairo_status(cr) != 0 or g.cairo_surface_status(surf) != 0) {
        s.cpu.presentationFailed();
        s.stale = true;
        return 0;
    }
    return 1;
}

fn onSize(w: *gtk.Widget, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = of(data);
    const g = &gtk.api;
    const size: types.Size = .{ .w = @floatFromInt(g.gtk_widget_get_allocated_width(w)), .h = @floatFromInt(g.gtk_widget_get_allocated_height(w)) };
    const scale: f32 = @floatFromInt(@max(1, g.gtk_widget_get_scale_factor(w)));
    if (size.w == s.size.w and size.h == s.size.h and scale == s.scale) return;
    s.size = size;
    s.scale = scale;
    s.text.setScale(scale);
    s.frame();
}

fn onPress(w: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    const g = &gtk.api;
    g.gtk_widget_grab_focus(w);
    var button: c_uint = 0;
    _ = gtk.v3.gdk_event_get_button(e, &button);
    if (button < 1 or button > 3) return 0;
    s.ctx.input.mouse_button = @import("../ui/input.zig").gtkButton(button);
    s.setMouse(e);
    s.ctx.updateHot();
    if (button != 1) {
        if (button == 3) s.ctx.secondaryDown();
        s.ctx.input.pressed = true;
        s.ctx.input.down = true;
        s.frame();
        return 1;
    }
    var count: c_uint = 1;
    _ = gtk.v3.gdk_event_get_click_count(e, &count);
    const kind = gtk.v3.gdk_event_get_event_type(e);
    s.ctx.input.click_count = count;
    // GTK sends a press for each click and then one more for a double
    // or triple click: that one only tells the count.
    if (kind == gtk.double_press or kind == gtk.triple_press) {
        s.ctx.input.pressed = true;
        s.frame();
        return 1;
    }
    s.ctx.updateHot();
    s.ctx.pointerDown();
    s.frame();
    return 1;
}

fn onRelease(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    var button: c_uint = 0;
    _ = gtk.v3.gdk_event_get_button(e, &button);
    if (button < 1 or button > 3) return 0;
    s.ctx.input.mouse_button = @import("../ui/input.zig").gtkButton(button);
    s.setMouse(e);
    s.ctx.updateHot();
    if (button != 1) {
        s.ctx.input.released = true;
        s.ctx.input.down = false;
        s.frame();
        return 1;
    }
    s.ctx.updateHot();
    s.ctx.pointerUp();
    s.frame();
    return 1;
}

fn onMotion(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    s.setMouse(e);
    const before = s.ctx.hot;
    s.ctx.updateHot();
    if (s.ctx.input.down or s.ctx.hot != before or s.ctx.wants_moves) {
        s.frame();
    } else if (s.ctx.pointerOverText() != s.ctx.cursor_text) {
        // Onto or off text that selects: the cursor only.
        s.ctx.cursor_text = !s.ctx.cursor_text;
        s.updateCursor();
    }
    return 1;
}

fn onLeave(_: *gtk.Widget, _: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    s.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
    if (s.ctx.hot != 0) {
        s.ctx.updateHot();
        s.frame();
    }
    return 0;
}

fn onScroll(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    s.setMouse(e);
    var dx: f64 = 0;
    var dy: f64 = 0;
    var delta: f32 = 0;
    var horizontal: f32 = 0;
    var lines: ?f32 = null;
    if (gtk.v3.gdk_event_get_scroll_deltas(e, &dx, &dy) != 0) {
        // Smooth deltas are in lines of about 40 pixels; up is negative.
        delta = @floatCast(-dy * 40);
        horizontal = @floatCast(-dx * 40);
    } else {
        var dir: c_int = 0;
        _ = gtk.v3.gdk_event_get_scroll_direction(e, &dir);
        delta = if (dir == 0) 48 else if (dir == 1) -48 else 0;
        horizontal = if (dir == 2) 48 else if (dir == 3) -48 else 0;
        lines = delta / 48;
    }
    if (delta != 0 and s.ctx.applyScroll(delta)) {
        s.frame();
        s.ctx.updateHot();
    } else if (s.ctx.wants_wheel) {
        s.ctx.input.scroll = .{ .x = horizontal, .y = delta };
        s.ctx.input.scroll_lines = lines;
        s.frame();
    }
    return 1;
}

fn onFocusIn(_: *gtk.Widget, _: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    gtk.api.gtk_im_context_focus_in(s.im);
    return 0;
}

fn onFocusOut(_: *gtk.Widget, _: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    const s = of(data);
    gtk.api.gtk_im_context_focus_out(s.im);
    gtk.api.gtk_im_context_reset(s.im);
    return 0;
}

fn onCommit(_: *anyopaque, str: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    InputHandler.commit(of(data), str);
}
fn onPreedit(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    InputHandler.preedit(of(data));
}
fn onKey(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    return InputHandler.press(of(data), e);
}
fn onKeyRelease(_: *gtk.Widget, e: *gtk.Event, data: ?*anyopaque) callconv(.c) c_int {
    return InputHandler.release(of(data), e);
}
