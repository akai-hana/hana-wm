///! Fullscreen management - OPTIMIZED

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const batch = @import("batch");
const workspaces = @import("workspaces");
const bar = @import("bar");
const debug = @import("debug");

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
        debug.err("Failed to save fullscreen state for workspace {}", .{ws});
        return;
    };
    
    bar.setBarState(wm, .hide_fullscreen);

    // OPTIMIZATION: Always use batch for consistency
    var b = batch.Batch.begin(wm) catch {
        applyFullscreenGeometryDirect(wm, win);
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
        // OPTIMIZATION: Use batch for restore as well
        var b = batch.Batch.begin(wm) catch {
            restoreWindowGeometryDirect(wm.conn, win, saved_geom);
            return;
        };
        defer b.deinit();
        
        const rect = utils.Rect{
            .x = saved_geom.x,
            .y = saved_geom.y,
            .width = saved_geom.width,
            .height = saved_geom.height,
        };
        b.configure(win, rect) catch {};
        if (saved_geom.border_width > 0) {
            b.setBorderWidth(win, saved_geom.border_width) catch {};
        }
        b.execute();
    }
}

// OPTIMIZATION: Direct fallback when batch unavailable
inline fn applyFullscreenGeometryDirect(wm: *WM, win: u32) void {
    const rect = getFullscreenRect(wm.screen);
    const r = rect.clamp();
    const values = [_]u32{
        @bitCast(@as(i32, r.x)),
        @bitCast(@as(i32, r.y)),
        r.width,
        r.height,
        0, // border_width
    };
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
    _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    utils.flush(wm.conn);
}

inline fn restoreWindowGeometryDirect(conn: *xcb.xcb_connection_t, win: u32, saved_geom: anytype) void {
    const rect = utils.Rect{
        .x = saved_geom.x,
        .y = saved_geom.y,
        .width = saved_geom.width,
        .height = saved_geom.height,
    };
    const r = rect.clamp();
    var values: [5]u32 = undefined;
    var mask: u16 = xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
    var count: usize = 4;
    
    values[0] = @bitCast(@as(i32, r.x));
    values[1] = @bitCast(@as(i32, r.y));
    values[2] = r.width;
    values[3] = r.height;
    
    if (saved_geom.border_width > 0) {
        values[4] = saved_geom.border_width;
        mask |= xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
        count = 5;
    }
    
    _ = xcb.xcb_configure_window(conn, win, mask, values[0..count]);
    utils.flush(conn);
}
