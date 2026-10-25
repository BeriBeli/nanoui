//! What one event brings, and what text editing keeps: keys, key
//! combinations offered to the view, text operations (typing, the input
//! method, selection, clipboard), the focused field as the input method
//! asks about it, where copied text goes, a field's editing state, and the
//! pointer and keys of this event.
const std = @import("std");
const types = @import("types.zig");

pub const Key = enum { backspace, delete, left, right, up, down, home, end, enter, tab, escape, page_up, page_down, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12 };

/// A key with modifiers, offered to the view before text editing sees it:
/// characters lowercase, other keys as `Shortcut.up` and the like.
pub const Shortcut = struct {
    key: u21,
    cmd: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub const up: u21 = 0xF700;
    pub const down: u21 = 0xF701;
    pub const left: u21 = 0xF702;
    pub const right: u21 = 0xF703;
    pub const escape: u21 = 0x1b;
    pub const tab: u21 = '\t';
    pub const enter: u21 = '\r';

    /// As this platform has it: Command is Control off Apple's systems.
    pub fn native(s: Shortcut) Shortcut {
        if (@import("keys.zig").mac or !s.cmd) return s;
        var n = s;
        n.cmd = false;
        n.ctrl = true;
        return n;
    }
};

/// What text input does to the focused text, in AppKit's terms: typed or
/// pasted text, an input method's composition, and editing commands.
pub const TextOp = union(enum) {
    insert: []const u8,
    /// Text being composed (underlined), with the selection inside it.
    set_marked: struct { text: []const u8, sel_start: usize, sel_len: usize },
    unmark,
    command: Command,
};

pub const Command = enum {
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_to_line_start,
    delete_word_forward,
    delete_to_line_end,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    select_left,
    select_right,
    select_word_left,
    select_word_right,
    select_line_start,
    select_line_end,
    select_all,
    /// A line up or down: a multiline field's; a single line's start or end.
    move_up,
    move_down,
    select_up,
    select_down,
    insert_newline,
    /// Option-Return, Shift-Return: a new line in a multiline field.
    insert_line_break,
    insert_tab,
    cancel,
    copy,
    cut,
};

/// The focused text field as the last frame left it, for the input
/// method's questions between frames. Offsets are bytes.
pub const FocusedText = struct {
    /// False for a terminal input client that owns its editing shortcuts.
    editable: bool = true,
    id: u64,
    text: []const u8,
    caret: usize,
    anchor: usize,
    marked: ?[2]usize,
    /// Where the caret is drawn, in view points.
    caret_rect: types.Rect,
};

/// Where copied text goes: the system's clipboard, or the Tester's own.
pub const Clipboard = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, text: []const u8) void = systemWrite,

    fn systemWrite(_: ?*anyopaque, s: []const u8) void {
        @import("../platform.zig").clipboardWrite(s);
    }
};

/// A text field's editing state, kept across frames.
pub const EditState = struct {
    caret: usize = 0,
    anchor: usize = 0,
    marked: ?[2]usize = null,
    scroll_x: f32 = 0,
    /// A multiline field's lines scrolled up past its top.
    scroll_y: f32 = 0,
    /// Pressed in the field: dragging extends the selection.
    selecting: bool = false,
    /// Emacs's and Vim's keys (keymap.zig) and the undo history.
    keys: KeyState = .{},
    undo: @import("undo.zig").History = .{},
};

/// What Emacs's and Vim's keys remember between events.
pub const KeyState = struct {
    /// What was killed or yanked, newest first: ^Y and p put back the
    /// first, M-y the ones before it.
    ring: [4][256]u8 = undefined,
    ring_len: [4]u16 = @splat(0),
    ring_count: u8 = 0,
    /// The last command killed (the next kill joins it), or put back
    /// [from, to) from ring entry `yank_at` (M-y swaps it for an older one).
    last_kill: bool = false,
    yanked: ?[2]usize = null,
    yank_at: u8 = 0,
    /// Emacs's mark (C-Space): the region is from it to the caret.
    mark: ?usize = null,
    /// Vim: normal or visual mode (where visual began); a count, an
    /// operator (d c y) and its count, a key waiting for the next one
    /// (f F t T r g, i a after an operator); the last f F t T and its char.
    vim_normal: bool = false,
    vim_visual: bool = false,
    vim_anchor: usize = 0,
    vim_count: u16 = 0,
    vim_op: u8 = 0,
    vim_op_count: u16 = 0,
    vim_prefix: u8 = 0,
    vim_find: [2]u8 = .{ 0, 0 },
};

pub const Input = struct {
    mouse: types.Point = .{ .x = -1e6, .y = -1e6 },
    down: bool = false,
    /// The button went down / up in this event.
    pressed: bool = false,
    released: bool = false,
    click_count: u32 = 0,
    mouse_button: u8 = 1,
    /// Scroll delta in logical pixels: positive moves toward top/left.
    scroll: types.Point = .{},
    /// A pinch in this event (two fingers on a touch screen, a trackpad's
    /// magnify): how much it scaled by (1: none), about `mouse`.
    zoom: f32 = 1,
    /// How far two fingers moved together in this event.
    pan: types.Point = .{},
    /// Native vertical line delta for discrete wheels; null for precise input.
    scroll_lines: ?f32 = null,
    /// A new native gesture must not inherit a previous fractional row.
    scroll_started: bool = false,
    key: ?Key = null,
    /// Text typed or pasted in this event.
    chars: []const u8 = "",
    /// Text input operations of this event, for the focused text field.
    ops: []const TextOp = &.{},
    /// A key combination offered in this event (`Context.shortcut`).
    shortcut: ?Shortcut = null,
    shift: bool = false,
    cmd: bool = false,
    ctrl: bool = false,
    /// Option on the Mac, Alt elsewhere: held with this event's key.
    alt: bool = false,

    /// The key that adds to a selection with a click: Command on the
    /// Mac, Control elsewhere.
    pub fn adding(i: Input) bool {
        return if (comptime @import("keys.zig").mac) i.cmd else i.ctrl;
    }

    pub fn clearEdges(i: *Input) void {
        i.pressed = false;
        i.released = false;
        i.scroll = .{};
        i.zoom = 1;
        i.pan = .{};
        i.scroll_lines = null;
        i.scroll_started = false;
        i.key = null;
        i.chars = "";
        i.ops = &.{};
        i.shortcut = null;
    }
};

/// Input's button contract is 1 left, 2 right, 3 middle on every backend.
pub fn gtkButton(button: u32) u8 {
    return switch (button) {
        1 => 1,
        2 => 3,
        3 => 2,
        else => 0,
    };
}
test "GTK mouse buttons normalize to the shared right/middle contract" {
    try std.testing.expectEqual(@as(u8, 2), gtkButton(3));
    try std.testing.expectEqual(@as(u8, 3), gtkButton(2));
    try std.testing.expectEqual(@as(u8, 0), gtkButton(9));
}

/// AppKit can report a slow discrete wheel detent as 0.1. Keep each
/// nonzero detent responsive while retaining OS acceleration above one.
/// Precise devices must keep their fractional logical-pixel displacement.
pub fn macosScrollDelta(delta: f32, precise: bool) f32 {
    if (!std.math.isFinite(delta)) return 0;
    if (precise or delta == 0) return delta;
    return if (delta > 0) @max(1, delta) else @min(-1, delta);
}
test "AppKit discrete detents have a minimum step without amplifying precise input" {
    try std.testing.expectEqual(@as(f32, 1), macosScrollDelta(0.1, false));
    try std.testing.expectEqual(@as(f32, -1), macosScrollDelta(-0.1, false));
    try std.testing.expectEqual(@as(f32, 2.5), macosScrollDelta(2.5, false));
    try std.testing.expectEqual(@as(f32, 0), macosScrollDelta(0, false));
    try std.testing.expectEqual(@as(f32, 0.1), macosScrollDelta(0.1, true));
    try std.testing.expectEqual(@as(f32, -0.1), macosScrollDelta(-0.1, true));
}
