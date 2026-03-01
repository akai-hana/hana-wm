//! Fullscreen management — enter, exit, and toggle fullscreen for the focused window.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");
const minimize   = @import("minimize");

// Fast path: tiled windows have a valid rect in the geometry cache; reading
// from it avoids the blocking xcb_get_geometry round-trip.
// Slow path (floating/cache miss): one blocking round-trip, falling back to
// a centered quarter-screen default if the reply fails or the window is offscreen.
fn fetchWindowGeom(wm: *WM, win: u32) defs.WindowGeometry {
    if (tiling.getCachedGeom(win)) |rect| {
        const bw: u16 = if (tiling.getState()) |ts| ts.border_width else 0;
        return .{
            .x            = rect.x,
            .y            = rect.y,
            .width        = rect.width,
            .height       = rect.height,
            .border_width = bw,
        };
    }

    const default: defs.WindowGeometry = .{
        .x            = @intCast(@divTrunc(@as(i32, wm.screen.width_in_pixels),  4)),
        .y            = @intCast(@divTrunc(@as(i32, wm.screen.height_in_pixels), 4)),
        .width        = @divTrunc(wm.screen.width_in_pixels,  2),
        .height       = @divTrunc(wm.screen.height_in_pixels, 2),
        .border_width = 0,
    };

    const reply = xcb.xcb_get_geometry_reply(
        wm.conn, xcb.xcb_get_geometry(wm.conn, win), null,
    ) orelse return default;
    defer std.c.free(reply);

    if (reply.*.x < constants.OFFSCREEN_THRESHOLD_MIN or
        reply.*.y < constants.OFFSCREEN_THRESHOLD_MIN) return default;
    return .{
        .x            = reply.*.x,
        .y            = reply.*.y,
        .width        = reply.*.width,
        .height       = reply.*.height,
        .border_width = reply.*.border_width,
    };
}

// Only queue XCB requests; the caller owns grab/ungrab/flush so that paired
// exit+enter transitions can share a single grab with no intermediate frame.

fn enterFullscreenCommit(wm: *WM, win: u32, ws: u8, geom: defs.WindowGeometry) void {
    wm.fullscreen.setForWorkspace(ws, .{
        .window         = win,
        .saved_geometry = geom,
    }) catch {
        debug.err("Failed to save fullscreen state for workspace {}", .{ws});
        return;
    };

    if (workspaces.getCurrentWorkspaceObject()) |ws_obj| {
        for (ws_obj.windows.items()) |other_win| {
            if (other_win == win) continue;
            _ = xcb.xcb_configure_window(wm.conn, other_win,
                xcb.XCB_CONFIG_WINDOW_X,
                &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            tiling.invalidateGeomCache(other_win);
        }
    }

    bar.setBarState(wm, .hide_fullscreen);

    utils.configureWindowGeom(wm.conn, win, .{
        .x            = 0,
        .y            = 0,
        .width        = @intCast(wm.screen.width_in_pixels),
        .height       = @intCast(wm.screen.height_in_pixels),
        .border_width = 0,
    });
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    // Evict the fullscreen window itself; its cache still holds the pre-fullscreen
    // tiled rect. On exit retile would compute the same rect, get a hit, and skip
    // configure_window, leaving the window stuck at fullscreen dimensions.
    tiling.invalidateGeomCache(win);
}

fn exitFullscreenCommit(wm: *WM, win: u32, ws: u8) void {
    const fs_info = wm.fullscreen.getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;

    wm.fullscreen.removeForWorkspace(ws);

    bar.setBarState(wm, .show_fullscreen);

    if (tiling.isWindowTiled(win)) {
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{saved.border_width});
    } else {
        utils.configureWindowGeom(wm.conn, win, saved);

        if (workspaces.getCurrentWorkspaceObject()) |ws_obj| {
            const pos = utils.floatDefaultPos(wm);
            for (ws_obj.windows.items()) |other_win| {
                if (other_win == win) continue;
                if (minimize.isMinimized(wm, other_win)) continue;
                _ = xcb.xcb_configure_window(wm.conn, other_win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }
    }

    _ = xcb.xcb_change_window_attributes(wm.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{
            if (wm.focused_window == win) wm.config.tiling.border_focused
            else wm.config.tiling.border_unfocused,
        });
}

/// Enter fullscreen for `win` on the current workspace.
/// Pass a pre-computed geometry in `saved_geom` (e.g. when restoring a
/// minimized fullscreen window); pass null to fetch it from the tiling cache
/// or a live round-trip (the common path for new fullscreen requests).
pub fn enterFullscreen(wm: *WM, win: u32, saved_geom: ?defs.WindowGeometry) void {
    const ws   = workspaces.getCurrentWorkspace() orelse return;
    const geom = saved_geom orelse fetchWindowGeom(wm, win);
    _ = xcb.xcb_grab_server(wm.conn);
    enterFullscreenCommit(wm, win, ws, geom);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

pub fn toggleFullscreen(wm: *WM) void {
    const win        = wm.focused_window orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (wm.fullscreen.getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            _ = xcb.xcb_grab_server(wm.conn);
            exitFullscreenCommit(wm, win, current_ws);
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
        } else {
            // Switching fullscreen from one window to another: share a single grab.
            const geom = fetchWindowGeom(wm, win);
            _ = xcb.xcb_grab_server(wm.conn);
            exitFullscreenCommit(wm, fs_info.window, current_ws);
            enterFullscreenCommit(wm, win, current_ws, geom);
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
        }
    } else {
        enterFullscreen(wm, win, null);
    }
}
