//! Monocle layout: fullscreen stacked windows.

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const xcb = defs.xcb;
const WM = defs.WM;

// Import the State type from tiling module
const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(wm: *WM, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    if (windows.len == 0) return;

    const inner = state.margins().innerRect(screen_w, screen_h);
    
    for (windows) |win| {
        utils.configureWindow(wm.conn, win, inner);
    }

    // Bring most recent window to top
    _ = xcb.xcb_configure_window(wm.conn, windows[windows.len - 1], 
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}
