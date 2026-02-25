// Focus management

const std    = @import("std");
const defs   = @import("defs");
const tiling = @import("tiling");
const utils  = @import("utils");
const bar    = @import("bar");
const window = @import("window");
const xcb    = defs.xcb;
const WM     = defs.WM;

pub const Reason = enum {
    mouse_click,
    mouse_enter,
    window_destroyed,
    workspace_switch,
    user_command,
    tiling_operation,
    // Distinct from other reasons so tiling operations cannot accidentally
    // inherit window_spawn crossing suppression via external state.
    window_spawn,
};

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (win == 0 or win == wm.root) return;
    if (wm.focused_window == win) return;
    if (bar.isBarWindow(win)) return;

    // EnterNotify/LeaveNotify are only delivered for mapped windows, so skip
    // the round-trip on hover. For window_spawn the map was queued on this
    // connection moments ago, so the attributes reply will always show mapped.
    // For all other reasons a race with destroy is possible, so we guard.
    if (reason != .mouse_enter and reason != .window_spawn and !isWindowMapped(wm.conn, win)) return;

    const input_model = utils.getInputModelCached(wm.conn, win);
    if (input_model == .no_input) return;

    const old = wm.focused_window;
    wm.focused_window = win;
    wm.suppress_focus_reason = suppressionFor(reason);

    window.grabButtons(wm, win, true);
    if (old) |old_win| window.grabButtons(wm, old_win, false);

    // ICCCM §4.1.7 says xcb_set_input_focus must not be sent to globally_active
    // windows, but Electron/Chromium ignores WM_TAKE_FOCUS on hover and only
    // accepts XSetInputFocus. Sending it unconditionally matches i3/openbox/kwin.
    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win,
        wm.last_event_time,
    );

    // Raise on click/command, and also on hover for globally_active windows
    // (Electron/Chromium only accept focus when topmost in the stacking order).
    if (shouldRaise(reason) or (reason == .mouse_enter and input_model == .globally_active)) {
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
        );
    }

    if (input_model == .locally_active or input_model == .globally_active) {
        utils.sendWMTakeFocus(wm.conn, win, wm.last_event_time);
    }

    tiling.updateWindowFocus(wm, old, win);
    // No flush here: the event loop batches rapid hover crossings into a single
    // write syscall rather than flushing on each one.
    bar.markDirty();
}

pub fn clearFocus(wm: *WM) void {
    if (wm.focused_window) |old_win| {
        window.grabButtons(wm, old_win, false);
        tiling.updateWindowFocus(wm, old_win, null);
    }
    wm.focused_window = null;
    wm.suppress_focus_reason = .none;
    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        wm.root,
        wm.last_event_time,
    );
    bar.markDirty();
}

fn shouldRaise(reason: Reason) bool {
    return switch (reason) {
        .mouse_click, .user_command => true,
        .mouse_enter, .window_destroyed, .workspace_switch,
        .tiling_operation, .window_spawn => false,
    };
}

fn suppressionFor(reason: Reason) defs.FocusSuppressReason {
    return switch (reason) {
        .mouse_click, .mouse_enter, .window_destroyed,
        .user_command, .workspace_switch => .none,
        .tiling_operation => .tiling_operation,
        .window_spawn     => .window_spawn,
    };
}

// Returns true only if the window is mapped and viewable.
// A failed reply (e.g. window was destroyed) is treated as unmapped.
fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn, xcb.xcb_get_window_attributes(conn, win), null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}
