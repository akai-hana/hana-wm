//! Fullscreen management — enter, exit, toggle, and state queries.
//!
//! All fullscreen state lives in the module-level g_state singleton.
//! WM no longer carries a fullscreen field.
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
// g_slots is a fixed array indexed directly by workspace index (u8).
// Workspace count is always a small number (default 9, max 255), so
// this is a dense array with zero heap involvement:
//   - getForWorkspace    — O(1) direct index
//   - setForWorkspace    — O(1) direct write, single array, no sync needed
//   - removeForWorkspace — O(1) direct write
//   - isFullscreen       — O(n) scan over at most 256 slots; faster in
//                          practice than a hashmap because n is tiny,
//                          there is no hashing cost, and the entire array
//                          fits in a single cache line
//   - workspaceFor       — O(n) scan, same reasoning
//   - clear              — single @splat(null) assignment
//
// g_float_saves replaces the former g_saved_float_geoms hashmap for the
// same reasons: the window count on a workspace is bounded and small,
// so a parallel fixed array with a length counter is simpler and cheaper.

const MAX_WORKSPACES:  usize = 256; // u8 key space — array is ~4 KB, trivial
const MAX_FLOAT_SAVES: usize = 64;  // matches the former MAX constant in saveFloatingWindowGeoms

var g_slots: [MAX_WORKSPACES]?FullscreenInfo = @splat(null);

const FloatSave = struct { win: u32, rect: utils.Rect };
/// Floating window positions saved just before a fullscreen enter. Populated
/// by saveFloatingWindowGeoms, consumed and cleared by restoreFloatingWindows.
var g_float_saves:     [MAX_FLOAT_SAVES]FloatSave = undefined;
var g_float_saves_len: usize = 0;

// EWMH atoms for _NET_WM_STATE_FULLSCREEN — interned once in init().
var g_net_wm_state:            xcb.xcb_atom_t = xcb.XCB_ATOM_NONE;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = xcb.XCB_ATOM_NONE;

pub fn init() void {
    g_slots           = @splat(null);
    g_float_saves_len = 0;

    // Intern EWMH atoms needed for _NET_WM_STATE_FULLSCREEN.
    // Batch both requests before consuming either reply so the round-trips overlap.
    const ck_state = xcb.xcb_intern_atom(core.conn, 0, "_NET_WM_STATE".len, "_NET_WM_STATE");
    const ck_fs    = xcb.xcb_intern_atom(core.conn, 0, "_NET_WM_STATE_FULLSCREEN".len, "_NET_WM_STATE_FULLSCREEN");
    if (xcb.xcb_intern_atom_reply(core.conn, ck_state, null)) |r| {
        g_net_wm_state = r.*.atom;
        std.c.free(r);
    }
    if (xcb.xcb_intern_atom_reply(core.conn, ck_fs, null)) |r| {
        g_net_wm_state_fullscreen = r.*.atom;
        std.c.free(r);
    }
}

pub fn deinit() void {
    g_slots           = @splat(null);
    g_float_saves_len = 0;
}

// Public state queries

pub fn isFullscreen(win: u32) bool {
    return workspaceFor(win) != null;
}

pub fn getForWorkspace(ws: u8) ?FullscreenInfo {
    return g_slots[ws];
}

/// Returns the workspace index that `win` is fullscreen on, or null.
/// O(workspace_count) — scans only the live slots, not the full 256-entry array.
pub fn workspaceFor(win: u32) ?u8 {
    const count = workspaces.getWorkspaceCount();
    for (g_slots[0..count], 0..) |slot, i|
        if (slot) |info| if (info.window == win) return @intCast(i);
    return null;
}

pub fn setForWorkspace(ws: u8, info: FullscreenInfo) void {
    g_slots[ws] = info;
}

pub fn removeForWorkspace(ws: u8) void {
    g_slots[ws] = null;
}

pub fn clear() void {
    g_slots = @splat(null);
}

pub fn hasAnyFullscreen() bool {
    const count = workspaces.getWorkspaceCount();
    for (g_slots[0..count]) |slot| if (slot != null) return true;
    return false;
}

/// Iterate over occupied slots. Diagnostics only.
/// Calls `cb` with (workspace_index, FullscreenInfo) for every non-null slot.
pub fn forEachFullscreen(cb: fn (u8, FullscreenInfo) void) void {
    const count = workspaces.getWorkspaceCount();
    for (g_slots[0..count], 0..) |slot, i|
        if (slot) |info| cb(@intCast(i), info);
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
            const bw: u16 = if (tiling.getStateOpt()) |ts| ts.border_width else 0;
            return .{
                .x            = rect.x,
                .y            = rect.y,
                .width        = rect.width,
                .height       = rect.height,
                .border_width = bw,
            };
        }
    }

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

// Floating geometry save/restore
//
// Window positions are saved to g_float_saves before a fullscreen enter
// so they survive the offscreen-push and can be exactly restored on exit.
// Cookies are fired in a batch before the server grab; replies are consumed
// immediately after so the round-trips overlap with in-memory setup.

/// Save the current on-screen position of every non-minimized, non-tiled
/// window on the current workspace (except `skip_win`) into g_float_saves.
/// Must be called BEFORE xcb_grab_server so the geometry round-trips do not
/// block inside a grab.
fn saveFloatingWindowGeoms(skip_win: u32) void {
    const ws_obj = workspaces.getCurrentWorkspaceObject() orelse return;

    var wins:    [MAX_FLOAT_SAVES]u32                            = undefined;
    var cookies: [MAX_FLOAT_SAVES]xcb.xcb_get_geometry_cookie_t = undefined;
    var n: usize = 0;

    for (ws_obj.windows.items()) |w| {
        if (w == skip_win) continue;
        if (minimize.isMinimized(w)) continue;
        const is_tiled = if (comptime build_options.has_tiling) tiling.isWindowTiled(w) else false;
        if (is_tiled) continue;
        if (n < MAX_FLOAT_SAVES) {
            wins[n]    = w;
            cookies[n] = xcb.xcb_get_geometry(core.conn, w);
            n += 1;
        }
    }

    g_float_saves_len = 0;

    for (wins[0..n], cookies[0..n]) |w, cookie| {
        const reply = xcb.xcb_get_geometry_reply(core.conn, cookie, null) orelse continue;
        defer std.c.free(reply);
        // Skip windows that are already offscreen (e.g. during a fullscreen switch).
        if (reply.*.x < constants.OFFSCREEN_THRESHOLD_MIN or
            reply.*.y < constants.OFFSCREEN_THRESHOLD_MIN) continue;
        g_float_saves[g_float_saves_len] = .{
            .win  = w,
            .rect = .{ .x = reply.*.x, .y = reply.*.y,
                       .width = reply.*.width, .height = reply.*.height },
        };
        g_float_saves_len += 1;
    }
}

/// Look up a saved float geometry by window ID. O(n) over g_float_saves_len.
fn getSavedFloatGeom(win: u32) ?utils.Rect {
    for (g_float_saves[0..g_float_saves_len]) |entry|
        if (entry.win == win) return entry.rect;
    return null;
}

/// Restore every non-minimized, non-tiled window on the current workspace
/// (except `skip_win`) to its saved position.
/// Priority: g_float_saves -> tiling geometry cache -> floatDefaultPos fallback.
/// Clears g_float_saves when done.
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
        //   3. null -> fall through to default placement below
        const rect: ?utils.Rect = getSavedFloatGeom(w) orelse
            if (comptime build_options.has_tiling) tiling.getWindowGeom(w) else null;

        if (rect) |r| {
            utils.configureWindow(core.conn, w, r);
        } else {
            _ = xcb.xcb_configure_window(core.conn, w,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{ pos.x, pos.y });
        }
    }

    g_float_saves_len = 0;
}

// Commit helpers (XCB-only; caller owns grab/ungrab/flush)

inline fn enterFullscreenCommit(win: u32, ws: u8, geom: core.WindowGeometry) void {
    setForWorkspace(ws, .{
        .window         = win,
        .saved_geometry = geom,
    });

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

    // Advertise fullscreen state via EWMH so external tools (e.g. compositor
    // scripts) can detect it with xprop / xev.
    if (g_net_wm_state != xcb.XCB_ATOM_NONE and g_net_wm_state_fullscreen != xcb.XCB_ATOM_NONE) {
        _ = xcb.xcb_change_property(
            core.conn, xcb.XCB_PROP_MODE_REPLACE,
            win, g_net_wm_state,
            xcb.XCB_ATOM_ATOM, 32,
            1, &g_net_wm_state_fullscreen,
        );
    }
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

    // Clear EWMH fullscreen state so external tools see the window is no longer fullscreen.
    if (g_net_wm_state != xcb.XCB_ATOM_NONE) {
        _ = xcb.xcb_change_property(
            core.conn, xcb.XCB_PROP_MODE_REPLACE,
            win, g_net_wm_state,
            xcb.XCB_ATOM_ATOM, 32,
            0, null,
        );
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

pub fn toggle() void {
    const win        = focus.getFocused() orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (getForWorkspace(current_ws)) |fs_info| {
        _ = xcb.xcb_grab_server(core.conn);
        exitFullscreenCommit(fs_info.window, current_ws);
        if (fs_info.window == win) {
            // The retile's EnterNotify correctly updates hover focus — no suppression needed.
            restoreFloatingWindows(win);
        } else {
            // Switching fullscreen from one window to another: share a single grab.
            // g_float_saves already holds positions from the original enter —
            // don't repopulate (windows are offscreen) and don't clear (they'll be
            // restored when the new fullscreen is eventually exited).
            enterFullscreenCommit(win, current_ws, fetchWindowGeom(win));
        }
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    } else {
        enterFullscreen(win, null);
    }
}
