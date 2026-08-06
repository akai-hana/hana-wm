//! Workspace management
//! Handles workspace creation, window assignment, and switching between workspaces.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const types = @import("types");
const constants = @import("constants");

const debug = @import("debug");

const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");

const fullscreen = @import("fullscreen");
const minimize = @import("minimize");

const tiling = @import("tiling");
const TilingLayout = tiling.Layout;

const bar = @import("bar");

pub const Workspace = struct {
    id: u8,
    name: []const u8,
    layout: TilingLayout,
    /// Per-workspace layout-variant override from config; null = global default.
    variants: ?types.LayoutVariantOverride = null,
    /// Per-workspace master-width override (master-stack layout); null = global default.
    master_width: ?f32 = null,
    /// Per-workspace master-count override (master-stack layout); null = global default.
    master_count: ?u8 = null,
    /// Per-workspace stack top/bottom balance override (master-stack layout,
    /// mod+n/mod+o); null = even split (0).
    stack_balance: ?f32 = null,
    /// Window focused here before the user last left; restored on re-entry
    /// when the cursor isn't hovering a window.
    last_focused: ?u32 = null,

    pub fn init(id: u8, name: []const u8, default_layout: TilingLayout) Workspace {
        return .{ .id = id, .name = name, .layout = default_layout };
    }

    pub fn removeAndClearFocus(self: *Workspace, win: u32) void {
        if (self.last_focused == win) self.last_focused = null;
    }
};

pub const State = struct {
    workspaces: []Workspace,
    current: u8,
    allocator: std.mem.Allocator,
    /// Windows temporarily patched into the current workspace by switchToAll();
    /// non-empty iff all-workspaces view is active.
    all_view_temp_wins: std.ArrayListUnmanaged(u32) = .empty,
};

var g_state: ?State = null;

pub inline fn getState() ?*State {
    return if (g_state) |*s| s else null;
}

/// Yields the index of each set bit in `mask`, lowest first.
const SetBitIterator = struct {
    bits: u64,
    pub fn next(self: *SetBitIterator) ?u8 {
        if (self.bits == 0) return null;
        const idx: u8 = @intCast(@ctz(self.bits));
        self.bits &= self.bits - 1;
        return idx;
    }
};
inline fn setBits(mask: u64) SetBitIterator {
    return .{ .bits = mask };
}

/// Push `win` offscreen and evict its geometry cache entry, for a window
/// leaving the current workspace.
inline fn evictWindow(win: u32) void {
    utils.pushWindowOffscreen(core.getState().conn, win);
    tiling.invalidateGeomCache(win);
}

/// Moves win's fullscreen record so it stays fullscreen after a tag/move.
/// No-op if win isn't fullscreen anywhere. Cleans up the source workspace's
/// live UI (bar, border) only when leaving `current` — other workspaces have
/// no live fullscreen chrome to clean up. `force`: follow `new_home` even
/// when fullscreen on some other, non-current workspace — used when `win` is
/// being detached from every workspace except `new_home`.
fn transferFullscreenRecord(win: u32, current: u8, new_home: u8, force: bool) void {
    const src_ws = fullscreen.workspaceFor(win) orelse return;
    if (src_ws == current) {
        fullscreen.cleanupFullscreenForMove(win, src_ws);
        fullscreen.moveRecord(src_ws, new_home);
    } else if (force) {
        fullscreen.moveRecord(src_ws, new_home);
    }
}

/// Initializes global workspace state. Workspaces-disabled collapses to a
/// single implicit workspace; every switch/tag/move action already no-ops on
/// an out-of-range target, so nothing else needs to branch on this.
pub fn init() !void {
    const cs = core.getState();
    const count = if (cs.config.workspaces.enabled) cs.config.workspaces.count else 1;
    const wss = try cs.alloc.alloc(Workspace, count);

    const default_layout: TilingLayout = tiling.getState().config.layout;
    const cfg_tiling = &cs.config.tiling;

    // Flatten the override lists into O(1)-lookup arrays, capped at 64
    // workspaces by the u64 tag bitmask used everywhere else.
    const MAX_WS = 64;
    const OverrideLookup = struct {
        layout_idx: usize,
        variant: ?types.LayoutVariantOverride,
    };
    var override_lookup: [MAX_WS]?OverrideLookup = .{null} ** MAX_WS;
    for (cfg_tiling.workspace_layout_overrides.items) |o| {
        if (o.workspace_idx < MAX_WS)
            override_lookup[o.workspace_idx] = .{
                .layout_idx = o.layout_idx,
                .variant = o.variant,
            };
    }

    var master_count_lookup: [MAX_WS]?u8 = .{null} ** MAX_WS;
    for (cfg_tiling.workspace_master_count_overrides.items) |o| {
        if (o.workspace_idx < MAX_WS)
            master_count_lookup[o.workspace_idx] = o.count;
    }

    for (wss, 0..) |*ws, i| {
        const id: u8 = @intCast(i);
        const name = if (i < tracking.WORKSPACE_LABELS.len) tracking.WORKSPACE_LABELS[i] else "?";

        var ws_layout = default_layout;
        var ws_variant: ?types.LayoutVariantOverride = null;
        if (id < MAX_WS) {
            if (override_lookup[id]) |o| {
                if (o.layout_idx < cfg_tiling.layouts.items.len)
                    ws_layout = tiling.layoutFromString(cfg_tiling.layouts.items[o.layout_idx]) orelse tiling.defaultLayout();
                ws_variant = o.variant;
            }
        }

        ws.* = Workspace.init(id, name, ws_layout);
        ws.variants = ws_variant;
        if (id < MAX_WS) {
            if (master_count_lookup[id]) |mc| ws.master_count = mc;
        }
    }

    tracking.setWorkspaceCount(count);
    tracking.setCurrentWorkspace(0);

    g_state = .{
        .workspaces = wss,
        .current = 0,
        .allocator = cs.alloc,
    };
}

pub fn deinit() void {
    if (g_state) |*s| {
        s.all_view_temp_wins.deinit(s.allocator);
        s.allocator.free(s.workspaces);
    }
    g_state = null;
    // setCurrentWorkspace asserts ws < g_workspace_count, so it must run
    // before setWorkspaceCount(0) zeroes that bound out from under it.
    tracking.setCurrentWorkspace(0);
    tracking.setWorkspaceCount(0);
}

pub fn removeWindow(win: u32) void {
    const s = getState() orelse {
        tracking.removeWindow(win);
        return;
    };
    if (tracking.getWindowWorkspaceMask(win)) |mask| {
        var it = setBits(mask);
        while (it.next()) |ws_idx| {
            if (ws_idx < s.workspaces.len)
                s.workspaces[ws_idx].removeAndClearFocus(win);
        }
    }
    tracking.removeWindow(win);
}

pub fn moveWindowTo(win: u32, target_ws: u8) !void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) {
        debug.err("Invalid target workspace: {}", .{target_ws});
        return;
    }

    const mask = tracking.getWindowWorkspaceMask(win) orelse {
        try tracking.registerWindow(win, target_ws); // new window: register in tracking
        return;
    };

    const target_bit = tracking.workspaceBit(target_ws);
    if (mask == target_bit) return;

    // new_mask is always non-zero: target_bit is always set.
    const new_mask = (mask & ~tracking.workspaceBit(s.current)) | target_bit;
    setWindowMask(s, win, new_mask);

    if (minimize.isMinimized(win)) minimize.moveToWorkspace(win, target_ws);
    transferFullscreenRecord(win, s.current, target_ws, false);

    if (target_ws != s.current) {
        evictWindow(win);
        if (focus.getFocused() == win) focus.clearFocus();
    }
    if (core.getState().config.tiling.enabled) tiling.markDirty();
    bar.scheduleRedraw();
    // No flush: the window has never been mapped, so evictWindow's offscreen
    // configure has no visible effect; the event loop flushes at end-of-batch.
}

// Tag operations

/// Low-level: set a window's workspace bitmask and clear last_focused on
/// workspaces it just left. Does not touch screen visibility or tiling.
fn setWindowMask(s: *State, win: u32, new_mask: u64) void {
    std.debug.assert(new_mask != 0);
    const old_mask = tracking.getWindowWorkspaceMask(win) orelse 0;
    tracking.setWindowMask(win, new_mask);

    var removed_it = setBits(old_mask & ~new_mask);
    while (removed_it.next()) |idx| {
        if (idx < s.workspaces.len)
            s.workspaces[idx].removeAndClearFocus(win);
    }
}

/// Retile + redraw + flush, run inside an already-held server grab.
inline fn retileRedrawAndFlush() void {
    const cs = core.getState();
    if (cs.config.tiling.enabled) tiling.retileCurrentWorkspace();
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(cs.conn);
}

/// Grab, retile, redraw, flush — for callers with no per-window op to
/// perform before the retile.
inline fn retileAndScheduleFlush() void {
    _ = xcb.xcb_grab_server(core.getState().conn);
    retileRedrawAndFlush();
}

/// `move_window` action (Mod+Shift+N): hard-moves `win` to `target_ws`
/// exclusively, clearing all other workspace bits.
pub fn moveWindowExclusive(win: u32, target_ws: u8) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (minimize.isMinimized(win)) return;

    const mask = tracking.getWindowWorkspaceMask(win) orelse return;
    if (mask == tracking.workspaceBit(target_ws)) return; // already exclusive there

    transferFullscreenRecord(win, s.current, target_ws, true);
    setWindowMask(s, win, tracking.workspaceBit(target_ws));

    if (target_ws != s.current) {
        evictWindow(win);
        if (focus.getFocused() == win) focus.clearFocus();
    }

    retileAndScheduleFlush();
}

/// Toggle workspace tag N on `win` (Mod+Alt+N). Focus is left unchanged so
/// the user can tag multiple workspaces in one gesture. `protect_current`
/// keeps the current workspace tagged too when adding. The last remaining
/// tag can never be cleared.
pub fn tagToggle(win: u32, target_ws: u8, protect_current: bool) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (minimize.isMinimized(win)) return;

    const current = s.current;
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;
    const tbit = tracking.workspaceBit(target_ws);

    if (mask & tbit != 0) {
        // Remove tag N.
        if (@popCount(mask) <= 1) return; // last workspace — protect
        const new_mask = mask & ~tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            // Leaving the current workspace: if fullscreen here, hand the
            // record to whichever tagged workspace remains lowest.
            transferFullscreenRecord(win, current, @intCast(@ctz(new_mask)), false);
            // Grab so the evict and retile land in one atomic batch — the
            // compositor never sees the window gone but peers not yet reflowed.
            _ = xcb.xcb_grab_server(core.getState().conn);
            evictWindow(win);
            retileRedrawAndFlush();
        } else {
            tiling.invalidateWsGeomBit(target_ws);
            bar.scheduleRedraw();
        }
    } else {
        // Add tag N.
        const new_mask = if (protect_current) mask | tbit | tracking.workspaceBit(current) else mask | tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            // Grab so the map and retile land in one atomic batch.
            const conn = core.getState().conn;
            _ = xcb.xcb_grab_server(conn);
            _ = xcb.xcb_map_window(conn, win);
            retileRedrawAndFlush();
        } else {
            tiling.invalidateWsGeomBit(target_ws);
            bar.scheduleRedraw();
        }
    }
}

// Workspace switch

pub fn switchTo(ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    exitAllWorkspacesView(s); // no-op if not in all-view
    const old = s.current;
    s.current = ws_id;
    tracking.setCurrentWorkspace(ws_id);
    executeSwitch(old, ws_id);
}

/// Strips the current-workspace bit from every window in
/// `s.all_view_temp_wins`, evicts each, and clears the list.
fn exitAllWorkspacesView(s: *State) void {
    if (s.all_view_temp_wins.items.len == 0) return;
    const current = s.current;
    for (s.all_view_temp_wins.items) |win| {
        const mask = tracking.getWindowWorkspaceMask(win) orelse continue;
        const restored = mask & ~tracking.workspaceBit(current);
        if (restored == 0) continue; // never leave a window with an empty mask
        setWindowMask(s, win, restored);
        evictWindow(win);
    }
    s.all_view_temp_wins.clearRetainingCapacity();
}

/// `all_workspaces` action (Mod+5): toggles a view where every window from
/// every workspace is visible at once, by temporarily tagging foreign
/// windows onto the current workspace.
pub fn switchToAll() void {
    const s = getState() orelse return;

    if (s.all_view_temp_wins.items.len > 0) {
        // Exit. Pointer position is drained before the grab so
        // applyPostSwitchFocus makes no xcb_*_reply call inside it.
        const cs = core.getState();
        const ptr_cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
        const ptr_reply = xcb.xcb_query_pointer_reply(cs.conn, ptr_cookie, null);
        defer if (ptr_reply) |r| std.c.free(r);

        _ = xcb.xcb_grab_server(cs.conn);
        exitAllWorkspacesView(s);
        // Resolve and apply focus BEFORE retiling: exitAllWorkspacesView may
        // have just evicted the still-focused window from this workspace's
        // list, and focus-driven layouts (monocle) pick their visible window
        // from focus.getFocused() at retile time — retiling first would use
        // the stale, now-evicted window with no follow-up retile once focus
        // actually moves. All windows here are already mapped, so it's safe
        // to apply focus ahead of the retile.
        applyPostSwitchFocus(resolvePostSwitchFocus(&s.workspaces[s.current], ptr_reply));
        if (cs.config.tiling.enabled) tiling.retileCurrentWorkspace();
        bar.raiseBar();
        bar.redrawInsideGrab();
        utils.ungrabAndFlush(cs.conn);
    } else {
        // Enter.
        const cs = core.getState();
        _ = xcb.xcb_grab_server(cs.conn);

        for (tracking.allWindows()) |entry| {
            if (tracking.isWindowOnWorkspace(entry.win, s.current)) continue;
            if (minimize.isMinimized(entry.win)) continue;
            const win = entry.win;
            const mask = entry.mask;
            setWindowMask(s, win, mask | tracking.workspaceBit(s.current));
            s.all_view_temp_wins.append(s.allocator, win) catch {
                setWindowMask(s, win, mask);
                continue;
            };
        }

        // Every foreign window is now genuinely on the current workspace;
        // retile handles mapping + positioning for tiled ones in one pass.
        if (cs.config.tiling.enabled) {
            tiling.retileCurrentWorkspace();
        } else {
            for (s.all_view_temp_wins.items) |win| {
                _ = xcb.xcb_map_window(cs.conn, win);
                window.restoreFloatGeom(win);
            }
        }

        bar.scheduleRedraw();
        utils.ungrabAndFlush(cs.conn);
    }
}

/// Shared body for moveWindowToAll / tagToggleAll: toggles `win` between
/// pinned-to-every-workspace and current-workspace-only.
fn pinToAllWorkspacesToggle(s: *State, win: u32) void {
    const all_mask = tracking.allWorkspacesMask(s.workspaces.len);
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;

    if (mask == all_mask) {
        setWindowMask(s, win, tracking.workspaceBit(s.current));
    } else {
        setWindowMask(s, win, all_mask);
        _ = xcb.xcb_map_window(core.getState().conn, win);
    }

    retileAndScheduleFlush();
}

/// `move_to_all_workspaces` action (Mod+Shift+5).
pub fn moveWindowToAll(win: u32) void {
    const s = getState() orelse return;
    if (minimize.isMinimized(win)) return;
    pinToAllWorkspacesToggle(s, win);
}

/// `toggle_tag_all` action (Mod+Alt+5). Same semantics as moveWindowToAll —
/// two key chords for user convenience, sharing one implementation so any
/// future behavioural change only needs updating in one place.
pub fn tagToggleAll(win: u32) void {
    const s = getState() orelse return;
    if (minimize.isMinimized(win)) return;
    pinToAllWorkspacesToggle(s, win);
}

pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    return tracking.getWindowWorkspaceMask(win);
}

pub inline fn isWindowOnWorkspace(win: u32, ws_idx: u8) bool {
    return tracking.isWindowOnWorkspace(win, ws_idx);
}

pub inline fn firstNonMinimized(windows: []const u32) ?u32 {
    return tracking.firstNonMinimized(windows);
}

/// The workspace's remembered focus target, falling back to the first
/// non-minimized window. Clears last_focused when it points at a now-
/// minimized window so the stale pointer isn't rechecked every call.
inline fn lastFocusedOrFirst(ws: *Workspace) ?u32 {
    if (ws.last_focused) |win| {
        if (!minimize.isMinimized(win)) return win;
        ws.last_focused = null;
    }
    const bit = tracking.workspaceBit(ws.id);
    for (tracking.allWindows()) |entry| {
        if (entry.mask & bit == 0) continue;
        if (!minimize.isMinimized(entry.win)) return entry.win;
    }
    return null;
}

pub inline fn getCurrentWorkspace() ?u8 {
    return tracking.getCurrentWorkspace();
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    return tracking.isOnCurrentWorkspace(win);
}

/// True when `win` is on the current workspace and not minimized. Used by
/// focus.focusBestAvailable as a typed `*const fn(u32) bool` predicate.
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    return tracking.isOnCurrentWorkspaceAndVisible(win);
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = getState() orelse return null;
    return &s.workspaces[s.current];
}

pub inline fn getWorkspaceCount() usize {
    const s = getState() orelse return 0;
    return s.workspaces.len;
}

/// Lowest-set-bit workspace index for `win`.
pub inline fn getWorkspaceForWindow(win: u32) ?u8 {
    return tracking.getWorkspaceForWindow(win);
}

pub fn isManaged(win: u32) bool {
    return tracking.isManaged(win);
}

// ── Workspace switch pipeline ────────────────────────────────────────────
// Runs inside one xcb_grab_server/ungrab pair so the compositor never sees
// old windows offscreen with new windows not yet mapped. Every xcb_*_reply
// call (geometry prefetch, pointer query) happens before the grab, so the
// grab body below is pure fire-and-forget: hide → restore → focus → flush.

/// Pre-grab: save geometry for floating windows leaving the old workspace.
/// Floating placement and drag already keep the geometry cache current, so
/// this only issues a live xcb_get_geometry for the rare window that reaches
/// a switch with no cache entry yet. Must run before the grab — any
/// round-trip here has to complete before the atomic hide/restore begins.
fn prefetchAndSaveWindowGeometries(ws: *const Workspace, new_ws: u8) void {
    const conn = core.getState().conn;
    const bit = tracking.workspaceBit(ws.id);
    for (tracking.allWindows()) |entry| {
        const win = entry.win;
        if (entry.mask & bit == 0) continue;
        if (tracking.isWindowOnWorkspace(win, new_ws)) continue; // stays visible
        if (tiling.isWindowActiveTiled(win) or minimize.isMinimized(win)) continue;
        if (tiling.getWindowGeom(win) != null) continue; // cache already correct

        const reply = xcb.xcb_get_geometry_reply(conn, xcb.xcb_get_geometry(conn, win), null) orelse continue;
        defer std.c.free(reply);
        window.saveWindowGeom(win, .{
            .x = reply.*.x,
            .y = reply.*.y,
            .width = reply.*.width,
            .height = reply.*.height,
        });
    }
}

/// Grab step 1: move old-workspace windows offscreen. Windows also tagged to
/// `new_ws` stay put — they're visible on both.
fn hideWorkspaceWindows(ws: *const Workspace, new_ws: u8) void {
    const conn = core.getState().conn;
    const bit = tracking.workspaceBit(ws.id);
    for (tracking.allWindows()) |entry| {
        const win = entry.win;
        if (entry.mask & bit == 0) continue;
        if (tracking.isWindowOnWorkspace(win, new_ws)) continue;

        utils.pushWindowOffscreen(conn, win);
        if (tiling.isWindowActiveTiled(win)) tiling.invalidateGeomCache(win);
    }
}

/// Grab step 2: restore geometry and map every window on the new workspace.
/// `pending_focus` is the not-yet-applied post-switch focus target (see
/// resolvePostSwitchFocus); on a cache miss this is passed through to the
/// retile so focus-driven layouts (monocle) show the right window on the
/// first frame, instead of reading focus.getFocused() — which at this point
/// still reports the old workspace's focused window, since the real
/// focus.setFocus() call happens only after every window here is mapped.
fn restoreWorkspaceWindows(ws: *const Workspace, old_ws: u8, pending_focus: ?u32) void {
    const tiling_active = tiling.getState().is_enabled;

    if (tiling_active) {
        if (!core.getState().config.tiling.global_layout) tiling.applyWorkspaceLayout(ws);

        // On success only windows shared with old_ws need invalidation; on
        // failure invalidate everything tiled for a full retile.
        const restore_ok = tiling.restoreWorkspaceGeom();
        const bit = tracking.workspaceBit(ws.id);
        for (tracking.allWindows()) |entry| {
            const win = entry.win;
            if (entry.mask & bit == 0) continue;
            if (!tiling.isWindowTiled(win)) continue;
            if (restore_ok and !tracking.isWindowOnWorkspace(win, old_ws)) continue;
            tiling.invalidateGeomCache(win);
        }
        if (!restore_ok) {
            if (pending_focus) |pf|
                tiling.retileCurrentWorkspaceWithPendingFocus(pf)
            else
                tiling.retileCurrentWorkspace();
        }
    } else if (tiling.isFloatingLayout()) {
        // Tiling is off, but a window's cache may have been zeroed the last
        // time it was left while tiling was still active. Try a fast cache
        // restore first; fall back to a silent retile (bypassing the
        // !enabled guard) to recompute positions without changing the
        // active layout or moving anything permanently.
        if (!tiling.restoreWorkspaceGeom()) tiling.retileForRestore();
    }

    const bit_map = tracking.workspaceBit(ws.id);
    const conn = core.getState().conn;
    for (tracking.allWindows()) |entry| {
        const win = entry.win;
        if (entry.mask & bit_map == 0) continue;
        _ = xcb.xcb_map_window(conn, win);
        if (!tiling.isWindowActiveTiled(win) and !minimize.isMinimized(win) and
            !tracking.isWindowOnWorkspace(win, old_ws))
        {
            window.restoreFloatGeom(win);
        }
    }
}

/// Grab step 3a: resolve (but do not apply) the post-switch focus target.
/// Pure — no side effects — so callers can resolve it early and pass it
/// through to a retile as a pending-focus override before actually applying
/// it. `ptr_reply` is the pre-drained pointer-query reply, so this makes no
/// xcb_*_reply call.
fn resolvePostSwitchFocus(new_ws_obj: *Workspace, ptr_reply: ?*xcb.xcb_query_pointer_reply_t) ?u32 {
    const ptr = ptr_reply orelse return lastFocusedOrFirst(new_ws_obj);
    const child = ptr.*.child;
    return if (child != 0 and child != core.getState().root and
        tracking.isWindowOnWorkspace(child, new_ws_obj.id) and !minimize.isMinimized(child))
        child
    else
        lastFocusedOrFirst(new_ws_obj);
}

/// Grab step 3b: apply an already-resolved post-switch focus target. Skips
/// the mapped-check and raise that focus.setFocus would normally do — every
/// window here is already mapped and a workspace switch never raises.
///
/// Route through focus.setFocus/clearFocus so commitFocusTransition runs
/// its full side-effect list (MRU history, tiling border state, carousel
/// notification, _NET_ACTIVE_WINDOW, button-grab transfer, input focus).
fn applyPostSwitchFocus(focus_target: ?u32) void {
    if (focus_target) |new_win| {
        focus.setFocus(new_win, .workspace_switch);
    } else {
        focus.clearFocus();
    }
}

fn executeSwitch(old_ws: u8, new_ws: u8) void {
    const s = getState() orelse return;
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info = fullscreen.getForWorkspace(new_ws);

    focus.setSuppressReason(.none);
    focus.cancelPointerSync(); // discard any stale beginPointerSync cookie
    s.workspaces[old_ws].last_focused = focus.getFocused();

    // Pre-grab: drain every xcb_*_reply call so the grab body is
    // fire-and-forget (no implicit flush points for the compositor to catch
    // a partial hide/restore).
    prefetchAndSaveWindowGeometries(&s.workspaces[old_ws], new_ws);

    const cs = core.getState();
    const ptr_cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
    const ptr_reply = xcb.xcb_query_pointer_reply(cs.conn, ptr_cookie, null);
    defer if (ptr_reply) |r| std.c.free(r);

    _ = xcb.xcb_grab_server(cs.conn);

    hideWorkspaceWindows(&s.workspaces[old_ws], new_ws);

    if (fs_info != null) bar.setBarState(.hide_fullscreen) else bar.setBarState(.show_fullscreen);

    if (fs_info) |info| {
        // Map and push offscreen every non-fullscreen window on this
        // workspace, so exiting fullscreen later never finds a stale
        // zero-rect cache entry. Tiled windows are invalidated for the next retile.
        const exec_bit = tracking.workspaceBit(new_ws);
        for (tracking.allWindows()) |entry| {
            if (entry.mask & exec_bit == 0) continue;
            const win = entry.win;
            if (win == info.window) continue;
            _ = xcb.xcb_map_window(cs.conn, win);
            utils.pushWindowOffscreen(cs.conn, win);
            if (tiling.isWindowActiveTiled(win)) tiling.invalidateGeomCache(win);
        }
        _ = xcb.xcb_configure_window(cs.conn, info.window, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{ 0, 0, @intCast(cs.screen.width_in_pixels), @intCast(cs.screen.height_in_pixels), 0 });
        _ = xcb.xcb_configure_window(cs.conn, info.window, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
        applyPostSwitchFocus(resolvePostSwitchFocus(new_ws_obj, ptr_reply));
    } else {
        // Resolve before restoring: on a geometry-cache miss,
        // restoreWorkspaceWindows falls back to a full retile, and
        // focus-driven layouts (monocle) need to know the intended focus
        // target at that point rather than reading the stale pre-switch
        // focus. The actual focus.setFocus() call still happens below,
        // after every window is mapped.
        const focus_target = resolvePostSwitchFocus(new_ws_obj, ptr_reply);
        restoreWorkspaceWindows(new_ws_obj, old_ws, focus_target);
        applyPostSwitchFocus(focus_target);
    }

    bar.raiseBar();
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(cs.conn);
}