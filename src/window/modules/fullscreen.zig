///! Fullscreen management

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const bar        = @import("bar");
const debug      = @import("debug");

inline fn borderColor(wm: *WM, win: u32) u32 {
    return if (wm.focused_window == win) wm.config.tiling.border_focused
           else                          wm.config.tiling.border_unfocused;
}

pub fn toggleFullscreen(wm: *WM) void {
    const win        = wm.focused_window orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (wm.fullscreen.getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            exitFullscreen(wm, win, current_ws);
        } else {
            exitFullscreen(wm, fs_info.window, current_ws);
            enterFullscreen(wm, win, current_ws);
        }
    } else {
        enterFullscreen(wm, win, current_ws);
    }

    utils.flush(wm.conn);
}

fn enterFullscreen(wm: *WM, win: u32, ws: u8) void {
    const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, xcb.xcb_get_geometry(wm.conn, win), null) orelse return;
    defer std.c.free(geom_reply);

    const is_offscreen = geom_reply.*.x < -1000 or geom_reply.*.x > 10000 or
                         geom_reply.*.y < -1000 or geom_reply.*.y > 10000;

    const fs_info = defs.FullscreenInfo{
        .window    = win,
        .workspace = ws,
        .saved_geometry = .{
            .x      = if (is_offscreen) @divTrunc(@as(i16, @intCast(wm.screen.width_in_pixels)),  4) else geom_reply.*.x,
            .y      = if (is_offscreen) @divTrunc(@as(i16, @intCast(wm.screen.height_in_pixels)), 4) else geom_reply.*.y,
            .width  = if (is_offscreen) @divTrunc(wm.screen.width_in_pixels,  2) else geom_reply.*.width,
            .height = if (is_offscreen) @divTrunc(wm.screen.height_in_pixels, 2) else geom_reply.*.height,
            .border_width = geom_reply.*.border_width,
        },
    };

    wm.fullscreen.setForWorkspace(ws, fs_info) catch {
        debug.err("Failed to save fullscreen state for workspace {}", .{ws});
        return;
    };

    bar.setBarState(wm, .hide_fullscreen);

    const values = [_]u32{
        0, 0,
        @intCast(wm.screen.width_in_pixels),
        @intCast(wm.screen.height_in_pixels),
        0,
    };
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    tiling.invalidateWindowGeometry(win);
}

fn exitFullscreen(wm: *WM, win: u32, ws: u8) void {
    const fs_info = wm.fullscreen.getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;
    wm.fullscreen.removeForWorkspace(ws);
    bar.setBarState(wm, .show_fullscreen);

    if (tiling.isWindowTiled(win)) {
        tiling.retileCurrentWorkspace(wm, true);
        tiling.invalidateWindowGeometry(win);
        // Retiling resets geometry but may not restore borders zeroed during fullscreen.
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{saved.border_width});
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(wm, win)});
    } else {
        const values = [_]u32{
            @bitCast(@as(i32, saved.x)),
            @bitCast(@as(i32, saved.y)),
            saved.width,
            saved.height,
            saved.border_width,
        };
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(wm, win)});
        tiling.invalidateWindowGeometry(win);
    }
}
