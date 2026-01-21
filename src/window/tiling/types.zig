//! Shared types for the tiling window system.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;

pub const Layout = enum {
    master_left,
    monocle,
    grid,
};

pub const TilingState = struct {
    enabled: bool = true,
    layout: Layout = .master_left,
    master_width_factor: f32 = 0.50,
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2,
    border_normal: u32 = 0x383C4A,
    tiled_windows: std.ArrayList(u32),
    master_count: usize = 1,
};

const MIN_WINDOW_DIM: u16 = 50;

/// Apply geometry to a window via XCB
pub fn configureWindow(wm: *WM, window: u32, x: u16, y: u16, width: u16, height: u16) void {
    const safe_width = @max(MIN_WINDOW_DIM, width);
    const safe_height = @max(MIN_WINDOW_DIM, height);

    const values = [_]u32{ x, y, safe_width, safe_height };

    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}
