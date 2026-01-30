//! Fullscreen management

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const batch = @import("batch");

pub fn toggleFullscreen(wm: *WM) void {
    const win = wm.focused_window orelse return;

    if (wm.fullscreen.window) |fs_win| {
        if (fs_win == win) {
            exitFullscreen(wm, win);
        } else {
            // Switch fullscreen to different window
            exitFullscreen(wm, fs_win);
            enterFullscreen(wm, win);
        }
    } else {
        enterFullscreen(wm, win);
    }
    
    // CRITICAL FIX: Re-grab keys after fullscreen transition to prevent keyboard lock
    // Fullscreen windows can steal keyboard input, so we need to re-establish our grabs
    utils.flush(wm.conn);
}

fn enterFullscreen(wm: *WM, win: u32) void {
    const geom = utils.getGeometry(wm.conn, win) orelse return;

    // Save current geometry for restoration
    wm.fullscreen.saved_geometry = .{
        .x = geom.x,
        .y = geom.y,
        .width = geom.width,
        .height = geom.height,
        .border_width = if (tiling.isWindowTiled(win)) wm.config.tiling.border_width else 0,
    };

    wm.fullscreen.window = win;

    var b = batch.Batch.begin(wm) catch {
        enterFullscreenDirect(wm, win);
        return;
    };
    defer b.deinit();

    const screen = wm.screen;
    const rect = utils.Rect{
        .x = 0,
        .y = 0,
        .width = screen.width_in_pixels,
        .height = screen.height_in_pixels,
    };

    b.configure(win, rect) catch {};
    b.setBorderWidth(win, 0) catch {};
    b.raise(win) catch {};
    b.execute();

    @import("bar").raiseBar();
}

fn enterFullscreenDirect(wm: *WM, win: u32) void {
    const screen = wm.screen;
    const rect = utils.Rect{
        .x = 0,
        .y = 0,
        .width = screen.width_in_pixels,
        .height = screen.height_in_pixels,
    };
    
    utils.configureWindow(wm.conn, win, rect);
    utils.setBorderWidth(wm.conn, win, 0);
    _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    utils.flush(wm.conn);
    
    @import("bar").raiseBar();
}

fn exitFullscreen(wm: *WM, win: u32) void {
    const saved_geom = wm.fullscreen.saved_geometry orelse return;

    wm.fullscreen = .{}; // Clear fullscreen state

    if (tiling.isWindowTiled(win)) {
        // Let tiling system handle geometry
        tiling.retileCurrentWorkspace(wm);
    } else {
        // Restore saved geometry for floating windows
        const rect = utils.Rect{
            .x = saved_geom.x,
            .y = saved_geom.y,
            .width = saved_geom.width,
            .height = saved_geom.height,
        };
        utils.configureWindow(wm.conn, win, rect);
        if (saved_geom.border_width > 0) {
            utils.setBorderWidth(wm.conn, win, saved_geom.border_width);
        }
        utils.flush(wm.conn);
    }
}
