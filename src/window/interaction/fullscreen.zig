//! Fullscreen management

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const batch = @import("batch");
const workspaces = @import("workspaces");

pub fn toggleFullscreen(wm: *WM) void {
    const win = wm.focused_window orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    // Check if this workspace already has a fullscreen window
    if (wm.fullscreen.getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            // Toggle off fullscreen for current window
            exitFullscreen(wm, win, current_ws);
        } else {
            // Switch fullscreen to different window on same workspace
            exitFullscreen(wm, fs_info.window, current_ws);
            enterFullscreen(wm, win, current_ws);
        }
    } else {
        // No fullscreen window on this workspace, enter fullscreen
        enterFullscreen(wm, win, current_ws);
    }
    
    utils.flush(wm.conn);
}

fn enterFullscreen(wm: *WM, win: u32, ws: usize) void {
    const geom = utils.getGeometry(wm.conn, win) orelse return;

    // Save fullscreen info for this workspace
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
    
    // Hide bar for fullscreen
    @import("bar").hideForFullscreen(wm);

    var b = batch.Batch.begin(wm) catch {
        // Fallback to direct XCB calls if batch allocation fails
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
}

fn exitFullscreen(wm: *WM, win: u32, ws: usize) void {
    // Get the fullscreen info for this workspace
    const fs_info = wm.fullscreen.getForWorkspace(ws) orelse return;
    
    // Make sure we're exiting the right window
    if (fs_info.window != win) return;
    
    const saved_geom = fs_info.saved_geometry;

    // Remove fullscreen state for this workspace
    wm.fullscreen.removeForWorkspace(ws);
    
    // Show bar again (if enabled in config)
    @import("bar").showForFullscreen(wm);

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
