// Focus management - IMPROVED: No event counters, intelligent filtering

const std = @import("std");
const defs = @import("defs");
const tiling = @import("tiling");
const utils = @import("utils");
const bar = @import("bar");
const window = @import("window");
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

// OPTIMIZATION: Single unified focus function with optional flush control
pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    setFocusImpl(wm, win, reason, true);
}

pub fn setFocusBatch(wm: *WM, win: u32, reason: Reason, defer_flush: bool) void {
    setFocusImpl(wm, win, reason, !defer_flush);
}

fn setFocusImpl(wm: *WM, win: u32, reason: Reason, do_flush: bool) void {
    if (win == wm.root or win == 0 or bar.isBarWindow(win) or wm.focused_window == win) return;

    const old = wm.focused_window;
    wm.focused_window = win;

    // Set suppression based on context
    wm.suppress_focus_reason = switch (reason) {
        .mouse_enter, .mouse_click, .window_destroyed, .user_command, .workspace_switch => .none,
        .tiling_operation => if (wm.suppress_focus_reason == .window_spawn) .window_spawn else .tiling_operation,
    };

    // Ungrab buttons on newly focused window, regrab on old window
    window.grabButtons(wm, win, true);
    if (old) |old_win| window.grabButtons(wm, old_win, false);

    // Set input focus
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    
    // Raise window only for mouse clicks and user commands
    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
    
    // Send WM_TAKE_FOCUS protocol message for applications that need it
    // FIXED 2.1: Use cached version to avoid ~50µs roundtrip
    if (utils.supportsWMTakeFocusCached(wm.conn, win)) {
        utils.sendWMTakeFocus(wm.conn, win);
    }

    // Update borders
    tiling.updateWindowFocusFast(wm, old, win);
    
    if (do_flush) utils.flush(wm.conn);
    bar.markDirty();
}

pub fn clearFocus(wm: *WM) void {
    const old = wm.focused_window;
    wm.focused_window = null;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);

    if (old) |old_win| {
        window.grabButtons(wm, old_win, false);
        tiling.updateWindowFocusFast(wm, old_win, null);
    }
    
    utils.flush(wm.conn);
    bar.markDirty();
}
