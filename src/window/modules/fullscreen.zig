//! Fullscreen state tracker.
//! Manages fullscreen transitions, geometry preservation, and deferred bar visibility.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");

const debug = @import("debug");

const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");

const minimize = @import("minimize");
// Workspaces dispatch is handled through tracking.workspaceBit and
// tracking.allWindows inside windowsOnCurrentWorkspace, so a top-level
// workspaces import is not needed here.

const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;
const tiling = if (build_options.has_tiling) @import("tiling") else null;

pub const FullscreenInfo = struct {
    window: core.WindowId,
    saved_geometry: utils.Rect,
};

// g_slots: fixed array keyed by workspace index (u8). O(1) ops, no heap.
// Floating-window geometry across a fullscreen transition lives in the
// shared tiling geometry cache (see the "Floating geometry save/restore"
// block below), not in module state here.

const max_workspaces: usize = constants.max_workspaces; // Sourced from constants; determines the size of g_slots.

var g_slots: [max_workspaces]?FullscreenInfo = @splat(null);

/// Window configured fullscreen but awaiting ConfigureNotify confirmation.
/// Zero when none pending. Set in enterFullscreenCommit; cleared in
/// notifyConfigureIfPending/resetState.
var g_pending_bar_hide_win: u32 = 0;

/// Window that has exited fullscreen and been retiled but awaits ConfigureNotify
/// confirming its new dimensions. Zero when none pending. Set in exitFullscreen
/// after retile; cleared in notifyConfigureIfPending, resetState, onWindowGone.
var g_pending_bar_show_win: u32 = 0;

// EWMH atoms for _NET_WM_STATE_FULLSCREEN, resolved from the shared atom
// cache (utils.initAtomCache) in init(). Zero (XCB_ATOM_NONE) when the cache
// was unavailable; setEwmhFullscreenState's guard already skips the write then.
var g_net_wm_state: xcb.xcb_atom_t = 0;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = 0;

// Shared reset sequence used by both init() and deinit() to keep them in sync.
fn resetState() void {
    g_slots = @splat(null);
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = 0;
    g_net_wm_state = 0;
    g_net_wm_state_fullscreen = 0;
}

pub fn init() void {
    resetState();

    // Re-resolve the EWMH fullscreen atoms from the shared atom cache rather
    // than interning them again here.
    g_net_wm_state = utils.getAtomOrZero("_NET_WM_STATE");
    g_net_wm_state_fullscreen = utils.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
}

pub fn deinit() void {
    resetState();
}

pub fn isFullscreen(win: u32) bool {
    return workspaceFor(win) != null;
}

pub fn getForWorkspace(ws: core.WorkspaceId) ?FullscreenInfo {
    return g_slots[ws.index];
}

/// Returns the workspace index that `win` is fullscreen on, or null.
/// Scans up to getWorkspaceCount() slots; O(workspace_count).
pub fn workspaceFor(win: u32) ?core.WorkspaceId {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count], 0..) |slot, i|
        if (slot) |info| if (info.window == win) return core.WorkspaceId.fromIndex(@intCast(i));
    return null;
}

fn setForWorkspace(ws: core.WorkspaceId, info: FullscreenInfo) void {
    g_slots[ws.index] = info;
}

pub fn removeForWorkspace(ws: core.WorkspaceId) void {
    g_slots[ws.index] = null;
}

// Drops any fullscreen record of `win` on a workspace other than `keep_ws`,
// so a window re-entering fullscreen elsewhere doesn't keep two records;
// workspaceFor(), which scans lowest-first, would then resolve exit/toggle
// to the stale slot.
fn dropOtherRecordsFor(win: u32, keep_ws: core.WorkspaceId) void {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count], 0..) |*slot, i| {
        if (i == keep_ws.index) continue;
        const info = slot.* orelse continue;
        if (info.window != win) continue;
        setEwmhFullscreenState(win, false);
        slot.* = null;
    }
}

/// After a workspace-mask change, drop any fullscreen record on a workspace
/// the window is no longer tagged on; a stale record would resurrect bogus
/// fullscreen chrome when shown next. Call from every setWindowMask site.
pub fn pruneForWorkspaceMask(win: u32, new_mask: u64) void {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count], 0..) |*slot, i| {
        const info = slot.* orelse continue;
        if (info.window != win) continue;
        if (new_mask & tracking.workspaceBit(@as(u8, @intCast(i))) != 0) continue;
        setEwmhFullscreenState(win, false);
        g_slots[i] = null;
    }
}

/// Transfer the fullscreen record from `src_ws` to `dst_ws`. If `dst_ws`
/// already holds one, the moved record is dropped; never clobber the
/// occupant's state (it would stay visually fullscreen but untracked).
/// Callers handle visual cleanup; workspaces.zig checks the destination too.
pub fn moveRecord(src_ws: core.WorkspaceId, dst_ws: core.WorkspaceId) void {
    const info = g_slots[src_ws.index].?;
    if (g_slots[dst_ws.index] != null) {
        debug.warn("moveRecord: workspace {} already has a fullscreen record; dropping the moved one", .{dst_ws.index});
        setEwmhFullscreenState(info.window, false);
        g_slots[src_ws.index] = null;
        return;
    }
    g_slots[src_ws.index] = null;
    g_slots[dst_ws.index] = info;
}

pub fn hasAnyFullscreen() bool {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count]) |slot| if (slot != null) return true;
    return false;
}

/// Iterate over occupied slots. Diagnostics only.
/// Calls `cb` with (workspace_index, FullscreenInfo) for every non-null slot.
/// `cb` may be any callable; resolved and inlined at compile time, zero runtime cost.
pub fn forEachFullscreen(cb: anytype) void {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count], 0..) |slot, i|
        if (slot) |info| cb(core.WorkspaceId.fromIndex(@intCast(i)), info);
}

// Retrieve the pre-fullscreen geometry for `win`: tiled windows hit the
// geometry cache; floating/new windows issue a blocking xcb_get_geometry.
// Falls back to a centred quarter-screen default if the reply fails, the
// window is offscreen, or reports zero dimensions.
fn fetchWindowGeom(win: u32) utils.Rect {
    if (@import("wincache").getWindowGeom(win)) |rect| {
        const bw: u16 = if (build_options.has_tiling) tiling.getBorderWidth() else 0;
        return .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height, .border_width = bw };
    }

    // Screen dimensions are u16; dividing by a power of two is unambiguous on unsigned values.
    const cs = core.getState();
    const default: utils.Rect = .{
        .x = @intCast(cs.screen.width_in_pixels / 4),
        .y = @intCast(cs.screen.height_in_pixels / 4),
        .width = cs.screen.width_in_pixels / 2,
        .height = cs.screen.height_in_pixels / 2,
        .border_width = 0,
    };

    const reply = xcb.xcb_get_geometry_reply(
        cs.conn,
        xcb.xcb_get_geometry(cs.conn, win),
        null,
    ) orelse return default;
    defer std.c.free(reply);

    // Also reject zero-size geometry: a window mapped but not yet sized reports
    // width=0/height=0; saving and restoring those dimensions would leave it invisible.
    if (utils.isOffscreenGeomReply(reply) or
        reply.*.width == 0 or
        reply.*.height == 0) return default;

    return window.geometryFromXcbReply(reply);
}

// Floating geometry save/restore
//
// Both directions go through the shared tiling geometry cache
// (tiling.getWindowGeom / window.saveWindowGeom / window.restoreFloatGeom):
// the same cache drag.zig's stopDrag and floating.zig's placement pass
// already keep current for floating windows, and that workspaces.zig's
// prefetchAndSaveWindowGeometries and restoreFloatGeom already rely on for
// the identical "remember position, restore it later" problem. No private
// snapshot array needed: as long as a window's cache entry is valid, it's
// already exactly what we'd have saved ourselves.

// True when `win` is free-floating, not minimized and not tiled, i.e. its
// geometry is owned by the floating cache rather than the layout engine.
// Shared by warmFloatingWindowGeoms and restoreFloatingWindows. Declared as
// a plain fn (not inline) so it can be passed as a *const fn(u32)bool
// predicate (see tracking.prefetchAndSaveGeometryOnCurrentWorkspace).
fn isFreeFloating(win: u32) bool {
    return !minimize.isMinimized(win) and !tracking.isTiledMode(win);
}

// Warm the geometry cache for every free-floating window on the current
// workspace (except `skip_win`) that has no cache entry yet: a live
// round-trip only for the rare window the cache has never seen. Shares its
// prefetch/save/offscreen-skip logic with workspaces.zig's pre-switch
// geometry warm via tracking.prefetchAndSaveGeometryOnCurrentWorkspace.
// Must run BEFORE xcb_grab_server: a round-trip can't happen inside a grab.
fn warmFloatingWindowGeoms(skip_win: u32) void {
    tracking.prefetchAndSaveGeometryOnCurrentWorkspace(&isFreeFloating, skip_win);
}

// Restore every free-floating window on the current workspace (except
// `skip_win`) to its cached position, falling back to the float default
// position when the cache has no entry (window.restoreFloatGeom).
// Safe inside xcb_grab_server: restoreFloatGeom only ever reads the cache,
// never issues a live round-trip.
fn restoreFloatingWindows(skip_win: u32) void {
    var it = tracking.windowsOnCurrentWorkspace(skip_win);
    while (it.next()) |entry| {
        const w = entry.win;
        if (!isFreeFloating(w)) continue;
        window.restoreFloatGeom(w);
    }
}

// Set or clear the EWMH _NET_WM_STATE_FULLSCREEN property on `win`.
// Guards on both atoms being valid before touching the property.
// PIPELINE: pub for actions.fullscreenToggle (train b) — EWMH advertisement
// stays protocol-side, exactly like the focus layer until train f.
pub fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or
        g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    const count: u32 = if (is_fullscreen) 1 else 0;
    _ = xcb.xcb_change_property(
        core.getState().conn,
        xcb.XCB_PROP_MODE_REPLACE,
        win,
        g_net_wm_state,
        xcb.XCB_ATOM_ATOM,
        32,
        count,
        if (is_fullscreen) &g_net_wm_state_fullscreen else null,
    );
}

// Commit helpers (XCB-only; caller owns grab/ungrab/flush)

/// Configure `win` at fullscreen geometry (screen-sized, borderless) and raise
/// it. X/Y/WIDTH/HEIGHT/BORDER_WIDTH/STACK_MODE are merged into a single
/// xcb_configure_window call; mirrors layouts.configureWithHintsImpl's raise
/// path: a compositor sees one configure+restack event instead of two.
/// Shared by enterFullscreenCommit and the workspace-switch path in
/// workspaces.zig, which must apply identical geometry to the fullscreen window.
pub fn applyFullscreenGeometry(win: u32) void {
    const cs = core.getState();
    _ = xcb.xcb_configure_window(
        cs.conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH | xcb.XCB_CONFIG_WINDOW_STACK_MODE,
        &[_]u32{
            utils.toXcbCoord(0),
            utils.toXcbCoord(0),
            @intCast(cs.screen.width_in_pixels),
            @intCast(cs.screen.height_in_pixels),
            0, // border_width
            xcb.XCB_STACK_MODE_ABOVE,
        },
    );
    // This raw configure bypasses borders.applyWidth, so the layout cache's
    // applied-border-width bookkeeping must be updated here. Without it the
    // cache still holds the pre-fullscreen width and exitFullscreenCommit's
    // applyBorder dedups against that stale value, skipping the restore send
    // and leaving the window at border width 0 ("lost borders" bug).
    if (build_options.has_tiling) _ = @import("wincache").cacheBorderWidth(win, 0);
}

fn enterFullscreenCommit(win: u32, ws: core.WorkspaceId, geom: utils.Rect) void {
    // A window can only be fullscreen on one workspace: drop stale records on
    // others, or workspaceFor()'s lowest-first scan resolves exit/toggle to
    // the wrong slot.
    dropOtherRecordsFor(win, ws);
    setForWorkspace(ws, .{
        .window = win,
        .saved_geometry = geom,
    });

    // Push every other window offscreen; workspace dispatch is through the shared iterator.
    const conn = core.getState().conn;
    var it = tracking.windowsOnCurrentWorkspace(win);
    while (it.next()) |entry| {
        const w = entry.win;
        utils.pushWindowOffscreen(conn, w);
        // Only invalidate tiled windows; floating windows' cache entries
        // hold the geometry we need to restore on exit.
        if (tracking.isTiledMode(w)) @import("wincache").invalidateGeomCache(w);
    }

    // Configure and raise BEFORE hiding the bar: deferring the bar hide until
    // ConfigureNotify keeps heavy clients (Discord, Electron) from exposing
    // the raw background during their repaint delay.
    applyFullscreenGeometry(win);

    // Evict the fullscreen window's own cache entry: on exit retile it would
    // hit the stale pre-fullscreen rect and skip configure_window, leaving the
    // window stuck at fullscreen dimensions.
    @import("wincache").invalidateGeomCache(win);

    // Cancel any pending deferred bar-show from a previous exit: entering
    // fullscreen again means the bar should stay hidden.
    g_pending_bar_show_win = 0;

    // Arm the deferred bar-hide (see comment above applyFullscreenGeometry).
    g_pending_bar_hide_win = win;

    // Advertise fullscreen state via EWMH so external tools (e.g. compositor
    // scripts) can detect it with xprop / xev.
    setEwmhFullscreenState(win, true);
}

fn exitFullscreenCommit(win: u32, ws: core.WorkspaceId) void {
    const fs_info = getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    // Cancel any in-flight deferred bar hide for this window: the fullscreen
    // transition is being reversed before the ConfigureNotify arrived.
    g_pending_bar_hide_win = 0;

    const saved = fs_info.saved_geometry;

    removeForWorkspace(ws);

    // Bar visibility is managed by the caller (bar.setBarState(.show_fullscreen)).
    // Drawing outside the grab prevents captureStateIntoSlot's implicit flush
    // from delivering xcb_grab_server early and stalling the compositor.

    const win_is_tiled = if (build_options.has_tiling) tiling.isWindowTiled(win) else false;
    // Tiled: geometry managed by tiling engine; applyBorder restores border.
    // Floating: configureWindowGeom restores position + size + border
    // atomically; saveWindowGeom re-syncs the shared geometry cache, which
    // enterFullscreenCommit invalidated on entry. Without this, a fullscreen
    // "switch" (toggle() swapping straight to another window) finds this
    // window's cache entry still invalid right after this restore and parks
    // it at the default position instead of the spot it was just restored to.
    if (!win_is_tiled) {
        window.configureWindowGeom(core.getState().conn, win, saved);
        window.saveWindowGeom(win, .{ .x = saved.x, .y = saved.y, .width = saved.width, .height = saved.height });
    }

    window.applyBorder(win);

    // Clear EWMH fullscreen state so external tools see the window is no longer fullscreen.
    setEwmhFullscreenState(win, false);
}

/// Clean up fullscreen side-effects when moving a fullscreen window: show the
/// bar, restore offscreen floats, reapply border, clear EWMH state. Geometry
/// restoration is the caller's job; `src_ws` must still hold the record.
pub fn cleanupFullscreenForMove(win: u32, src_ws: core.WorkspaceId) void {
    const fs_info = getForWorkspace(src_ws) orelse return;
    if (fs_info.window != win) return;

    // Cancel deferred bar-show if one was in flight for this window.
    g_pending_bar_show_win = 0;
    if (build_options.has_bar) bar.setBarState(.show_fullscreen);
    restoreFloatingWindows(win);
    window.applyBorder(win);
    setEwmhFullscreenState(win, false);
}

/// Enter fullscreen for `win` on the current workspace. Pass pre-computed
/// geometry in `saved_geom` (e.g. restoring a minimized window); null fetches
/// it from the tiling cache or a live round-trip.
// WP6: enterFullscreen/exitFullscreen deleted — actions.fullscreenToggleWindow
// owns the model path (enterFullscreenCommit/exitFullscreenCommit) and the old
// wrappers' only remaining caller (minimize's legacy restore) is gone.

/// Called from the ConfigureNotify handler in events.zig. Drives both deferred
/// bar transitions: hide on confirmed fullscreen dimensions (enter), show on
/// non-fullscreen ones (exit). Safe for every ConfigureNotify; no-ops when
/// nothing is pending or dimensions don't match.
pub fn notifyConfigureIfPending(win: u32, width: u16, height: u16) void {
    const cs = core.getState();
    const screen_w = @as(u16, @intCast(cs.screen.width_in_pixels));
    const screen_h = @as(u16, @intCast(cs.screen.height_in_pixels));

    // Deferred bar hide (enter-fullscreen path): window must report exactly
    // screen dimensions before we hide the bar. Deferred bar show (exit
    // path) must report non-fullscreen dimensions first. The else-if makes
    // the mutual exclusion explicit: both can never match for the same win.
    if (g_pending_bar_hide_win == win) {
        if (width == screen_w and height == screen_h) {
            g_pending_bar_hide_win = 0;
            if (build_options.has_bar) bar.setBarState(.hide_fullscreen);
        }
    } else if (g_pending_bar_show_win == win) {
        if (width != screen_w or height != screen_h) {
            resolvePendingBarShow();
        }
    }
}

fn resolvePendingBarShow() void {
    g_pending_bar_show_win = 0;
    if (build_options.has_bar) bar.setBarState(.show_fullscreen);
}

/// PIPELINE (train b): arm the deferred bar-hide from the new path's
/// fullscreenToggle. Same contract as enterFullscreenCommit's tail.
pub fn armPendingBarHide(win: u32) void {
    g_pending_bar_show_win = 0;
    g_pending_bar_hide_win = win;
}

/// PIPELINE (train b): arm the deferred bar-show after an exit reconcile.
/// Same contract as exitFullscreen's tail (armed AFTER geometry settles).
pub fn armPendingBarShow(win: u32) void {
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = win;
}

/// Called when a window is destroyed; clears its pending deferred bar op so
/// the bar doesn't stay hidden. The hide case is already cleaned by
/// exitFullscreenCommit; this exists for the show case, where the window can
/// be destroyed after exitFullscreen returns but before ConfigureNotify.
pub fn onWindowGone(win: u32) void {
    if (g_pending_bar_show_win == win) resolvePendingBarShow();
}
