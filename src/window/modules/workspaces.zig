//! Workspace state and switching logic.
//! Manages workspace creation, tag operations, focus restoration, and workspace switching.

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

const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;
const tiling = if (build_options.has_tiling) @import("tiling") else null;

const TilingLayout = types.Layout;

pub const Workspace = struct {
    id: u8,
    layout: TilingLayout,
    /// Per-workspace layout-variant override from config; null = global default.
    variants: ?types.LayoutVariantOverride = null,
    /// Master-width override for master-stack layout; null = global default.
    master_width: ?f32 = null,
    /// Master-count override for master-stack layout; null = global default.
    master_count: ?u8 = null,
    /// Master-stack top/bottom balance override (mod+n/mod+o); null = even split (0).
    stack_balance: ?f32 = null,
    /// Window focused here before the user last left; restored on re-entry
    /// when the cursor isn't hovering a window.
    last_focused: ?u32 = null,

    pub fn init(id: u8, default_layout: TilingLayout) Workspace {
        return .{ .id = id, .layout = default_layout };
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
    pub fn next(self: *SetBitIterator) ?core.WorkspaceId {
        if (self.bits == 0) return null;
        const idx: u8 = @intCast(@ctz(self.bits));
        self.bits &= self.bits - 1;
        return core.WorkspaceId.fromIndex(idx);
    }
};
inline fn setBits(mask: u64) SetBitIterator {
    return .{ .bits = mask };
}

/// Evict a window leaving the current workspace (offscreen + cache invalidation).
inline fn evictWindow(win: u32) void {
    utils.pushWindowOffscreen(core.getState().conn, win);
    if (build_options.has_tiling) tiling.invalidateGeomCache(win);
}

/// Moves win's fullscreen record so it stays fullscreen after a tag/move.
/// No-op if win isn't fullscreen anywhere. Cleans up the source workspace's
/// live UI (bar, border) only when leaving `current`.
///
/// Must run BEFORE setWindowMask: that call prunes fullscreen records on
/// workspaces the window is no longer tagged on, so a record relocated here
/// first survives because `new_home` is still tagged. If `new_home` already
/// holds a record for another window, win's record is dropped rather than
/// clobbering it; a window leaving the visible workspace does not displace a
/// resident workspace's fullscreen window.
fn transferFullscreenRecord(win: u32, current: core.WorkspaceId, new_home: core.WorkspaceId) void {
    const src_ws = fullscreen.workspaceFor(win) orelse return;
    if (src_ws.index != current.index) return;
    fullscreen.cleanupFullscreenForMove(win, src_ws);
    if (fullscreen.getForWorkspace(new_home) != null) {
        fullscreen.removeForWorkspace(src_ws);
        return;
    }
    fullscreen.moveRecord(src_ws, new_home);
}

/// Resolved layout + variant override for a single workspace, keyed by
/// workspace index in the flat lookup table built by applyWorkspaceOverrides.
const OverrideLookup = struct {
    layout_idx: usize,
    variant: ?types.LayoutVariantOverride,
};

/// Applies per-workspace layout and master-count overrides from `cfg_tiling`
/// to every workspace in `wss`, falling back to `default_layout` for any
/// workspace without its own override.
///
/// Shared by workspaces.init() (first launch) and tiling.reloadConfig()
/// (config reload / SIGHUP) so config-declared overrides are re-applied
/// identically in both cases; previously reload discarded every override
/// back to the global default because the logic lived inline in init() only.
///
/// `master_width` and `stack_balance` always reset to their global defaults
/// (null): neither has a config-file representation (unlike layout/variant/
/// master_count); they're pure runtime state from adjustMasterWidth and
/// adjustStackBalance, and genuinely should reset on reload.
///
/// `last_focused` (workspace-switch focus restoration) is deliberately
/// untouched: pure interactive runtime state with no config-file concept
/// behind it, so a reload shouldn't disturb it any more than it should
/// disturb the currently-focused window.
pub fn applyWorkspaceOverrides(
    wss: []Workspace,
    cfg_tiling: *const types.TilingConfig,
    default_layout: TilingLayout,
) void {
    const max_ws = constants.max_workspaces;

    var override_lookup: [max_ws]?OverrideLookup = .{null} ** max_ws;
    for (cfg_tiling.workspace_layout_overrides.items) |o| {
        if (o.workspace_idx < max_ws)
            override_lookup[o.workspace_idx] = .{
                .layout_idx = o.layout_idx,
                .variant = o.variant,
            };
    }

    var master_count_lookup: [max_ws]?u8 = .{null} ** max_ws;
    for (cfg_tiling.workspace_master_count_overrides.items) |o| {
        if (o.workspace_idx < max_ws)
            master_count_lookup[o.workspace_idx] = o.count;
    }

    for (wss) |*ws| {
        const id = ws.id;

        var ws_layout = default_layout;
        var ws_variant: ?types.LayoutVariantOverride = null;
        if (id < max_ws) {
            if (override_lookup[id]) |o| {
                if (o.layout_idx < cfg_tiling.layouts.items.len) {
                    const raw = if (build_options.has_tiling) tiling.layoutFromString(cfg_tiling.layouts.items[o.layout_idx]) else null;
                    ws_layout = raw orelse if (build_options.has_tiling) tiling.defaultLayout() else .master;
                }
                ws_variant = o.variant;
            }
        }

        ws.layout = ws_layout;
        ws.variants = ws_variant;
        ws.master_width = null;
        ws.stack_balance = null;
        ws.master_count = if (id < max_ws) master_count_lookup[id] else null;
    }
}

/// Initializes global workspace state. Workspaces-disabled collapses to a
/// single implicit workspace; every switch/tag/move action already no-ops on
/// an out-of-range target, so nothing else needs to branch on this.
pub fn init() !void {
    const cs = core.getState();
    const count = if (cs.config.workspaces.enabled) cs.config.workspaces.count else 1;
    const wss = try cs.alloc.alloc(Workspace, count);

    const default_layout: TilingLayout = if (build_options.has_tiling) tiling.defaultLayout() else .master;
    const cfg_tiling = &cs.config.tiling;

    for (wss, 0..) |*ws, i| {
        const id: u8 = @intCast(i);
        ws.* = Workspace.init(id, default_layout);
    }
    applyWorkspaceOverrides(wss, cfg_tiling, default_layout);

    tracking.setWorkspaceCount(count);
    tracking.setCurrentWorkspace(core.WorkspaceId.fromIndex(0));

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
    tracking.setCurrentWorkspace(core.WorkspaceId.fromIndex(0));
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
            if (ws_idx.index < s.workspaces.len)
                s.workspaces[ws_idx.index].removeAndClearFocus(win);
        }
    }
    tracking.removeWindow(win);
}

pub fn moveWindowTo(win: u32, target_ws: core.WorkspaceId) !void {
    const s = getState() orelse return;
    if (target_ws.index >= s.workspaces.len) {
        debug.err("Invalid target workspace: {}", .{target_ws.index});
        return;
    }

    const mask = tracking.getWindowWorkspaceMask(win) orelse {
        try tracking.registerWindow(win, target_ws);
        return;
    };

    const target_bit = tracking.workspaceBit(target_ws.index);
    if (mask == target_bit) return;

    const new_mask = (mask & ~tracking.workspaceBit(s.current)) | target_bit;
    // Relocate the fullscreen record BEFORE the mask change: setWindowMask's
    // pruneForWorkspaceMask would otherwise drop it (win is no longer tagged
    // on its old workspace), instead of carrying it to the new home.
    transferFullscreenRecord(win, core.WorkspaceId.fromIndex(s.current), target_ws);
    setWindowMask(s, win, new_mask);

    if (minimize.isMinimized(win)) minimize.moveToWorkspace(win, target_ws);

    if (target_ws.index != s.current) {
        // Resolve the refocus target BEFORE the grab (same reasoning as the
        // tagToggle remove-branch below): FocusContext.resolve waits on a
        // blocking WM_PROTOCOLS reply, and running that inside the grab would
        // implicitly flush the queued evict/retile batch to the compositor
        // mid-operation.
        const was_focused = focus.getFocused() == win;
        const refocus_ctx = focus.FocusContext.resolve(
            if (was_focused) focus.findBestAvailable(tracking.isOnCurrentWorkspaceAndVisible) else null,
        );

        // Grab so the evict and retile land in one atomic batch, and retile
        // immediately: peers must reflow now, not whenever some unrelated
        // action happens to trigger retileIfDirty -- until then the workspace
        // shows a hole where `win` used to be.
        utils.grabServer(core.getState().conn);
        evictWindow(win);
        if (was_focused) refocus_ctx.apply(.tiling_operation);
        retileRedrawAndFlush();
    } else {
        // Pin-to-current / mask narrowing: the visible layout is unchanged,
        // only future retiles need to know the pool shifted.
        if (core.getState().config.tiling.enabled) if (build_options.has_tiling) tiling.markDirty();
    }
    if (build_options.has_bar) bar.scheduleRedraw();
}

/// Low-level: set a window's workspace bitmask and clear last_focused on
/// workspaces it just left. Does not touch screen visibility or tiling.
/// Any fullscreen record for `win` on a workspace it no longer occupies is
/// pruned here, so a stale record can never survive a mask change.
fn setWindowMask(s: *State, win: u32, new_mask: u64) void {
    std.debug.assert(new_mask != 0);
    const old_mask = tracking.getWindowWorkspaceMask(win) orelse 0;
    tracking.setWindowMask(win, new_mask);
    fullscreen.pruneForWorkspaceMask(win, new_mask);

    var removed_it = setBits(old_mask & ~new_mask);
    while (removed_it.next()) |idx| {
        if (idx.index < s.workspaces.len)
            s.workspaces[idx.index].removeAndClearFocus(win);
    }
}

/// Retile + redraw + flush, run inside an already-held server grab.
inline fn retileRedrawAndFlush() void {
    const cs = core.getState();
    if (cs.config.tiling.enabled) if (build_options.has_tiling) tiling.retileCurrentWorkspace();
    if (build_options.has_bar) bar.commitInsideGrab() else utils.ungrabAndFlush(cs.conn);
}

/// Remove tag `target_ws` from `win`; the last remaining tag is protected.
fn tagRemove(s: *State, win: u32, target_ws: core.WorkspaceId, target_bit: u64, current_ws: core.WorkspaceId) void {
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;
    if (@popCount(mask) <= 1) return; // last workspace, protect
    const new_mask = mask & ~target_bit;
    if (target_ws.eql(current_ws)) {
        // Leaving the current workspace: hand the fullscreen record to
        // whichever tagged workspace remains lowest. This must run before
        // setWindowMask, whose pruneForWorkspaceMask would drop the record
        // because win is no longer tagged on the old current workspace.
        transferFullscreenRecord(win, current_ws, core.WorkspaceId.fromIndex(@intCast(@ctz(new_mask))));
    }
    setWindowMask(s, win, new_mask);
    if (target_ws.eql(current_ws)) {
        // Unlike the *add* branch (where the window stays visible, so
        // focus correctly stays put, see the doc comment above), `win`
        // is actually leaving the screen here. Leaving focus.getFocused()
        // pointing at it would violate the same "focus is always on the
        // current workspace" invariant minimize's restore fallback used
        // to violate, matches the pattern moveWindowTo already uses for
        // its structurally identical case.
        //
        // Resolve the refocus target and its input model BEFORE the grab
        // below (same reasoning as minimize.zig/restoreWindowImpl):
        // setFocus's blocking WM_PROTOCOLS reply wait must not happen
        // inside the grab, or it would implicitly flush the queued
        // evict/retile batch to the compositor mid-grab, breaking the
        // grab's atomicity. setWindowMask has already run above, so
        // `win` no longer satisfies isOnCurrentWorkspace and can't be
        // picked as its own replacement.
        const was_focused = focus.getFocused() == win;
        const refocus_ctx = focus.FocusContext.resolve(
            if (was_focused) focus.findBestAvailable(tracking.isOnCurrentWorkspaceAndVisible) else null,
        );

        // Grab so the evict and retile land in one atomic batch; the
        // compositor never sees the window gone but peers not yet reflowed.
        utils.grabServer(core.getState().conn);
        evictWindow(win);
        if (was_focused) refocus_ctx.apply(.tiling_operation);
        retileRedrawAndFlush();
    }
}

/// Add tag `target_ws` to `win`, keeping the current workspace tagged too
/// when `protect_current` is set.
fn tagAdd(s: *State, win: u32, target_ws: core.WorkspaceId, target_bit: u64, current_ws: core.WorkspaceId, protect_current: bool) void {
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;
    const new_mask = if (protect_current) mask | target_bit | tracking.workspaceBit(current_ws.index) else mask | target_bit;
    setWindowMask(s, win, new_mask);
    if (target_ws.eql(current_ws)) {
        // Grab so the map and retile land in one atomic batch.
        const conn = core.getState().conn;
        utils.grabServer(conn);
        _ = xcb.xcb_map_window(conn, win);
        retileRedrawAndFlush();
    }
}

/// Toggle workspace tag N on `win` (Mod+Alt+N). Focus is left unchanged so
/// the user can tag multiple workspaces in one gesture. `protect_current`
/// keeps the current workspace tagged too when adding. The last remaining
/// tag can never be cleared.
pub fn tagToggle(win: u32, target_ws: core.WorkspaceId, protect_current: bool) void {
    const s = getState() orelse return;
    if (target_ws.index >= s.workspaces.len) return;
    if (minimize.isMinimized(win)) return;

    const current = s.current;
    const tbit = tracking.workspaceBit(target_ws.index);
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;

    if (mask & tbit != 0) {
        tagRemove(s, win, target_ws, tbit, core.WorkspaceId.fromIndex(current));
    } else {
        tagAdd(s, win, target_ws, tbit, core.WorkspaceId.fromIndex(current), protect_current);
    }
    if (target_ws.index != current) {
        // Off-workspace change: just mark that workspace's geometry stale.
        if (build_options.has_tiling) tiling.invalidateWsGeomBit(target_ws);
        if (build_options.has_bar) bar.scheduleRedraw();
    }
}

pub fn switchTo(ws_id: core.WorkspaceId) void {
    const s = getState() orelse return;
    if (ws_id.index >= s.workspaces.len or ws_id.index == s.current) return;
    exitAllWorkspacesView(s); // no-op if not in all-view
    const old = s.current;
    s.current = ws_id.index;
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
    if (s.all_view_temp_wins.items.len == 0) {
        enterAllView(s);
    } else {
        exitAllView(s);
    }
}

fn exitAllView(s: *State) void {
    // Pointer position is drained before the grab so
    // applyPostSwitchFocus makes no xcb_*_reply call inside it.
    const cs = core.getState();
    const ptr_cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
    const ptr_reply = xcb.xcb_query_pointer_reply(cs.conn, ptr_cookie, null);
    defer if (ptr_reply) |r| std.c.free(r);

    // Pre-resolve the focus target + input model before the grab so the
    // grab body performs no blocking reply waits (see executeSwitch).
    const focus_ctx = focus.FocusContext.resolve(
        resolvePostSwitchFocus(&s.workspaces[s.current], ptr_reply),
    );

    utils.grabServer(cs.conn);
    exitAllWorkspacesView(s);
    // Apply focus BEFORE retiling: exitAllWorkspacesView may have just
    // evicted the still-focused window from this workspace's list, and
    // focus-driven layouts (monocle) read focus.getFocused() at retile
    // time; retiling first would use the stale, now-evicted window with
    // no follow-up retile once focus moves. All windows are already
    // mapped, so applying focus early is safe.
    focus.focusOrClear(focus_ctx.target, focus_ctx.model, .workspace_switch);
    if (cs.config.tiling.enabled) if (build_options.has_tiling) tiling.retileCurrentWorkspace();
    if (build_options.has_bar) bar.raiseBar();
    if (build_options.has_bar) bar.commitInsideGrab() else utils.ungrabAndFlush(cs.conn);
}

fn enterAllView(s: *State) void {
    const cs = core.getState();
    utils.grabServer(cs.conn);

    const cur_bit = tracking.workspaceBit(s.current);
    for (tracking.allWindows()) |entry| {
        if (entry.mask & cur_bit != 0) continue;
        if (minimize.isMinimized(entry.win)) continue;
        const win = entry.win;
        const mask = entry.mask;
        setWindowMask(s, win, mask | cur_bit);
        s.all_view_temp_wins.append(s.allocator, win) catch {
            setWindowMask(s, win, mask);
            continue;
        };
    }

    // Every foreign window is now genuinely on the current workspace. The
    // retile positions tiled ones in the same pass, but it only ever sends
    // configure_window -- windows that registered while their home workspace
    // was hidden were never mapped server-side (registerWindowOffscreen
    // consumed their MapRequest without mapping), so they must be mapped
    // explicitly here, mirroring the floating branch. Mapping an
    // already-mapped window is a harmless server-side no-op.
    if (cs.config.tiling.enabled) {
        for (s.all_view_temp_wins.items) |win| _ = xcb.xcb_map_window(cs.conn, win);
        if (build_options.has_tiling) tiling.retileCurrentWorkspace();
    } else {
        for (s.all_view_temp_wins.items) |win| {
            _ = xcb.xcb_map_window(cs.conn, win);
            window.restoreFloatGeom(win);
        }
    }

    if (build_options.has_bar) bar.scheduleRedraw();
    utils.ungrabAndFlush(cs.conn);
}

/// Shared body for the move_to_all_workspaces and toggle_tag_all actions:
/// toggles `win` between pinned-to-every-workspace and current-workspace-only.
fn pinToAllWorkspacesToggle(s: *State, win: u32) void {
    const cs = core.getState();
    const all_mask = tracking.allWorkspacesMask(s.workspaces.len);
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;

    // Grab covers the mask flip and the map too, so the retile batch lands
    // atomically with the visibility change instead of the map leaking out
    // ahead of it.
    utils.grabServer(cs.conn);
    if (mask == all_mask) {
        setWindowMask(s, win, tracking.workspaceBit(s.current));
    } else {
        setWindowMask(s, win, all_mask);
        _ = xcb.xcb_map_window(cs.conn, win);
    }
    retileRedrawAndFlush();
}

/// `move_to_all_workspaces` and `toggle_tag_all` actions both route here:
/// toggles `win` between pinned-to-every-workspace and current-workspace-only.
pub fn moveWindowToAll(win: u32) void {
    const s = getState() orelse return;
    if (minimize.isMinimized(win)) return;
    pinToAllWorkspacesToggle(s, win);
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
    var it = tracking.onWorkspace(bit, 0);
    while (it.next()) |entry| {
        if (!minimize.isMinimized(entry.win)) return entry.win;
    }
    return null;
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = getState() orelse return null;
    return &s.workspaces[s.current];
}

// -- Workspace switch pipeline -------------------------------------------------
// Runs inside one xcb_grab_server/ungrab pair so the compositor never sees
// old windows offscreen with new windows not yet mapped. Every xcb_*_reply
// call (geometry prefetch, pointer query) happens before the grab, so the
// grab body below is pure fire-and-forget: hide -> restore -> focus -> flush.

/// Pre-grab: save geometry for floating windows leaving the old workspace.
/// Floating placement and drag already keep the geometry cache current, so
/// this only issues a live xcb_get_geometry for the rare window that reaches
/// a switch with no cache entry yet. Must run before the grab; any
/// round-trip here has to complete before the atomic hide/restore begins.
fn prefetchAndSaveWindowGeometries(ws: *const Workspace, new_ws: core.WorkspaceId) void {
    tracking.prefetchAndSaveGeometry(tracking.workspaceBit(ws.id), &prefetchGeometryFilter, 0, new_ws.index);
}

fn prefetchGeometryFilter(win: u32) bool {
    return !(build_options.has_tiling and tiling.isWindowActiveTiled(win)) and !minimize.isMinimized(win);
}

/// Grab step 1: move old-workspace windows offscreen. Windows also tagged to
/// `new_ws` stay put; they're visible on both.
fn hideWorkspaceWindows(ws: *const Workspace, new_ws: core.WorkspaceId) void {
    const conn = core.getState().conn;
    const bit = tracking.workspaceBit(ws.id);
    const tiling_on = build_options.has_tiling and tiling.isEnabled();
    var it = tracking.onWorkspace(bit, 0);
    while (it.next()) |entry| {
        const win = entry.win;
        if (tracking.isWindowOnWorkspace(win, new_ws)) continue;

        utils.pushWindowOffscreen(conn, win);
        if (tiling_on and tiling.isWindowActiveTiled(win)) tiling.invalidateGeomCache(win);
    }
}

/// Grab step 2: restore geometry and map every window on the new workspace.
/// `pending_focus` is the not-yet-applied post-switch target; on a cache miss
/// it's passed to the retile so focus-driven layouts (monocle) show the right
/// window on the first frame instead of reading focus.getFocused(), still
/// the old workspace's window until the real setFocus() below.
fn restoreWorkspaceWindows(ws: *const Workspace, old_ws: core.WorkspaceId, pending_focus: ?u32) void {
    const tiling_active = build_options.has_tiling and tiling.isEnabled();
    const cs = core.getState();
    const conn = cs.conn;
    const bit_map = tracking.workspaceBit(ws.id);

    if (tiling_active) {
        if (!cs.config.tiling.global_layout and build_options.has_tiling) tiling.applyWorkspaceLayout(@ptrCast(ws));

        // On success only windows shared with old_ws need invalidation; on
        // failure invalidate everything tiled for a full retile.
        const restore_ok = build_options.has_tiling and tiling.restoreWorkspaceGeom();
        var it = tracking.onWorkspace(bit_map, 0);
        while (it.next()) |entry| {
            const win = entry.win;
            // Invalidate tiled windows that need it (first pass).
            if (build_options.has_tiling and tiling.isWindowTiled(win)) {
                if (restore_ok and !tracking.isWindowOnWorkspace(win, old_ws)) continue;
                tiling.invalidateGeomCache(win);
            }
            // Map windows that left the screen. Windows also tagged on old_ws
            // never went anywhere (hideWorkspaceWindows skips them), so
            // map_window on them is pure redundant traffic.
            if (!tracking.isWindowOnWorkspace(win, old_ws))
                _ = xcb.xcb_map_window(conn, win);
            if (!minimize.isMinimized(win) and !tracking.isWindowOnWorkspace(win, old_ws) and
                !(build_options.has_tiling and tiling.isWindowActiveTiled(win)))
            {
                window.restoreFloatGeom(win);
            }
        }
        if (!restore_ok) {
            if (pending_focus) |pf| {
                if (build_options.has_tiling) tiling.retileCurrentWorkspaceWithOpts(.{ .focus_override = pf });
            } else {
                if (build_options.has_tiling) tiling.retileCurrentWorkspace();
            }
        }
    } else {
        // Tiling disabled: just map + restore geometry.
        if (build_options.has_tiling and tiling.isFloatingLayout()) {
            // Tiling is off, but a window's cache may have been zeroed the last
            // time it was left while tiling was still active. Try a fast cache
            // restore; fall back to a silent retile that recomputes positions
            // without changing the active layout.
            if (!tiling.restoreWorkspaceGeom()) tiling.retileForRestore();
        }
        var it = tracking.onWorkspace(bit_map, 0);
        while (it.next()) |entry| {
            const win = entry.win;
            // Same shared-with-old-ws skip as the tiling branch above.
            if (!tracking.isWindowOnWorkspace(win, old_ws))
                _ = xcb.xcb_map_window(conn, win);
            if (!minimize.isMinimized(win) and !tracking.isWindowOnWorkspace(win, old_ws))
                window.restoreFloatGeom(win);
        }
    }
}

/// Grab step 3a: resolve (but do not apply) the post-switch focus target.
/// Pure, no side effects, so callers can resolve it early and pass it
/// through to a retile as a pending-focus override before actually applying
/// it. `ptr_reply` is the pre-drained pointer-query reply, so this makes no
/// xcb_*_reply call.
fn resolvePostSwitchFocus(new_ws_obj: *Workspace, ptr_reply: ?*xcb.xcb_query_pointer_reply_t) ?u32 {
    const ptr = ptr_reply orelse return lastFocusedOrFirst(new_ws_obj);
    const child = ptr.*.child;
    return if (child != 0 and child != core.getState().root and
        tracking.isWindowOnWorkspace(child, core.WorkspaceId.fromIndex(new_ws_obj.id)) and !minimize.isMinimized(child))
        child
    else
        lastFocusedOrFirst(new_ws_obj);
}

fn executeSwitch(old_ws: u8, new_ws: core.WorkspaceId) void {
    const s = getState() orelse return;
    const new_ws_obj = &s.workspaces[new_ws.index];
    const fs_info = fullscreen.getForWorkspace(new_ws);

    focus.setSuppressReason(.none);
    focus.cancelPointerSync(); // discard any stale beginPointerSync cookie
    s.workspaces[old_ws].last_focused = focus.getFocused();

    const cs = core.getState();

    // Fire the pointer query early so it's in flight while geometry prefetch
    // drains its pipelined replies, overlapping two round trips into ~1.
    const ptr_cookie = xcb.xcb_query_pointer(cs.conn, cs.root);

    // Pre-grab: drain every xcb_*_reply call so the grab body is
    // fire-and-forget (no implicit flush points for the compositor to catch
    // a partial hide/restore).
    prefetchAndSaveWindowGeometries(&s.workspaces[old_ws], new_ws);

    const ptr_reply = xcb.xcb_query_pointer_reply(cs.conn, ptr_cookie, null);
    defer if (ptr_reply) |r| std.c.free(r);

    const focus_ctx = focus.FocusContext.resolve(resolvePostSwitchFocus(new_ws_obj, ptr_reply));

    utils.grabServer(cs.conn);

    hideWorkspaceWindows(&s.workspaces[old_ws], new_ws);

    if (fs_info != null) (if (build_options.has_bar) bar.setBarState(.hide_fullscreen)) else (if (build_options.has_bar) bar.setBarState(.show_fullscreen));

    if (fs_info) |info| {
        const exec_bit = tracking.workspaceBit(new_ws.index);
        var it = tracking.onWorkspace(exec_bit, info.window);
        while (it.next()) |entry| {
            const win = entry.win;
            _ = xcb.xcb_map_window(cs.conn, win);
            utils.pushWindowOffscreen(cs.conn, win);
            if (build_options.has_tiling and tiling.isWindowActiveTiled(win)) tiling.invalidateGeomCache(win);
        }
        fullscreen.applyFullscreenGeometry(info.window);
    } else {
        restoreWorkspaceWindows(new_ws_obj, core.WorkspaceId.fromIndex(old_ws), focus_ctx.target);
    }

    focus.focusOrClear(focus_ctx.target, focus_ctx.model, .workspace_switch);
    if (build_options.has_bar) bar.raiseBar();
    if (build_options.has_bar) bar.commitInsideGrab() else utils.ungrabAndFlush(cs.conn);
}
