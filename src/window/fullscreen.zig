//! Fullscreen window management
//!
//! Provides fullscreen functionality by:
//! - Saving the window's original geometry
//! - Expanding window to screen dimensions
//! - Removing borders
//! - Restoring geometry and borders when exiting fullscreen

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");

pub fn toggleFullscreen(wm: *WM) void {
    const win = wm.focused_window orelse return;

    if (wm.fullscreen_window == win) {
        exitFullscreen(wm);
    } else {
        if (wm.fullscreen_window != null) {
            exitFullscreen(wm);
        }
        enterFullscreen(wm, win);
    }
}

/// Exit fullscreen for a specific window if it's currently fullscreen
pub fn exitFullscreenForWindow(wm: *WM, win: u32) void {
    if (wm.fullscreen_window) |fs_win| {
        if (fs_win == win) {
            exitFullscreen(wm);
        }
    }
}

fn enterFullscreen(wm: *WM, win: u32) void {
    const cookie = xcb.xcb_get_geometry(wm.conn, win);
    const geom = xcb.xcb_get_geometry_reply(wm.conn, cookie, null) orelse {
        std.log.err("[fullscreen] Failed to get window geometry", .{});
        return;
    };
    defer std.c.free(geom);

    // Save current geometry for restoration
    wm.fullscreen_geometry = .{
        .x = geom.*.x,
        .y = geom.*.y,
        .width = geom.*.width,
        .height = geom.*.height,
        .border_width = geom.*.border_width,
    };

    const screen = wm.screen;
    const attrs = utils.WindowAttrs{
        .x = 0,
        .y = 0,
        .width = screen.width_in_pixels,
        .height = screen.height_in_pixels,
        .border_width = 0,
        .stack_mode = xcb.XCB_STACK_MODE_ABOVE,
    };
    attrs.configure(wm.conn, win);

    wm.fullscreen_window = win;
    utils.flush(wm.conn);

    // Retile other windows to update their layout
    if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
}

fn exitFullscreen(wm: *WM) void {
    const win = wm.fullscreen_window orelse return;
    const saved = wm.fullscreen_geometry orelse {
        std.log.warn("[fullscreen] No saved geometry for window", .{});
        wm.fullscreen_window = null;
        return;
    };

    const attrs = utils.WindowAttrs{
        .x = saved.x,
        .y = saved.y,
        .width = saved.width,
        .height = saved.height,
        .border_width = saved.border_width,
    };
    attrs.configure(wm.conn, win);

    // Restore border color if window is focused and tiled
    if (wm.focused_window == win and tiling.isWindowTiled(win)) {
        if (tiling.getState()) |t_state| {
            _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL,
                &[_]u32{t_state.border_focused});
        }
    }

    wm.fullscreen_window = null;
    wm.fullscreen_geometry = null;
    utils.flush(wm.conn);

    // Retile to restore proper layout
    if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
}
