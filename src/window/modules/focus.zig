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

pub fn setFocus(wm: *WM, win: u32, reason: Reason) void {
    if (win == wm.root or win == 0 or bar.isBarWindow(win) or wm.focused_window == win) return;

    const old = wm.focused_window;
    wm.focused_window = win;

    // IMPROVED: Set suppression based on context, not arbitrary event counts
    // This allows precise control over when focus-follows-mouse is active
    switch (reason) {
        .mouse_enter, .mouse_click, .window_destroyed => {
            // User-initiated or expected focus changes - allow normal behavior
            wm.suppress_focus_reason = .none;
        },
        .tiling_operation => {
            // During tiling, prevent cursor from stealing focus from repositioned windows
            // BUT: Don't overwrite .window_spawn - that needs to persist
            if (wm.suppress_focus_reason != .window_spawn) {
                wm.suppress_focus_reason = .tiling_operation;
            }
        },
        .user_command, .workspace_switch => {
            // Keyboard commands - allow immediate focus changes
            wm.suppress_focus_reason = .none;
        },
    }

    // Ungrab buttons on newly focused window, regrab on old window
    window.grabButtons(wm, win, true);
    if (old) |old_win| {
        window.grabButtons(wm, old_win, false);
    }

    // Raise window for mouse clicks and user commands
    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    }
    
    // Send WM_TAKE_FOCUS protocol message for applications that need it
    if (utils.supportsWMTakeFocus(wm.conn, win)) {
        utils.sendWMTakeFocus(wm.conn, win);
    }

    // Update borders
    tiling.updateWindowFocusFast(wm, old, win);
    utils.flush(wm.conn);
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

// Batch focus operation for multiple windows (e.g., during workspace switch)
pub fn setFocusBatch(wm: *WM, win: u32, reason: Reason, defer_flush: bool) void {
    if (win == wm.root or win == 0 or bar.isBarWindow(win) or wm.focused_window == win) return;

    const old = wm.focused_window;
    wm.focused_window = win;

    // Set suppression based on context
    switch (reason) {
        .mouse_enter, .mouse_click, .window_destroyed => {
            wm.suppress_focus_reason = .none;
        },
        .tiling_operation => {
            // Don't overwrite .window_spawn - that needs to persist
            if (wm.suppress_focus_reason != .window_spawn) {
                wm.suppress_focus_reason = .tiling_operation;
            }
        },
        .user_command, .workspace_switch => {
            wm.suppress_focus_reason = .none;
        },
    }

    // Ungrab buttons on newly focused window, regrab on old window
    window.grabButtons(wm, win, true);
    if (old) |old_win| {
        window.grabButtons(wm, old_win, false);
    }

    if (reason == .mouse_click or reason == .user_command) {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
    }
    
    // Send WM_TAKE_FOCUS protocol message
    if (utils.supportsWMTakeFocus(wm.conn, win)) {
        utils.sendWMTakeFocus(wm.conn, win);
    }

    tiling.updateWindowFocusFast(wm, old, win);
    
    // Allow caller to defer flush for batch operations
    if (!defer_flush) {
        utils.flush(wm.conn);
    }
    
    bar.markDirty();
}
