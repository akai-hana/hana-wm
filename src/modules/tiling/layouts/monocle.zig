// Monocle layout - all windows fullscreen, stacked
// Only the top window is visible
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const xcb = defs.xcb;
const WM = defs.WM;
const tiling_types = @import("tiling_types");
const TilingState = tiling_types.TilingState;

pub fn tile(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const bw = state.border_width;

    if (builtin.mode == .Debug) {
        std.debug.print("[monocle] Tiling {} windows fullscreen\n", .{windows.len});
    }

    const w = tiling_types.calcWindowDimension(screen_w, gap, bw);
    const h = tiling_types.calcWindowDimension(screen_h, gap, bw);

    // All windows fullscreen, stacked
    for (windows) |win| {
        tiling_types.configureWindow(wm, win, gap, gap, w, h);
    }

    // Raise last window to top
    if (windows.len > 0) {
        _ = xcb.xcb_configure_window(wm.conn, windows[windows.len - 1],
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}
