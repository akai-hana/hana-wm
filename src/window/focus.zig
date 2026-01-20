//! Centralized focus management with protection against focus stealing during layout
const std = @import("std");
const defs = @import("defs");
const tiling = @import("tiling");
const log = @import("logging");
const xcb = defs.xcb;
const WM = defs.WM;

pub const Reason = enum {
    mouse_click,
    mouse_enter,
    window_destroyed,
    workspace_switch,
    user_command,
    tiling_operation,
};

const FOCUS_PROTECTION_GRACE_NS: u64 = 50 * std.time.ns_per_ms;

var layout_timer: ?std.time.Timer = null;

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (wm.focused_window == win) return;

    const old = wm.focused_window;
    wm.focused_window = win;

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);

    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    tiling.updateWindowFocus(wm, old, win);

    log.focusChanged(old, win, @tagName(reason));
}

pub fn clearFocus(wm: *WM) void {
    const old = wm.focused_window;
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);

    if (old) |old_win| {
        tiling.updateWindowFocus(wm, old_win, null);
    }
}

pub fn shouldSuppressMouseFocus() bool {
    if (layout_timer) |*timer| {
        const elapsed = timer.read();
        if (elapsed < FOCUS_PROTECTION_GRACE_NS) {
            log.focusSuppressed(elapsed / std.time.ns_per_ms);
            return true;
        }
        layout_timer = null;
    }
    return false;
}

pub fn markLayoutOperation() void {
    layout_timer = std.time.Timer.start() catch {
        layout_timer = null;
        return;
    };

    log.focusLayoutMarked();
}
