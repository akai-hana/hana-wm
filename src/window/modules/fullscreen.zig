//! Fullscreen management
//! Handles entering, exiting, toggling, and querying fullscreen state for windows.

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

const minimize = if (build.has_minimize) @import("minimize");
// Note: workspaces dispatch is handled through tracking.workspaceBit /
// tracking.allWindows inside forEachWindowOnCurrentWorkspace; a top-level
// workspaces import is not needed here.

const tiling = if (build.has_tiling) @import("tiling");

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn setBarState(_: anytype) void {}
};

// Shim: returns false when minimize is compiled out, matching the pattern in
// workspaces.zig. Prevents a compile error on minimize.isMinimized when
// build.has_minimize is false (the bare import resolves to void in that case).
inline fn isMinimized(win: u32) bool {
    return if (build.has_minimize) minimize.isMinimized(win) else false;
}


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
/// Zero-initialised at program start; note that resetState() only resets
/// g_float_saves_len and does not re-zero the backing array, so stale data
/// may exist in g_float_saves[0..old_len] after a reset.  All reads must be
/// bounded by g_float_saves_len to avoid accessing that stale data.
var g_float_saves:     [MAX_FLOAT_SAVES]FloatSave = std.mem.zeroes([MAX_FLOAT_SAVES]FloatSave);
var g_float_saves_len: usize = 0;

// EWMH atoms for _NET_WM_STATE_FULLSCREEN — interned once in init().
var g_net_wm_state:            xcb.xcb_atom_t = xcb.XCB_ATOM_NONE;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = xcb.XCB_ATOM_NONE;

/// Shared reset sequence used by both init() and deinit() to keep them in sync.
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

/// Atomically transfer the fullscreen record from `src_ws` to `dst_ws`.
/// Callers are responsible for any visual cleanup (bar, floating windows,
/// border restoration) before calling this.
/// Asserts that a record exists at `src_ws`; call `getForWorkspace` to verify
/// first if that is not guaranteed by the call-site invariants.
/// Asserts that `dst_ws` is empty: if a FullscreenInfo already occupies that
/// slot it would be silently discarded, leaking associated state.  The caller
/// must ensure `dst_ws` has no active fullscreen record before calling
/// (e.g. by calling `removeForWorkspace(dst_ws)` after any required cleanup).
pub fn moveRecord(src_ws: u8, dst_ws: u8) void {
    std.debug.assert(g_slots[dst_ws] == null); // dst_ws must be empty; see doc comment
    const info = g_slots[src_ws].?;
    g_slots[src_ws] = null;
    g_slots[dst_ws] = info;
}

pub fn hasAnyFullscreen() bool {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count]) |slot| if (slot != null) return true;
    return false;
}

/// Iterate over occupied slots. Diagnostics only.
/// Calls `cb` with (workspace_index, FullscreenInfo) for every non-null slot.
/// `cb` may be any callable — resolved and inlined at compile time, zero runtime cost.
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
    if (build.has_workspaces) {
        const cur = tracking.getCurrentWorkspace() orelse return;
        const bit = tracking.workspaceBit(cur);
        for (tracking.allWindows()) |entry| {
            if (entry.mask & bit == 0) continue;
            if (entry.win == skip) continue;
            ctx.call(entry.win);
        }
    } else {
        for (tracking.allWindows()) |entry| {
            if (entry.win == skip) continue;
            ctx.call(entry.win);
        }
    }
}

// Geometry helpers

/// Retrieve the pre-fullscreen geometry for `win` before entering fullscreen.
///
/// Fast path — tiled windows: `configureWithHints` stores the most recent tiled
/// rect in the geometry cache after every retile.  Reading from the cache
/// avoids a blocking xcb_get_geometry round-trip.
///
/// Slow path — floating or newly-spawned windows: these are not in the tiling
/// cache (they were never passed through `configureWithHints`), so a blocking
/// xcb_get_geometry round-trip is unavoidable.  Falls back to a centred
/// quarter-screen default if the reply fails, the window is offscreen
/// (x/y below OFFSCREEN_SENTINEL_MIN), or the window reports a zero-size
/// geometry (mapped but not yet sized).
fn fetchWindowGeom(win: u32) core.WindowGeometry {
    if (build.has_tiling) {
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

    // Screen dimensions are u16; dividing by a power of two is unambiguous on unsigned values.
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

    // Also reject zero-size geometry: a window mapped but not yet sized reports
    // width=0/height=0; saving and restoring those dimensions would leave it invisible.
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

    // Uses forEachWindowOnCurrentWorkspace for workspace dispatch.
    // Overflow past MAX_FLOAT_SAVES is logged rather than silently dropped.
    const CollectCtx = struct {
        n:         *usize,
        truncated: *bool,
        wins:      *[MAX_FLOAT_SAVES]u32,
        cookies:   *[MAX_FLOAT_SAVES]xcb.xcb_get_geometry_cookie_t,

        fn call(self: @This(), w: u32) void {
            if (isMinimized(w)) return;
            if (build.has_tiling) if (tiling.isWindowTiled(w)) return;
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
    const pos = window.floatDefaultPos();

    // Workspace dispatch is handled by forEachWindowOnCurrentWorkspace.
    const RestoreCtx = struct {
        pos_x: u32,
        pos_y: u32,

        fn call(self: @This(), w: u32) void {
            if (isMinimized(w)) return;
            if (build.has_tiling) if (tiling.isWindowTiled(w)) return;
            // Do NOT fall back to window.getWindowGeom here: restoreFloatingWindows
            // is called inside xcb_grab_server, and a synchronous xcb_get_geometry
            // round-trip would block indefinitely waiting for a reply that can never
            // be delivered while this client holds the grab (classic XCB grab
            // deadlock).  Windows absent from g_float_saves fall back to the
            // pre-computed default position instead.
            if (getSavedFloatGeom(w)) |r| {
                utils.configureWindow(core.conn, w, r);
            } else {
                _ = xcb.xcb_configure_window(core.conn, w,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ self.pos_x, self.pos_y });
            }
        }
    };

    forEachWindowOnCurrentWorkspace(skip_win, RestoreCtx{ .pos_x = @intCast(pos.x), .pos_y = @intCast(pos.y) });

    g_float_saves_len = 0;
}

/// Advertise or clear the EWMH _NET_WM_STATE_FULLSCREEN property on `win`.
///
/// Guards on both atoms being valid so a partial atom-intern failure cannot
/// corrupt the property (matches the enter-path guard that was already
/// dual-checking both atoms; exit paths now do the same).
///
/// `is_fullscreen = true`  → sets count=1, data=&g_net_wm_state_fullscreen
/// `is_fullscreen = false` → sets count=0, data=null  (clears the property)
fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or
        g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    const count: u32 = if (is_fullscreen) 1 else 0;
    _ = xcb.xcb_change_property(
        core.conn, xcb.XCB_PROP_MODE_REPLACE,
        win, g_net_wm_state,
        xcb.XCB_ATOM_ATOM, 32,
        count, if (is_fullscreen) &g_net_wm_state_fullscreen else null,
    );
}

// Commit helpers (XCB-only; caller owns grab/ungrab/flush)

fn enterFullscreenCommit(win: u32, ws: u8, geom: core.WindowGeometry) void {
    setForWorkspace(ws, .{
        .window         = win,
        .saved_geometry = geom,
    });

    // Push every other window offscreen; workspace dispatch is through the shared helper.
    const PushCtx = struct {
        fn call(_: @This(), w: u32) void {
            utils.pushWindowOffscreen(core.conn, w);
            if (build.has_tiling) {
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
    window.configureWindowGeom(core.conn, win, .{
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
    if (build.has_tiling) tiling.invalidateGeomCache(win);

    bar.setBarState(.hide_fullscreen);

    // Advertise fullscreen state via EWMH so external tools (e.g. compositor
    // scripts) can detect it with xprop / xev.
    setEwmhFullscreenState(win, true);
}

fn exitFullscreenCommit(win: u32, ws: u8) void {
    const fs_info = getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;

    removeForWorkspace(ws);

    bar.setBarState(.show_fullscreen);

    const win_is_tiled = if (build.has_tiling) tiling.isWindowTiled(win) else false;
    // Tiled windows: geometry is managed by the tiling engine; applyBorder below
    // restores the border width and colour in one pass.
    // Floating windows: restore position + size + border_width atomically via
    // configureWindowGeom to avoid a visible intermediate frame.
    if (!win_is_tiled) window.configureWindowGeom(core.conn, win, saved);

    window.applyBorder(win);

    // Clear EWMH fullscreen state so external tools see the window is no longer fullscreen.
    setEwmhFullscreenState(win, false);
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

    // Restore border width (zeroed on enter) and colour. applyBorder handles
    // both in one pass via applyBorderWidth + xcb_change_window_attributes.
    window.applyBorder(win);

    // Clear the EWMH fullscreen property so external tools (compositors, etc.)
    // see the window is no longer fullscreen.
    setEwmhFullscreenState(win, false);
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
    utils.ungrabAndFlush(core.conn);
}

// toggle() design note:
//
// All round-trip work (saveFloatingWindowGeoms, fetchWindowGeom) is hoisted
// before xcb_grab_server because replies cannot be delivered while the same
// client holds the server grab — xcb_get_geometry_reply would block indefinitely.
// All three branches own the grab uniformly via enterFullscreenCommit /
// exitFullscreenCommit rather than delegating to enterFullscreen().
pub fn toggle() void {
    const win        = focus.getFocused() orelse return;
    const current_ws = tracking.getCurrentWorkspace() orelse return;

    if (getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            // Toggle off: exit fullscreen for the focused window.
            _ = xcb.xcb_grab_server(core.conn);
            exitFullscreenCommit(win, current_ws);
            restoreFloatingWindows(win);
            utils.ungrabAndFlush(core.conn);
        } else {
            // Switch: a different window is currently fullscreen.
            // Hoist the round-trip (fetchWindowGeom issues a synchronous
            // xcb_get_geometry) before acquiring the grab so its reply can be
            // delivered by the server.
            //
            // Do NOT call saveFloatingWindowGeoms here: all background windows
            // are already offscreen (pushed there by the original
            // enterFullscreenCommit), so every geometry reply would fail the
            // OFFSCREEN_SENTINEL_MIN guard and saveFloatingWindowGeoms would
            // reset g_float_saves_len to 0, destroying the valid positions that
            // were captured before the initial enter.  The existing g_float_saves
            // entries already hold the correct pre-fullscreen positions and will
            // be consumed by restoreFloatingWindows below.
            const new_geom = fetchWindowGeom(win);
            _ = xcb.xcb_grab_server(core.conn);
            exitFullscreenCommit(fs_info.window, current_ws);
            // Restore background windows to their positions before pushing
            // them offscreen again for the new fullscreen window.  Without
            // this step they remain invisible after the transition.
            restoreFloatingWindows(win);
            enterFullscreenCommit(win, current_ws, new_geom);
            utils.ungrabAndFlush(core.conn);
        }
    } else {
        // Nothing fullscreen on this workspace — enter fullscreen.
        // Round-trip work is hoisted before the grab, consistent with the
        // switch branch above.
        const geom = fetchWindowGeom(win);
        saveFloatingWindowGeoms(win);
        _ = xcb.xcb_grab_server(core.conn);
        enterFullscreenCommit(win, current_ws, geom);
        utils.ungrabAndFlush(core.conn);
    }
}
