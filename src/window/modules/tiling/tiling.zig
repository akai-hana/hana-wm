
//! Tiling window manager
//! Orchestrates layout, window tracking, and geometry/border cache. Delegates pixel arithmetic to the per-layout modules.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const utils     = @import("utils");
const types     = @import("types");
const constants = @import("constants");

const debug = @import("debug");

const tracking = @import("tracking");
const focus    = @import("focus");

const layouts  = @import("layouts");
const floating = @import("floating");

const fullscreen = if (build.has_fullscreen) @import("fullscreen") else struct {};
const workspaces = if (build.has_workspaces) @import("workspaces") else struct {
    pub const Workspace = struct {};
    pub inline fn getState() ?*State { return null; }
    pub inline fn getCurrentWorkspaceObject() ?*Workspace { return null; }
};
const WsState     = workspaces.State;
const WsWorkspace = workspaces.Workspace;

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn redrawInsideGrab() void {}
    pub fn isVisible() bool { return false; }
    pub fn getBarHeight() u16 { return 0; }
    pub fn scheduleFullRedraw() void {}
};

const scale = if (build.has_scale) @import("scale") else utils.scale_fallback;


const LayoutStub = struct {
    pub fn tileWithOffset(
        _: *const layouts.LayoutCtx,
        _: anytype,
        _: []const u32,
        _: u16, _: u16, _: u16,
    ) void {}
};

const master    = if (build.has_master)    @import("master")    else LayoutStub;
const monocle   = if (build.has_monocle)   @import("monocle")   else LayoutStub;
const grid      = if (build.has_grid)      @import("grid")      else LayoutStub;
const fibonacci = if (build.has_fibonacci) @import("fibonacci") else LayoutStub;

// Module constants 

const max_master_width_ratio: f32  = 0.95;
const max_workspace_windows: usize = 128; // per-retile window list capacity
const max_workspaces: usize        = 64;  // matches u64 workspace_geom_valid_bits

// Public types 

/// Sentinel zero rect used to mark a cache entry as stale.
/// Exported so layout modules (monocle) can write it directly.
pub const zero_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub const Layout = enum {
    master,
    monocle,
    grid,
    fibonacci,
    /// Windows are left at their current positions; no tiling is applied.
    /// Entered and exited via `toggleFloating()`; never part of the normal cycle.
    floating,
};

// Variant enums are defined in core.zig to allow config.zig to parse them
// without a circular import. Re-exported here for convenience.
pub const MasterVariant  = types.MasterVariant;
pub const MonocleVariant = types.MonocleVariant;
pub const GridVariant    = types.GridVariant;

pub const LayoutVariants = struct {
    master:  MasterVariant  = .lifo,
    monocle: MonocleVariant = .gapless,
    grid:    GridVariant    = .rigid,
};

pub const State = struct {
    is_enabled:       bool,
    layout:           Layout,
    /// The layout active before floating mode was entered.
    /// Restored by `toggleFloating()` when exiting floating.
    prev_layout:      Layout,
    layout_variants:  LayoutVariants,
    master_side:      types.MasterSide,
    master_width:     f32,
    master_count:     u8,
    gap_width:        u16,
    border_width:     u16,
    border_focused:   u32,
    border_unfocused: u32,
    windows:          tracking.Tracking,
    is_dirty:         bool,

    /// Runtime layout cycle: intersection of config `layouts` and disk-present
    /// layout files. `stepLayout` walks this so layouts omitted from the
    /// config are invisible at runtime even if their .zig file exists on disk.
    enabled_layouts:       [4]Layout,
    enabled_layout_count:  u8,

    /// Per-workspace geometry validity bitmask (64 bits -> up to 64 workspaces).
    ///
    /// Bit N is set when workspace N's geometry has been pre-computed and the
    /// cache holds correct on-screen positions for all its windows.
    ///
    /// Cleared by: addWindow, removeWindow, adjustMasterWidth, applyWorkspaceLayout.
    /// Set by the retile call that immediately follows each of those.
    workspace_geom_valid_bits: u64,

    /// Screen area used in the most recent retile call. restoreWorkspaceGeom
    /// rejects the cache when this differs from the current area (e.g. after a
    /// bar height or position change).
    last_retile_area: utils.Rect,

    /// Per-window cache storing last geometry AND last border color in a single
    /// open-addressing hash table. Populated by configureWithHints (rect) and
    /// applyBorderColor (border). O(1) lookup per window per retile.
    cache: layouts.CacheMap,

    // Scratch buffers — fixed-size arrays embedded in State (BSS, zero allocation).
    //
    // Reused across retile calls to avoid per-call stack pressure.
    //   scratch_wins   — [max_workspace_windows]u32   single-workspace window list
    //   scratch_rects  — [max_workspace_windows]Rect  parallel rect array for restore path
    //   retile_wins    — [max_workspaces * max_workspace_windows]u32  flattened 2-D per-workspace lists
    //   retile_lens    — [max_workspaces]usize         fill counters for retile_wins rows
    scratch_wins:  [max_workspace_windows]u32,
    scratch_rects: [max_workspace_windows]utils.Rect,
    retile_wins:   [max_workspaces * max_workspace_windows]u32,
    retile_lens:   [max_workspaces]usize,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gap_width, .border = self.border_width };
    }

    pub inline fn borderColor(self: *const State, win: u32) u32 {
        if (comptime build.has_fullscreen) {
            if (fullscreen.isFullscreen(win)) return 0;
        }
        return if (focus.getFocused() == win) self.border_focused else self.border_unfocused;
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
pub inline fn getStateOpt() ?*State { return if (state) |*s| s else null; }

// Lifecycle 

pub fn init() void {
    state = initState();
}

pub fn deinit() void {
    // State holds only fixed arrays and value types; nothing to free.
    state = null;
}

pub fn reloadConfig() void {
    const s = getState();
    const saved_windows = s.windows;

    // initState is infallible: scratch buffers are fixed arrays in BSS.
    // Config changes invalidate every cached rect and border color, so we
    // want the fresh empty cache initState produces. The only field that
    // must survive the rebuild is the live window list.
    var new_state = initState();
    new_state.windows = saved_windows;
    state = new_state;

    // getState() is safe here: we just assigned a non-null value above.
    const ns = getState();

    // Reset all workspace layouts and master widths to the new config defaults.
    // Per-workspace adjustments made at runtime are intentionally discarded so
    // the reloaded config values take effect immediately.
    if (comptime build.has_workspaces) {
        if (workspaces.getState()) |ws_state| {
            for (ws_state.workspaces) |*ws| {
                ws.layout       = ns.layout;
                ws.master_width = null;
                ws.master_count = null;
            }
        }
    }

    if (ns.is_enabled) {
        // Wrap border-width push and retile in a single server grab so picom
        // never composites an intermediate frame where some windows have the
        // new border width but the layout has not yet been recalculated.
        _ = xcb.xcb_grab_server(core.conn);
        for (ns.windows.items()) |win| {
            _ = xcb.xcb_configure_window(core.conn, win,
                xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{ns.border_width});
        }
        retileCurrentWorkspace();
        bar.redrawInsideGrab();
        utils.ungrabAndFlush(core.conn);
    }
}

// Size hints (delegated to layouts.zig via the combined cache) 

/// Cache WM_NORMAL_HINTS minimum size constraints for `win` in its CacheMap entry.
/// Called from window.zig at MapRequest time after the property cookie is drained.
/// The hints live inside the same flat-array entry as the window's geometry and
/// border color, so no separate table scan is needed inside configureWithHints.
pub fn cacheSizeHints(win: u32, hints: layouts.SizeHints) void {
    getState().cache.cacheHints(win, hints);
}

/// No-op: size-hint eviction now happens automatically inside `removeWindow`
/// when the combined cache entry is removed via `s.cache.remove(window_id)`.
/// Kept as a named symbol so call-sites in window.zig do not need to change.
pub fn evictSizeHints(_: u32) void {}

// Window management 

pub fn addWindow(window_id: u32) void {
    std.debug.assert(window_id != 0);
    const s = getState();

    // Always add to the tracking list, even when the floating layout is active
    // (s.is_enabled == false). Windows opened during floating mode must be tracked
    // so they enter the tiling pool when toggleFloating() restores a tiling layout.
    // Use prev_layout to resolve FIFO/LIFO when the current layout is .floating,
    // so new windows land in the correct slot once floating is exited.
    const effective_layout = if (s.layout == .floating) s.prev_layout else s.layout;
    if (effective_layout == .master and s.layout_variants.master == .fifo)
        s.windows.addFront(window_id)
    else
        s.windows.add(window_id);

    s.is_dirty = true;
    s.workspace_geom_valid_bits = 0;

    // Skip X protocol operations while the tiling engine is disabled. Border
    // width and color will be applied on the first retile after floating exits.
    if (!s.is_enabled) return;

    const border_color = s.borderColor(window_id);
    _ = xcb.xcb_change_window_attributes(core.conn, window_id,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{border_color});

    // NOTE: BORDER_WIDTH is intentionally NOT sent here.
    //
    // Every code path that calls addWindow is immediately followed by a call
    // that owns the BORDER_WIDTH send:
    //   • mapWindowToScreen      → applyBorderWidth(win)   (on-screen spawn)
    //   • registerWindowOffscreen → applyBorder(win)        (off-screen spawn)
    //   • toggleWindowFloat       (float→tiled)             border width already
    //   • addWindowAtFilteredIndex (unminimize)              set at initial map
    //
    // The X server retains BORDER_WIDTH between configure_window calls, so the
    // value from the initial map remains correct for toggle and unminimize paths.
    // Sending it here duplicated the request from applyBorderWidth in the common
    // spawn path, costing one extra XCB round-trip per window open.

    // Pre-populate the cache so the immediately-following retile does not
    // re-send the border pixel. getOrPut is infallible on the flat-array cache.
    const gop = s.cache.getOrPut(window_id);
    gop.value_ptr.border = border_color;
}

pub fn removeWindow(window_id: u32) void {
    const s = getState();
    if (s.windows.remove(window_id)) {
        s.is_dirty = true;
        s.workspace_geom_valid_bits = 0;
    }
    // Always evict the cache entry — this removes geometry, border dedup data,
    // AND the embedded WM_NORMAL_HINTS in one operation, replacing the previous
    // two-step design (s.cache.remove + layouts.evictSizeHints on a separate
    // hints_buf).  No-op when the window was never cached (e.g. floating windows
    // that opened while tiling was disabled).
    _ = s.cache.remove(window_id);
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
    _ = xcb.xcb_flush(core.conn);
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
    const wd = s.cache.get(window_id) orelse return null;
    if (!wd.hasValidRect()) return null;
    return wd.rect;
}

/// Evict a window's rect from the cache without removing it from tiling.
/// Call whenever a window's position is changed outside the normal retile path
/// (e.g. pushed offscreen during fullscreen) so the next retile does not find a
/// stale cache hit and skip configure_window. The border entry is preserved.
pub fn invalidateGeomCache(window_id: u32) void {
    const s = getState();
    if (s.cache.getPtr(window_id)) |wd| wd.rect = zero_rect;
}

/// Clear the workspace-valid bit for `ws_idx` so the next restoreWorkspaceGeom
/// for that workspace triggers a full retile.
pub inline fn invalidateWsGeomBit(ws_idx: u8) void {
    const s = getState();
    if (ws_idx < max_workspaces) s.workspace_geom_valid_bits &= ~tracking.workspaceBit(ws_idx);
}

pub inline fn markDirty() void {
    getState().is_dirty = true;
}

// Retile 

/// Retile the current workspace immediately.
pub fn retileCurrentWorkspace() void {
    const s = getState();
    if (!s.is_enabled) {
        // Tiling is disabled but windows are still tracked. The workspace
        // switcher routes them through this function for restore, so we bring
        // them back to their last known positions via the geometry cache.
        _ = restoreWorkspaceGeom();
        return;
    }
    retile(calcScreenArea(), null);
    s.is_dirty = false;
}

/// Like retileCurrentWorkspace, but passes `defer_win` through to the layout
/// context so that window is configured LAST inside every column/stack it
/// appears in.  Used by swap_master to ensure the shrinking window (old master
/// moving into the stack) fills its new slot before the growing window (new
/// master) vacates its old one — eliminating the one-frame wallpaper gap.
pub fn retileCurrentWorkspaceDeferred(defer_win: ?u32) void {
    const s = getState();
    if (!s.is_enabled) {
        _ = restoreWorkspaceGeom();
        return;
    }
    retileDeferred(calcScreenArea(), null, defer_win);
    s.is_dirty = false;
}

/// Retile the current workspace only when state has been marked dirty.
pub fn retileIfDirty() void {
    const s = getState();
    if (!s.is_enabled or !s.is_dirty) return;
    retileCurrentWorkspace();
}

/// Retile all workspaces in one pass, updating the cache for each.
/// Skips the current workspace (handled separately) and any fullscreen workspace.
pub fn retileAllWorkspaces() void {
    const s = getState();
    if (!s.is_enabled) return;

    const screen      = calcScreenArea();
    const ws_count    = tracking.getWorkspaceCount();
    const current_ws  = tracking.getCurrentWorkspace() orelse return;
    const ws_state_opt = if (!core.config.tiling.global_layout) workspaces.getState() else null;
    const ctx         = makeLayoutCtx(s);
    const effective_ws = @min(ws_count, max_workspaces);

    @memset(s.retile_lens[0..effective_ws], 0);

    // Build per-workspace window lists in one pass.  For each window, obtain
    // its workspace bitmask and iterate only over set bits using @ctz (count
    // trailing zeros) — for the common case of one workspace per window this
    // performs exactly one iteration rather than up to max_workspaces (64).
    // Windows on multiple workspaces (tags) still visit each workspace exactly
    // once via the bit-clear loop idiom (bits &= bits - 1).
    const ws_range_mask: u64 = if (effective_ws >= 64)
        ~@as(u64, 0)
    else
        (@as(u64, 1) << @intCast(effective_ws)) - 1;

    for (s.windows.items()) |win| {
        const mask = tracking.getWindowWorkspaceMask(win) orelse continue;
        var bits = mask & ws_range_mask;
        while (bits != 0) {
            const ws_bit: u8 = @intCast(@ctz(bits));
            bits &= bits - 1; // clear lowest set bit
            if (s.retile_lens[ws_bit] < max_workspace_windows) {
                s.retile_wins[ws_bit * max_workspace_windows + s.retile_lens[ws_bit]] = win;
                s.retile_lens[ws_bit] += 1;
            }
        }
    }

    var ws_idx: u8 = 0;
    while (ws_idx < effective_ws) : (ws_idx += 1) {
        if (ws_idx == current_ws) continue;
        if (comptime build.has_fullscreen) {
            if (fullscreen.getForWorkspace(ws_idx)) |_| continue;
        }

        const n = s.retile_lens[ws_idx];
        if (n == 0) continue;
        const ws_windows = s.retile_wins[ws_idx * max_workspace_windows ..][0..n];

        const saved_width = s.master_width;
        const saved_count = s.master_count;
        s.master_width = resolveMasterWidth(s, ws_state_opt, ws_idx);
        s.master_count = resolveMasterCount(s, ws_state_opt, ws_idx);
        defer s.master_width = saved_width;
        defer s.master_count = saved_count;

        invokeLayout(selectLayout(s, ws_state_opt, ws_idx, core.config.tiling.global_layout), &ctx, s, ws_windows, screen);
        markWorkspaceGeomValid(s, ws_idx);
    }

    s.last_retile_area = screen;
}

/// Retile a specific inactive workspace so its cache is correct before the
/// user switches to it. MUST be called inside a server grab.
pub fn retileInactiveWorkspace(ws_idx: u8) void {
    const s = getState();
    if (!s.is_enabled) return;
    if (comptime !build.has_workspaces) return;

    const ws_state = workspaces.getState() orelse return;

    if (ws_idx == ws_state.current) {
        retileCurrentWorkspace();
        return;
    }

    retile(calcScreenArea(), ws_idx);

    // Push windows back offscreen while their workspace is inactive.
    // Do NOT invalidate the cache: restoreWorkspaceGeom will find the
    // valid bit set and replay positions in one batch.
    for (ws_state.workspaces[ws_idx].windows.items()) |win| {
        utils.pushWindowOffscreen(core.conn, win);
    }
}

/// Compute tiled geometry bypassing the `!is_enabled` guard, then restore
/// `s.layout`. Used by the workspace switcher when floating mode is active and
/// the geometry cache is stale — this pre-populates the cache with correct
/// tiled positions so the float-restore path can use `getWindowGeom` instead
/// of falling back to the default float position.
pub fn retileForRestore() void {
    const s = getState();
    const saved = s.layout;
    s.layout = s.prev_layout;
    retile(calcScreenArea(), null);
    s.layout = saved;
    s.is_dirty = false;
}

/// Restore windows on the current workspace to their cached tiled positions,
/// bypassing the layout algorithm. Returns true if the cache is valid and
/// positions have been replayed. Returns false if the cache is stale; the caller
/// must fall back to `retileCurrentWorkspace`.
pub fn restoreWorkspaceGeom() bool {
    const s = getStateOpt() orelse return false;

    const ws_count   = collectWorkspaceWindows(s, &s.scratch_wins, null);
    const ws_windows = s.scratch_wins[0..ws_count];
    if (ws_windows.len == 0) return true;

    const current_ws = tracking.getCurrentWorkspace() orelse return false;
    if (current_ws >= max_workspaces) return false;
    if (s.workspace_geom_valid_bits & tracking.workspaceBit(current_ws) == 0) return false;

    const current_screen = calcScreenArea();
    if (!layouts.rectsEqual(current_screen, s.last_retile_area)) return false;

    // Verify every window is cached before emitting any XCB calls.
    const rects = s.scratch_rects[0..ws_windows.len];
    for (ws_windows, 0..) |win, i| {
        const wd = s.cache.get(win) orelse return false;
        if (!wd.hasValidRect()) return false;
        rects[i] = wd.rect;
    }

    for (ws_windows, rects) |win, rect| {
        utils.configureWindow(core.conn, win, rect);
    }
    // updateBorders is required here: restoreWorkspaceGeom replays cached
    // positions via utils.configureWindow directly, bypassing configureWithHints
    // and its get_border_color callback. Border colors must therefore be
    // applied as a separate pass on this fast path.
    updateBorders(s, ws_windows);
    return true;
}

// Layout control 

/// Toggle the floating layout.
///
/// Entering floating: sets `s.is_enabled = false` so every existing
/// `!s.is_enabled` guard fires automatically. `s.layout` is set to `.floating`
/// purely for bar display.
///
/// Exiting floating: re-enables the tiling engine, restores the correct layout
/// (from the current workspace in per-workspace mode, or from `prev_layout` in
/// global mode), and retiles.
pub fn toggleFloating() void {
    const s = getState();
    if (s.layout != .floating) {
        s.prev_layout = s.layout;
        s.layout      = .floating;
        s.is_enabled  = false;
        debug.info("Floating enabled (was: {s})", .{@tagName(s.prev_layout)});
        return;
    }
    s.is_enabled = true;
    const restore: Layout = if (!core.config.tiling.global_layout)
        if (comptime build.has_workspaces)
            (if (workspaces.getCurrentWorkspaceObject()) |ws| ws.layout else s.prev_layout)
        else s.prev_layout
    else
        s.prev_layout;
    s.layout = restore;
    retileCurrentWorkspace();
    bar.scheduleFullRedraw();
    debug.info("Floating disabled, restored layout: {s}", .{@tagName(restore)});
}

/// Cycle to the next layout in the enabled-layout list.
pub fn toggleLayout()        void { applyLayoutStep(true);  }
/// Cycle to the previous layout in the enabled-layout list.
pub fn toggleLayoutReverse() void { applyLayoutStep(false); }

/// Cycle through the per-layout variants for the currently active layout.
pub fn stepLayoutVariant() void {
    const s = getState();
    switch (s.layout) {
        .master  => {
            cycleEnum(&s.layout_variants.master);
            debug.info("Master variant: {s}", .{@tagName(s.layout_variants.master)});
        },
        .monocle => {
            cycleEnum(&s.layout_variants.monocle);
            debug.info("Monocle variant: {s}", .{@tagName(s.layout_variants.monocle)});
        },
        .grid    => {
            cycleEnum(&s.layout_variants.grid);
            debug.info("Grid variant: {s}", .{@tagName(s.layout_variants.grid)});
        },
        else     => {
            debug.info("{s} has no variants", .{@tagName(s.layout)});
            return;
        },
    }
    retileCurrentWorkspace();
}

pub fn applyWorkspaceLayout(ws: *const WsWorkspace) void {
    const s = getState();
    const needs_retile = s.layout != ws.layout or ws.variants != null;
    s.layout = ws.layout;
    if (ws.master_width) |mw| s.master_width = mw;
    s.master_count = ws.master_count orelse core.config.tiling.master_count;
    if (ws.variants) |v| {
        switch (v) {
            .master  => |mv| s.layout_variants.master  = mv,
            .monocle => |mv| s.layout_variants.monocle = mv,
            .grid    => |gv| s.layout_variants.grid    = gv,
        }
    }
    if (needs_retile) {
        s.is_dirty = true;
        s.workspace_geom_valid_bits = 0;
    }
}

pub inline fn defaultLayout() Layout { return layout_cycle[0]; }

pub inline fn isLayoutAvailable(layout: Layout) bool {
    return switch (layout) {
        .master    => build.has_master,
        .monocle   => build.has_monocle,
        .grid      => build.has_grid,
        .fibonacci => build.has_fibonacci,
        .floating  => true, // always built-in
    };
}

// Master width and count 

pub fn adjustMasterCount(delta: i8) void {
    const s = getState();
    const new: i16 = @as(i16, s.master_count) + delta;
    if (new < 1) return;
    const clamped: u8 = @intCast(@min(new, 10));
    if (clamped == s.master_count) return;
    s.master_count = clamped;
    if (!core.config.tiling.global_layout) {
        if (comptime build.has_workspaces) {
            if (workspaces.getCurrentWorkspaceObject()) |ws| ws.master_count = s.master_count;
        }
    }
    retileCurrentWorkspace();
}

pub inline fn increaseMasterCount() void { adjustMasterCount(1);  }
pub inline fn decreaseMasterCount() void { adjustMasterCount(-1); }

pub fn adjustMasterWidth(delta: f32) void {
    const s = getState();
    s.master_width = @max(constants.MIN_MASTER_WIDTH,
        @min(max_master_width_ratio, s.master_width + delta));
    if (!core.config.tiling.global_layout) {
        if (comptime build.has_workspaces) {
            if (workspaces.getCurrentWorkspaceObject()) |ws| ws.master_width = s.master_width;
        }
    }
    s.is_dirty = true;
    s.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

pub inline fn increaseMasterWidth() void { adjustMasterWidth( 0.025); }
pub inline fn decreaseMasterWidth() void { adjustMasterWidth(-0.025); }

// Window swap operations 

/// Swap the focused window into the master slot (index 0 of the current
/// workspace window list). If it is already the master, promotes the next
/// workspace window.
///
/// NOTE: Does NOT call retileCurrentWorkspace(). The caller (action handler)
/// is responsible for retiling inside the server grab so that the list
/// reorder and the geometry flush are part of the same atomic batch.
pub fn swapWithMaster() void {
    const s = getState();
    _ = swapWithMasterCore(s, findFocusMasterPos(s) orelse return);
}

/// Like `swapWithMaster`, but returns the displaced window so the caller can
/// transfer focus to it after retiling, still inside the server grab.
///
/// NOTE: Does NOT call retileCurrentWorkspace(). See swapWithMaster().
pub fn swapWithMasterFollowFocus() ?u32 {
    const s = getState();
    return swapWithMasterCore(s, findFocusMasterPos(s) orelse return null);
}

/// Swap the on-screen positions of the currently focused window and the most
/// recently previously focused window.
///
/// In tiling mode both windows exchange their slots in the tracking list so the
/// layout engine places each one exactly where the other was. In floating mode
/// (or when either window is individually floated) the actual X11 geometries are
/// exchanged directly and the cache is kept coherent for workspace-switch restore.
pub fn swapFocusedWithPrevious() void {
    const s       = getState();
    const focused = focus.getFocused() orelse return;
    const history = focus.historyItems();
    if (history.len == 0) return;
    const prev = history[0];
    if (prev == focused) return;

    if (!tracking.isOnCurrentWorkspace(focused)) return;
    if (!tracking.isOnCurrentWorkspace(prev))    return;

    const is_focused_tiled = s.is_enabled and s.windows.contains(focused);
    const is_prev_tiled    = s.is_enabled and s.windows.contains(prev);

    if (!is_focused_tiled or !is_prev_tiled) {
        // One or both windows are floating: exchange their on-screen geometries
        // directly without touching the tiling list.
        swapWindowGeometriesDirectly(s, focused, prev);
        _ = xcb.xcb_flush(core.conn);
        return;
    }

    // Both are under tiler control: swap their positions in the tracking list
    // so the next retile assigns each window to the other's cell.
    const all       = s.windows.items();
    const idx_focused = std.mem.indexOfScalar(u32, all, focused) orelse return;
    const idx_prev    = std.mem.indexOfScalar(u32, all, prev)    orelse return;
    swapWindowsInList(s, idx_focused, idx_prev);
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
    return s.layout == .floating;
}

/// Returns true only when tiling is *actively running* (runtime toggle on) AND
/// the window is managed by the tiler. Use this in handleConfigureRequest so
/// that toggling tiling off at runtime actually frees applications to reposition.
pub inline fn isWindowActiveTiled(window_id: u32) bool {
    const s = getStateOpt() orelse return false;
    return s.is_enabled and s.windows.contains(window_id);
}

// Focus / border management 

pub fn updateWindowFocus(old_focused: ?u32, new_focused: ?u32) void {
    const s = getState();
    for ([2]?u32{ old_focused, new_focused }) |opt| {
        const win = opt orelse continue;
        if (!s.windows.contains(win)) continue;
        applyBorderColor(s, core.conn, win, s.borderColor(win));
    }
}

// Private implementation

// Layout cycle (comptime) 

// Layouts present on disk at build time. `toggleLayout`/`toggleLayoutReverse`
// walk this list so missing layouts are never visited during cycling.
// A compile error fires if every layout file has been removed.
const layout_cycle: []const Layout = blk: {
    var list: []const Layout = &.{};
    if (build.has_master)    list = list ++ &[_]Layout{.master};
    if (build.has_monocle)   list = list ++ &[_]Layout{.monocle};
    if (build.has_grid)      list = list ++ &[_]Layout{.grid};
    if (build.has_fibonacci) list = list ++ &[_]Layout{.fibonacci};
    if (list.len == 0) @compileError("No tiling layouts found. Add at least one .zig file to src/tiling/layouts/.");
    break :blk list;
};

// layoutFromString — plain if-else over 5 fixed strings.
// StaticStringMap carries comptime build complexity for no runtime gain at n=5.
inline fn layoutFromString(name: []const u8) ?Layout {
    if (std.mem.eql(u8, name, "master-stack") or
        std.mem.eql(u8, name, "master"))    return .master;
    if (std.mem.eql(u8, name, "monocle"))   return .monocle;
    if (std.mem.eql(u8, name, "grid"))      return .grid;
    if (std.mem.eql(u8, name, "fibonacci")) return .fibonacci;
    return null;
}

/// Build the runtime-enabled layout list from the config's `layouts` array,
/// keeping only entries whose .zig file is present on disk. Duplicates are
/// dropped. Falls back to `layout_cycle` when the config produces an empty list.
fn parseEnabledLayouts(layouts_cfg: []const []const u8) struct { arr: [4]Layout, len: u8 } {
    var arr: [4]Layout = undefined;
    var len: u8 = 0;
    for (layouts_cfg) |name| {
        if (len >= arr.len) break;
        const layout = layoutFromString(name) orelse continue;
        if (!isLayoutAvailable(layout)) continue;
        if (std.mem.indexOfScalar(Layout, arr[0..len], layout) != null) continue;
        arr[len] = layout;
        len += 1;
    }
    if (len == 0) {
        @memcpy(arr[0..layout_cycle.len], layout_cycle);
        len = @intCast(layout_cycle.len);
    }
    return .{ .arr = arr, .len = len };
}

/// Walk the runtime-enabled layout list to find `current`, then step forward or
/// backward. Falls back to `layout_cycle` if state has no enabled layouts.
inline fn stepLayout(s: *const State, current: Layout, comptime forward: bool) Layout {
    const cycle: []const Layout = if (s.enabled_layout_count > 0)
        s.enabled_layouts[0..s.enabled_layout_count]
    else
        layout_cycle;
    for (cycle, 0..) |l, i| {
        if (l != current) continue;
        return cycle[if (forward) (i + 1) % cycle.len else (cycle.len + i - 1) % cycle.len];
    }
    return cycle[0]; // current not in list (disabled at reload) — jump to first
}

fn calcMasterWidth() f32 {
    const raw = scale.scaleMasterWidth(core.config.tiling.master_width);
    if (raw < 0) {
        const ratio = -raw / @as(f32, @floatFromInt(core.screen.width_in_pixels));
        return @min(max_master_width_ratio, @max(constants.MIN_MASTER_WIDTH, ratio));
    }
    return raw;
}

fn initState() State {
    const screen_height = core.screen.height_in_pixels;
    const el            = parseEnabledLayouts(core.config.tiling.layouts.items);

    return .{
        .is_enabled       = core.config.tiling.enabled,
        .layout           = blk: {
            const requested = std.meta.stringToEnum(Layout, core.config.tiling.layout)
                orelse layout_cycle[0];
            break :blk if (isLayoutAvailable(requested)) requested else layout_cycle[0];
        },
        .prev_layout           = layout_cycle[0],
        .enabled_layouts       = el.arr,
        .enabled_layout_count  = el.len,
        .layout_variants = .{
            .master  = core.config.tiling.master_variant,
            .monocle = core.config.tiling.monocle_variant,
            .grid    = core.config.tiling.grid_variant,
        },
        .master_side      = core.config.tiling.master_side,
        .master_width     = calcMasterWidth(),
        .master_count     = core.config.tiling.master_count,
        .gap_width        = scale.scaleBorderWidth(core.config.tiling.gap_width, screen_height),
        .border_width     = scale.scaleBorderWidth(core.config.tiling.border_width, screen_height),
        .border_focused   = core.config.tiling.border_focused,
        .border_unfocused = core.config.tiling.border_unfocused,
        .windows          = .{},
        .is_dirty         = false,
        .workspace_geom_valid_bits = 0,
        .last_retile_area = zero_rect,
        .cache            = .{},
        .scratch_wins     = undefined,
        .scratch_rects    = undefined,
        .retile_wins      = undefined,
        .retile_lens      = undefined,
    };
}

// Layout dispatch helpers 

/// Stable function-pointer target for `LayoutCtx.get_border_color`.
fn getBorderColorForWindow(win: u32) u32 {
    return getState().borderColor(win);
}

inline fn makeLayoutCtx(s: *State) layouts.LayoutCtx {
    return .{
        .conn             = core.conn,
        .cache            = &s.cache,
        .get_border_color = getBorderColorForWindow,
        .defer_configure  = null,
    };
}

/// Like makeLayoutCtx but sets defer_configure so the named window is emitted
/// last in every column/stack, preventing it from vacating its slot before the
/// shrinking window has filled the adjacent slot.
inline fn makeLayoutCtxDeferred(s: *State, defer_win: ?u32) layouts.LayoutCtx {
    return .{
        .conn             = core.conn,
        .cache            = &s.cache,
        .get_border_color = getBorderColorForWindow,
        .defer_configure  = defer_win,
    };
}

fn invokeLayout(
    layout: Layout,
    ctx:    *const layouts.LayoutCtx,
    s:      *State,
    wins:   []const u32,
    screen: utils.Rect,
) void {
    const w = screen.width;
    const h = screen.height;
    const y: u16 = @intCast(screen.y);
    switch (layout) {
        .master    => master.tileWithOffset(ctx, s, wins, w, h, y),
        .monocle   => monocle.tileWithOffset(ctx, s, wins, w, h, y),
        .grid      => grid.tileWithOffset(ctx, s, wins, w, h, y),
        .fibonacci => fibonacci.tileWithOffset(ctx, s, wins, w, h, y),
        .floating  => floating.tileWithOffset(ctx, s, wins, w, h, y),
    }
}

inline fn calcScreenArea() utils.Rect {
    const bar_height: u16 = if (bar.isVisible()) bar.getBarHeight() else 0;
    const is_bar_at_bottom = core.config.bar.bar_position == .bottom;
    return .{
        .x      = 0,
        .y      = if (is_bar_at_bottom) 0 else @intCast(bar_height),
        .width  = core.screen.width_in_pixels,
        .height = core.screen.height_in_pixels -| bar_height,
    };
}

fn selectLayout(s: *State, ws_state: ?*WsState, ws_idx: u8, is_global: bool) Layout {
    if (comptime !build.has_workspaces) return s.layout;
    if (is_global) return s.layout;
    const wss = ws_state orelse return s.layout;
    return if (ws_idx < wss.workspaces.len) wss.workspaces[ws_idx].layout else s.layout;
}

/// Returns the master width for `ws_idx` in per-workspace mode.
/// Falls back to the current global value for workspaces that have not yet
/// had their width adjusted (master_width == null).
inline fn resolveMasterWidth(s: *const State, ws_state: ?*WsState, ws_idx: u8) f32 {
    if (comptime !build.has_workspaces) return s.master_width;
    if (core.config.tiling.global_layout) return s.master_width;
    const wss = ws_state orelse return s.master_width;
    if (ws_idx >= wss.workspaces.len) return s.master_width;
    if (wss.workspaces[ws_idx].master_width) |mw| return mw;
    return s.master_width;
}

/// Returns the master count for `ws_idx` in per-workspace mode.
/// Falls back to the current global value for workspaces that have no override.
inline fn resolveMasterCount(s: *const State, ws_state: ?*WsState, ws_idx: u8) u8 {
    if (comptime !build.has_workspaces) return s.master_count;
    if (core.config.tiling.global_layout) return s.master_count;
    const wss = ws_state orelse return s.master_count;
    if (ws_idx >= wss.workspaces.len) return s.master_count;
    if (wss.workspaces[ws_idx].master_count) |mc| return mc;
    return s.master_count;
}

// Core retile 

/// Core retile. `for_ws`: when non-null, process that specific workspace instead
/// of the current one.
fn retile(screen: utils.Rect, for_ws: ?u8) void {
    retileDeferred(screen, for_ws, null);
}

/// Like retile but sets LayoutCtx.defer_configure = defer_win.
/// The named window is configured last inside every column/stack it appears in.
fn retileDeferred(screen: utils.Rect, for_ws: ?u8, defer_win: ?u32) void {
    const s = getState();

    const target_ws: u8 = for_ws orelse
        @intCast(tracking.getCurrentWorkspace() orelse return);

    if (comptime build.has_fullscreen) {
        if (fullscreen.getForWorkspace(target_ws)) |_| return;
    }

    const ws_count   = collectWorkspaceWindows(s, &s.scratch_wins, for_ws);
    const ws_windows = s.scratch_wins[0..ws_count];
    if (ws_windows.len == 0) return;

    const ctx = makeLayoutCtxDeferred(s, defer_win);

    // Hoist getState() once — used by resolve* and selectLayout below.
    const wss = workspaces.getState();

    const saved_width = s.master_width;
    const saved_count = s.master_count;
    if (for_ws != null) {
        s.master_width = resolveMasterWidth(s, wss, target_ws);
        s.master_count = resolveMasterCount(s, wss, target_ws);
    }
    defer s.master_width = saved_width;
    defer s.master_count = saved_count;

    invokeLayout(
        selectLayout(s, wss, target_ws, core.config.tiling.global_layout),
        &ctx, s, ws_windows, screen,
    );

    s.last_retile_area = screen;
    markWorkspaceGeomValid(s, target_ws);
}

// Border management 

/// Send border pixel only if color changed since last send.
fn applyBorderColor(s: *State, conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    const gop = s.cache.getOrPut(win);
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

inline fn updateBorders(s: *State, ws_windows: []const u32) void {
    for (ws_windows) |win| applyBorderColor(s, core.conn, win, s.borderColor(win));
}

/// Public dedup helper for window.zig's border-sweep functions.
///
/// Checks the tiling geometry cache for `win` and sends
/// `xcb_change_window_attributes BORDER_PIXEL` only when `color` differs from
/// the stored value.  Returns true when the window was found in the cache
/// (caller should `continue` and not send again).  Returns false when the
/// window has no cache entry (pure floating window never retiled), so the
/// caller falls back to an unconditional send.
///
/// This eliminates one `xcb_change_window_attributes` per tiled window per
/// event batch when the focused window has not changed — the most common case
/// during idle scroll, typing, or cursor movement inside a window.
pub fn sendBorderColorIfChanged(win: u32, color: u32) bool {
    const s = getStateOpt() orelse return false;
    const wd = s.cache.getPtr(win) orelse return false;
    if (wd.border == color) return true; // cached, color unchanged — skip XCB
    wd.border = color;
    _ = xcb.xcb_change_window_attributes(core.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    return true;
}

// Window list helpers 

/// Collect windows belonging to the target workspace into `buf`.
/// `for_ws`: when non-null, filter by that index; when null, use current workspace.
/// Returns the number of windows written.
fn collectWorkspaceWindows(s: *State, buf: []u32, for_ws: ?u8) usize {
    // Optimization: iterate the per-workspace window list (typically 5–15
    // entries) and filter for tiling-managed windows, rather than scanning
    // the global s.windows list (up to 64 entries across all workspaces) and
    // probing the workspace hash-map for every entry.  The outer loop is 5–15
    // iterations instead of 64; each body just calls Tracking.contains(), which
    // is a linear scan of a 64-element contiguous u32 array that fits in L1.
    if (comptime build.has_workspaces) {
        const ws_obj = if (for_ws) |idx| blk: {
            const ws_state = workspaces.getState() orelse break :blk null;
            if (idx >= ws_state.workspaces.len) break :blk null;
            break :blk &ws_state.workspaces[idx];
        } else workspaces.getCurrentWorkspaceObject();

        if (ws_obj) |ws| {
            var n: usize = 0;
            for (ws.windows.items()) |win| {
                if (n >= buf.len) break;
                if (s.windows.contains(win)) { buf[n] = win; n += 1; }
            }
            return n;
        }
    }

    // Fallback: no workspace subsystem or workspace lookup failed — scan all.
    var n: usize = 0;
    for (s.windows.items()) |win| {
        if (n >= buf.len) break;
        const is_on_target = if (for_ws) |idx|
            tracking.isWindowOnWorkspace(win, idx)
        else
            tracking.isOnCurrentWorkspace(win);
        if (is_on_target) { buf[n] = win; n += 1; }
    }
    return n;
}

inline fn hasWindowBufCapacity(s: *const State, n: usize, comptime caller: []const u8) bool {
    if (n <= s.scratch_wins.len) return true;
    debug.warn(caller ++ ": too many windows ({})", .{n});
    return false;
}

fn moveWindowToIndex(s: *State, from_idx: usize, to_idx: usize) void {
    if (from_idx == to_idx) return;
    const current = s.windows.items();
    if (!hasWindowBufCapacity(s, current.len, "moveWindowToIndex")) return;

    const win = current[from_idx];
    var j: usize = 0;
    for (current, 0..) |w, i| {
        if (i == from_idx) continue;
        if (j == to_idx) { s.scratch_wins[j] = win; j += 1; }
        s.scratch_wins[j] = w;
        j += 1;
    }
    if (to_idx >= j) { s.scratch_wins[j] = win; j += 1; }
    s.windows.reorder(s.scratch_wins[0..j]);
}

/// Reposition `win` within the global window list so that it lands at
/// workspace-filtered index `target` (0 = master slot).
///
/// Background — the shift arithmetic:
///   moveWindowToIndex(from, to) removes the source element first, then
///   inserts at position `to` in the *shortened* list. When `from` lies
///   before `to`, removal shifts elements left by one, so the effective
///   insertion point is `tg - 1`. When `from` lies after `to` no shift occurs.
fn moveWindowToFilteredSlot(s: *State, win: u32, target: usize) void {
    const items = s.windows.items();
    const from_global = std.mem.indexOfScalar(u32, items, win) orelse return;

    var filtered_count: usize = 0;
    var to_global: ?usize = null;
    for (items, 0..) |w, i| {
        if (w == win) continue;
        if (!tracking.isOnCurrentWorkspace(w)) continue;
        if (filtered_count == target) { to_global = i; break; }
        filtered_count += 1;
    }

    const tg = to_global orelse return;
    const effective_to: usize = if (from_global < tg) tg - 1 else tg;
    if (effective_to != from_global) moveWindowToIndex(s, from_global, effective_to);
}

/// Swap the two elements at `idx_a` and `idx_b` inside the tracking list.
fn swapWindowsInList(s: *State, idx_a: usize, idx_b: usize) void {
    if (idx_a == idx_b) return;
    std.mem.swap(u32, &s.windows.buf[idx_a], &s.windows.buf[idx_b]);
}

/// Swap two tiled windows by their IDs.  Used by focus.zig to implement
/// Mod+Shift+j / Mod+Shift+k — move the focused window in cycle order.
pub fn swapWindowsById(win_a: u32, win_b: u32) void {
    const s   = getState();
    const all = s.windows.items();
    const idx_a = std.mem.indexOfScalar(u32, all, win_a) orelse return;
    const idx_b = std.mem.indexOfScalar(u32, all, win_b) orelse return;
    swapWindowsInList(s, idx_a, idx_b);
    retileCurrentWorkspace();
}

/// Locates the focused window and the current workspace's master window in the
/// ordered window list. Returns null when preconditions are not met (nothing
/// focused, not tiled, not on current workspace, or fewer than 2 windows).
const FocusMasterPos = struct { fp: usize, mp: usize, all: []const u32 };
fn findFocusMasterPos(s: *State) ?FocusMasterPos {
    const focused = focus.getFocused() orelse return null;
    if (!s.windows.contains(focused) or !tracking.isOnCurrentWorkspace(focused)) return null;
    const all = s.windows.items();
    if (all.len < 2) return null;
    var fp: ?usize = null;
    var mp: ?usize = null;
    for (all, 0..) |win, i| {
        if (win == focused) fp = i;
        if (mp == null and tracking.isOnCurrentWorkspace(win)) mp = i;
        if (fp != null and mp != null) break;
    }
    return .{ .fp = fp orelse return null, .mp = mp orelse return null, .all = all };
}

/// Shared core for both swap-with-master variants.
///
/// Uses swapWindowsInList (O(1) std.mem.swap) instead of moveWindowToIndex
/// (O(n) remove-then-insert) so that only the two swapping windows receive new
/// geometry during the subsequent retile.  Every other window's slot is
/// unchanged → same rect → cache hit → no configure_window call → no
/// intermediate frames visible to the compositor.
fn swapWithMasterCore(s: *State, pos: FocusMasterPos) ?u32 {
    if (pos.fp == pos.mp) {
        // Focused is already master — promote the next workspace window.
        // A swap is sufficient: brings the target to index mp, demotes the
        // current master to that target's slot.  Stack order differs from the
        // old rotate but the visual result is identical for single-master layouts.
        for (pos.all[pos.mp + 1..], pos.mp + 1..) |win, i| {
            if (tracking.isOnCurrentWorkspace(win)) {
                swapWindowsInList(s, pos.mp, i);
                return win;
            }
        }
        return null;
    }
    const other = pos.all[pos.mp];
    swapWindowsInList(s, pos.fp, pos.mp);
    return other;
}

/// Query the current geometry of `win` from the X server.
/// Returns null when the window no longer exists or the server returns an error.
fn queryWindowRect(win: u32) ?utils.Rect {
    const cookie = xcb.xcb_get_geometry(core.conn, win);
    const reply  = xcb.xcb_get_geometry_reply(core.conn, cookie, null) orelse return null;
    defer std.c.free(reply);
    return .{
        .x      = reply.*.x,
        .y      = reply.*.y,
        .width  = reply.*.width,
        .height = reply.*.height,
    };
}

fn updateCacheRect(s: *State, win: u32, rect: utils.Rect) void {
    s.cache.getOrPut(win).value_ptr.rect = rect;
}

/// Exchange the on-screen positions of `win_a` and `win_b`.
fn swapWindowGeometriesDirectly(s: *State, win_a: u32, win_b: u32) void {
    const rect_a: utils.Rect = blk: {
        if (s.cache.get(win_a)) |wd| if (wd.hasValidRect()) break :blk wd.rect;
        break :blk queryWindowRect(win_a) orelse return;
    };
    const rect_b: utils.Rect = blk: {
        if (s.cache.get(win_b)) |wd| if (wd.hasValidRect()) break :blk wd.rect;
        break :blk queryWindowRect(win_b) orelse return;
    };

    if (layouts.rectsEqual(rect_a, rect_b)) return;

    utils.configureWindow(core.conn, win_a, rect_b);
    utils.configureWindow(core.conn, win_b, rect_a);
    updateCacheRect(s, win_a, rect_b);
    updateCacheRect(s, win_b, rect_a);
}

// Misc private helpers

inline fn markWorkspaceGeomValid(s: *State, ws_idx: anytype) void {
    if (ws_idx < max_workspaces) s.workspace_geom_valid_bits |= tracking.workspaceBit(ws_idx);
}

inline fn applyLayoutStep(comptime forward: bool) void {
    const s = getState();
    if (s.layout == .floating) return;
    applyLayout(s, stepLayout(s, s.layout, forward));
}

fn applyLayout(s: *State, layout: Layout) void {
    s.layout = layout;
    if (!core.config.tiling.global_layout) {
        if (comptime build.has_workspaces) {
            if (workspaces.getCurrentWorkspaceObject()) |ws| ws.layout = layout;
        }
    }
    retileCurrentWorkspace();
    bar.scheduleFullRedraw();
    debug.info("Layout: {s}", .{@tagName(layout)});
}

/// Advance a finite enum field to its next variant, wrapping around.
inline fn cycleEnum(v: anytype) void {
    const T = @TypeOf(v.*);
    v.* = @enumFromInt((@intFromEnum(v.*) + 1) % std.meta.fields(T).len);
}
