//! Centralized focus management for Hana window manager.
//!
//! Handles:
//! - Setting window focus with proper X11 calls
//! - Tracking focus changes with reasons for debugging
//! - Notifying tiling system of focus changes
//! - Preventing race conditions from multiple focus sources

const std = @import("std");
const builtin = @import("builtin");
const defs = @import("defs");
const tiling = @import("tiling");
const xcb = defs.xcb;
const WM = defs.WM;

/// Reasons why focus changed (for debugging)
pub const FocusReason = enum {
    mouse_click,
    mouse_enter,
    window_destroyed,
    workspace_switch,
    user_command,
    tiling_operation,
};

/// Set focus to a window using centralized logic
pub fn setFocus(wm: *WM, window: u32, reason: FocusReason) void {
    // Skip if already focused
    if (wm.focused_window == window) return;
    
    const old = wm.focused_window;
    wm.focused_window = window;
    
    // Set X11 focus
    _ = xcb.xcb_set_input_focus(wm.conn, 
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT, window, xcb.XCB_CURRENT_TIME);
    
    // Raise window
    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    
    // Notify tiling system to update borders
    tiling.updateWindowFocus(wm, window);
    
    if (builtin.mode == .Debug) {
        std.log.info("[focus] {?} → 0x{x} (reason: {s})", .{old, window, @tagName(reason)});
    }
}

/// Clear focus (set to root window)
pub fn clearFocus(wm: *WM) void {
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);
}
