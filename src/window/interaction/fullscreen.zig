//! Fullscreen management

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const batch = @import("batch");
const workspaces = @import("workspaces");
const bar = @import("bar");

inline fn getFullscreenRect(screen: *xcb.xcb_screen_t) utils.Rect {
    return .{ .x = 0, .y = 0, .width = screen.width_in_pixels, .height = screen.height_in_pixels };
}

pub fn toggleFullscreen(wm: *WM) void {
    const win = wm.focused_window orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (wm.fullscreen.getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            exitFullscreen(wm, win, current_ws);
        } else {
            // OPTIMIZATION: Batch the state transition
            exitFullscreen(wm, fs_info.window, current_ws);
            enterFullscreen(wm, win, current_ws);
        }
    } else {
        enterFullscreen(wm, win, current_ws);
    }
    
    utils.flush(wm.conn);
}

fn enterFullscreen(wm: *WM, win: u32, ws: usize) void {
    const geom = utils.getGeometry(wm.conn, win) orelse return;

    const fs_info = defs.FullscreenInfo{
        .window = win,
        .workspace = ws,
        .saved_geometry = .{
            .x = geom.x,
            .y = geom.y,
            .width = geom.width,
            .height = geom.height,
            .border_width = if (tiling.isWindowTiled(win)) wm.config.tiling.border_width else 0,
        },
    };
    
    wm.fullscreen.setForWorkspace(ws, fs_info) catch {
        std.log.err("[fullscreen] Failed to save fullscreen state for workspace {}", .{ws});
        return;
    };
    
    bar.setBarState(wm, .hide_fullscreen);

    // OPTIMIZATION: Use batch if possible, fall back to direct calls
    var b = batch.Batch.begin(wm) catch {
        applyFullscreenGeometry(wm, win);
        return;
    };
    defer b.deinit();

    const rect = getFullscreenRect(wm.screen);
    b.configure(win, rect) catch {};
    b.setBorderWidth(win, 0) catch {};
    b.raise(win) catch {};
    b.execute();
}

fn exitFullscreen(wm: *WM, win: u32, ws: usize) void {
    const fs_info = wm.fullscreen.getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;
    
    const saved_geom = fs_info.saved_geometry;
    wm.fullscreen.removeForWorkspace(ws);
    bar.setBarState(wm, .show_fullscreen);

    if (tiling.isWindowTiled(win)) {
        tiling.retileCurrentWorkspace(wm);
    } else {
        restoreWindowGeometry(wm.conn, win, saved_geom);
        utils.flush(wm.conn);
    }
}

// OPTIMIZATION: Extract geometry application into helper functions
inline fn applyFullscreenGeometry(wm: *WM, win: u32) void {
    const rect = getFullscreenRect(wm.screen);
    utils.configureWindow(wm.conn, win, rect);
    utils.setBorderWidth(wm.conn, win, 0);
    _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    utils.flush(wm.conn);
}

inline fn restoreWindowGeometry(conn: *xcb.xcb_connection_t, win: u32, saved_geom: anytype) void {
    const rect = utils.Rect{
        .x = saved_geom.x,
        .y = saved_geom.y,
        .width = saved_geom.width,
        .height = saved_geom.height,
    };
    utils.configureWindow(conn, win, rect);
    if (saved_geom.border_width > 0) {
        utils.setBorderWidth(conn, win, saved_geom.border_width);
    }
}
