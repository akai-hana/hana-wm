//! Focus management — set, clear, and reason-aware focus routing.

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

    // Skip the blocking xcb_get_window_attributes round-trip when we can
    // guarantee the window is mapped without asking the server:
    //
    //  mouse_enter / mouse_leave — only delivered for mapped windows.
    //  window_spawn              — map was queued on this connection moments ago.
    //  tiling_operation          — window is in the tiling tracking set, which is
    //                              populated at map time and kept coherent by
    //                              removeWindow on unmap/destroy.
    //
    // For all other reasons (click, command, destroyed, workspace_switch) a race
    // with destroy is possible, so we guard with a live attribute query.
    const input_model = utils.getInputModelCached(wm.conn, win);
    if (input_model == .no_input) return;

    if (switch (reason) {
        .mouse_click, .window_destroyed, .workspace_switch, .user_command => !isWindowMapped(wm.conn, win),
        .mouse_enter, .window_spawn, .tiling_operation => false,
    }) return;

    const old = wm.focused_window;
    wm.focused_window = win;
    wm.suppress_focus_reason = suppressionFor(reason);

    window.grabButtons(wm, win, true);
    if (old) |old_win| window.grabButtons(wm, old_win, false);

    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win,
        wm.last_event_time,
    );

    // Raise on click/command, and also on hover for globally_active windows
    // (they never receive xcb_set_input_focus, so raising is the only signal).
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

    // Compliant locally_active clients respond to xcb_set_input_focus directly
    // and need no raise. Non-compliant ones (e.g. Electron, which mis-declares
    // its input model) silently ignore the request unless they are already
    // topmost. Passive clients (Java/AWT, some Electron builds that omit
    // WM_TAKE_FOCUS) have the same problem — xcb_set_input_focus is silently
    // dropped when the window is not topmost.
    //
    // Confirm via xcb_get_input_focus: if focus didn't land, raise and retry.
    // The blocking reply also acts as a flush barrier, ensuring the original
    // xcb_set_input_focus request has been processed before we check.
    //
    // This avoids unconditionally raising all passive/locally_active windows on
    // hover while still self-correcting for any non-compliant client regardless
    // of toolkit, class name, or property advertisement.
    //
    // For locally_active windows (e.g. Qt), WM_TAKE_FOCUS is the real focus
    // activation trigger.  The client processes it asynchronously — potentially
    // after our confirm check has already passed — and may redirect input focus
    // to a child widget.  Re-sending WM_TAKE_FOCUS after the raise ensures the
    // client processes it in the correct stacking context.
    if (reason == .mouse_enter and
        (input_model == .locally_active or input_model == .passive))
    {
        const confirm_cookie = xcb.xcb_get_input_focus(wm.conn);
        const confirm = xcb.xcb_get_input_focus_reply(wm.conn, confirm_cookie, null);
        if (confirm) |c| {
            defer std.c.free(c);
            if (c.*.focus != win) {
                _ = xcb.xcb_configure_window(
                    wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_STACK_MODE,
                    &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
                );
                _ = xcb.xcb_set_input_focus(
                    wm.conn,
                    xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
                    win,
                    wm.last_event_time,
                );
                // Re-send WM_TAKE_FOCUS after the raise so locally_active
                // clients (e.g. Qt) process it in the correct stacking context.
                // Not sent for passive windows — they have no WM_TAKE_FOCUS
                // handler and xcb_set_input_focus alone is the correct protocol.
                if (input_model == .locally_active) {
                    utils.sendWMTakeFocus(wm.conn, win, wm.last_event_time);
                }
            }
        }
    }

    tiling.updateWindowFocus(wm, old, win);
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

inline fn shouldRaise(reason: Reason) bool {
    return switch (reason) {
        .mouse_click, .user_command => true,
        .mouse_enter, .window_destroyed, .workspace_switch,
        .tiling_operation, .window_spawn => false,
    };
}

inline fn suppressionFor(reason: Reason) defs.FocusSuppressReason {
    return switch (reason) {
        .mouse_click, .mouse_enter, .window_destroyed,
        .user_command, .workspace_switch => .none,
        .tiling_operation => .tiling_operation,
        .window_spawn     => .window_spawn,
    };
}

fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn, xcb.xcb_get_window_attributes(conn, win), null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}
