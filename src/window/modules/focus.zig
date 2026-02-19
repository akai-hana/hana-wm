// Focus management

const std = @import("std");
const defs = @import("defs");
const tiling = @import("tiling");
const utils = @import("utils");
const bar = @import("bar");
const window = @import("window");
const debug = @import("debug");
const xcb = defs.xcb;
const WM = defs.WM;

pub const Reason = enum {
    mouse_click,
    mouse_enter,
    window_destroyed,
    workspace_switch,
    user_command,
    tiling_operation,
    // Explicit reason for newly spawned windows; prevents tiling operations
    // from inadvertently inheriting window_spawn suppression via external state.
    window_spawn,
};

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (win == 0 or win == wm.root or bar.isBarWindow(win)) return;
    if (wm.focused_window == win) return;

    // EnterNotify / LeaveNotify are only delivered for mapped, viewable windows —
    // the X server guarantees this.  Skip the round-trip for hover focus.
    // For .window_spawn, xcb_map_window was sent on this same connection moments
    // before this call; XCB's in-order delivery means the get_window_attributes
    // reply will always reflect the already-mapped state — the check can never
    // fail, so skip it.  For all other reasons (click, workspace switch, destroy
    // recovery) the window could be destroyed between the triggering event and
    // this call, so we guard against that BadMatch race.
    if (reason != .mouse_enter and reason != .window_spawn and !isWindowMapped(wm.conn, win)) return;

    const input_model = utils.getInputModelCached(wm.conn, win);
    if (input_model == .no_input) return;

    const old = wm.focused_window;
    wm.focused_window = win;
    wm.suppress_focus_reason = suppressionFor(reason);
    wm.suppress_focus_count = 1; // handleMapRequest bumps to 2 when needed

    window.grabButtons(wm, win, true);
    if (old) |old_win| window.grabButtons(wm, old_win, false);

    // ICCCM §4.1.7 says xcb_set_input_focus must not be sent to globally_active
    // windows.  In practice, Electron/Chromium ignores WM_TAKE_FOCUS for
    // pointer-entry events and only accepts focus via XSetInputFocus anyway.
    // Sending it unconditionally is what i3, openbox, xfwm4, and kwin all do.
    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win,
        wm.last_event_time,
    );

    // Raise windows on click/command, AND for globally_active windows on hover.
    // Electron/Chromium only accept focus when topmost in the stacking order.
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
    // Do not flush here — the main event loop flushes after draining all pending
    // events.  This batches rapid hover crossings (e.g. fast mouse sweeps across
    // several windows) into a single write syscall rather than one per crossing.
    bar.markDirty();
}

pub fn clearFocus(wm: *WM) void {
    if (wm.focused_window) |old_win| {
        window.grabButtons(wm, old_win, false);
        tiling.updateWindowFocus(wm, old_win, null);
    }
    wm.focused_window = null;
    wm.suppress_focus_reason = .none;
    wm.suppress_focus_count = 1;
    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        wm.root,
        wm.last_event_time,
    );
    bar.markDirty();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

// Returns true only if the window is mapped and viewable. xcb_get_window_attributes
// failing (e.g. the window was destroyed) is treated as unmapped.
fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const cookie = xcb.xcb_get_window_attributes(conn, win);
    const reply = xcb.xcb_get_window_attributes_reply(conn, cookie, null);
    if (reply) |r| {
        defer std.c.free(r);
        return r.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
    }
    return false;
}
