//! Shared types and utilities for the tiling window system.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;

/// Available tiling layout algorithms
pub const Layout = enum {
    master_left,  // Master windows on left, stack on right
    monocle,      // All windows fullscreen, stacked
    grid,         // Windows in a grid pattern
};

/// Tiling system state
pub const TilingState = struct {
    /// Whether tiling is currently enabled
    enabled: bool = true,

    /// Current active layout
    layout: Layout = .master_left,

    /// Percentage of screen width for master area (0.05 - 0.95)
    master_width_factor: f32 = 0.50,

    /// Gap between windows and screen edges (in pixels)
    gaps: u16 = 10,

    /// Border width for tiled windows (in pixels)
    border_width: u16 = 2,

    /// Border color for focused window (RGB hex)
    border_focused: u32 = 0x5294E2,

    /// Border color for unfocused windows (RGB hex)
    border_normal: u32 = 0x383C4A,

    /// List of currently tiled window IDs (front = most recent)
    tiled_windows: std.ArrayList(u32),

    /// Number of windows to keep in master area
    master_count: usize = 1,
};

/// Minimum window dimensions to keep windows visible
const MIN_WINDOW_DIM: u16 = 50;

/// Configure a window's position and size via XCB.
/// Used by all layout algorithms to apply calculated geometry.
pub fn configureWindow(wm: *WM, window: u32, x: u16, y: u16, width: u16, height: u16) void {
    // Ensure windows are never too small to be usable
    const safe_width = @max(MIN_WINDOW_DIM, width);
    const safe_height = @max(MIN_WINDOW_DIM, height);

    const values = [_]u32{
        x,
        y,
        safe_width,
        safe_height,
    };

    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}
