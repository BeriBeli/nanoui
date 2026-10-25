//! GTK signals become owned, ordered input before a view can run/reenter GTK.
const std = @import("std");
const gtk = @import("gtk.zig");
const ui = @import("../ui/input.zig");

const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    fn apply(m: @This(), in: *ui.Input) void {
        in.shift = m.shift;
        in.ctrl = m.ctrl;
        in.alt = m.alt;
        in.cmd = false;
    }
};
const Press = struct { key: ?ui.Key, cp: u21, keyval: c_uint };
const Payload = union(enum) {
    text: []u8,
    marked: struct { text: []u8, cursor: usize },
    press: Press,
    modifiers,
    fn bytes(p: @This()) usize {
        return switch (p) {
            .text => |t| t.len,
            .marked => |m| m.text.len,
            else => 0,
        };
    }
    fn deinit(p: @This(), a: std.mem.Allocator) void {
        switch (p) {
            .text => |t| a.free(t),
            .marked => |m| a.free(m.text),
            else => {},
        }
    }
};
const Event = struct { payload: Payload, modifiers: Modifiers };
pub const State = struct {
    pub const max_bytes = 1024 * 1024;
    pub const max_events = 4096;
    events: std.ArrayList(Event) = .empty,
    head: usize = 0,
    bytes: usize = 0,
    filtering: usize = 0,
    preediting: bool = false,
    draining: bool = false,
    modifiers: Modifiers = .{},
    failure: ?anyerror = null,
    pub fn deinit(s: *State, a: std.mem.Allocator) void {
        for (s.events.items[s.head..]) |event| event.payload.deinit(a);
        s.events.deinit(a);
    }
    fn reserve(s: *State, a: std.mem.Allocator, byte_count: usize) !void {
        if (byte_count > max_bytes - s.bytes or s.events.items.len - s.head >= max_events) return error.InputQueueFull;
        // Consumed events own nothing; compaction cannot invalidate in-flight text.
        if (s.head > 0) {
            std.mem.copyForwards(Event, s.events.items, s.events.items[s.head..]);
            s.events.items.len -= s.head;
            s.head = 0;
        }
        try s.events.ensureUnusedCapacity(a, 1);
    }
    fn append(s: *State, a: std.mem.Allocator, payload: Payload) !void {
        try s.reserve(a, payload.bytes());
        s.events.appendAssumeCapacity(.{ .payload = payload, .modifiers = s.modifiers });
        s.bytes += payload.bytes();
    }
    fn text(s: *State, a: std.mem.Allocator, value: []const u8, cursor: ?usize) !void {
        try s.reserve(a, value.len);
        const owned = try a.dupe(u8, value);
        s.events.appendAssumeCapacity(.{ .payload = if (cursor) |c| .{ .marked = .{ .text = owned, .cursor = c } } else .{ .text = owned }, .modifiers = s.modifiers });
        s.bytes += value.len;
    }
};

/// The native backend and the test backend use these identical callbacks.
pub fn Handler(comptime Backend: type) type {
    return struct {
        fn failed(s: anytype, err: anyerror) void {
            s.input_state.failure = err;
            s.inputFailed(err);
        }
        pub fn commit(s: anytype, str: [*:0]const u8) void {
            const value = std.mem.span(str);
            if (value.len == 0) return;
            s.input_state.text(s.gpa, value, null) catch |err| {
                failed(s, err);
                return;
            };
            drain(s);
        }
        pub fn preedit(s: anytype) void {
            var str: ?[*:0]u8 = null;
            var cursor: c_int = 0;
            Backend.api.gtk_im_context_get_preedit_string(s.im, &str, null, &cursor);
            const p = str orelse return;
            defer Backend.api.g_free(p);
            s.input_state.preediting = p[0] != 0;
            s.input_state.text(s.gpa, std.mem.span(p), cursorByte(std.mem.span(p), cursor)) catch |err| {
                failed(s, err);
                return;
            };
            drain(s);
        }
        fn filtered(s: anytype, e: *gtk.Event) c_int {
            s.input_state.filtering += 1;
            defer s.input_state.filtering -= 1;
            return Backend.v3.gtk_im_context_filter_keypress(s.im, e);
        }
        fn modifiers(s: anytype, e: *gtk.Event, pressed: bool) c_uint {
            var keyval: c_uint = 0;
            var state: c_uint = 0;
            _ = Backend.v3.gdk_event_get_keyval(e, &keyval);
            _ = Backend.v3.gdk_event_get_state(e, &state);
            var m: Modifiers = .{ .shift = state & gtk.shift_mask != 0, .ctrl = state & gtk.control_mask != 0, .alt = state & gtk.alt_mask != 0 };
            // GDK's state is the state BEFORE the modifier press/release.
            switch (keyval) {
                0xffe1, 0xffe2 => m.shift = pressed,
                0xffe3, 0xffe4 => m.ctrl = pressed,
                0xffe9, 0xffea => m.alt = pressed,
                else => {},
            }
            s.input_state.modifiers = m;
            return keyval;
        }
        fn queue(s: anytype, payload: Payload) void {
            s.input_state.append(s.gpa, payload) catch |err| {
                failed(s, err);
            };
        }
        pub fn press(s: anytype, e: *gtk.Event) c_int {
            const keyval = modifiers(s, e, true);
            const state = &s.input_state;
            const pending = state.events.items.len - state.head;
            const composing = state.preediting;
            // IME owns consumed keys, including Ctrl+Shift+U and composition
            // confirmation/cancellation, before application/terminal shortcuts.
            const handled = filtered(s, e);
            const p: Press = .{ .key = keyOf(keyval), .cp = @intCast(Backend.api.gdk_keyval_to_unicode(keyval)), .keyval = keyval };
            // Some GTK IM contexts commit literal Ctrl punctuation and report
            // it consumed. Recover only an exact, synchronous ASCII echo with
            // no composition; transformed text, AltGr and preedit stay IM-owned.
            var direct = false;
            if (state.modifiers.ctrl and !state.modifiers.alt and !composing and !state.preediting and
                p.cp >= 0x20 and p.cp < 0x7f and state.events.items.len - state.head == pending + 1)
            {
                const event = &state.events.items[state.head + pending];
                if (event.payload == .text and event.payload.text.len == 1 and event.payload.text[0] == p.cp) {
                    state.bytes -= 1;
                    event.payload.deinit(s.gpa);
                    event.payload = .{ .press = p };
                    direct = true;
                }
            }
            if (handled == 0 and !direct) queue(s, .{ .press = p });
            // FALSE does not revoke commits already emitted by the input method.
            drain(s);
            return 1;
        }
        pub fn release(s: anytype, e: *gtk.Event) c_int {
            const keyval = modifiers(s, e, false);
            const result = filtered(s, e);
            if (keyval >= 0xffe1 and keyval <= 0xffea) queue(s, .modifiers);
            drain(s);
            return result;
        }
        pub fn drain(s: anytype) void {
            const state = &s.input_state;
            if (state.filtering > 0 or state.draining) return;
            state.draining = true;
            defer s.finishInput();
            defer state.draining = false;
            var budget: usize = State.max_events;
            while (state.head < state.events.items.len and budget > 0 and s.inputAlive()) : (budget -= 1) {
                const event = state.events.items[state.head];
                state.head += 1;
                state.bytes -= event.payload.bytes();
                // Detach before frame(): nested commits can grow or compact
                // the queue, but cannot mutate/replay this event's storage.
                defer event.payload.deinit(s.gpa);
                defer s.ctx.input.clearEdges();
                event.modifiers.apply(&s.ctx.input);
                switch (event.payload) {
                    .text => |t| {
                        s.ctx.input.chars = t;
                        s.frame();
                        s.ctx.input.chars = "";
                    },
                    .marked => |m| {
                        var ops = [_]ui.TextOp{.{ .set_marked = .{ .text = m.text, .sel_start = m.cursor, .sel_len = 0 } }};
                        s.ctx.input.ops = &ops;
                        s.frame();
                        s.ctx.input.ops = &.{};
                    },
                    .press => |p| dispatch(s, p),
                    .modifiers => s.frame(),
                }
            }
            if (!s.inputAlive()) return;
            if (state.head == state.events.items.len) {
                state.events.clearRetainingCapacity();
                state.head = 0;
            } else s.requestFrame();
        }
        fn dispatch(s: anytype, p: Press) void {
            const in = &s.ctx.input;
            const ctrl = in.ctrl;
            const alt = in.alt;
            if (p.keyval == 0xffe3 or p.keyval == 0xffe4) s.frame();
            const special: ?u21 = if (p.key) |k| switch (k) {
                .up => ui.Shortcut.up,
                .down => ui.Shortcut.down,
                .left => ui.Shortcut.left,
                .right => ui.Shortcut.right,
                .tab => ui.Shortcut.tab,
                .escape => ui.Shortcut.escape,
                .enter => ui.Shortcut.enter,
                else => null,
            } else null;
            const base: u21 = special orelse if (p.cp < 128) std.ascii.toLower(@intCast(p.cp)) else p.cp;
            if (base != 0 and (ctrl or alt or (special != null and (base == ui.Shortcut.up or base == ui.Shortcut.down or base == ui.Shortcut.tab or base == ui.Shortcut.escape)))) {
                const sc: ui.Shortcut = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
                if (s.window.app.accelerator(sc)) return;
                if (ctrl and s.ctx.focused_text != null and s.ctx.focused_text.?.editable and editShortcut(s, base)) return;
                s.ctx.shortcut_taken = false;
                in.shortcut = sc;
                s.frame();
                in.shortcut = null;
                if (s.ctx.shortcut_taken) return;
            }
            if (p.key) |k| {
                in.key = k;
                s.frame();
                return;
            }
            if (ctrl or p.cp < 0x20 or p.cp == 0x7f) return;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(p.cp, &buf) catch return;
            in.chars = buf[0..n];
            s.frame();
            in.chars = "";
        }
        fn editShortcut(s: anytype, key: u21) bool {
            const op: ui.TextOp = switch (key) {
                'c' => .{ .command = .copy },
                'x' => .{ .command = .cut },
                'a' => .{ .command = .select_all },
                'v' => {
                    const pasted = s.readClipboard() catch return true;
                    const t = pasted orelse return false;
                    defer s.gpa.free(t);
                    for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
                        ch.* = ' ';
                    };
                    var ops = [1]ui.TextOp{.{ .insert = t }};
                    s.ctx.input.ops = &ops;
                    s.frame();
                    s.ctx.input.ops = &.{};
                    return true;
                },
                else => return false,
            };
            var ops = [1]ui.TextOp{op};
            s.ctx.input.ops = &ops;
            s.frame();
            s.ctx.input.ops = &.{};
            return true;
        }
    };
}

fn keyOf(keyval: c_uint) ?ui.Key {
    return switch (keyval) {
        0xff08 => .backspace,
        0xffff => .delete,
        0xff51 => .left,
        0xff52 => .up,
        0xff53 => .right,
        0xff54 => .down,
        0xff50 => .home,
        0xff57 => .end,
        0xff55 => .page_up,
        0xff56 => .page_down,
        0xff0d, 0xff8d => .enter,
        0xff09, 0xfe20 => .tab,
        0xff1b => .escape,
        0xffbe...0xffc9 => @fromBackingInt(@intCast(@backingInt(ui.Key.f1) + keyval - 0xffbe)),
        else => null,
    };
}

// GTK reports a Unicode-character index; TextOp selections use UTF-8 bytes.
fn cursorByte(text: []const u8, cursor: c_int) usize {
    var at: usize = 0;
    var left: usize = @intCast(@max(0, cursor));
    while (left > 0 and at < text.len) : (left -= 1) {
        const count = std.unicode.utf8ByteSequenceLength(text[at]) catch break;
        if (count > text.len - at) break;
        at += count;
    }
    return at;
}
