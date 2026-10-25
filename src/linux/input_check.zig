//! Exercises the same handlers installed on GtkDrawingArea, without a desktop.
const std = @import("std");
const gtk = @import("gtk.zig");
const ui = @import("../ui/input.zig");
const H = @import("input.zig").Handler(Backend);

const Event = struct {
    code: c_uint,
    state: c_uint = 0,
    handled: c_int = 0,
    text: ?[:0]const u8 = null,
    marked: ?[:0]const u8 = null,
    end_marked: bool = false,
    fn native(e: *@This()) *gtk.Event {
        return @ptrCast(e);
    }
};
const Backend = struct {
    pub var api: gtk.Api = undefined;
    pub var v3: gtk.Api3 = undefined;
    var preedit_text: [:0]const u8 = "";
    var preedit_cursor: ?c_int = null;
    fn init() void {
        preedit_cursor = null;
        preedit_text = "";
        v3.gdk_event_get_keyval = keyval;
        v3.gdk_event_get_state = state;
        api.gdk_keyval_to_unicode = unicode;
        v3.gtk_im_context_filter_keypress = filter;
        api.gtk_im_context_get_preedit_string = marked;
        api.g_free = free;
    }
    fn keyval(e: *gtk.Event, value: *c_uint) callconv(.c) c_int {
        const event: *Event = @ptrCast(@alignCast(e));
        value.* = event.code;
        return 1;
    }
    fn state(e: *gtk.Event, value: *c_uint) callconv(.c) c_int {
        const event: *Event = @ptrCast(@alignCast(e));
        value.* = event.state;
        return 1;
    }
    fn unicode(value: c_uint) callconv(.c) u32 {
        return if (value < 128) value else 0;
    }
    fn filter(im: *anyopaque, e: *gtk.Event) callconv(.c) c_int {
        const s: *Fixture = @ptrCast(@alignCast(im));
        const event: *Event = @ptrCast(@alignCast(e));
        s.filters += 1;
        if (event.marked) |value| {
            preedit_text = value;
            H.preedit(s);
        }
        if (event.text) |value| H.commit(s, value);
        if (event.end_marked) {
            preedit_text = "";
            H.preedit(s);
        }
        return event.handled;
    }
    fn marked(_: *anyopaque, value: *?[*:0]u8, _: ?*anyopaque, cursor: *c_int) callconv(.c) void {
        value.* = (std.testing.allocator.dupeSentinel(u8, preedit_text, 0) catch unreachable).ptr;
        cursor.* = preedit_cursor orelse @intCast(std.unicode.utf8CountCodepoints(preedit_text) catch unreachable);
    }
    fn free(value: ?*anyopaque) callconv(.c) void {
        const text: [*:0]u8 = @ptrCast(value.?);
        std.testing.allocator.free(std.mem.span(text));
    }
};
const App = struct {
    pub fn accelerator(_: *@This(), _: ui.Shortcut) bool {
        return false;
    }
};
const Window = struct { app: *App };
const Context = struct {
    input: ui.Input = .{},
    shortcut_taken: bool = false,
    focused_text: ?struct { id: u64, editable: bool = true } = null,
};
const Fixture = struct {
    gpa: std.mem.Allocator = std.testing.allocator,
    app: App = .{},
    win: Window = undefined,
    window: *Window = undefined,
    im: *anyopaque = undefined,
    ctx: Context = .{},
    input_state: @import("input.zig").State = .{},
    reported: ?anyerror = null,
    requested: bool = false,
    out: std.ArrayList(u8) = .empty,
    order: std.ArrayList(u8) = .empty,
    marked_text: std.ArrayList(u8) = .empty,
    marked_cursor: usize = 0,
    during_frame: ?[:0]const u8 = null,
    depth: usize = 0,
    max_depth: usize = 0,
    frames: usize = 0,
    alive: bool = true,
    close_during_frame: bool = false,
    input_finished: bool = false,
    filters: usize = 0,
    last_shortcut: ?ui.Shortcut = null,
    fn init(s: *@This()) void {
        Backend.init();
        s.win = .{ .app = &s.app };
        s.window = &s.win;
        s.im = s;
    }
    fn deinit(s: *@This()) void {
        s.input_state.deinit(s.gpa);
        s.out.deinit(s.gpa);
        s.order.deinit(s.gpa);
        s.marked_text.deinit(s.gpa);
    }
    pub fn inputAlive(s: *@This()) bool {
        return s.alive;
    }
    pub fn finishInput(s: *@This()) void {
        s.input_finished = true;
    }
    pub fn requestFrame(s: *@This()) void {
        s.requested = true;
    }
    pub fn inputFailed(s: *@This(), err: anyerror) void {
        s.reported = err;
    }
    pub fn readClipboard(_: *@This()) !?[]u8 {
        return null;
    }
    pub fn frame(s: *@This()) void {
        s.depth += 1;
        s.max_depth = @max(s.max_depth, s.depth);
        s.frames += 1;
        defer s.depth -= 1;
        for (s.ctx.input.ops) |op| switch (op) {
            .set_marked => |m| {
                s.marked_cursor = m.sel_start;
                s.marked_text.clearRetainingCapacity();
                s.marked_text.appendSlice(s.gpa, m.text) catch unreachable;
                s.order.append(s.gpa, if (m.text.len > 0) 'M' else 'E') catch unreachable;
            },
            else => {},
        };
        if (s.ctx.input.chars.len > 0) {
            s.out.appendSlice(s.gpa, s.ctx.input.chars) catch unreachable;
            s.order.append(s.gpa, 'T') catch unreachable;
        }
        if (s.ctx.input.key == .enter) s.out.append(s.gpa, '\r') catch unreachable;
        if (s.ctx.input.shortcut != null) {
            s.last_shortcut = s.ctx.input.shortcut;
            s.ctx.shortcut_taken = true;
            s.out.append(s.gpa, '^') catch unreachable;
        }
        s.ctx.input.clearEdges();
        if (s.close_during_frame) s.alive = false;
        if (s.during_frame) |value| {
            s.during_frame = null;
            H.commit(s, value);
        }
    }
};

test "GTK rapid press/release and overlapping presses deliver every byte once" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    const sample = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    for (0..1000) |_| {
        for (sample) |ch| {
            var event: Event = .{ .code = ch };
            _ = H.press(&s, event.native());
        }
        for (sample) |ch| {
            var event: Event = .{ .code = ch };
            _ = H.release(&s, event.native());
        }
    }
    try std.testing.expectEqual(sample.len * 1000, s.out.items.len);
    for (0..1000) |i| try std.testing.expectEqualStrings(sample, s.out.items[i * sample.len ..][0..sample.len]);
    try std.testing.expectEqual(@as(usize, 1), s.max_depth);
}
test "GTK IM commit before an unconsumed Enter is retained before the key" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    var event: Event = .{ .code = 0xff0d, .text = "中文" };
    _ = H.press(&s, event.native());
    try std.testing.expectEqualStrings("中文\r", s.out.items);
}
test "GTK asynchronous commit during delivery never replays or nests a frame" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    s.during_frame = "b";
    H.commit(&s, "a");
    try std.testing.expectEqualStrings("ab", s.out.items);
    try std.testing.expectEqual(@as(usize, 1), s.max_depth);
}
test "GTK preedit and commit signals preserve their callback order" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    var event: Event = .{ .code = 'x', .handled = 1, .marked = "zhong", .text = "中", .end_marked = true };
    _ = H.press(&s, event.native());
    try std.testing.expectEqualStrings("中", s.out.items);
    try std.testing.expectEqualStrings("MTE", s.order.items);
    try std.testing.expectEqualStrings("", s.marked_text.items);
}
test "GTK IM gets modified keys before terminal fallback shortcuts" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    var event: Event = .{ .code = 'u', .state = gtk.control_mask | gtk.shift_mask, .handled = 1, .text = "中" };
    _ = H.press(&s, event.native());
    try std.testing.expectEqualStrings("中", s.out.items);
}
test "GTK release-generated and delayed commits are each delivered once" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    var event: Event = .{ .code = 'a', .handled = 1 };
    _ = H.press(&s, event.native());
    H.commit(&s, "α");
    event.text = "β";
    _ = H.release(&s, event.native());
    event.text = null;
    _ = H.release(&s, event.native());
    H.commit(&s, "γ");
    try std.testing.expectEqualStrings("αβγ", s.out.items);
}

test "GTK queued commits own bytes and queue limits fail visibly" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    s.input_state.filtering = 1;
    var value = [_:0]u8{'a'};
    H.commit(&s, &value);
    value[0] = 'b';
    H.commit(&s, &value);
    for (2..@import("input.zig").State.max_events) |_| H.commit(&s, "x");
    H.commit(&s, "overflow");
    try std.testing.expectEqual(error.InputQueueFull, s.reported.?);
    try std.testing.expectEqual(@import("input.zig").State.max_events, s.input_state.events.items.len);
    s.input_state.filtering = 0;
    H.drain(&s);
    try std.testing.expectEqualStrings("ab", s.out.items[0..2]);
    try std.testing.expectEqual(@import("input.zig").State.max_events, s.out.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.input_state.bytes);
    try std.testing.expectEqual(@as(usize, 0), s.ctx.input.chars.len);
}
test "GTK byte limit rejects oversized commits without corrupting accepted input" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    const value = try s.gpa.allocSentinel(u8, @import("input.zig").State.max_bytes + 1, 0);
    defer s.gpa.free(value);
    @memset(value, 'x');
    H.commit(&s, value);
    try std.testing.expectEqual(error.InputQueueFull, s.reported.?);
    H.commit(&s, "ok");
    try std.testing.expectEqualStrings("ok", s.out.items);
}
test "GTK unconsumed shortcuts and modifier release retain fallback behavior" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    var event: Event = .{ .code = 'c', .state = gtk.control_mask };
    _ = H.press(&s, event.native());
    try std.testing.expectEqualStrings("^", s.out.items);
    event = .{ .code = 0xffe3, .state = gtk.control_mask };
    _ = H.release(&s, event.native());
    try std.testing.expect(!s.ctx.input.ctrl);
    event = .{ .code = 'b' };
    _ = H.press(&s, event.native());
    try std.testing.expectEqualStrings("^b", s.out.items);
}

test "GTK window close during input stops delivery and releases only after unwind" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    s.close_during_frame = true;
    s.during_frame = "queued after close";
    H.commit(&s, "a");
    try std.testing.expectEqualStrings("a", s.out.items);
    try std.testing.expect(s.input_finished and !s.input_state.draining and !s.requested);
}

test "GTK direct Ctrl punctuation commits become one shortcut without literal text" {
    for ([_]u8{ ',', '+', '-', '<' }) |ch| for ([_]c_int{ 0, 1 }) |handled| {
        var s: Fixture = .{};
        s.init();
        defer s.deinit();
        const text = [_:0]u8{ch};
        const shift = ch != ',';
        var event: Event = .{ .code = ch, .state = gtk.control_mask | (if (shift) @as(c_uint, gtk.shift_mask) else 0), .handled = handled, .text = &text };
        _ = H.press(&s, event.native());
        try std.testing.expectEqualStrings("^", s.out.items);
        const sc = s.last_shortcut.?;
        try std.testing.expect(sc.ctrl and sc.shift == shift and sc.key == ch);
        try std.testing.expectEqual(@as(usize, 0), s.input_state.bytes);
    };
}

test "GTK composition and transformed modified commits retain input method ownership" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    var start: Event = .{ .code = 'x', .handled = 1, .marked = "compose" };
    _ = H.press(&s, start.native());
    var composed: Event = .{ .code = ',', .state = gtk.control_mask, .handled = 1, .text = ",", .end_marked = true };
    _ = H.press(&s, composed.native());
    var transformed: Event = .{ .code = ',', .state = gtk.control_mask, .handled = 1, .text = "中" };
    _ = H.press(&s, transformed.native());
    var ordinary: Event = .{ .code = ',', .handled = 1, .text = "," };
    _ = H.press(&s, ordinary.native());
    var altgr: Event = .{ .code = '@', .state = gtk.control_mask | gtk.alt_mask, .handled = 1, .text = "@" };
    _ = H.press(&s, altgr.native());
    try std.testing.expectEqualStrings(",中,@", s.out.items);
    try std.testing.expect(s.last_shortcut == null);
}

test "GTK delayed modified commits are text rather than replayed shortcuts" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    var event: Event = .{ .code = ',', .state = gtk.control_mask, .handled = 1 };
    _ = H.press(&s, event.native());
    H.commit(&s, ",");
    try std.testing.expectEqualStrings(",", s.out.items);
    try std.testing.expect(s.last_shortcut == null);
}

test "GTK terminal shortcuts do not depend on the stable pane ID bits" {
    for ([_]u64{ 1, (@as(u64, 1) << 63) | 1 }) |id| {
        var s: Fixture = .{};
        s.init();
        defer s.deinit();
        s.ctx.focused_text = .{ .id = id, .editable = false };
        for ("cavx") |key| {
            var event: Event = .{ .code = key, .state = gtk.control_mask };
            _ = H.press(&s, event.native());
            try std.testing.expectEqual(@as(u21, key), s.last_shortcut.?.key);
        }
        try std.testing.expectEqualStrings("^^^^", s.out.items);
    }
}

test "GTK preedit character positions become UTF-8 byte boundaries" {
    var s: Fixture = .{};
    s.init();
    defer s.deinit();
    Backend.preedit_text = "中文e\u{301}";
    const Case = struct { native: c_int, byte: usize };
    for ([_]Case{ .{ .native = -1, .byte = 0 }, .{ .native = 1, .byte = 3 }, .{ .native = 2, .byte = 6 }, .{ .native = 3, .byte = 7 }, .{ .native = 4, .byte = 9 }, .{ .native = 99, .byte = 9 } }) |case| {
        Backend.preedit_cursor = case.native;
        H.preedit(&s);
        try std.testing.expectEqualStrings(Backend.preedit_text, s.marked_text.items);
        try std.testing.expectEqual(case.byte, s.marked_cursor);
    }
}
