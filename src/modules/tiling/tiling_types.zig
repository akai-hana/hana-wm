// Shared types and utilities for tiling system
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

/// Configure a window's position and size via XCB
/// Used by all layout algorithms
pub fn configureWindow(wm: *WM, window: u32, x: u16, y: u16, width: u16, height: u16) void {
    const values = [_]u32{
        x,
        y,
        @max(1, width),
        @max(1, height),
    };

    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}

/// Calculate window dimension accounting for gaps and borders
/// Returns 1 as minimum to avoid zero-sized windows
pub fn calcWindowDimension(total: u16, gaps: u16, border_width: u16) u16 {
    const padding = 2 * gaps + 2 * border_width;
    return if (total > padding) total - padding else 1;
}

/// Calculate available space after accounting for gap on one side and borders
pub fn calcAvailableSpace(total: u16, gap: u16, border_width: u16) u16 {
    return if (total > gap + 2 * border_width)
        total - gap - 2 * border_width
    else 1;
}
