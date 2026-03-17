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
const core = @import("core");
const xcb        = core.xcb;
const utils      = @import("utils");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const workspaces = @import("workspaces");
const focus    = @import("focus");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");
const minimize   = @import("minimize");

// Fullscreen types

pub const FullscreenInfo = struct {
    window:         core.WindowId,
    saved_geometry: core.WindowGeometry,
};

// Module state
//
// Two hash maps rather than a single one: keyed by workspace for O(1) lookup
// when switching workspaces, and keyed by window for O(1) isFullscreen checks.
// Both are always kept in sync — every write goes through setForWorkspace /
// removeForWorkspace which updates both atomically.

var g_per_workspace:       std.AutoHashMap(u8,  FullscreenInfo) = undefined;
var g_window_to_workspace: std.AutoHashMap(u32, u8)             = undefined;
/// Floating window positions saved just before a fullscreen enter. Populated
/// by saveFloatingWindowGeoms, consumed and cleared by restoreFloatingWindows.
var g_saved_float_geoms:   std.AutoHashMap(u32, utils.Rect)     = undefined;
var g_initialized: bool = false;

pub fn init() void {
    g_per_workspace       = std.AutoHashMap(u8,  FullscreenInfo).init(core.alloc);
    g_window_to_workspace = std.AutoHashMap(u32, u8).init(core.alloc);
    g_saved_float_geoms   = std.AutoHashMap(u32, utils.Rect).init(core.alloc);
    g_per_workspace.ensureTotalCapacity(4)       catch {};
    g_window_to_workspace.ensureTotalCapacity(4) catch {};
    g_saved_float_geoms.ensureTotalCapacity(8)   catch {};
    g_initialized = true;
}

pub fn deinit() void {
    if (!g_initialized) return;
    g_per_workspace.deinit();
    g_window_to_workspace.deinit();
    g_saved_float_geoms.deinit();
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
    // fetchRemove combines the get + remove into a single hash probe instead of two.
    if (g_per_workspace.fetchRemove(ws)) |entry|
        _ = g_window_to_workspace.remove(entry.value.window);
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
fn fetchWindowGeom(win: u32) core.WindowGeometry {
    if (comptime build_options.has_tiling) {
        if (tiling.getWindowGeom(win)) |rect| {
            // Fast path: tiled windows have a cached rect from the last retile.
            const bw: u16 = if (tiling.getStateOpt()) |ts| ts.border_width else 0;
            return rectToGeom(rect, bw);
        }
    }

    // Slow path: floating or newly-spawned windows are not in the tiling cache
    // (never passed through configureSafe), so a blocking round-trip is needed.
    // Falls back to a centred quarter-screen default if the reply fails or the
    // window is offscreen (x/y below OFFSCREEN_THRESHOLD_MIN), which happens
    // when a window was spawned but never placed on-screen before fullscreen.
    const default: core.WindowGeometry = .{
        .x            = @intCast(@divTrunc(@as(i32, core.screen.width_in_pixels),  4)),
        .y            = @intCast(@divTrunc(@as(i32, core.screen.height_in_pixels), 4)),
        .width        = @divTrunc(core.screen.width_in_pixels,  2),
        .height       = @divTrunc(core.screen.height_in_pixels, 2),
        .border_width = 0,
    };

    const reply = xcb.xcb_get_geometry_reply(
        core.conn, xcb.xcb_get_geometry(core.conn, win), null,
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
inline fn rectToGeom(rect: utils.Rect, border_width: u16) core.WindowGeometry {
    return .{
        .x            = rect.x,
        .y            = rect.y,
        .width        = rect.width,
        .height       = rect.height,
        .border_width = border_width,
    };
}

// Floating geometry save/restore
//
// Window positions are saved to g_saved_float_geoms before a fullscreen enter
// so they survive the offscreen-push and can be exactly restored on exit.
// Cookies are fired in a batch before the server grab; replies are consumed
// immediately after so the round-trips overlap with in-memory setup.

/// Save the current on-screen position of every non-minimized, non-tiled
/// window on the current workspace (except `skip_win`) into g_saved_float_geoms.
/// Must be called BEFORE xcb_grab_server so the geometry round-trips do not
/// block inside a grab.
fn saveFloatingWindowGeoms(skip_win: u32) void {
    const ws_obj = workspaces.getCurrentWorkspaceObject() orelse return;

    const MAX = 64;
    var wins:    [MAX]u32                            = undefined;
    var cookies: [MAX]xcb.xcb_get_geometry_cookie_t = undefined;
    var n: usize = 0;

    for (ws_obj.windows.items()) |w| {
        if (w == skip_win) continue;
        if (minimize.isMinimized(w)) continue;
        const is_tiled = if (comptime build_options.has_tiling) tiling.isWindowTiled(w) else false;
        if (is_tiled) continue;
        if (n < MAX) {
            wins[n]    = w;
            cookies[n] = xcb.xcb_get_geometry(core.conn, w);
            n += 1;
        }
    }

    g_saved_float_geoms.clearRetainingCapacity();

    for (wins[0..n], cookies[0..n]) |w, cookie| {
        const reply = xcb.xcb_get_geometry_reply(core.conn, cookie, null) orelse continue;
        defer std.c.free(reply);
        // Skip windows that are already offscreen (e.g. during a fullscreen switch).
        if (reply.*.x < constants.OFFSCREEN_THRESHOLD_MIN or
            reply.*.y < constants.OFFSCREEN_THRESHOLD_MIN) continue;
        g_saved_float_geoms.put(w, .{
            .x = reply.*.x, .y = reply.*.y,
            .width = reply.*.width, .height = reply.*.height,
        }) catch {};
    }
}

/// Restore every non-minimized, non-tiled window on the current workspace
/// (except `skip_win`) to its saved position.
/// Priority: g_saved_float_geoms → tiling geometry cache → floatDefaultPos fallback.
/// Clears g_saved_float_geoms when done.
fn restoreFloatingWindows(skip_win: u32) void {
    const ws_obj = workspaces.getCurrentWorkspaceObject() orelse return;
    const pos    = utils.floatDefaultPos();

    for (ws_obj.windows.items()) |w| {
        if (w == skip_win) continue;
        if (minimize.isMinimized(w)) continue;
        const is_tiled = if (comptime build_options.has_tiling) tiling.isWindowTiled(w) else false;
        if (is_tiled) continue;

        // Resolve the best available geometry through the priority chain:
        //   1. saved float geometry (exact pre-fullscreen position)
        //   2. tiling cache (last known tiled rect)
        //   3. null → fall through to default placement below
        const rect: ?utils.Rect = g_saved_float_geoms.get(w) orelse
            if (comptime build_options.has_tiling) tiling.getWindowGeom(w) else null;

        if (rect) |r| {
            utils.configureWindow(core.conn, w, r);
        } else {
            _ = xcb.xcb_configure_window(core.conn, w,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{ pos.x, pos.y });
        }
    }

    g_saved_float_geoms.clearRetainingCapacity();
}

// Commit helpers (XCB-only; caller owns grab/ungrab/flush) 

inline fn enterFullscreenCommit(win: u32, ws: u8, geom: core.WindowGeometry) void {
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
            _ = xcb.xcb_configure_window(core.conn, other_win,
                xcb.XCB_CONFIG_WINDOW_X,
                &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            if (comptime build_options.has_tiling) {
                // Only invalidate tiled windows — floating windows' cache entries
                // hold the geometry we need to restore on exit.
                if (tiling.isWindowTiled(other_win)) tiling.invalidateGeomCache(other_win);
            }
        }
    }

    bar.setBarState(.hide_fullscreen);

    utils.configureWindowGeom(core.conn, win, .{
        .x            = 0,
        .y            = 0,
        .width        = @intCast(core.screen.width_in_pixels),
        .height       = @intCast(core.screen.height_in_pixels),
        .border_width = 0,
    });
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    // Evict the fullscreen window itself; its cache still holds the pre-fullscreen
    // tiled rect. On exit retile would compute the same rect, get a hit, and skip
    // configure_window, leaving the window stuck at fullscreen dimensions.
    if (comptime build_options.has_tiling) tiling.invalidateGeomCache(win);
}

inline fn exitFullscreenCommit(win: u32, ws: u8) void {
    const fs_info = getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;

    removeForWorkspace(ws);

    bar.setBarState(.show_fullscreen);

    const win_is_tiled = if (comptime build_options.has_tiling) tiling.isWindowTiled(win) else false;
    if (win_is_tiled) {
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{saved.border_width});
    } else {
        utils.configureWindowGeom(core.conn, win, saved);
    }

    if (comptime build_options.has_tiling) {
        _ = xcb.xcb_change_window_attributes(core.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{
                if (focus.getFocused() == win) core.config.tiling.border_focused
                else core.config.tiling.border_unfocused,
            });
    }
}

// Public actions 

/// Enter fullscreen for `win` on the current workspace.
/// Pass a pre-computed geometry in `saved_geom` (e.g. when restoring a
/// minimized fullscreen window); pass null to fetch it from the tiling cache
/// or a live round-trip (the common path for new fullscreen requests).
pub fn enterFullscreen(win: u32, saved_geom: ?core.WindowGeometry) void {
    const ws   = workspaces.getCurrentWorkspace() orelse return;
    const geom = saved_geom orelse fetchWindowGeom(win);
    saveFloatingWindowGeoms(win);
    _ = xcb.xcb_grab_server(core.conn);
    enterFullscreenCommit(win, ws, geom);
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

pub fn toggleFullscreen() void {
    const win        = focus.getFocused() orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            _ = xcb.xcb_grab_server(core.conn);
            exitFullscreenCommit(win, current_ws);
            restoreFloatingWindows(win);
            // The retile's EnterNotify correctly updates hover focus — no suppression needed.
            _ = xcb.xcb_ungrab_server(core.conn);
            _ = xcb.xcb_flush(core.conn);
        } else {
            // Switching fullscreen from one window to another: share a single grab.
            // g_saved_float_geoms already holds positions from the original enter —
            // don't repopulate (windows are offscreen) and don't clear (they'll be
            // restored when the new fullscreen is eventually exited).
            const geom = fetchWindowGeom(win);
            _ = xcb.xcb_grab_server(core.conn);
            exitFullscreenCommit(fs_info.window, current_ws);
            enterFullscreenCommit(win, current_ws, geom);
            _ = xcb.xcb_ungrab_server(core.conn);
            _ = xcb.xcb_flush(core.conn);
        }
    } else {
        enterFullscreen(win, null);
    }
}
