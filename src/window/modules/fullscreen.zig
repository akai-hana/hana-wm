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
//!
//! Internal window iteration is centralised in forEachWindowOnCurrentWorkspace,
//! which dispatches to the workspace window list (has_workspaces) or the
//! global tracking iterator, eliminating three separate copies of that branch.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const utils     = @import("utils");
const constants = @import("constants");

const debug = @import("debug");

const window   = @import("window");
const tracking = @import("tracking");
const focus    = @import("focus");

const minimize   = if (build.has_minimize) @import("minimize") else struct {};
const workspaces = if (build.has_workspaces) @import("workspaces") else struct {};

const tiling = if (build.has_tiling) @import("tiling") else struct {};

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn setBarState(_: anytype) void {}
};


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
// Improvement #7: zero-initialised instead of `undefined` — eliminates the
// footgun where a length-tracking bug would silently yield garbage data.
var g_float_saves:     [MAX_FLOAT_SAVES]FloatSave = std.mem.zeroes([MAX_FLOAT_SAVES]FloatSave);
var g_float_saves_len: usize = 0;

// EWMH atoms for _NET_WM_STATE_FULLSCREEN — interned once in init().
var g_net_wm_state:            xcb.xcb_atom_t = xcb.XCB_ATOM_NONE;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = xcb.XCB_ATOM_NONE;

// Improvement #6: single source of truth for the reset sequence shared by
// init() and deinit(), so adding a new state field can never cause one to
// fall out of sync with the other.
fn resetState() void {
    g_slots           = @splat(null);
    g_float_saves_len = 0;
}

pub fn init() void {
    resetState();

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
    resetState();
}

// Public state queries

pub fn isFullscreen(win: u32) bool {
    return workspaceFor(win) != null;
}

pub fn getForWorkspace(ws: u8) ?FullscreenInfo {
    return g_slots[ws];
}

/// Returns the workspace index that `win` is fullscreen on, or null.
// Improvement #14: reworded from "scans only the live slots, not the full
// 256-entry array" — that claim is only true for typical workspace counts.
/// Scans up to getWorkspaceCount() slots; O(workspace_count).
pub fn workspaceFor(win: u32) ?u8 {
    const count = tracking.getWorkspaceCount();
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

// Improvement #13: clear() previously only zeroed g_slots, leaving a stale
// g_float_saves_len that could cause restoreFloatingWindows to act on data
// from a prior session if clear() was called mid-session.
pub fn clear() void {
    g_slots           = @splat(null);
    g_float_saves_len = 0;
}

pub fn hasAnyFullscreen() bool {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count]) |slot| if (slot != null) return true;
    return false;
}

/// Iterate over occupied slots. Diagnostics only.
/// Calls `cb` with (workspace_index, FullscreenInfo) for every non-null slot.
// Improvement #9: accepts anytype instead of a bare fn pointer so the caller
// can pass a struct with a `call` method that captures local state, or any
// other callable — all resolved and inlined at compile time, zero cost.
pub fn forEachFullscreen(cb: anytype) void {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count], 0..) |slot, i|
        if (slot) |info| cb(@intCast(i), info);
}

// Internal iteration helper
//
// Calls `ctx.call(window_id)` for every window on the current workspace
// except `skip`, dispatching to the workspace window list when workspaces
// are compiled in and falling back to the global tracking iterator otherwise.
// `ctx` is anytype so each call site is monomorphised over its specific
// context struct; the resulting code is equivalent to a hand-written branch
// at each site with zero overhead.
//
// This helper is the single place that knows about the has_workspaces
// dispatch, replacing three separate copies of the same branching pattern
// that formerly lived inside saveFloatingWindowGeoms, restoreFloatingWindows,
// and enterFullscreenCommit.
fn forEachWindowOnCurrentWorkspace(skip: u32, ctx: anytype) void {
    if (comptime build.has_workspaces) {
        const ws_obj = workspaces.getCurrentWorkspaceObject() orelse return;
        for (ws_obj.windows.items()) |w| {
            if (w == skip) continue;
            ctx.call(w);
        }
    } else {
        var iter = tracking.allWindowsIterator() orelse return;
        while (iter.next()) |wp| {
            const w = wp.*;
            if (w == skip) continue;
            ctx.call(w);
        }
    }
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
/// quarter-screen default if the reply fails, the window is offscreen
/// (x/y below OFFSCREEN_THRESHOLD_MIN), or the window reports a zero-size
/// geometry (mapped but not yet sized).
fn fetchWindowGeom(win: u32) core.WindowGeometry {
    if (comptime build.has_tiling) {
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

    // Improvement #10: screen dimensions are u16; dividing by a power of two
    // on an unsigned value is unambiguous — the former @as(i32, ...) cast and
    // @divTrunc were unnecessary and misleading.
    const default: core.WindowGeometry = .{
        .x            = @intCast(core.screen.width_in_pixels  / 4),
        .y            = @intCast(core.screen.height_in_pixels / 4),
        .width        = core.screen.width_in_pixels  / 2,
        .height       = core.screen.height_in_pixels / 2,
        .border_width = 0,
    };

    const reply = xcb.xcb_get_geometry_reply(
        core.conn, xcb.xcb_get_geometry(core.conn, win), null,
    ) orelse return default;
    defer std.c.free(reply);

    // Improvement #11: also reject zero-size geometry.  A window that has
    // been mapped but not yet sized reports width=0/height=0; saving those
    // dimensions and restoring them on exit would leave the window invisible.
    if (reply.*.x < constants.OFFSCREEN_SENTINEL_MIN or
        reply.*.y < constants.OFFSCREEN_SENTINEL_MIN or
        reply.*.width  == 0 or
        reply.*.height == 0) return default;

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
    var wins:      [MAX_FLOAT_SAVES]u32                            = undefined;
    var cookies:   [MAX_FLOAT_SAVES]xcb.xcb_get_geometry_cookie_t = undefined;
    var n:         usize = 0;
    var truncated: bool  = false;

    // Improvement #3 (iteration) + #8 (truncation log):
    // The collection step now uses forEachWindowOnCurrentWorkspace so the
    // has_workspaces dispatch is not repeated here.  Overflow past
    // MAX_FLOAT_SAVES is logged rather than silently dropped.
    const CollectCtx = struct {
        n:         *usize,
        truncated: *bool,
        wins:      *[MAX_FLOAT_SAVES]u32,
        cookies:   *[MAX_FLOAT_SAVES]xcb.xcb_get_geometry_cookie_t,

        fn call(self: @This(), w: u32) void {
            if (minimize.isMinimized(w)) return;
            if (comptime build.has_tiling) if (tiling.isWindowTiled(w)) return;
            if (self.n.* >= MAX_FLOAT_SAVES) {
                self.truncated.* = true;
                return;
            }
            self.wins[self.n.*]    = w;
            self.cookies[self.n.*] = xcb.xcb_get_geometry(core.conn, w);
            self.n.* += 1;
        }
    };

    forEachWindowOnCurrentWorkspace(skip_win, CollectCtx{
        .n         = &n,
        .truncated = &truncated,
        .wins      = &wins,
        .cookies   = &cookies,
    });

    if (truncated) debug.warn(
        "saveFloatingWindowGeoms: more than {d} floating windows on workspace; " ++
        "excess positions will not be restored on fullscreen exit",
        .{MAX_FLOAT_SAVES},
    );

    g_float_saves_len = 0;

    for (wins[0..n], cookies[0..n]) |w, cookie| {
        const reply = xcb.xcb_get_geometry_reply(core.conn, cookie, null) orelse continue;
        defer std.c.free(reply);
        // Skip windows that are already offscreen (e.g. during a fullscreen switch).
        if (reply.*.x < constants.OFFSCREEN_SENTINEL_MIN or
            reply.*.y < constants.OFFSCREEN_SENTINEL_MIN) continue;
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
    const pos = utils.floatDefaultPos();

    // Improvement #3: the has_workspaces dispatch now lives only in
    // forEachWindowOnCurrentWorkspace.  We capture pos by its component
    // values (x, y as u32) to avoid needing to know its concrete type inside
    // the context struct declaration.
    const RestoreCtx = struct {
        pos_x: u32,
        pos_y: u32,

        fn call(self: @This(), w: u32) void {
            if (minimize.isMinimized(w)) return;
            if (comptime build.has_tiling) if (tiling.isWindowTiled(w)) return;
            const rect: ?utils.Rect = getSavedFloatGeom(w) orelse window.getWindowGeom(w);
            if (rect) |r| {
                utils.configureWindow(core.conn, w, r);
            } else {
                _ = xcb.xcb_configure_window(core.conn, w,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ self.pos_x, self.pos_y });
            }
        }
    };

    forEachWindowOnCurrentWorkspace(skip_win, RestoreCtx{ .pos_x = pos.x, .pos_y = pos.y });

    g_float_saves_len = 0;
}

// Commit helpers (XCB-only; caller owns grab/ungrab/flush)
//
// Improvement #4: `inline` removed from both helpers.  These functions contain
// array loops, multiple conditional branches, several XCB calls, and a bar
// state update (which may trigger a tiling retile).  Forcing inlining at every
// call site produces larger binary output and misleads readers into thinking
// these are trivial leaf functions.  The compiler will inline them on its own
// if it determines the trade-off is worthwhile.

fn enterFullscreenCommit(win: u32, ws: u8, geom: core.WindowGeometry) void {
    setForWorkspace(ws, .{
        .window         = win,
        .saved_geometry = geom,
    });

    // Push every other window offscreen.
    // Improvement #3: iteration dispatched through the shared helper.
    const PushCtx = struct {
        fn call(_: @This(), w: u32) void {
            _ = xcb.xcb_configure_window(core.conn, w,
                xcb.XCB_CONFIG_WINDOW_X,
                &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            if (comptime build.has_tiling) {
                // Only invalidate tiled windows — floating windows' cache entries
                // hold the geometry we need to restore on exit.
                if (tiling.isWindowTiled(w)) tiling.invalidateGeomCache(w);
            }
        }
    };
    forEachWindowOnCurrentWorkspace(win, PushCtx{});

    // Configure the fullscreen window and raise it BEFORE calling setBarState.
    // setBarState(.hide_fullscreen) triggers tiling.retileCurrentWorkspace() when
    // tiling is active. If setBarState ran first, the retile would pull the other
    // windows back to their tiled on-screen positions, undoing the offscreen push
    // above. By configuring and raising the fullscreen window first, the retile
    // that fires inside setBarState sees a fully-committed fullscreen state and
    // skips (or correctly handles) the fullscreen window, leaving everything else
    // offscreen where we placed it.
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
    if (comptime build.has_tiling) tiling.invalidateGeomCache(win);

    bar.setBarState(.hide_fullscreen);

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

fn exitFullscreenCommit(win: u32, ws: u8) void {
    const fs_info = getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;

    removeForWorkspace(ws);

    bar.setBarState(.show_fullscreen);

    const win_is_tiled = if (comptime build.has_tiling) tiling.isWindowTiled(win) else false;
    if (win_is_tiled) {
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{saved.border_width});
    } else {
        utils.configureWindowGeom(core.conn, win, saved);
    }

    window.applyBorder(win);

    // Clear EWMH fullscreen state so external tools see the window is no longer fullscreen.
    // Improvement #2: guard now checks both atoms, mirroring the enter path.
    // Previously only g_net_wm_state was checked; if atom interning had partially
    // failed, the clear would still fire and write against an unexpected atom value.
    if (g_net_wm_state != xcb.XCB_ATOM_NONE and g_net_wm_state_fullscreen != xcb.XCB_ATOM_NONE) {
        _ = xcb.xcb_change_property(
            core.conn, xcb.XCB_PROP_MODE_REPLACE,
            win, g_net_wm_state,
            xcb.XCB_ATOM_ATOM, 32,
            0, null,
        );
    }
}

// Public actions

/// Cleans up fullscreen side-effects when a fullscreen window is being moved
/// to a different workspace.  Specifically, this handles what exitFullscreenCommit
/// would have done on the source workspace — without restoring the window's
/// geometry, since the caller is responsible for repositioning it on the target.
///
/// Concretely:
///   - Shows the bar again on the source workspace.
///   - Restores any floating windows that were pushed offscreen during enter.
///   - Restores the window's border width (zeroed on enter) and re-applies the
///     border colour via window.applyBorder.
///   - Clears the EWMH _NET_WM_STATE_FULLSCREEN property on the window.
///
/// The fullscreen record for `src_ws` must still be present when this is called.
/// The caller is responsible for removing/transferring the record afterward.
pub fn cleanupFullscreenForMove(win: u32, src_ws: u8) void {
    const fs_info = getForWorkspace(src_ws) orelse return;
    if (fs_info.window != win) return;

    // Restore the bar on the source workspace.
    bar.setBarState(.show_fullscreen);

    // Bring back floating windows that were pushed offscreen during enter.
    // restoreFloatingWindows also clears g_float_saves_len.
    restoreFloatingWindows(win);

    // Restore the border width that was zeroed by enterFullscreenCommit.
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{fs_info.saved_geometry.border_width});
    window.applyBorder(win);

    // Clear the EWMH fullscreen property so external tools (compositors, etc.)
    // see the window is no longer fullscreen.
    if (g_net_wm_state != xcb.XCB_ATOM_NONE and g_net_wm_state_fullscreen != xcb.XCB_ATOM_NONE) {
        _ = xcb.xcb_change_property(
            core.conn, xcb.XCB_PROP_MODE_REPLACE,
            win, g_net_wm_state,
            xcb.XCB_ATOM_ATOM, 32,
            0, null,
        );
    }
}

/// Enter fullscreen for `win` on the current workspace.
/// Pass a pre-computed geometry in `saved_geom` (e.g. when restoring a
/// minimized fullscreen window); pass null to fetch it from the tiling cache
/// or a live round-trip (the common path for new fullscreen requests).
pub fn enterFullscreen(win: u32, saved_geom: ?core.WindowGeometry) void {
    const ws   = tracking.getCurrentWorkspace() orelse return;
    const geom = saved_geom orelse fetchWindowGeom(win);
    saveFloatingWindowGeoms(win);
    _ = xcb.xcb_grab_server(core.conn);
    enterFullscreenCommit(win, ws, geom);
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

// Improvement #1 (bug fix) + #5 (uniform grab ownership):
//
// Former toggle() had two problems:
//
//   1. In the "switch fullscreen to a different window" branch,
//      saveFloatingWindowGeoms() and fetchWindowGeom() were called INSIDE
//      xcb_grab_server/xcb_ungrab_server.  Both functions issue
//      xcb_get_geometry requests and then read their replies.  Those replies
//      cannot be delivered while the same client holds the server grab —
//      xcb_get_geometry_reply blocks indefinitely, hanging the WM.
//      (saveFloatingWindowGeoms' own doc comment says "must be called BEFORE
//      xcb_grab_server".)  Fix: hoist all round-trip work before the grab.
//
//   2. The not-fullscreen branch delegated to enterFullscreen(), which owns
//      its own grab internally.  This made toggle() partly an orchestrator
//      and partly a thin wrapper depending on runtime state.  All three
//      branches now own the grab uniformly, calling enterFullscreenCommit
//      (rather than enterFullscreen) in the not-fullscreen case.
pub fn toggle() void {
    const win        = focus.getFocused() orelse return;
    const current_ws = tracking.getCurrentWorkspace() orelse return;

    if (getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            // Toggle off: exit fullscreen for the focused window.
            _ = xcb.xcb_grab_server(core.conn);
            exitFullscreenCommit(win, current_ws);
            restoreFloatingWindows(win);
            _ = xcb.xcb_ungrab_server(core.conn);
            _ = xcb.xcb_flush(core.conn);
        } else {
            // Switch: a different window is currently fullscreen.
            // Hoist both round-trip operations (fetchWindowGeom issues a
            // synchronous xcb_get_geometry; saveFloatingWindowGeoms batches
            // several) before acquiring the grab so their replies can be
            // delivered by the server.
            const new_geom = fetchWindowGeom(win);
            saveFloatingWindowGeoms(win);
            _ = xcb.xcb_grab_server(core.conn);
            exitFullscreenCommit(fs_info.window, current_ws);
            // Restore background windows to their positions before pushing
            // them offscreen again for the new fullscreen window.  Without
            // this step they remain invisible after the transition.
            restoreFloatingWindows(win);
            enterFullscreenCommit(win, current_ws, new_geom);
            _ = xcb.xcb_ungrab_server(core.conn);
            _ = xcb.xcb_flush(core.conn);
        }
    } else {
        // Nothing fullscreen on this workspace — enter fullscreen.
        // Round-trip work is hoisted before the grab, consistent with the
        // switch branch above.
        const geom = fetchWindowGeom(win);
        saveFloatingWindowGeoms(win);
        _ = xcb.xcb_grab_server(core.conn);
        enterFullscreenCommit(win, current_ws, geom);
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    }
}
