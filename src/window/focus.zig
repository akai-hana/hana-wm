//! Centralized focus management for window manager.
//!
//! This module provides a single point of control for window focus changes,
//! ensuring consistent border updates and proper XCB focus commands.

const std = @import("std");
const builtin = @import("builtin");
const defs = @import("defs");
const tiling = @import("tiling");
const utils = @import("utils");
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

/// Set focus to a window with appropriate border updates
pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    // CRITICAL: Never focus the root window
    if (win == wm.root) {
        std.log.err("[CRITICAL] Attempted to focus ROOT window (0x{x})! Reason: {s}. Aborting.", .{ win, @tagName(reason) });
        if (builtin.mode == .Debug) {
            @panic("Root window focus attempted - this is a bug!");
        }
        return;
    }

    if (wm.focused_window == win) return;

    const old = wm.focused_window;
    wm.focused_window = win;

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);

    // Raise window on explicit user actions
    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    tiling.updateWindowFocus(wm, old, win);
    utils.flush(wm.conn);
}

/// Clear focus (no window focused)
pub fn clearFocus(wm: *WM) void {
    const old = wm.focused_window;
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);

    if (old) |old_win| {
        tiling.updateWindowFocus(wm, old_win, null);
    }
    utils.flush(wm.conn);
}
