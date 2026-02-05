// Focus management - OPTIMIZED

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

var focus_protection_active: bool = false;

pub inline fn isProtected() bool {
    return focus_protection_active;
}

pub inline fn releaseProtection() void {
    focus_protection_active = false;
}

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    // OPTIMIZATION: Combined early return checks, removed duplicate root check
    if (win == wm.root or win == 0 or bar.isBarWindow(win) or wm.focused_window == win) return;

    // Block mouse_enter during protection period
    if (reason == .mouse_enter and focus_protection_active) return;

    // Set protection for explicit focus changes
    if (reason != .mouse_enter) {
        focus_protection_active = true;
    }

    const old = wm.focused_window;
    wm.focused_window = win;

    // OPTIMIZATION: Batch XCB calls when raising window
    if (reason == .mouse_click or reason == .user_command) {
        // Combine set_input_focus and raise in sequence without intermediate flush
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    }

    // OPTIMIZATION: Update borders first, flush once at the end
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

// OPTIMIZATION: Batch focus operation for multiple windows (e.g., during workspace switch)
pub fn setFocusBatch(wm: *WM, win: u32, reason: Reason, defer_flush: bool) void {
    if (win == wm.root or win == 0 or bar.isBarWindow(win) or wm.focused_window == win) return;

    if (reason == .mouse_enter and focus_protection_active) return;

    if (reason != .mouse_enter) {
        focus_protection_active = true;
    }

    const old = wm.focused_window;
    wm.focused_window = win;

    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    }

    tiling.updateWindowFocusFast(wm, old, win);
    
    // OPTIMIZATION: Allow caller to defer flush for batch operations
    if (!defer_flush) {
        utils.flush(wm.conn);
    }
    
    bar.markDirty();
}
