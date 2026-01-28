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

    if (wm.fullscreen_window) |fs_win| {
        if (fs_win == win) {
            exitFullscreen(wm, win);
        } else {
            exitFullscreen(wm, fs_win);
            enterFullscreen(wm, win);
        }
    } else {
        enterFullscreen(wm, win);
    }
}

fn enterFullscreen(wm: *WM, win: u32) void {
    const geom = utils.getGeometry(wm.conn, win) orelse return;

    wm.fullscreen_geometry = .{
        .x = geom.x,
        .y = geom.y,
        .width = geom.width,
        .height = geom.height,
        .border_width = if (tiling.isWindowTiled(win)) wm.config.tiling.border_width else 0,
    };

    wm.fullscreen_window = win;

    var b = batch.Batch.begin(wm) catch return;
    defer b.deinit();

    const screen = wm.screen;
    const rect = utils.Rect{
        .x = 0,
        .y = 0,
        .width = screen.width_in_pixels,
        .height = screen.height_in_pixels,
    };

    b.configure(win, rect) catch {};
    b.setBorder(win, 0) catch {};
    b.raise(win) catch {};
    b.execute();

    @import("bar").raiseBar();
}

fn exitFullscreen(wm: *WM, win: u32) void {
    const saved_geom = wm.fullscreen_geometry orelse return;

    wm.fullscreen_window = null;
    wm.fullscreen_geometry = null;

    if (tiling.isWindowTiled(win)) {
        tiling.retileCurrentWorkspace(wm);
    } else {
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
