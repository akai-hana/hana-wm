//! Centralized focus management
const std = @import("std");
const builtin = @import("builtin");
const defs = @import("defs");
const tiling = @import("tiling");
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

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (wm.focused_window == win) return;

    const old = wm.focused_window;
    wm.focused_window = win;

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, 
        &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    tiling.updateWindowFocus(wm, win);

    if (builtin.mode == .Debug) {
        std.log.debug("[focus] {?} → 0x{x} ({s})", .{old, win, @tagName(reason)});
    }
}

pub fn clearFocus(wm: *WM) void {
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);
}
