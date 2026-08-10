//! Tiling window manager
//! Orchestrates window layout, tracking, and border management for all tiled windows.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const types = @import("types");
const constants = @import("constants");

const debug = @import("debug");

const tracking = @import("tracking");
const focus = @import("focus");

const layouts = @import("layouts");
const floating = @import("floating");

const fullscreen = @import("fullscreen");
const workspaces = @import("workspaces");
const WsState = workspaces.State;
const WsWorkspace = workspaces.Workspace;

const bar = @import("bar");

const scale = @import("scale");

const master = @import("master");
const monocle = @import("monocle");
const grid = @import("grid");
const fibonacci = @import("fibonacci");
const leaf = @import("leaf");
const scroll = @import("scroll");

// Module constants

const max_master_width_ratio: f32 = 0.95; // prevents master from consuming the full screen
const max_master_count: u8 = 10;
// Per-retile window list capacity. A single workspace can never hold more
// tiled windows than the global pool (tracking.Tracking, s.windows below)
// allows, so scratch_wins below is always large enough.
const max_workspace_windows: usize = constants.Limits.MAX_TILED_WINDOWS;
// Single-sourced in constants.zig: also matches workspaces.zig's fixed-size
// override lookup tables and the u64 workspace_geom_valid_bits bitmask below.
const max_workspaces: usize = constants.MAX_WORKSPACES;

// Public types

/// Defined in types.zig (see its doc comment for why) so config.zig and
/// workspaces.zig can resolve layout names without a circular import;
/// re-exported here so every existing `tiling.Layout` call site is unaffected.
pub const Layout = types.Layout;

// Variant enums are defined in types.zig to allow config.zig to parse them
// without a circular import. Short private aliases for the struct fields below.
const MasterVariant = types.MasterVariant;
const MonocleVariant = types.MonocleVariant;
const GridVariant = types.GridVariant;

pub const LayoutVariants = struct {
    master: MasterVariant = .lifo,
    monocle: MonocleVariant = .gapless,
    grid: GridVariant = .rigid,
};

/// Scroll-layout runtime state, defined in scroll.zig alongside the scroll
/// layout's other logic.
const ScrollState = scroll.State;

/// Layout configuration: all user-adjustable parameters that control which
/// layout is active and how it sizes windows.  Functions that only need to
/// read or modify layout behaviour should accept *LayoutConfig (or
/// *const LayoutConfig) rather than *State to make their dependencies explicit.
pub const LayoutConfig = struct {
    layout: Layout,
    layout_variants: LayoutVariants,
    master_side: types.MasterSide,
    master_width: f32,
    master_count: u8,
    /// Master layout only: signed balance between the stack's top and bottom
    /// slave slots. 0 = even split (default). Positive grows the topmost
    /// slave's share (mod+n), negative grows the bottommost's (mod+o) — see
    /// master.zig's tileWithOffset for how this maps to per-slot weights.
    /// A single signed scalar (rather than two independent boosts) means
    /// mod+n/mod+o partially undo each other instead of compounding to
    /// squeeze the windows in between toward zero.
    stack_balance: f32,
    gap_width: u16,
    border_width: u16,
    border_focused: u32,
    border_unfocused: u32,

    /// Runtime layout cycle: intersection of config `layouts` and disk-present
    /// layout files. `stepLayout` walks this so layouts omitted from the
    /// config are invisible at runtime even if their .zig file exists on disk.
    enabled_layouts: [types.LAYOUT_TABLE.len]Layout,
    enabled_layout_count: u8,
};

/// Geometry cache: workspace validity tracking, the per-window rect/border/hints
/// hash table, and the scratch buffer reused across retile calls.  Functions
/// that only touch cached geometry should accept *GeomCache rather than *State.
pub const GeomCache = struct {
    /// Per-window cache storing last geometry AND last border color in a single
    /// open-addressing hash table. Populated by configureWithHints (rect) and
    /// applyBorderColor (border). O(1) lookup per window per retile.
    cache: layouts.CacheMap,

    /// Per-workspace geometry validity bitmask (64 bits -> up to 64 workspaces).
    ///
    /// Bit N is set when workspace N's geometry has been pre-computed and the
    /// cache holds correct on-screen positions for all its windows.
    ///
    /// Cleared by: addWindow, removeWindow, adjustMasterWidth, growTopSlave,
    /// growBottomSlave, applyWorkspaceLayout.
    /// Set by the retile call that immediately follows each of those.
    workspace_geom_valid_bits: u64,

    /// Screen area used in the most recent retile call. restoreWorkspaceGeom
    /// rejects the cache when this differs from the current area (e.g. after a
    /// bar height or position change).
    last_retile_area: utils.Rect,

    /// Single-workspace window list, reused across retile calls (BSS, zero
    /// allocation) instead of collecting into a fresh per-call buffer.
    /// Background retiles reuse this same buffer once per workspace in their
    /// loop rather than a flattened `[workspaces][windows]` array — window
    /// and workspace counts are both small and bounded, so the O(workspaces
    /// × windows) it costs is negligible, and it avoids the ~50 KB a
    /// flattened buffer would need.
    scratch_wins: [max_workspace_windows]u32,
};

pub const State = struct {
    /// Mirrors config.tiling.enabled at init/reload; there is no runtime
    /// toggle. When false the tiler is dormant: retiles replay cached geometry
    /// and windows are free to move on their own.
    is_enabled: bool,
    is_dirty: bool,

    config: LayoutConfig,
    windows: tracking.Tracking,
    geom: GeomCache,

    /// Scroll-layout runtime state; dormant (but preserved) when layout != .scroll.
    scroll: ScrollState,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.config.gap_width, .border = self.config.border_width };
    }

    /// Returns the border color for `win`: 0 for fullscreen windows, focused or
    /// unfocused color otherwise.
    pub inline fn borderColor(self: *const State, win: u32) u32 {
        if (fullscreen.isFullscreen(win)) return 0;
        return if (focus.getFocused() == win) self.config.border_focused else self.config.border_unfocused;
    }
};

// Module-level singleton

// Null before init(), non-null for the rest of the process lifetime.
// Using ?State rather than (State + bool) makes pre-init access a safe
// runtime @panic in all build modes, not UB in ReleaseFast.
var state: ?State = null;

/// Returns a pointer to the live tiling state.
/// Panics in all build modes when called before init() — never silent UB.
pub inline fn getState() *State {
    if (state) |*s| return s;
    @panic("tiling: getState() called before init()");
}

/// Safe pre-init query for code that may run before the event loop starts.
/// Returns null only during the narrow startup window before `init()` is called.
pub inline fn getStateOpt() ?*State {
    return if (state) |*s| s else null;
}

// Lifecycle

pub fn init() void {
    state = initState();
}

pub fn deinit() void {
    if (state) |*s| s.geom.cache.deinit();
    state = null;
}

pub fn reloadConfig() void {
    const s = getState();
    const saved_windows = s.windows;
    s.geom.cache.deinit();

    // Config changes invalidate every cached rect and border color, so we
    // want the fresh empty cache initState produces. The only field that
    // must survive the rebuild is the live window list.
    var new_state = initState();
    new_state.windows = saved_windows;
    state = new_state;

    const ns = getState();

    // Re-apply per-workspace layout/variant/master-count overrides from the
    // *new* config, falling back to the new global default layout for any
    // workspace without its own override. Runtime-only state with no
    // config-file representation — master_width (increase_master/
    // decrease_master) and stack_balance (mod+n/mod+o grow-slave actions) —
    // is reset to null by applyWorkspaceOverrides itself, since a reload has
    // no config-declared value to restore either to.
    if (workspaces.getState()) |ws_state| {
        workspaces.applyWorkspaceOverrides(ws_state.workspaces, &core.getState().config.tiling, ns.config.layout);
    }

    if (ns.is_enabled) {
        // Wrap everything in a single server grab so picom never composites a
        // frame where some windows have the new border width but the layout has
        // not yet been recalculated.
        //
        // BORDER_WIDTH is sent explicitly to every tiled window here, then the
        // normal retile path recalculates geometry separately. This costs one
        // extra XCB request per window, in exchange for keeping the retile
        // path free of any border-width bookkeeping.
        const conn = core.getState().conn;
        _ = xcb.xcb_grab_server(conn);
        for (ns.windows.items()) |win| {
            _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{ns.config.border_width});
        }
        retileCurrentWorkspace();
        bar.redrawInsideGrab();
        utils.ungrabAndFlush(conn);
    }
}

// Size hints (delegated to layouts.zig via the combined cache)

/// Cache WM_NORMAL_HINTS minimum size constraints for `win` in its CacheMap entry.
/// Called from window.zig at MapRequest time after the property cookie is drained.
/// The hints live inside the same flat-array entry as the window's geometry and
/// border color, so no separate table scan is needed inside configureWithHints.
pub fn cacheSizeHints(win: u32, hints: layouts.SizeHints) void {
    layouts.cacheHints(&getState().geom.cache, win, hints);
}

// Window management

pub fn addWindow(window_id: u32) void {
    std.debug.assert(window_id != 0);
    const s = getState();

    // Always add to the tracking list, even when tiling is disabled
    // (is_enabled == false) or the floating layout is active. Windows opened
    // in those modes must be tracked so they enter the tiling pool as soon as
    // a tiled layout is active again.
    // FIFO/LIFO insertion order is resolved from the master layout's variant
    // when the current layout is .floating: floating has no window order of
    // its own, and master (the cycle's first layout) is where cycling away
    // from floating lands — so new windows arrive in the slot they'd have
    // under master.
    const fifo_insert = s.config.layout_variants.master == .fifo and
        (s.config.layout == .floating or s.config.layout == .master);
    if (fifo_insert)
        s.windows.addFront(window_id)
    else
        s.windows.add(window_id);

    s.is_dirty = true;
    s.geom.workspace_geom_valid_bits = 0;

    // Skip X protocol operations while the tiler is disabled (is_enabled ==
    // false). Border width and color will be applied on the first retile after
    // tiling is re-enabled.
    if (!s.is_enabled) return;

    const border_color = s.borderColor(window_id);
    _ = xcb.xcb_change_window_attributes(core.getState().conn, window_id, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{border_color});

    // NOTE: BORDER_WIDTH is intentionally NOT sent here — every caller of
    // addWindow is immediately followed by the code that owns the BORDER_WIDTH
    // send (mapWindowToScreen → applyBorderWidth, registerWindowOffscreen →
    // applyBorder, toggleWindowFloat / unminimize → already set at initial
    // map). The X server retains BORDER_WIDTH between configure calls, so
    // sending it here would duplicate that request in the common spawn path.

    // Pre-populate the cache so the immediately-following retile does not
    // re-send the border pixel.
    const wd = layouts.getOrPutDefault(&s.geom.cache, window_id) catch return;
    wd.border = border_color;
}

pub fn removeWindow(window_id: u32) void {
    const s = getState();
    if (s.windows.remove(window_id)) {
        s.is_dirty = true;
        s.geom.workspace_geom_valid_bits = 0;
    }
    // Always evict the cache entry — this removes geometry, border dedup data,
    // AND the embedded WM_NORMAL_HINTS in one operation.  No-op when the window
    // was never cached (e.g. floating windows that opened while tiling was disabled).
    _ = s.geom.cache.remove(window_id);
    // If this window was stored as the previous focused window for scroll focus
    // restoration, clear it now — returning a destroyed window ID to the caller
    // of takePrevFocusedForScroll would generate an XCB BadWindow error.
    if (s.scroll.prev_focused == window_id) s.scroll.prev_focused = null;
}

/// Toggle a window between tiled and floating.
///
/// Tiled -> floating: removes from the tiling pool so it sits at its current position.
/// Floating -> tiled: hands back to the tiling pool (respecting LIFO/FIFO) and retiles.
///
/// This per-window toggle is distinct from the floating *layout* and is a no-op
/// while the floating layout is active, since all windows are already unconstrained.
pub fn toggleWindowFloat(window_id: u32) void {
    const s = getState();
    if (!s.is_enabled) return;

    if (s.windows.contains(window_id)) {
        removeWindow(window_id);
        debug.info("[FLOAT] 0x{x} -> floating", .{window_id});
    } else {
        addWindow(window_id);
        debug.info("[FLOAT] 0x{x} -> tiled", .{window_id});
    }
    retileCurrentWorkspace();
    // Grab, border sweep, bar redraw, and flush are the caller's responsibility
    // (input.zig executeAction / executeMouseAction).  Keeping this function
    // grab-agnostic matches swapWithMaster's convention and lets the caller
    // compose the full atomic batch.
}

/// Returns the position of `win` in the current-workspace-filtered window list —
/// the same slice the master layout receives as its `windows` argument.
/// Index 0 is the master slot; indices >= master_count are stack slots.
///
/// Must be called BEFORE `removeWindow` so the window is still tracked.
/// Returns null when tiling is disabled or `win` is not in the tiling list.
pub fn getWindowFilteredIndex(win: u32) ?usize {
    const s = getStateOpt() orelse return null;
    if (!s.is_enabled) return null;
    std.debug.assert(tracking.isOnCurrentWorkspace(win));
    var filtered_idx: usize = 0;
    for (s.windows.items()) |w| {
        if (w == win) return filtered_idx;
        if (tracking.isOnCurrentWorkspace(w)) filtered_idx += 1;
    }
    return null;
}

/// Add `win` to the tiling list and place it at workspace-filtered position
/// `target_filtered_idx`. Used by the unminimize path to restore a window to
/// its original layout slot.
pub fn addWindowAtFilteredIndex(win: u32, target_filtered_idx: usize) void {
    addWindow(win);
    moveWindowToFilteredSlot(getState(), win, target_filtered_idx);
}

/// Save geometry for any window (tiled or floating) into the shared cache.
/// Called by the workspace switcher before pushing windows off-screen.
pub fn saveWindowGeom(window_id: u32, rect: utils.Rect) void {
    updateCacheRect(getState(), window_id, rect);
}

/// Return the cached geometry for any window. Returns null when no entry exists
/// or the entry has been invalidated (zeroed rect).
pub fn getWindowGeom(window_id: u32) ?utils.Rect {
    const s = getStateOpt() orelse return null;
    const wd = s.geom.cache.getPtr(window_id) orelse return null;
    if (!wd.hasValidRect()) return null;
    return wd.rect;
}

/// Evict a window's rect from the cache without removing it from tiling.
/// Call whenever a window's position is changed outside the normal retile path
/// (e.g. pushed offscreen during fullscreen) so the next retile does not find a
/// stale cache hit and skip configure_window. The border entry is preserved.
pub fn invalidateGeomCache(window_id: u32) void {
    const s = getState();
    if (s.geom.cache.getPtr(window_id)) |wd| wd.rect = layouts.zero_rect;
}

/// Clear the workspace-valid bit for `ws_idx` so the next restoreWorkspaceGeom
/// for that workspace triggers a full retile.
pub inline fn invalidateWsGeomBit(ws_idx: u8) void {
    const s = getState();
    if (ws_idx < max_workspaces) s.geom.workspace_geom_valid_bits &= ~tracking.workspaceBit(ws_idx);
}

pub inline fn markDirty() void {
    getState().is_dirty = true;
}

// Retile

/// Shared body for every "retile current workspace" entry point: falls back
/// to replaying cached geometry when tiling is disabled, otherwise runs
/// retileImpl with the given options and clears the dirty flag.
fn retileCurrentWorkspaceWithOpts(opts: RetileOpts) void {
    const s = getState();
    if (!s.is_enabled) {
        _ = restoreWorkspaceGeom();
        return;
    }
    retileImpl(calcScreenArea(), opts);
    s.is_dirty = false;
}

/// Retile the current workspace immediately.
pub fn retileCurrentWorkspace() void {
    retileCurrentWorkspaceWithOpts(.{});
}

/// Like retileCurrentWorkspace, but passes `defer_win` through to the layout
/// context so that window is configured LAST inside every column/stack it
/// appears in.  Used by swap_master to eliminate the one-frame wallpaper gap.
pub fn retileCurrentWorkspaceDeferred(defer_win: ?u32) void {
    retileCurrentWorkspaceWithOpts(.{ .defer_win = defer_win });
}

/// Like retileCurrentWorkspace, but overrides LayoutCtx.focused_win with
/// `pending_focus` instead of reading focus.getFocused().
///
/// Used by window.zig's spawn path: a newly-mapped window is retiled before
/// focus.setFocus runs on it (retiling is deliberately kept outside the
/// atomic map/focus/border grab — see mapWindowToScreen), so
/// focus.getFocused() would still report the previously-focused window at
/// retile time. Passing the spawning window here keeps focus-driven layouts
/// (e.g. monocle raising the focused window) in sync with the window that is
/// about to actually receive focus, instead of lagging by one retile.
pub fn retileCurrentWorkspaceWithPendingFocus(pending_focus: u32) void {
    retileCurrentWorkspaceWithOpts(.{ .focus_override = pending_focus });
}

/// Retile the current workspace only when state has been marked dirty.
pub fn retileIfDirty() void {
    const s = getState();
    if (!s.is_enabled or !s.is_dirty) return;
    retileCurrentWorkspace();
}

/// Retile `ws_idx`, which is guaranteed not to be the current workspace.
/// Used to keep an inactive workspace's geometry cache correct so it is ready
/// before the user switches to it (see bar.retileAllWorkspaces).
pub fn retileInactiveWorkspace(ws_idx: u8) void {
    const s = getState();
    if (!s.is_enabled) return;
    if (!core.getState().config.workspaces.enabled) return;

    const ws_state = workspaces.getState() orelse return;
    if (ws_idx == ws_state.current) {
        retileCurrentWorkspace();
        return;
    }

    retileImpl(calcScreenArea(), .{ .for_ws = ws_idx });

    // Defense in depth: monocle (and fibonacci's overflow fallback) now skip
    // raising during a background retile (see LayoutCtx.is_background), but
    // nothing here relies on that being the *only* way a window could have
    // ended up first in stacking order — pushWindowOffscreenAndLower also
    // explicitly sends XCB_STACK_MODE_BELOW alongside the offscreen X, so a
    // hidden window can never surface above the bar or the visible
    // workspace regardless of what raised it.
    const bit = tracking.workspaceBit(ws_idx);
    const conn = core.getState().conn;
    for (tracking.allWindows()) |entry| {
        if (entry.mask & bit != 0) utils.pushWindowOffscreenAndLower(conn, entry.win);
    }
}

/// Compute tiled geometry bypassing the `!is_enabled` guard, then restore
/// `s.layout`. Used by the workspace switcher when tiling is disabled (the
/// .floating layout may also be active) and the geometry cache is stale —
/// pre-populates the cache so float-restore can use `getWindowGeom` instead
/// of falling back to the default float position.
pub fn retileForRestore() void {
    const s = getState();
    const saved = s.config.layout;
    // Stand-in layout for the cache warm-up: any tiling algorithm produces a
    // stable cached position, and master is where cycling away from floating
    // lands. The cache is only used as a fallback float position.
    s.config.layout = .master;
    retileImpl(calcScreenArea(), .{});
    s.config.layout = saved;
    s.is_dirty = false;
}

/// Restore windows on the current workspace to their cached tiled positions,
/// bypassing the layout algorithm. Returns true if the cache is valid and
/// positions have been replayed. Returns false if the cache is stale; the caller
/// must fall back to `retileCurrentWorkspace`.
pub fn restoreWorkspaceGeom() bool {
    const s = getStateOpt() orelse return false;

    const ws_windows = collectWorkspaceWindows(s, null);
    if (ws_windows.len == 0) return true;

    const current_ws = tracking.getCurrentWorkspace() orelse return false;
    if (current_ws >= max_workspaces) return false;
    if (s.geom.workspace_geom_valid_bits & tracking.workspaceBit(current_ws) == 0) return false;

    const current_screen = calcScreenArea();
    if (!layouts.rectsEqual(current_screen, s.geom.last_retile_area)) return false;

    // Pass 1 — validate all cache entries before emitting any XCB calls.
    // getPtr pointers stay valid through pass 2 because no insertion happens
    // into the cache between collecting them here and dereferencing them below
    // (AutoHashMap pointers are only invalidated by insertion/rehash).
    var wd_ptrs: [max_workspace_windows]*layouts.WindowData = undefined;
    for (ws_windows, 0..) |win, i| {
        const wd = s.geom.cache.getPtr(win) orelse return false;
        if (!wd.hasValidRect()) return false;
        wd_ptrs[i] = wd;
    }

    // Pass 2 — configure and apply border color in a single loop.
    const conn = core.getState().conn;
    for (ws_windows, wd_ptrs[0..ws_windows.len]) |win, wd| {
        utils.configureWindow(conn, win, wd.rect);
        const color = s.borderColor(win);
        if (wd.border != color) {
            wd.border = color;
            _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
        }
    }
    return true;
}

// Layout control

/// Cycle to the next layout in the enabled-layout list.
pub fn toggleLayout() void {
    applyLayoutStep(true);
}
/// Cycle to the previous layout in the enabled-layout list.
pub fn toggleLayoutReverse() void {
    applyLayoutStep(false);
}

/// Cycle through the per-layout variants for the currently active layout.
pub fn stepLayoutVariant() void {
    const s = getState();
    switch (s.config.layout) {
        .master => {
            cycleEnum(&s.config.layout_variants.master);
            debug.info("Master variant: {s}", .{@tagName(s.config.layout_variants.master)});
        },
        .monocle => {
            cycleEnum(&s.config.layout_variants.monocle);
            debug.info("Monocle variant: {s}", .{@tagName(s.config.layout_variants.monocle)});
        },
        .grid => {
            cycleEnum(&s.config.layout_variants.grid);
            debug.info("Grid variant: {s}", .{@tagName(s.config.layout_variants.grid)});
        },
        else => {
            debug.info("{s} has no variants", .{@tagName(s.config.layout)});
            return;
        },
    }
    // Variants are always global — all inactive workspace caches are now stale.
    s.geom.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

/// Apply `ws`'s stored layout/variant/master settings to State, marking dirty when anything changed.
pub fn applyWorkspaceLayout(ws: *const WsWorkspace) void {
    const s = getState();
    // Resolve every nullable override to its effective value first so the
    // dirty check below compares against exactly what gets applied.
    const master_width = ws.master_width orelse s.config.master_width;
    const master_count = ws.master_count orelse core.getState().config.tiling.master_count;
    const stack_balance = ws.stack_balance orelse 0;
    const needs_retile =
        s.config.layout != ws.layout or ws.variants != null or
        master_width != s.config.master_width or master_count != s.config.master_count or stack_balance != s.config.stack_balance;
    s.config.layout = ws.layout;
    s.config.master_width = master_width;
    s.config.master_count = master_count;
    s.config.stack_balance = stack_balance;
    if (ws.variants) |v| {
        switch (v) {
            .master => |mv| s.config.layout_variants.master = mv,
            .monocle => |mv| s.config.layout_variants.monocle = mv,
            .grid => |gv| s.config.layout_variants.grid = gv,
        }
    }
    if (needs_retile) {
        s.is_dirty = true;
        s.geom.workspace_geom_valid_bits = 0;
    }
}

pub inline fn defaultLayout() Layout {
    return layout_cycle[0];
}

/// Persist a layout-config field to the current workspace's override slot in
/// per-workspace mode. Global mode has no per-workspace overrides to write.
inline fn persistToCurrentWorkspace(comptime field: []const u8, value: anytype) void {
    if (core.getState().config.tiling.global_layout) return;
    if (workspaces.getCurrentWorkspaceObject()) |ws| @field(ws, field) = value;
}

// Master width and count

pub fn adjustMasterCount(delta: i8) void {
    const s = getState();
    const new: i16 = @as(i16, s.config.master_count) + delta;
    if (new < 1) return;
    const clamped: u8 = @intCast(@min(new, max_master_count));
    if (clamped == s.config.master_count) return;
    s.config.master_count = clamped;
    persistToCurrentWorkspace("master_count", s.config.master_count);
    // In global mode master_count applies to every workspace, so all inactive
    // workspace caches are now stale.
    if (core.getState().config.tiling.global_layout) s.geom.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

pub inline fn increaseMasterCount() void {
    adjustMasterCount(1);
}
pub inline fn decreaseMasterCount() void {
    adjustMasterCount(-1);
}

pub fn adjustMasterWidth(delta: f32) void {
    const s = getState();
    s.config.master_width = std.math.clamp(s.config.master_width + delta, constants.MIN_MASTER_WIDTH, max_master_width_ratio);
    persistToCurrentWorkspace("master_width", s.config.master_width);
    // Invalidate inactive workspace caches so their next switch-in forces a
    // full retile with the new width, rather than replaying stale positions.
    // is_dirty is NOT set here: retileCurrentWorkspace() immediately below
    // sets is_dirty = false unconditionally, making the write a no-op.
    s.geom.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

pub inline fn increaseMasterWidth() void {
    adjustMasterWidth(0.025);
}
pub inline fn decreaseMasterWidth() void {
    adjustMasterWidth(-0.025);
}

// Stack slot balance (mod+n / mod+o)
//
// Persisted per-workspace like master width/count (see Workspace.stack_balance
// in workspaces.zig), so it respects `global_layout`: per-workspace when false
// (the default), shared across every workspace when true.

const stack_balance_step: f32 = 0.5;
const max_stack_balance: f32 = 6.0;

/// Nudge the stack's top/bottom balance by `delta` (positive grows the
/// topmost slave's share, negative the bottommost's), clamped to
/// [-max_stack_balance, max_stack_balance]. See LayoutConfig.stack_balance's
/// doc comment for the signed-scalar reasoning.
fn adjustStackBalance(delta: f32) void {
    const s = getState();
    s.config.stack_balance = std.math.clamp(s.config.stack_balance + delta, -max_stack_balance, max_stack_balance);
    persistToCurrentWorkspace("stack_balance", s.config.stack_balance);
    s.geom.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

/// Grows the topmost stack slave's share of the column, shrinking the rest
/// evenly; bound to mod+n by convention.
pub inline fn growTopSlave() void {
    adjustStackBalance(stack_balance_step);
}

/// Grows the bottommost stack slave's share of the column, shrinking the rest
/// evenly; bound to mod+o by convention.
pub inline fn growBottomSlave() void {
    adjustStackBalance(-stack_balance_step);
}

/// Shift the scroll-layout viewport left or right by one slot.
/// `delta` is +1 (right/forward) or -1 (left/backward).
/// No-op when the current layout is not .scroll.
pub fn stepScrollView(delta: i32) void {
    if (scroll.step(getState(), delta)) retileCurrentWorkspace();
}

pub inline fn scrollViewLeft() void {
    stepScrollView(-1);
}
pub inline fn scrollViewRight() void {
    stepScrollView(1);
}

/// Brings the newly focused window into view after keyboard focus-cycle
/// actions (focus_next_window / focus_prev_window), for layouts where a
/// plain focus change doesn't already make the right window visible:
///
///   • .scroll: snaps the viewport to the focused window when it's off-screen,
///     then retiles.
///   • .monocle: always retiles. Monocle hides every window but the focused
///     one by moving it off-screen (see monocle.zig's
///     pushBackgroundWindowsOffscreen), not by lowering it in the stacking
///     order, so the plain raise that setFocus() already performs is a
///     no-op — only a retile repositions the newly focused window back on
///     screen and pushes the previously focused one off.
///
/// No-op when:
///   • the active layout is neither .scroll nor .monocle
///   • (.scroll only) no window is focused, or it's already fully visible
///     in the current viewport
pub fn snapScrollToFocused() void {
    const s = getState();
    switch (s.config.layout) {
        .monocle => retileCurrentWorkspace(),
        .scroll => {
            const win = focus.getFocused() orelse return;
            if (scroll.snapOffsetToWindow(s, collectWorkspaceWindows(s, null), win)) retileCurrentWorkspace();
        },
        else => {},
    }
}

// Window swap operations

/// Swap the focused window into the master slot (index 0 of the current
/// workspace window list). If it is already master, promotes the next
/// window instead. Returns the window that was displaced, so the caller can
/// re-focus it — or null if there was nothing to swap.
///
/// NOTE: Does NOT call retileCurrentWorkspace(). The caller (action handler)
/// is responsible for retiling inside the server grab so that the list
/// reorder and the geometry flush are part of the same atomic batch.
pub fn swapWithMaster() ?u32 {
    const s = getState();
    return swapWithMasterCore(s, findFocusMasterPos(s) orelse return null);
}

/// Swap two tiled windows by their IDs.  Used by focus.zig to implement
/// Mod+Shift+j / Mod+Shift+k — move the focused window in cycle order.
pub fn swapWindowsById(win_a: u32, win_b: u32) void {
    const s = getState();
    const all = s.windows.items();
    const idx_a = std.mem.indexOfScalar(u32, all, win_a) orelse return;
    const idx_b = std.mem.indexOfScalar(u32, all, win_b) orelse return;
    swapWindowsInList(s, idx_a, idx_b);
    retileCurrentWorkspace();
}

// Query functions

pub inline fn isWindowTiled(window_id: u32) bool {
    const s = getStateOpt() orelse return false;
    return s.windows.contains(window_id);
}

/// Returns true when the floating layout is currently active.
pub inline fn isFloatingLayout() bool {
    const s = getStateOpt() orelse return false;
    return s.config.layout == .floating;
}

/// Returns true only when the tiler is enabled AND `window_id` is managed by
/// the tiler. `is_enabled` mirrors config.tiling.enabled (applied at
/// init/reload — there is no runtime toggle), so when tiling is disabled this
/// returns false and applications are free to position themselves. Use this in
/// handleConfigureRequest so tiled windows' configure requests are denied (the
/// WM owns their geometry) while untiled ones pass through.
pub inline fn isWindowActiveTiled(window_id: u32) bool {
    const s = getStateOpt() orelse return false;
    return s.is_enabled and s.windows.contains(window_id);
}

// Focus / border management

pub fn updateWindowFocus(old_focused: ?u32, new_focused: ?u32) void {
    const s = getState();

    // Track focus history for scroll-layout close recovery.
    // Only update when focus moves between two live windows (not on clear).
    // updateWindowFocus(A, null) is called by clearFocus when a window is being
    // closed — we must NOT update prev_focused there, because A is about to be
    // removed and prev_focused should still point to the last window before A.
    if (old_focused != null and new_focused != null) {
        s.scroll.prev_focused = old_focused;
    }

    for ([2]?u32{ old_focused, new_focused }) |opt| {
        const win = opt orelse continue;
        if (!s.windows.contains(win)) continue;
        applyBorderColor(s, core.getState().conn, win, s.borderColor(win));
    }
}

/// Scroll layout only: return and consume the previously focused window so
/// that the caller can restore focus to it after the current focused window
/// is closed. See scroll.takePrevFocused for the full contract.
pub fn takePrevFocusedForScroll() ?u32 {
    return scroll.takePrevFocused(getState());
}

// Private implementation

// Layout cycle (comptime)

// All six layouts are always compiled in now. toggleLayout/toggleLayoutReverse
// walk this fixed list when cycling.
const layout_cycle: [types.LAYOUT_TABLE.len]Layout = blk: {
    var arr: [types.LAYOUT_TABLE.len]Layout = undefined;
    for (types.LAYOUT_TABLE, 0..) |entry, i| arr[i] = entry.tag;
    break :blk arr;
};

/// Resolves a config-file layout name (canonical or alias, e.g. "master-stack",
/// "master", "monocle") to its `Layout` tag. Driven by types.LAYOUT_TABLE, the
/// single source of truth also used by config.zig's isKnownLayout/canonicalLayout
/// and workspaces.zig's layout-name resolution. A linear scan over the table
/// is plenty fast at n=6 (plus a couple aliases).
pub inline fn layoutFromString(name: []const u8) ?Layout {
    for (types.LAYOUT_TABLE) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.tag;
        for (entry.aliases) |alias| {
            if (std.mem.eql(u8, name, alias)) return entry.tag;
        }
    }
    return null;
}

/// Build the runtime-enabled layout list from the config's `layouts` array,
/// keeping only entries whose .zig file is present on disk. Duplicates are
/// dropped. When the config produces an empty list (all names unknown or all
/// layouts disabled at build time), seeds from layout_cycle so the returned
/// list is always non-empty — stepLayout depends on this guarantee.
fn parseEnabledLayouts(layouts_cfg: []const []const u8) struct { arr: [types.LAYOUT_TABLE.len]Layout, len: u8 } {
    var arr: [types.LAYOUT_TABLE.len]Layout = undefined;
    var len: u8 = 0;
    for (layouts_cfg) |name| {
        if (len >= arr.len) break;
        const layout = layoutFromString(name) orelse continue;
        if (std.mem.indexOfScalar(Layout, arr[0..len], layout) != null) continue;
        arr[len] = layout;
        len += 1;
    }
    if (len == 0) {
        @memcpy(arr[0..layout_cycle.len], layout_cycle[0..]);
        len = @intCast(layout_cycle.len);
    }
    return .{ .arr = arr, .len = len };
}

/// Walk the runtime-enabled layout list to find `current`, then step forward or
/// backward. enabled_layouts is always non-empty — parseEnabledLayouts seeds it
/// from layout_cycle when the config produces no valid entries.
inline fn stepLayout(s: *const State, current: Layout, comptime forward: bool) Layout {
    const cycle: []const Layout = s.config.enabled_layouts[0..s.config.enabled_layout_count];
    for (cycle, 0..) |l, i| {
        if (l != current) continue;
        return cycle[if (forward) (i + 1) % cycle.len else (cycle.len + i - 1) % cycle.len];
    }
    return cycle[0]; // current not in list (disabled at reload) — jump to first
}

/// Compute the initial master pane width ratio from config, converting negative
/// pixel values to screen-relative fractions.
fn calcMasterWidth() f32 {
    const cs = core.getState();
    const raw = scale.scaleMasterWidth(cs.config.tiling.master_width);
    if (raw < 0) {
        const ratio = -raw / @as(f32, @floatFromInt(cs.screen.width_in_pixels));
        return @min(max_master_width_ratio, @max(constants.MIN_MASTER_WIDTH, ratio));
    }
    return raw;
}

fn initState() State {
    const cs = core.getState();
    const screen_height = cs.screen.height_in_pixels;
    const el = parseEnabledLayouts(cs.config.tiling.layouts.items);

    return .{
        .is_enabled = cs.config.tiling.enabled,
        .is_dirty = false,
        .config = .{
            // stringToEnum (not layoutFromString) so the scalar config key
            // `tiling.layout = "floating"` resolves: layoutFromString is scoped
            // to LAYOUT_TABLE, which deliberately excludes .floating.
            .layout = std.meta.stringToEnum(Layout, cs.config.tiling.layout) orelse layout_cycle[0],
            .enabled_layouts = el.arr,
            .enabled_layout_count = el.len,
            .layout_variants = .{
                .master = cs.config.tiling.master_variant,
                .monocle = cs.config.tiling.monocle_variant,
                .grid = cs.config.tiling.grid_variant,
            },
            .master_side = cs.config.tiling.master_side,
            .master_width = calcMasterWidth(),
            .master_count = cs.config.tiling.master_count,
            .stack_balance = 0,
            .gap_width = scale.scaleBorderWidth(cs.config.tiling.gap_width, screen_height),
            .border_width = scale.scaleBorderWidth(cs.config.tiling.border_width, screen_height),
            .border_focused = cs.config.tiling.border_focused,
            .border_unfocused = cs.config.tiling.border_unfocused,
        },
        .windows = .{},
        .geom = .{
            .cache = layouts.CacheMap.init(cs.alloc),
            .workspace_geom_valid_bits = 0,
            .last_retile_area = layouts.zero_rect,
            .scratch_wins = undefined,
        },
        .scroll = .{},
    };
}

// Layout dispatch helpers

/// Build a LayoutCtx for a normal retile. defer_win is left at its default
/// (null); retileImpl sets it from RetileOpts after this call returns.
/// `deferred` must point at a scratch slot the caller owns for the lifetime
/// of the retile pass (see LayoutCtx.deferred) — invokeLayout flushes it.
inline fn makeLayoutCtx(s: *State, deferred: *?utils.Rect) layouts.LayoutCtx {
    return .{
        .conn = core.getState().conn,
        .cache = &s.geom.cache,
        .focused_win = focus.getFocused(),
        .deferred = deferred,
    };
}

fn invokeLayout(
    layout: Layout,
    ctx: *const layouts.LayoutCtx,
    s: *State,
    wins: []const u32,
    screen: utils.Rect,
) void {
    // Central empty-list guard: layout modules assume a non-empty list (master
    // and grid divide by the window count, monocle indexes windows[len-1]).
    // retileImpl already returns early on an empty workspace, but keeping the
    // guard here — the sole dispatch point for every layout — means no module
    // ever has to re-check, even if a future caller reaches invokeLayout with
    // an empty list.
    if (wins.len == 0) return;

    const w = screen.width;
    const h = screen.height;
    const y: u16 = @intCast(@max(screen.y, @as(i16, 0)));
    switch (layout) {
        .master => master.tileWithOffset(ctx, s, wins, w, h, y),
        .monocle => monocle.tileWithOffset(ctx, s, wins, w, h, y),
        .grid => grid.tileWithOffset(ctx, s, wins, w, h, y),
        .fibonacci => fibonacci.tileWithOffset(ctx, s, wins, w, h, y),
        .leaf => leaf.tileWithOffset(ctx, s, wins, w, h, y),
        .scroll => scroll.tileWithOffset(ctx, s, wins, w, h, y),
        .floating => floating.tileWithOffset(ctx, s, wins, w, h, y),
    }
    // Centralized flush of the deferred swap_master rect (see LayoutCtx.deferred
    // and emitOrDefer's doc comment). This is the single place that flushes —
    // layout modules never do it themselves. Reset to null afterward so a
    // stale rect can never leak into a future retile pass that reuses this
    // scratch slot.
    if (ctx.deferred.*) |rect| {
        layouts.configureWithHints(ctx, ctx.defer_win.?, rect);
        ctx.deferred.* = null;
    }
}

/// Screen area available for tiling, with bar height subtracted from the appropriate edge.
inline fn calcScreenArea() utils.Rect {
    const bar_height: u16 = if (bar.isVisible()) bar.getBarHeight() else 0;
    const cs = core.getState();
    const is_bar_at_bottom = cs.config.bar.bar_position == .bottom;
    return .{
        .x = 0,
        .y = if (is_bar_at_bottom) 0 else @intCast(bar_height),
        .width = cs.screen.width_in_pixels,
        .height = cs.screen.height_in_pixels -| bar_height,
    };
}

fn selectLayout(s: *State, ws_state: ?*WsState, ws_idx: u8, is_global: bool) Layout {
    if (is_global) return s.config.layout;
    const wss = ws_state orelse return s.config.layout;
    return if (ws_idx < wss.workspaces.len) wss.workspaces[ws_idx].layout else s.config.layout;
}

/// Shared body for resolveMasterWidth/resolveMasterCount: returns `field`'s
/// per-workspace override for `ws_idx` in per-workspace mode, falling back to
/// `global_value` in global mode, when no per-workspace state exists, when
/// `ws_idx` is out of range, or when that workspace has no override yet.
inline fn resolveWorkspaceOverride(
    comptime T: type,
    comptime field: []const u8,
    global_value: T,
    ws_state: ?*WsState,
    ws_idx: u8,
) T {
    if (core.getState().config.tiling.global_layout) return global_value;
    const wss = ws_state orelse return global_value;
    if (ws_idx >= wss.workspaces.len) return global_value;
    return @field(wss.workspaces[ws_idx], field) orelse global_value;
}

/// Returns the master width for `ws_idx` in per-workspace mode. Falls back to
/// the current global value for workspaces that have no override yet.
inline fn resolveMasterWidth(s: *const State, ws_state: ?*WsState, ws_idx: u8) f32 {
    return resolveWorkspaceOverride(f32, "master_width", s.config.master_width, ws_state, ws_idx);
}

/// Returns the master count for `ws_idx` in per-workspace mode. Falls back to
/// the current global value for workspaces that have no override yet.
inline fn resolveMasterCount(s: *const State, ws_state: ?*WsState, ws_idx: u8) u8 {
    return resolveWorkspaceOverride(u8, "master_count", s.config.master_count, ws_state, ws_idx);
}

// Core retile

/// Options for the single core retile implementation. All public retile
/// entry points are thin wrappers that fill this in and call retileImpl.
const RetileOpts = struct {
    /// Target workspace. Null = current workspace.
    for_ws: ?u8 = null,
    /// When non-null, threaded into LayoutCtx.defer_win so the named window's
    /// configure_window call lands last within whatever column/stack group it
    /// belongs to. Used by swap_master to eliminate the one-frame wallpaper gap.
    defer_win: ?u32 = null,
    /// When non-null, overrides LayoutCtx.focused_win instead of reading
    /// focus.getFocused(). Used by the spawn path (retileCurrentWorkspaceWithPendingFocus)
    /// to hand a freshly-mapped window to the layout before focus.setFocus
    /// has actually run on it.
    focus_override: ?u32 = null,
};

/// Single implementation underlying every public retile entry point.
fn retileImpl(screen: utils.Rect, opts: RetileOpts) void {
    const s = getState();

    const current_ws_opt = tracking.getCurrentWorkspace();
    const target_ws: u8 = opts.for_ws orelse
        @intCast(current_ws_opt orelse return);

    if (fullscreen.getForWorkspace(target_ws)) |_| return;

    const ws_windows = collectWorkspaceWindows(s, opts.for_ws);
    if (ws_windows.len == 0) return;

    var deferred: ?utils.Rect = null;
    var ctx = makeLayoutCtx(s, &deferred);
    ctx.defer_win = opts.defer_win;
    if (opts.focus_override) |f| ctx.focused_win = f;
    // Background whenever the target isn't the workspace actually on screen
    // (retileInactiveWorkspace is the only caller that ever sets for_ws to
    // something other than the current workspace) — see LayoutCtx.is_background.
    ctx.is_background = current_ws_opt == null or target_ws != current_ws_opt.?;

    const wss = workspaces.getState();

    // Only override when targeting a non-current workspace: for the current
    // workspace, s.config already holds the authoritative values (kept in
    // sync by applyWorkspaceLayout/adjustMasterWidth/adjustMasterCount), so
    // re-resolving here would be redundant at best.
    const saved_width = s.config.master_width;
    const saved_count = s.config.master_count;
    if (opts.for_ws != null) {
        s.config.master_width = resolveMasterWidth(s, wss, target_ws);
        s.config.master_count = resolveMasterCount(s, wss, target_ws);
    }
    defer {
        s.config.master_width = saved_width;
        s.config.master_count = saved_count;
    }

    invokeLayout(
        selectLayout(s, wss, target_ws, core.getState().config.tiling.global_layout),
        &ctx,
        s,
        ws_windows,
        screen,
    );

    updateBorders(s, ws_windows);

    s.geom.last_retile_area = screen;
    markWorkspaceGeomValid(s, target_ws);
}

// Border management

/// Change the border pixel for `win` only when `color` differs from the cached value.
fn applyBorderColor(s: *State, conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    const gop = s.geom.cache.getOrPut(win) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

/// Refresh border colors for all `ws_windows`, deduped via the cache.
inline fn updateBorders(s: *State, ws_windows: []const u32) void {
    for (ws_windows) |win| applyBorderColor(s, core.getState().conn, win, s.borderColor(win));
}

/// Sends the border-pixel change for `win` only if `color` differs from the
/// cached value. Returns true when `win` had a cache entry (a tiled or
/// previously-retiled window) — the caller should treat that as "handled".
/// Returns false when there is no cache entry (a pure floating window that
/// was never retiled), so the caller should fall back to an unconditional
/// send. Used by window.zig's border-sweep functions.
pub fn sendBorderColorIfChanged(win: u32, color: u32) bool {
    const s = getStateOpt() orelse return false;
    const wd = s.geom.cache.getPtr(win) orelse return false;
    if (wd.border == color) return true; // cached, color unchanged — skip XCB
    wd.border = color;
    _ = xcb.xcb_change_window_attributes(core.getState().conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    return true;
}

// Window list helpers

/// Collect windows belonging to the target workspace into the reusable
/// `s.geom.scratch_wins` buffer and return the filled slice.
/// `for_ws`: when non-null, filter by that index; when null, use current workspace.
fn collectWorkspaceWindows(s: *State, for_ws: ?u8) []const u32 {
    // Must iterate s.windows.items() (tiling order), not tracking.allWindows()
    // (registration order): swap/move operations reorder s.windows.buf, so
    // retile must observe the same sequence or swaps have no visual effect.
    var n: usize = 0;
    for (s.windows.items()) |win| {
        const is_on_target = if (for_ws) |idx|
            tracking.isWindowOnWorkspace(win, idx)
        else
            tracking.isOnCurrentWorkspace(win);
        if (is_on_target) {
            s.geom.scratch_wins[n] = win;
            n += 1;
        }
    }
    return s.geom.scratch_wins[0..n];
}

/// Move the element at `from_idx` to `to_idx` in `s.windows`, shifting
/// intervening elements — equivalent to removing at `from_idx` and
/// re-inserting at `to_idx` (see moveWindowToFilteredSlot's contract below).
///
/// Implemented as an in-place rotation of the sub-range spanning both
/// indices: rotating [from, to] left by one slides the removed slot's
/// neighbours down and drops `from`'s element in at the far end, and the
/// mirror image (rotate right by one) does the same for `from > to`. This
/// touches only the |to_idx - from_idx| elements between the two positions
/// — no scratch buffer, no full-list rebuild, no capacity check needed
/// since both indices are already valid positions in `s.windows`.
fn moveWindowToIndex(s: *State, from_idx: usize, to_idx: usize) void {
    if (from_idx == to_idx) return;
    if (from_idx < to_idx) {
        std.mem.rotate(u32, s.windows.buf[from_idx .. to_idx + 1], 1);
    } else {
        const slice = s.windows.buf[to_idx .. from_idx + 1];
        std.mem.rotate(u32, slice, slice.len - 1);
    }
}

/// Reposition `win` within the global window list so that it lands at
/// workspace-filtered index `target` (0 = master slot).
///
/// moveWindowToIndex(from, to) removes the source element first, then
/// inserts at position `to` in the shortened list. When `from` lies before
/// `to`, removal shifts elements left by one, so the effective insertion
/// point is `tg - 1`; when `from` lies after `to`, no shift occurs.
fn moveWindowToFilteredSlot(s: *State, win: u32, target: usize) void {
    const items = s.windows.items();

    // `to_global` is a filtered *positional* match (the Nth window on the
    // current workspace), not an ID match like `from_global`, so both are
    // found in one pass here rather than via a plain indexOfScalar.
    var from_global: ?usize = null;
    var to_global: ?usize = null;
    var filtered_count: usize = 0;
    for (items, 0..) |w, i| {
        if (w == win) {
            from_global = i;
            if (to_global != null) break;
            continue;
        }
        if (!tracking.isOnCurrentWorkspace(w)) continue;
        if (filtered_count == target) {
            to_global = i;
            if (from_global != null) break;
        }
        filtered_count += 1;
    }

    const fg = from_global orelse return;
    const tg = to_global orelse return;
    const effective_to: usize = if (fg < tg) tg - 1 else tg;
    if (effective_to != fg) moveWindowToIndex(s, fg, effective_to);
}

/// Swap the two elements at `idx_a` and `idx_b` inside the tracking list.
fn swapWindowsInList(s: *State, idx_a: usize, idx_b: usize) void {
    if (idx_a == idx_b) return;
    std.mem.swap(u32, &s.windows.buf[idx_a], &s.windows.buf[idx_b]);
    // The bar's title dirty-check compares window IDs in tracking-table
    // order, which a same-workspace swap doesn't change — only on-screen
    // position changes. Force a full redraw so the title segment picks up
    // the new geometry even though focus and the window-ID set are unchanged.
    bar.scheduleFullRedraw();
}

/// Locates the focused window and the current workspace's master window in
/// the ordered window list. Returns null when preconditions are not met
/// (nothing focused, not tiled, not on current workspace, or fewer than two
/// windows on the workspace).
const FocusMasterPos = struct {
    fp_global: usize, // index of the focused window in s.windows.buf
    mp_global: usize, // index of the master window (ws_wins[0]) in s.windows.buf
    next_global: usize, // index of ws_wins[1], the first stack window
    fp_filtered: usize, // index of the focused window in ws_wins (0 == focused is master)
    ws_wins: []const u32, // per-workspace filtered list; ws_wins[0] is the layout master
};

fn findFocusMasterPos(s: *State) ?FocusMasterPos {
    const focused = focus.getFocused() orelse return null;
    if (!s.windows.contains(focused) or !tracking.isOnCurrentWorkspace(focused)) return null;

    // Build the per-workspace filtered list exactly as retile does, so that
    // ws_wins[0] is the true layout master regardless of s.windows.buf
    // insertion order across workspaces.
    const ws_wins = collectWorkspaceWindows(s, null);
    if (ws_wins.len < 2) return null; // need at least two windows for a meaningful swap

    const fp_filtered = std.mem.indexOfScalar(u32, ws_wins, focused) orelse return null;
    const all = s.windows.items();

    return .{
        .fp_global = std.mem.indexOfScalar(u32, all, focused) orelse return null,
        .mp_global = std.mem.indexOfScalar(u32, all, ws_wins[0]) orelse return null,
        .next_global = std.mem.indexOfScalar(u32, all, ws_wins[1]) orelse return null,
        .fp_filtered = fp_filtered,
        .ws_wins = ws_wins,
    };
}

/// Shared core for swapWithMaster.
///
/// Uses swapWindowsInList (O(1) std.mem.swap) instead of moveWindowToIndex
/// (O(n) remove-then-insert) — untouched windows keep their slots, get cache
/// hits, and receive no configure_window call, preventing intermediate frames.
fn swapWithMasterCore(s: *State, pos: FocusMasterPos) ?u32 {
    if (pos.fp_filtered == 0) {
        // Focused is already master — promote ws_wins[1]; a swap gives the same
        // visual result as a rotation for single-master layouts.
        if (pos.ws_wins.len < 2) return null;
        const next_win = pos.ws_wins[1];
        swapWindowsInList(s, pos.mp_global, pos.next_global);
        return next_win;
    }
    const master_win = pos.ws_wins[0];
    swapWindowsInList(s, pos.fp_global, pos.mp_global);
    return master_win;
}

fn updateCacheRect(s: *State, win: u32, rect: utils.Rect) void {
    const wd = layouts.getOrPutDefault(&s.geom.cache, win) catch return;
    wd.rect = rect;
}

/// Set the geometry-valid bit for `ws_idx`, indicating the cache is correct for that workspace.
inline fn markWorkspaceGeomValid(s: *State, ws_idx: anytype) void {
    if (ws_idx < max_workspaces) s.geom.workspace_geom_valid_bits |= tracking.workspaceBit(ws_idx);
}

/// Step the layout forward or backward and apply it.
inline fn applyLayoutStep(comptime forward: bool) void {
    const s = getState();
    // No .floating guard needed here: stepLayout only walks enabled_layouts,
    // which never contains .floating, so stepping from the floating layout
    // falls through to cycle[0]. That's exactly the intent — floating is not
    // cyclable, but cycling must still be able to LEAVE it.
    const layout = stepLayout(s, s.config.layout, forward);
    s.config.layout = layout;
    persistToCurrentWorkspace("layout", layout);
    // In global mode all workspaces share the same layout; inactive caches are stale.
    if (core.getState().config.tiling.global_layout) s.geom.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
    bar.scheduleFullRedraw();
    debug.info("Layout: {s}", .{@tagName(layout)});
}

/// Advance a finite enum field to its next variant, wrapping around.
inline fn cycleEnum(v: anytype) void {
    const T = @TypeOf(v.*);
    v.* = @enumFromInt((@intFromEnum(v.*) + 1) % std.meta.fields(T).len);
}
