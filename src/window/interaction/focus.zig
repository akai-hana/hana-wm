//! Focus management

const std = @import("std");
const defs = @import("defs");
const tiling = @import("tiling");
const utils = @import("utils");
const bar = @import("bar");
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

// Simplified focus protection - no separate timestamp, just a counter
var focus_protection_active: bool = false;

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (win == wm.root) {
        std.log.err("[CRITICAL] Attempted to focus ROOT window!", .{});
        return;
    }

    if (bar.isBarWindow(win)) return;

    // Simplified grace period - just block mouse_enter briefly after explicit focus
    if (reason == .mouse_enter and focus_protection_active) return;

    if (wm.focused_window == win) return;

    // Set protection for explicit focus changes
    if (reason != .mouse_enter) {
        focus_protection_active = true;
    }

    const old = wm.focused_window;
    wm.focused_window = win;

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);

    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    tiling.updateWindowFocusFast(wm, old, win);
    utils.flush(wm.conn);

    bar.markDirty();
}

pub fn clearFocus(wm: *WM) void {
    const old = wm.focused_window;
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);

    if (old) |old_win| {
        tiling.updateWindowFocusFast(wm, old_win, null);
    }
    utils.flush(wm.conn);

    bar.markDirty();
}

// Called from main loop to release focus protection after events settle
pub fn releaseProtection() void {
    focus_protection_active = false;
}
