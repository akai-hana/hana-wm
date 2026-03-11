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
// Defined here (not in defs.zig) so fullscreen.zig is the single owner.
// defs.zig used to declare these; remaining references should use fullscreen.X.

pub const FullscreenInfo = struct {
    window:         defs.WindowId,
    saved_geometry: defs.WindowGeometry,
};

pub const FullscreenState = struct {
    per_workspace:       std.AutoHashMap(u8, FullscreenInfo),
    window_to_workspace: std.AutoHashMap(u32, u8),

    pub fn init(allocator: std.mem.Allocator) FullscreenState {
        var per_ws    = std.AutoHashMap(u8, FullscreenInfo).init(allocator);
        var win_to_ws = std.AutoHashMap(u32, u8).init(allocator);
        per_ws.ensureTotalCapacity(4)    catch {};
        win_to_ws.ensureTotalCapacity(4) catch {};
        return .{ .per_workspace = per_ws, .window_to_workspace = win_to_ws };
    }

    pub fn deinit(self: *FullscreenState) void {
        self.per_workspace.deinit();
        self.window_to_workspace.deinit();
    }

    pub inline fn isFullscreen(self: *const FullscreenState, win: u32) bool {
        return self.window_to_workspace.contains(win);
    }

    pub inline fn getForWorkspace(self: *const FullscreenState, ws: u8) ?FullscreenInfo {
        return self.per_workspace.get(ws);
    }

    pub fn setForWorkspace(self: *FullscreenState, ws: u8, info: FullscreenInfo) !void {
        try self.per_workspace.ensureUnusedCapacity(1);
        try self.window_to_workspace.ensureUnusedCapacity(1);
        self.per_workspace.putAssumeCapacity(ws, info);
        self.window_to_workspace.putAssumeCapacity(info.window, ws);
    }

    pub fn removeForWorkspace(self: *FullscreenState, ws: u8) void {
        if (self.per_workspace.get(ws)) |info|
            _ = self.window_to_workspace.remove(info.window);
        _ = self.per_workspace.remove(ws);
    }

    pub inline fn clear(self: *FullscreenState) void {
        self.per_workspace.clearRetainingCapacity();
        self.window_to_workspace.clearRetainingCapacity();
    }
};


// Module state 

var g_state: ?FullscreenState = null;

pub fn init(wm: *WM) void {
    g_state = FullscreenState.init(wm.allocator);
}

pub fn deinit() void {
    if (g_state) |*s| s.deinit();
    g_state = null;
}

// Public state queries 

pub inline fn isFullscreen(win: u32) bool {
    const s = g_state orelse return false;
    return s.isFullscreen(win);
}

pub inline fn getForWorkspace(ws: u8) ?FullscreenInfo {
    const s = g_state orelse return null;
    return s.getForWorkspace(ws);
}

/// Returns the workspace index that `win` is fullscreen on, or null.
/// Used instead of direct window_to_workspace.get() access.
pub inline fn workspaceFor(win: u32) ?u8 {
    const s = g_state orelse return null;
    return s.window_to_workspace.get(win);
}

pub fn setForWorkspace(ws: u8, info: FullscreenInfo) !void {
    const s = &(g_state orelse return);
    try s.setForWorkspace(ws, info);
}

pub fn removeForWorkspace(ws: u8) void {
    const s = &(g_state orelse return);
    s.removeForWorkspace(ws);
}

pub fn clear() void {
    const s = &(g_state orelse return);
    s.clear();
}

/// Iterator over per-workspace fullscreen entries. Diagnostics only.
pub fn perWorkspaceIterator() ?std.AutoHashMap(u8, FullscreenInfo).Iterator {
    const s = &(g_state orelse return null);
    return s.per_workspace.iterator();
}

// Geometry helpers 

// Fast path: tiled windows have a valid rect in the geometry cache; reading
// from it avoids the blocking xcb_get_geometry round-trip.
// Slow path (floating/cache miss): one blocking round-trip, falling back to
// a centered quarter-screen default if the reply fails or the window is offscreen.
fn fetchWindowGeom(wm: *WM, win: u32) defs.WindowGeometry {
    if (tiling.getWindowGeom(win)) |rect| {
        const bw: u16 = if (tiling.getStateOpt()) |ts| ts.border_width else 0;
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

// Commit helpers (XCB-only; caller owns grab/ungrab/flush) 

fn enterFullscreenCommit(wm: *WM, win: u32, ws: u8, geom: defs.WindowGeometry) void {
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

fn exitFullscreenCommit(wm: *WM, win: u32, ws: u8) void {
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
                if (minimize.isMinimized(wm, other_win)) continue;
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
            // Suppress hover-focus theft: retiling moves windows under the
            // cursor, generating EnterNotify events that would otherwise
            // steal focus away from the window we just un-fullscreened.
            // tiling_operation suppression is cleared by the first real
            // mouse movement in input.handleMotionNotify.
            focus.setSuppressReason(.tiling_operation);
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


