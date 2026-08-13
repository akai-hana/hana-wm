//! Fullscreen management
//! Handles entering, exiting, toggling, and querying fullscreen state for windows.

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
// Note: workspaces dispatch is handled through tracking.workspaceBit /
// tracking.allWindows inside windowsOnCurrentWorkspace; a top-level
// workspaces import is not needed here.

const tiling = @import("tiling");

const bar = @import("bar");

// Fullscreen types

pub const FullscreenInfo = struct {
    window: core.WindowId,
    saved_geometry: core.WindowGeometry,
};

// Module state
//
// g_slots: fixed array keyed by workspace index (u8); O(1) operations, no heap.
// g_float_saves: fixed array with length-bounded reads.

const MAX_WORKSPACES: usize = constants.MAX_WORKSPACES; // single-sourced; keys g_slots
// Intentionally distinct from constants.Limits.MAX_TILED_WINDOWS — bounds
// floating windows saved across a single fullscreen transition, not the pool.
const MAX_FLOAT_SAVES: usize = 64;

var g_slots: [MAX_WORKSPACES]?FullscreenInfo = @splat(null);

const FloatSave = struct { win: u32, rect: utils.Rect };
/// Floating window positions saved before fullscreen enter (by
/// saveFloatingWindowGeoms) and restored on exit. resetState() only resets
/// g_float_saves_len — reads must stay bounded by it to avoid stale data.
var g_float_saves: [MAX_FLOAT_SAVES]FloatSave = std.mem.zeroes([MAX_FLOAT_SAVES]FloatSave);
var g_float_saves_len: usize = 0;

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
// was unavailable — setEwmhFullscreenState's guard already skips the write then.
var g_net_wm_state: xcb.xcb_atom_t = 0;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = 0;

/// Shared reset sequence used by both init() and deinit() to keep them in sync.
fn resetState() void {
    g_slots = @splat(null);
    g_float_saves_len = 0;
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = 0;
    g_net_wm_state = 0;
    g_net_wm_state_fullscreen = 0;
}

/// Returns true when the reply geometry indicates the window is parked
/// offscreen. Used by both saveFloatingWindowGeoms and fetchWindowGeom so
/// the sentinel check is not duplicated.
inline fn isOffscreenReply(r: *const xcb.xcb_get_geometry_reply_t) bool {
    return r.x < constants.OFFSCREEN_SENTINEL_MIN or
        r.y < constants.OFFSCREEN_SENTINEL_MIN;
}

pub fn init() void {
    resetState();

    // Re-resolve the EWMH fullscreen atoms from the shared atom cache rather
    // than interning them again here.
    g_net_wm_state = utils.getAtomCached("_NET_WM_STATE") catch 0;
    g_net_wm_state_fullscreen = utils.getAtomCached("_NET_WM_STATE_FULLSCREEN") catch 0;
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

fn setForWorkspace(ws: u8, info: FullscreenInfo) void {
    g_slots[ws] = info;
}

pub fn removeForWorkspace(ws: u8) void {
    g_slots[ws] = null;
}

/// Drops the record at `ws`, clearing the window's EWMH fullscreen property so
/// external tools stop seeing it as fullscreen. No-op when the slot is empty.
fn dropRecord(ws: u8) void {
    if (g_slots[ws]) |info| {
        setEwmhFullscreenState(info.window, false);
        g_slots[ws] = null;
    }
}

/// Drops any fullscreen record of `win` on a workspace other than `keep_ws`,
/// so a window re-entering fullscreen elsewhere doesn't keep two records —
/// workspaceFor(), which scans lowest-first, would then resolve exit/toggle
/// to the stale slot.
fn dropOtherRecordsFor(win: u32, keep_ws: u8) void {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count], 0..) |*slot, i| {
        if (i == keep_ws) continue;
        if (slot.*) |info| {
            if (info.window == win) {
                setEwmhFullscreenState(win, false);
                slot.* = null;
            }
        }
    }
}

/// After a window's workspace-mask change, drop any fullscreen record on a
/// workspace it's no longer tagged on — a stale record would resurrect bogus
/// fullscreen chrome (hidden bar, offscreen peers) when that workspace is next
/// shown (see executeSwitch in workspaces.zig). Call from every setWindowMask
/// site after the mask is updated.
pub fn pruneForWorkspaceMask(win: u32, new_mask: u64) void {
    const count = tracking.getWorkspaceCount();
    for (g_slots[0..count], 0..) |*slot, i| {
        if (slot.*) |info| {
            if (info.window == win and (new_mask & tracking.workspaceBit(@as(u8, @intCast(i)))) == 0)
                dropRecord(@as(u8, @intCast(i)));
        }
    }
}

/// Transfer the fullscreen record from `src_ws` to `dst_ws`. If `dst_ws`
/// already holds one, the moved record is dropped — never clobber the
/// occupant's state (it would stay visually fullscreen but untracked).
/// Callers handle visual cleanup; workspaces.zig checks the destination too.
pub fn moveRecord(src_ws: u8, dst_ws: u8) void {
    const info = g_slots[src_ws].?;
    if (g_slots[dst_ws] != null) {
        debug.warn("moveRecord: workspace {} already has a fullscreen record; dropping the moved one", .{dst_ws});
        setEwmhFullscreenState(info.window, false);
        g_slots[src_ws] = null;
        return;
    }
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

/// Iterates windows on the current workspace, skipping `skip`. Uses the
/// workspace window list when workspaces are enabled, otherwise falls back
/// to the global window list.
const WorkspaceWindowIter = struct {
    entries: []const tracking.Entry,
    idx: usize = 0,
    skip: u32,
    filtered: bool,
    bit: u64 = 0,

    fn next(self: *@This()) ?u32 {
        while (self.idx < self.entries.len) {
            const entry = self.entries[self.idx];
            self.idx += 1;
            if (self.filtered and entry.mask & self.bit == 0) continue;
            if (entry.win == self.skip) continue;
            return entry.win;
        }
        return null;
    }
};

fn windowsOnCurrentWorkspace(skip: u32) WorkspaceWindowIter {
    if (core.getState().config.workspaces.enabled) {
        const cur = tracking.getCurrentWorkspace() orelse
            return .{ .entries = &.{}, .skip = skip, .filtered = true };
        return .{ .entries = tracking.allWindows(), .skip = skip, .filtered = true, .bit = tracking.workspaceBit(cur) };
    }
    return .{ .entries = tracking.allWindows(), .skip = skip, .filtered = false };
}

// Geometry helpers

/// Retrieve the pre-fullscreen geometry for `win`: tiled windows hit the
/// geometry cache; floating/new windows issue a blocking xcb_get_geometry.
/// Falls back to a centred quarter-screen default if the reply fails, the
/// window is offscreen, or reports zero dimensions.
fn fetchWindowGeom(win: u32) core.WindowGeometry {
    if (tiling.getWindowGeom(win)) |rect| {
        const bw: u16 = if (tiling.getStateOpt()) |ts| ts.config.border_width else 0;
        return .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
            .border_width = bw,
        };
    }

    // Screen dimensions are u16; dividing by a power of two is unambiguous on unsigned values.
    const cs = core.getState();
    const default: core.WindowGeometry = .{
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
    if (isOffscreenReply(reply) or
        reply.*.width == 0 or
        reply.*.height == 0) return default;

    return .{
        .x = reply.*.x,
        .y = reply.*.y,
        .width = reply.*.width,
        .height = reply.*.height,
        .border_width = reply.*.border_width,
    };
}

// Floating geometry save/restore
//
// Positions saved before fullscreen enter so they survive the offscreen-push;
// cookies batched so replies don't block inside the grab.

/// Save the on-screen position of every non-minimized, non-tiled window on
/// the current workspace (except `skip_win`) into g_float_saves. Must run
/// BEFORE xcb_grab_server so the round-trips don't block inside a grab.
fn saveFloatingWindowGeoms(skip_win: u32) void {
    var wins: [MAX_FLOAT_SAVES]u32 = undefined;
    var cookies: [MAX_FLOAT_SAVES]xcb.xcb_get_geometry_cookie_t = undefined;
    var n: usize = 0;
    var truncated: bool = false;

    // Overflow past MAX_FLOAT_SAVES is logged rather than silently dropped.
    var it = windowsOnCurrentWorkspace(skip_win);
    while (it.next()) |w| {
        if (minimize.isMinimized(w)) continue;
        if (tiling.isWindowTiled(w)) continue;
        if (n >= MAX_FLOAT_SAVES) {
            truncated = true;
            continue;
        }
        wins[n] = w;
        cookies[n] = xcb.xcb_get_geometry(core.getState().conn, w);
        n += 1;
    }

    if (truncated) debug.warn(
        "saveFloatingWindowGeoms: more than {d} floating windows on workspace; " ++
            "excess positions will not be restored on fullscreen exit",
        .{MAX_FLOAT_SAVES},
    );

    g_float_saves_len = 0;

    for (wins[0..n], cookies[0..n]) |w, cookie| {
        const reply = xcb.xcb_get_geometry_reply(core.getState().conn, cookie, null) orelse continue;
        defer std.c.free(reply);
        // Skip windows that are already offscreen (e.g. during a fullscreen switch).
        if (isOffscreenReply(reply)) continue;
        g_float_saves[g_float_saves_len] = .{
            .win = w,
            .rect = .{ .x = reply.*.x, .y = reply.*.y, .width = reply.*.width, .height = reply.*.height },
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
/// (except `skip_win`) to its saved position, falling back to
/// moveFloatToDefaultPos. Clears g_float_saves when done.
fn restoreFloatingWindows(skip_win: u32) void {
    var it = windowsOnCurrentWorkspace(skip_win);
    while (it.next()) |w| {
        if (minimize.isMinimized(w)) continue;
        if (tiling.isWindowTiled(w)) continue;
        // Do NOT call window.getWindowGeom here: we are inside xcb_grab_server
        // and a synchronous xcb_get_geometry round-trip would deadlock.
        // Windows absent from g_float_saves fall back to the default position.
        if (getSavedFloatGeom(w)) |r| {
            utils.configureWindow(core.getState().conn, w, r);
        } else {
            window.moveFloatToDefaultPos(w);
        }
    }

    g_float_saves_len = 0;
}

/// Set or clear the EWMH _NET_WM_STATE_FULLSCREEN property on `win`.
/// Guards on both atoms being valid before touching the property.
/// `is_fullscreen = true` → sets the atom; false → clears it (count=0).
fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
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
/// it. Shared by enterFullscreenCommit and the workspace-switch path in
/// workspaces.zig, which must apply identical geometry to the fullscreen window.
pub fn applyFullscreenGeometry(win: u32) void {
    const cs = core.getState();
    window.configureWindowGeom(cs.conn, win, .{
        .x = 0,
        .y = 0,
        .width = @intCast(cs.screen.width_in_pixels),
        .height = @intCast(cs.screen.height_in_pixels),
        .border_width = 0,
    });
    utils.raiseWindow(cs.conn, win);
}

fn enterFullscreenCommit(win: u32, ws: u8, geom: core.WindowGeometry) void {
    // A window can only be fullscreen on one workspace: drop stale records on
    // others, or workspaceFor()'s lowest-first scan resolves exit/toggle to
    // the wrong slot.
    dropOtherRecordsFor(win, ws);
    setForWorkspace(ws, .{
        .window = win,
        .saved_geometry = geom,
    });

    // Push every other window offscreen; workspace dispatch is through the shared iterator.
    var it = windowsOnCurrentWorkspace(win);
    while (it.next()) |w| {
        utils.pushWindowOffscreen(core.getState().conn, w);
        // Only invalidate tiled windows — floating windows' cache entries
        // hold the geometry we need to restore on exit.
        if (tiling.isWindowTiled(w)) tiling.invalidateGeomCache(w);
    }

    // Configure and raise BEFORE hiding the bar: deferring the bar hide until
    // ConfigureNotify keeps heavy clients (Discord, Electron) from exposing
    // the raw background during their repaint delay.
    applyFullscreenGeometry(win);

    // Evict the fullscreen window's own cache entry — on exit retile it would
    // hit the stale pre-fullscreen rect and skip configure_window, leaving the
    // window stuck at fullscreen dimensions.
    tiling.invalidateGeomCache(win);

    // Cancel any pending deferred bar-show from a previous exit: entering
    // fullscreen again means the bar should stay hidden.
    g_pending_bar_show_win = 0;

    // Arm the deferred bar-hide (see comment above configureWindowGeom).
    g_pending_bar_hide_win = win;

    // Advertise fullscreen state via EWMH so external tools (e.g. compositor
    // scripts) can detect it with xprop / xev.
    setEwmhFullscreenState(win, true);
}

fn exitFullscreenCommit(win: u32, ws: u8) void {
    const fs_info = getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    // Cancel any in-flight deferred bar hide for this window — the fullscreen
    // transition is being reversed before the ConfigureNotify arrived.
    g_pending_bar_hide_win = 0;

    const saved = fs_info.saved_geometry;

    removeForWorkspace(ws);

    // Bar visibility is managed by the caller (bar.setBarState(.show_fullscreen)).
    // Drawing outside the grab prevents captureStateIntoSlot's implicit flush
    // from delivering xcb_grab_server early and stalling the compositor.

    const win_is_tiled = tiling.isWindowTiled(win);
    // Tiled: geometry managed by tiling engine; applyBorder restores border.
    // Floating: configureWindowGeom restores position + size + border atomically.
    if (!win_is_tiled) window.configureWindowGeom(core.getState().conn, win, saved);

    window.applyBorder(win);

    // Clear EWMH fullscreen state so external tools see the window is no longer fullscreen.
    setEwmhFullscreenState(win, false);
}

// Public actions

/// Clean up fullscreen side-effects when moving a fullscreen window: show the
/// bar, restore offscreen floats, reapply border, clear EWMH state. Geometry
/// restoration is the caller's job; `src_ws` must still hold the record.
pub fn cleanupFullscreenForMove(win: u32, src_ws: u8) void {
    const fs_info = getForWorkspace(src_ws) orelse return;
    if (fs_info.window != win) return;

    // Cancel deferred bar-show if one was in flight for this window.
    g_pending_bar_show_win = 0;
    bar.setBarState(.show_fullscreen);
    restoreFloatingWindows(win);
    window.applyBorder(win);
    setEwmhFullscreenState(win, false);
}

/// Enter fullscreen for `win` on the current workspace. Pass pre-computed
/// geometry in `saved_geom` (e.g. restoring a minimized window); null fetches
/// it from the tiling cache or a live round-trip.
pub fn enterFullscreen(win: u32, saved_geom: ?core.WindowGeometry) void {
    if (!core.getState().config.fullscreen_enabled) return;
    const ws = tracking.getCurrentWorkspace() orelse return;
    const geom = saved_geom orelse fetchWindowGeom(win);
    saveFloatingWindowGeoms(win);
    const conn = core.getState().conn;
    utils.grabServer(conn);
    enterFullscreenCommit(win, ws, geom);
    utils.ungrabAndFlush(conn);
}

/// Exit fullscreen for `win`. No-op if not currently fullscreen. Targets `win`
/// explicitly (unlike toggle()) for event-driven call sites.
pub fn exitFullscreen(win: u32) void {
    const ws = workspaceFor(win) orelse return;
    // The window was raised on enter; mapping the bar before it repaints at
    // its new tiled size would let it occlude the bar — the mirror image of
    // the enter-path bar-hide race. So the bar show is deferred until the
    // window confirms its non-fullscreen dimensions via ConfigureNotify, like
    // the hide is on enter.
    const conn = core.getState().conn;
    utils.grabServer(conn);
    exitFullscreenCommit(win, ws);
    restoreFloatingWindows(win);
    tiling.retileCurrentWorkspace();
    // Record the pending show AFTER retile so the window ID is set before
    // the grab is released and ConfigureNotify can arrive.
    g_pending_bar_show_win = win;
    utils.ungrabAndFlush(conn);
}

// Round-trips hoisted before xcb_grab_server (replies can't arrive while a
// grab is held). The switch holds one grab across both commits — no
// intermediate frame.
pub fn toggle() void {
    const win = focus.getFocused() orelse return;
    const current_ws = tracking.getCurrentWorkspace() orelse return;

    if (getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            // Toggle off: exit fullscreen for the focused window.
            exitFullscreen(win);
        } else {
            // Switch: fetch geometry before the grab; skip saveFloatingWindowGeoms —
            // windows are already offscreen, so replies would fail the sentinel guard
            // and zero out the still-valid g_float_saves entries.
            const new_geom = fetchWindowGeom(win);
            const conn = core.getState().conn;
            utils.grabServer(conn);
            exitFullscreenCommit(fs_info.window, current_ws);
            // Restore background windows before pushing them offscreen again.
            restoreFloatingWindows(win);
            enterFullscreenCommit(win, current_ws, new_geom);
            utils.ungrabAndFlush(conn);
        }
    } else {
        // Nothing fullscreen on this workspace.
        enterFullscreen(win, null);
    }
}

/// Called from the ConfigureNotify handler in events.zig. Drives both deferred
/// bar transitions — hide on confirmed fullscreen dimensions (enter), show on
/// non-fullscreen ones (exit). Safe for every ConfigureNotify; no-ops when
/// nothing is pending or dimensions don't match.
pub fn notifyConfigureIfPending(win: u32, width: u16, height: u16) void {
    const cs = core.getState();
    const screen_w = @as(u16, @intCast(cs.screen.width_in_pixels));
    const screen_h = @as(u16, @intCast(cs.screen.height_in_pixels));

    // Deferred bar hide (enter-fullscreen path): window must report exactly
    // screen dimensions before we hide the bar.
    if (g_pending_bar_hide_win != 0 and g_pending_bar_hide_win == win) {
        if (width == screen_w and height == screen_h) {
            g_pending_bar_hide_win = 0;
            bar.setBarState(.hide_fullscreen);
        }
        return;
    }

    // Deferred bar show (exit-fullscreen path): window must report dimensions
    // that are no longer fullscreen before we show the bar.  This fires as
    // soon as the retile configure_window is acknowledged — before the
    // window has repainted — so the bar appears exactly when the window
    // starts rendering at its new tiled size.
    if (g_pending_bar_show_win != 0 and g_pending_bar_show_win == win) {
        if (width != screen_w or height != screen_h) {
            g_pending_bar_show_win = 0;
            bar.setBarState(.show_fullscreen);
        }
    }
}

/// Called when a window is destroyed; clears its pending deferred bar op so
/// the bar doesn't stay hidden. The hide case is already cleaned by
/// exitFullscreenCommit — this exists for the show case, where the window can
/// be destroyed after exitFullscreen returns but before ConfigureNotify.
pub fn onWindowGone(win: u32) void {
    if (g_pending_bar_show_win == win) {
        g_pending_bar_show_win = 0;
        bar.setBarState(.show_fullscreen);
    }
}
