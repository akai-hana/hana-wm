//! Monocle layout - fullscreen stacked windows.
//!
//! All windows are sized to fill the entire screen and stacked on top of each
//! other. Only the most recently focused window (last in list) is visible.
//! Useful for maximizing screen real estate for focused work.

const std = @import("std");
const defs = @import("defs");
const log = @import("logging");
const xcb = defs.xcb;
const WM = defs.WM;
const types = @import("types");
const TilingState = types.TilingState;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    if (windows.len == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;

    log.debugLayoutTilingSimple("monocle", windows.len);

    // Calculate fullscreen size accounting for gaps and borders
    const w = if (screen_w > 2 * gap + 2 * bw)
        screen_w - 2 * gap - 2 * bw
    else
        1;
    const h = if (screen_h > 2 * gap + 2 * bw)
        screen_h - 2 * gap - 2 * bw
    else
        1;

    // Size all windows identically (they're stacked)
    for (windows) |win| {
        types.configureWindow(wm, win, gap, gap, w, h);
    }

    // Ensure last window (most recent) is on top
    _ = xcb.xcb_configure_window(wm.conn, windows[windows.len - 1], xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}
