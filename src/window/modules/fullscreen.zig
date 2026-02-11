///! Fullscreen management - MEMORY OPTIMIZED
/// OPTIMIZED: Direct XCB calls - no batch overhead

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
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
            // Transition: exit old fullscreen, enter new
            exitFullscreen(wm, fs_info.window, current_ws);
            enterFullscreen(wm, win, current_ws);
        }
    } else {
        enterFullscreen(wm, win, current_ws);
    }
    
    utils.flush(wm.conn);
}

fn enterFullscreen(wm: *WM, win: u32, ws: u8) void {
    const geom = utils.getGeometry(wm.conn, win) orelse return;

    // CRITICAL FIX: Don't save off-screen positions (from hidden windows)
    // If window is off-screen, use a sensible default geometry for when we exit fullscreen
    const is_offscreen = geom.x < -1000 or geom.x > 10000 or geom.y < -1000 or geom.y > 10000;

    // BUGFIX: Query the actual border width directly from the window using XCB
    // Previously only saved border_width for tiled windows, causing floating windows to lose borders
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, win);
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null);
    const border_width: u16 = if (geom_reply) |reply| blk: {
        defer std.c.free(reply);
        break :blk reply.*.border_width;
    } else 0;
    
    // Use default centered geometry if window is off-screen
    const saved_x: i16 = if (is_offscreen) @divTrunc(@as(i16, @intCast(wm.screen.width_in_pixels)), 4) else geom.x;
    const saved_y: i16 = if (is_offscreen) @divTrunc(@as(i16, @intCast(wm.screen.height_in_pixels)), 4) else geom.y;
    const saved_width: u16 = if (is_offscreen) @divTrunc(wm.screen.width_in_pixels, 2) else geom.width;
    const saved_height: u16 = if (is_offscreen) @divTrunc(wm.screen.height_in_pixels, 2) else geom.height;
    
    const fs_info = defs.FullscreenInfo{
        .window = win,
        .workspace = ws,
        .saved_geometry = .{
            .x = saved_x,
            .y = saved_y,
            .width = saved_width,
            .height = saved_height,
            .border_width = border_width,
        },
    };
    
    wm.fullscreen.setForWorkspace(ws, fs_info) catch {
        debug.err("Failed to save fullscreen state for workspace {}", .{ws});
        return;
    };
    
    bar.setBarState(wm, .hide_fullscreen);

    // Direct XCB calls - no batch overhead
    const rect = getFullscreenRect(wm.screen);
    const values = [_]u32{
        0, // x
        0, // y
        rect.width,
        rect.height,
        0, // border_width
    };
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
    _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    
    // OPTIMIZATION: Invalidate cached geometry after fullscreen
    tiling.invalidateWindowGeometry(win);
}

fn exitFullscreen(wm: *WM, win: u32, ws: u8) void {
    const fs_info = wm.fullscreen.getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;
    
    const saved_geom = fs_info.saved_geometry;
    wm.fullscreen.removeForWorkspace(ws);
    bar.setBarState(wm, .show_fullscreen);

    if (tiling.isWindowTiled(win)) {
        tiling.retileCurrentWorkspace(wm, true);
        // OPTIMIZATION: Invalidate cached geometry after retile
        tiling.invalidateWindowGeometry(win);
        
        // CRITICAL FIX: Ensure border is restored after retile
        // Retiling might not restore borders if they were set to 0 during fullscreen
        if (saved_geom.border_width > 0) {
            _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, 
                &[_]u32{saved_geom.border_width});
            const border_color = if (wm.focused_window == win) 
                wm.config.tiling.border_focused 
            else 
                wm.config.tiling.border_unfocused;
            _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{border_color});
        }
    } else {
        // Direct XCB calls to restore window geometry
        const rect = utils.Rect{
            .x = saved_geom.x,
            .y = saved_geom.y,
            .width = saved_geom.width,
            .height = saved_geom.height,
        };
        
        var values: [5]u32 = undefined;
        values[0] = @bitCast(@as(i32, rect.x));
        values[1] = @bitCast(@as(i32, rect.y));
        values[2] = rect.width;
        values[3] = rect.height;
        values[4] = saved_geom.border_width;
        
        // BUGFIX: Always restore border_width, even if it's 0
        // The previous conditional restoration caused border loss for floating windows
        const mask: u16 = xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
        
        _ = xcb.xcb_configure_window(wm.conn, win, mask, &values);
        
        // CRITICAL FIX: Restore border color after setting border width
        // Without this, the border is invisible even though width is restored
        const border_color = if (wm.focused_window == win) 
            wm.config.tiling.border_focused 
        else 
            wm.config.tiling.border_unfocused;
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{border_color});
        
        // OPTIMIZATION: Invalidate cached geometry after restoration
        tiling.invalidateWindowGeometry(win);
    }
}
