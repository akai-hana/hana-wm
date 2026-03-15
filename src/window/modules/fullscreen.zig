//! Fullscreen management — enter, exit, toggle, and state queries.
//!
//! All fullscreen state lives in the module-level g_state singleton,
//! owned and freed here. WM no longer carries a fullscreen field.
//! Callers use the module-level query functions (isFullscreen,
//! getForWorkspace, etc.) rather than going through WM.
//!
//! The two commit helpers only queue XCB requests; the caller owns
//! grab/ungrab/flush so paired exit+enter transitions can share one
//! grab with no intermediate composited frame.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const focus    = @import("focus");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");
const minimize   = @import("minimize");

// Fullscreen types

pub const FullscreenInfo = struct {
    window:         defs.WindowId,
    saved_geometry: defs.WindowGeometry,
};

// Module state
//
// Two hash maps rather than a single one: keyed by workspace for O(1) lookup
// when switching workspaces, and keyed by window for O(1) isFullscreen checks.
// Both are always kept in sync — every write goes through setForWorkspace /
// removeForWorkspace which updates both atomically.

var g_per_workspace:       std.AutoHashMap(u8,  FullscreenInfo) = undefined;
var g_window_to_workspace: std.AutoHashMap(u32, u8)             = undefined;
var g_initialized: bool = false;

pub fn init(wm: *WM) void {
    g_per_workspace       = std.AutoHashMap(u8,  FullscreenInfo).init(wm.allocator);
    g_window_to_workspace = std.AutoHashMap(u32, u8).init(wm.allocator);
    g_per_workspace.ensureTotalCapacity(4)       catch {};
    g_window_to_workspace.ensureTotalCapacity(4) catch {};
    g_initialized = true;
}

pub fn deinit() void {
    if (!g_initialized) return;
    g_per_workspace.deinit();
    g_window_to_workspace.deinit();
    g_initialized = false;
}

// Public state queries

pub fn isFullscreen(win: u32) bool {
    if (!g_initialized) return false;
    return g_window_to_workspace.contains(win);
}

pub fn getForWorkspace(ws: u8) ?FullscreenInfo {
    if (!g_initialized) return null;
    return g_per_workspace.get(ws);
}

/// Returns the workspace index that `win` is fullscreen on, or null.
pub fn workspaceFor(win: u32) ?u8 {
    if (!g_initialized) return null;
    return g_window_to_workspace.get(win);
}

pub fn setForWorkspace(ws: u8, info: FullscreenInfo) !void {
    if (!g_initialized) return;
    try g_per_workspace.ensureUnusedCapacity(1);
    try g_window_to_workspace.ensureUnusedCapacity(1);
    g_per_workspace.putAssumeCapacity(ws, info);
    g_window_to_workspace.putAssumeCapacity(info.window, ws);
}

pub fn removeForWorkspace(ws: u8) void {
    if (!g_initialized) return;
    if (g_per_workspace.get(ws)) |info|
        _ = g_window_to_workspace.remove(info.window);
    _ = g_per_workspace.remove(ws);
}

pub fn clear() void {
    if (!g_initialized) return;
    g_per_workspace.clearRetainingCapacity();
    g_window_to_workspace.clearRetainingCapacity();
}

/// Iterator over per-workspace fullscreen entries. Diagnostics only.
pub fn perWorkspaceIterator() ?std.AutoHashMap(u8, FullscreenInfo).Iterator {
    if (!g_initialized) return null;
    return g_per_workspace.iterator();
}

// Geometry helpers

/// Retrieve the pre-fullscreen geometry for `win` before entering fullscreen.
///
/// Fast path — tiled windows: `configureSafe` stores the most recent tiled
/// rect in the geometry cache after every retile.  Reading from the cache
/// avoids a blocking xcb_get_geometry round-trip.
///
/// Slow path — floating or newly-spawned windows: these are not in the tiling
/// cache (they were never passed through `configureSafe`), so a blocking
/// xcb_get_geometry round-trip is unavoidable.  Falls back to a centred
/// quarter-screen default if the reply fails or the window is offscreen
/// (x/y below OFFSCREEN_THRESHOLD_MIN), which happens when a window was
/// spawned but never placed on-screen before the user triggered fullscreen.
fn fetchWindowGeom(wm: *WM, win: u32) defs.WindowGeometry {
    if (tiling.getWindowGeom(win)) |rect| {
        // Fast path: tiled windows have a cached rect from the last retile.
        const bw: u16 = if (tiling.getStateOpt()) |ts| ts.border_width else 0;
        return rectToGeom(rect, bw);
    }

    // Slow path: floating or newly-spawned windows are not in the tiling cache
    // (never passed through configureSafe), so a blocking round-trip is needed.
    // Falls back to a centred quarter-screen default if the reply fails or the
    // window is offscreen (x/y below OFFSCREEN_THRESHOLD_MIN), which happens
    // when a window was spawned but never placed on-screen before fullscreen.
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

/// Convert a tiling rect + border width to a WindowGeometry.
inline fn rectToGeom(rect: utils.Rect, border_width: u16) defs.WindowGeometry {
    return .{
        .x            = rect.x,
        .y            = rect.y,
        .width        = rect.width,
        .height       = rect.height,
        .border_width = border_width,
    };
}

// Commit helpers (XCB-only; caller owns grab/ungrab/flush) 

inline fn enterFullscreenCommit(wm: *WM, win: u32, ws: u8, geom: defs.WindowGeometry) void {
    setForWorkspace(ws, .{
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

inline fn exitFullscreenCommit(wm: *WM, win: u32, ws: u8) void {
    const fs_info = getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;

    removeForWorkspace(ws);

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
                if (minimize.isMinimized(other_win)) continue;
                _ = xcb.xcb_configure_window(wm.conn, other_win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }
    }

    _ = xcb.xcb_change_window_attributes(wm.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{
            if (focus.getFocused() == win) wm.config.tiling.border_focused
            else wm.config.tiling.border_unfocused,
        });
}

// Public actions 

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
    _ = xcb.xcb_flush(wm.conn);
}

pub fn toggleFullscreen(wm: *WM) void {
    const win        = focus.getFocused() orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            _ = xcb.xcb_grab_server(wm.conn);
            exitFullscreenCommit(wm, win, current_ws);
            // The retile's EnterNotify correctly updates hover focus — no suppression needed.
            _ = xcb.xcb_ungrab_server(wm.conn);
            _ = xcb.xcb_flush(wm.conn);
        } else {
            // Switching fullscreen from one window to another: share a single grab.
            const geom = fetchWindowGeom(wm, win);
            _ = xcb.xcb_grab_server(wm.conn);
            exitFullscreenCommit(wm, fs_info.window, current_ws);
            enterFullscreenCommit(wm, win, current_ws, geom);
            _ = xcb.xcb_ungrab_server(wm.conn);
            _ = xcb.xcb_flush(wm.conn);
        }
    } else {
        enterFullscreen(wm, win, null);
    }
}
