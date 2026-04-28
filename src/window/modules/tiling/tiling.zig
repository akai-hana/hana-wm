//! Tiling window manager
//! Orchestrates window layout, tracking, and border management for all tiled windows.

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

const fullscreen = if (build.has_fullscreen) @import("fullscreen");
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


/// Fallback no-op layout used when a layout module is excluded from the build.
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
const leaf       = if (build.has_leaf)       @import("leaf")       else LayoutStub;
const scroll     = if (build.has_scroll)     @import("scroll")     else LayoutStub;

// Comptime verification that every layout module (or its LayoutStub fallback)
// exports a `tileWithOffset` function with the exact signature the dispatcher
// `invokeLayout` requires.  This fires a compile error — not a runtime panic —
// the moment a new layout module is added or an existing one's signature drifts,
// before any tests are run.  Without this check, a duck-typed mismatch only
// surfaces if the mismatched layout is selected at runtime in a test run that
// actually exercises it.
comptime {
    const LayoutModule = type;
    const expected_params = .{
        *const layouts.LayoutCtx, // ctx
        *State,                   // state
        []const u32,              // windows
        u16,                      // screen_w
        u16,                      // screen_h
        u16,                      // y_offset
    };
    const layout_modules = [_]LayoutModule{ master, monocle, grid, fibonacci, leaf, scroll };
    for (layout_modules) |Mod| {
        if (!@hasDecl(Mod, "tileWithOffset")) {
            @compileError(@typeName(Mod) ++ " must export `tileWithOffset`");
        }
        const fn_info = @typeInfo(@TypeOf(Mod.tileWithOffset));
        if (fn_info != .@"fn") {
            @compileError(@typeName(Mod) ++ ".tileWithOffset must be a function");
        }
        const params = fn_info.@"fn".params;
        if (params.len != expected_params.len) {
            @compileError(@typeName(Mod) ++ ".tileWithOffset has wrong parameter count");
        }
        // Parameter type checks — each must match the expected type exactly.
        for (expected_params, 0..) |ExpT, i| {
            if (params[i].type) |ActT| {
                if (ActT != ExpT) {
                    @compileError(@typeName(Mod) ++ ".tileWithOffset parameter " ++
                        std.fmt.comptimePrint("{d}", .{i}) ++ " type mismatch");
                }
            }
        }
    }
}

// Module constants

const max_master_width_ratio: f32  = 0.95; // prevents master from consuming the full screen
const max_master_count:       u8   = 10;
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
    leaf,
    scroll,
    /// Windows are left at their current positions. Never part of the layout cycle.
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

/// All scroll-layout-specific runtime state, grouped to make it clear
/// which fields are only meaningful while `layout == .scroll`.  When a
/// different layout is active these fields are dormant but retain their
/// last values so that switching back to scroll restores the viewport
/// position the user left it at.
///
/// Kept on State rather than being heap-allocated so that the WM never
/// touches an allocator during normal operation.  The size cost is
/// negligible (16 bytes) and the separation makes future removal of the
/// scroll layout a one-field delete instead of a multi-site grep.
pub const ScrollState = struct {
    /// Horizontal pixel offset of the scroll viewport.
    /// Clamped by scroll.tileWithOffset on every retile.
    offset:       i32   = 0,
    /// Window count seen on the last scroll retile.
    /// Used to detect new windows and snap the viewport to them.
    prev_n:       usize = 0,
    /// The window that held focus just before the current one, inside the
    /// scroll layout.  Updated on every real A→B focus transition.  Used
    /// by takePrevFocusedForScroll so closing the focused window restores
    /// focus to the previous one rather than falling back to list order.
    prev_focused: ?u32  = null,
};

pub const State = struct {
    is_enabled:       bool,
    layout:           Layout,
    /// The layout active before floating mode was entered.
    /// Used by retileForRestore and addWindow when the current layout is .floating.
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
    enabled_layouts:       [6]Layout,
    enabled_layout_count:  u8,

    /// Scroll-layout runtime state, grouped so its lifetime and ownership are
    /// explicit.  Dormant (but preserved) when layout != .scroll.
    scroll: ScrollState,

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

    // Scratch buffer — fixed-size array embedded in State (BSS, zero allocation).
    //
    // Reused across retile calls to avoid per-call stack pressure.
    //   scratch_wins — [max_workspace_windows]u32   single-workspace window list;
    //                  also used by retileAllWorkspaces for per-workspace collection.
    scratch_wins: [max_workspace_windows]u32,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gap_width, .border = self.border_width };
    }

    /// Returns the border color for `win`: 0 for fullscreen windows, focused or
    /// unfocused color otherwise.
    pub inline fn borderColor(self: *const State, win: u32) u32 {
        if (build.has_fullscreen) {
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

    const ns = getState();

    // Reset all workspace layouts and master widths to the new config defaults.
    // Per-workspace adjustments made at runtime are intentionally discarded so
    // the reloaded config values take effect immediately.
    if (build.has_workspaces) {
        if (workspaces.getState()) |ws_state| {
            for (ws_state.workspaces) |*ws| {
                ws.layout       = ns.layout;
                ws.master_width = null;
                ws.master_count = null;
            }
        }
    }

    if (ns.is_enabled) {
        // Wrap everything in a single server grab so picom never composites a
        // frame where some windows have the new border width but the layout has
        // not yet been recalculated.
        //
        // Current-workspace windows: BORDER_WIDTH is merged into the geometry
        // configure_window call inside retileCurrentWorkspaceReload, saving one
        // XCB round-trip per window vs. the old separate-loop approach.
        //
        // Inactive-workspace windows: they only receive a geometry
        // configure_window when their workspace is next activated, so they
        // MUST get an explicit BORDER_WIDTH send here — otherwise the new
        // border width is never applied to them.
        _ = xcb.xcb_grab_server(core.conn);
        const current_ws = tracking.getCurrentWorkspace();
        for (ns.windows.items()) |win| {
            // Skip current-workspace windows: retileCurrentWorkspaceReload
            // merges BORDER_WIDTH into their geometry request below.
            if (current_ws) |cws| {
                if (tracking.isWindowOnWorkspace(win, @intCast(cws))) continue;
            }
            _ = xcb.xcb_configure_window(core.conn, win,
                xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{ns.border_width});
        }
        retileCurrentWorkspaceReload(ns.border_width);
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

// Window management

pub fn addWindow(window_id: u32) void {
    std.debug.assert(window_id != 0);
    const s = getState();

    // Always add to the tracking list, even when the floating layout is active
    // (s.is_enabled == false). Windows opened during floating mode must be tracked
    // so they enter the tiling pool when floating is later exited.
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
    // AND the embedded WM_NORMAL_HINTS in one operation.  No-op when the window
    // was never cached (e.g. floating windows that opened while tiling was disabled).
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
    // Grab, border sweep, bar redraw, and flush are the caller's responsibility
    // (input.zig executeAction / executeMouseAction).  Keeping this function
    // grab-agnostic matches the swapWithMaster / swapWithMasterFollowFocus
    // convention and lets the caller compose the full atomic batch.
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
    const wd = s.cache.getPtr(window_id) orelse return null;
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
        _ = restoreWorkspaceGeom();
        return;
    }
    retileImpl(calcScreenArea(), .{});
    s.is_dirty = false;
}

/// Like retileCurrentWorkspace, but passes `defer_win` through to the layout
/// context so that window is configured LAST inside every column/stack it
/// appears in.  Used by swap_master to eliminate the one-frame wallpaper gap.
pub fn retileCurrentWorkspaceDeferred(defer_win: ?u32) void {
    const s = getState();
    if (!s.is_enabled) { _ = restoreWorkspaceGeom(); return; }
    retileImpl(calcScreenArea(), .{ .defer_win = defer_win });
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
///
/// Previously this function built a flattened 2-D window-list array
/// (retile_wins[max_workspaces * max_workspace_windows]) in a first pass using
/// bitmask iteration, then processed each workspace in a second pass.  That
/// required 32 KB of BSS scratch space and was sensitive to the interaction
/// between the two passes.
///
/// Now: a single loop collects each workspace's windows into scratch_wins (128 B
/// of already-available BSS) immediately before invoking the layout.  The
/// tradeoff — O(workspaces × all_windows) instead of O(all_windows) — is
/// acceptable because both counts are bounded small (≤64 workspaces, ≤128
/// windows per workspace) and this path only runs on workspace switch, not on
/// every keypress.
pub fn retileAllWorkspaces() void {
    const s = getState();
    if (!s.is_enabled) return;

    const screen      = calcScreenArea();
    const ws_count    = tracking.getWorkspaceCount();
    const current_ws  = tracking.getCurrentWorkspace() orelse return;
    const ws_state_opt = if (!core.config.tiling.global_layout) workspaces.getState() else null;
    var   ctx         = makeLayoutCtx(s);
    const effective_ws = @min(ws_count, max_workspaces);

    var ws_idx: u8 = 0;
    while (ws_idx < effective_ws) : (ws_idx += 1) {
        if (ws_idx == current_ws) continue;
        if (build.has_fullscreen) {
            if (fullscreen.getForWorkspace(ws_idx)) |_| continue;
        }

        const n = collectWorkspaceWindows(s, &s.scratch_wins, ws_idx);
        if (n == 0) continue;
        const ws_windows = s.scratch_wins[0..n];

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
    if (!build.has_workspaces) return;

    const ws_state = workspaces.getState() orelse return;
    if (ws_idx == ws_state.current) { retileCurrentWorkspace(); return; }

    retileImpl(calcScreenArea(), .{ .for_ws = ws_idx });

    const bit = tracking.workspaceBit(ws_idx);
    for (tracking.allWindows()) |entry| {
        if (entry.mask & bit != 0) utils.pushWindowOffscreen(core.conn, entry.win);
    }
}

/// Compute tiled geometry bypassing the `!is_enabled` guard, then restore
/// `s.layout`. Used by the workspace switcher when floating mode is active and
/// the geometry cache is stale — pre-populates the cache so float-restore can
/// use `getWindowGeom` instead of falling back to the default float position.
pub fn retileForRestore() void {
    const s = getState();
    const saved = s.layout;
    s.layout = s.prev_layout;
    retileImpl(calcScreenArea(), .{});
    s.layout = saved;
    s.is_dirty = false;
}

/// Retile the current workspace, merging `border_width` into each geometry
/// configure_window call. Used exclusively by reloadConfig so that BORDER_WIDTH
/// and X|Y|W|H are sent as a single request per window inside the server grab.
fn retileCurrentWorkspaceReload(border_width: u16) void {
    const s = getState();
    if (!s.is_enabled) return;
    retileImpl(calcScreenArea(), .{ .border_width = border_width });
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

    // Pass 1 — validate all cache entries before emitting any XCB calls.
    // getPtr returns a stable pointer (CacheMap never reallocates) so we can
    // collect pointers here and dereference them safely in pass 2.
    var wd_ptrs: [max_workspace_windows]*layouts.WindowData = undefined;
    for (ws_windows, 0..) |win, i| {
        const wd = s.cache.getPtr(win) orelse return false;
        if (!wd.hasValidRect()) return false;
        wd_ptrs[i] = wd;
    }

    // Pass 2 — configure + border in one loop (replaces the previous separate
    // configureWindow pass and updateBorders pass).
    for (ws_windows, wd_ptrs[0..ws_windows.len]) |win, wd| {
        utils.configureWindow(core.conn, win, wd.rect);
        const color = s.borderColor(win);
        if (wd.border != color) {
            wd.border = color;
            _ = xcb.xcb_change_window_attributes(core.conn, win,
                xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
        }
    }
    return true;
}

// Layout control

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
    // Variants are always global — all inactive workspace caches are now stale.
    s.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

/// Apply `ws`'s stored layout/variant/master settings to State, marking dirty when anything changed.
pub fn applyWorkspaceLayout(ws: *const WsWorkspace) void {
    const s = getState();
    const needs_retile =
        s.layout != ws.layout
        or ws.variants != null
        or (ws.master_width != null and ws.master_width.? != s.master_width)
        or (ws.master_count != null and ws.master_count.? != s.master_count);
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
        .leaf       => build.has_leaf,
        .scroll     => build.has_scroll,
        .floating  => true, // always built-in
    };
}

// Master width and count

pub fn adjustMasterCount(delta: i8) void {
    const s = getState();
    const new: i16 = @as(i16, s.master_count) + delta;
    if (new < 1) return;
    const clamped: u8 = @intCast(@min(new, max_master_count));
    if (clamped == s.master_count) return;
    s.master_count = clamped;
    if (!core.config.tiling.global_layout) {
        if (build.has_workspaces) {
            if (workspaces.getCurrentWorkspaceObject()) |ws| ws.master_count = s.master_count;
        }
    }
    // In global mode master_count applies to every workspace, so all inactive
    // workspace caches are now stale.
    if (core.config.tiling.global_layout) s.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

pub inline fn increaseMasterCount() void { adjustMasterCount(1);  }
pub inline fn decreaseMasterCount() void { adjustMasterCount(-1); }

pub fn adjustMasterWidth(delta: f32) void {
    const s = getState();
    s.master_width = @max(constants.MIN_MASTER_WIDTH,
        @min(max_master_width_ratio, s.master_width + delta));
    if (!core.config.tiling.global_layout) {
        if (build.has_workspaces) {
            if (workspaces.getCurrentWorkspaceObject()) |ws| ws.master_width = s.master_width;
        }
    }
    // Invalidate inactive workspace caches so their next switch-in forces a
    // full retile with the new width, rather than replaying stale positions.
    // is_dirty is NOT set here: retileCurrentWorkspace() immediately below
    // sets is_dirty = false unconditionally, making the write a no-op.
    s.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
}

pub inline fn increaseMasterWidth() void { adjustMasterWidth( 0.025); }
pub inline fn decreaseMasterWidth() void { adjustMasterWidth(-0.025); }

/// Shift the scroll-layout viewport left or right by one slot.
/// `delta` is +1 (right/forward) or -1 (left/backward).
/// No-op when the current layout is not .scroll.
/// tileWithOffset clamps the result to [0, max_off] on the next retile.
pub fn stepScrollView(delta: i32) void {
    const s = getState();
    if (s.layout != .scroll) return;
    const slot_w: i32 = @intCast(core.screen.width_in_pixels / 2);
    s.scroll.offset += delta * slot_w;
    retileCurrentWorkspace();
}

pub inline fn scrollViewLeft()  void { stepScrollView(-1); }
pub inline fn scrollViewRight() void { stepScrollView( 1); }

/// Scroll layout only: if `win` is not fully in the current viewport, snaps
/// `scrolling_offset` so `win` occupies either the left or right half-screen
/// slot — whichever requires the smaller offset change.
///
/// Returns true when the offset actually changed (caller should retile).
///
/// Visibility rule: window at filtered index `fi` has its left (strip) edge at
/// `fi * slot_w`.  It is fully visible when that edge falls in [scroll, scroll +
/// slot_w].  Outside that range:
///   • edge > scroll + slot_w  →  window is to the right  →  place on right half:
///     new_scroll = fi*slot_w - slot_w   (predecessor fills left half)
///   • edge < scroll           →  window is to the left   →  place on left half:
///     new_scroll = fi*slot_w            (successor  fills right half)
fn snapScrollOffsetToWindow(s: *State, win: u32) bool {
    const ws_count = collectWorkspaceWindows(s, &s.scratch_wins, null);
    const ws_wins  = s.scratch_wins[0..ws_count];
    const fi = std.mem.indexOfScalar(u32, ws_wins, win) orelse return false;

    const fi_i32:  i32 = @intCast(fi);
    const slot_w:  i32 = @intCast(core.screen.width_in_pixels / 2);
    const n_i32:   i32 = @intCast(ws_wins.len);
    const sw_i32:  i32 = @intCast(core.screen.width_in_pixels);
    const max_off: i32 = @max(0, n_i32 * slot_w - sw_i32);

    const win_left:  i32 = fi_i32 * slot_w;
    const scroll_off = s.scroll.offset;

    // Already fully visible — left edge is inside [scroll_off, scroll_off + slot_w].
    if (win_left >= scroll_off and win_left <= scroll_off + slot_w) return false;

    const new_scroll: i32 = if (win_left > scroll_off + slot_w)
        win_left - slot_w
    else
        win_left;

    const clamped = std.math.clamp(new_scroll, 0, max_off);
    if (clamped == scroll_off) return false;
    s.scroll.offset = clamped;
    return true;
}

/// Scroll layout only: snaps the viewport to the currently focused window when
/// it is off-screen, then retiles. Called after keyboard focus-cycle actions
/// (focus_next_window / focus_prev_window) so a window that was moved into
/// focus via Mod+j/k is immediately brought into view.
///
/// No-op when:
///   • the active layout is not .scroll
///   • no window is focused
///   • the focused window is already fully visible in the current viewport
pub fn snapScrollToFocused() void {
    const s = getState();
    if (s.layout != .scroll) return;
    const win = focus.getFocused() orelse return;
    if (snapScrollOffsetToWindow(s, win)) retileCurrentWorkspace();
}

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

/// Like swapWithMaster but returns the post-swap per-workspace window slice
/// (already residing in s.scratch_wins). Pass it directly to
/// retileCurrentWorkspaceDeferredPrebuilt to avoid a redundant
/// collectWorkspaceWindows call on the same hot path.
///
/// Returns null when preconditions are not met (nothing focused, fewer than 2
/// windows, etc.) — the caller should skip retile in that case.
pub fn swapWithMasterGetWins() ?[]const u32 {
    const s = getState();
    const pos = findFocusMasterPos(s) orelse return null;
    _ = swapWithMasterCore(s, pos);
    return pos.ws_wins; // already updated in-place by swapWithMasterCore
}

/// Like swapWithMasterFollowFocus but also returns the post-swap workspace
/// window slice so the caller can skip the second collectWorkspaceWindows call.
pub fn swapWithMasterFollowFocusGetWins() ?struct { displaced: ?u32, ws_wins: []const u32 } {
    const s = getState();
    const pos = findFocusMasterPos(s) orelse return null;
    const displaced = swapWithMasterCore(s, pos);
    return .{ .displaced = displaced, .ws_wins = pos.ws_wins };
}

/// Retile the current workspace using a pre-built window list, skipping the
/// collectWorkspaceWindows scan. Intended for use with the slice returned by
/// swapWithMasterGetWins / swapWithMasterFollowFocusGetWins so that the
/// swap-master action path performs one collect instead of two.
pub fn retileCurrentWorkspaceDeferredPrebuilt(ws_wins: []const u32, defer_win: ?u32) void {
    const s = getState();
    if (!s.is_enabled) { _ = restoreWorkspaceGeom(); return; }
    retileImpl(calcScreenArea(), .{ .defer_win = defer_win, .pre_built = ws_wins });
    s.is_dirty = false;
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
        applyBorderColor(s, core.conn, win, s.borderColor(win));
    }
}

/// Scroll layout only: return and consume the previously focused window so
/// that the caller can restore focus to it after the current focused window
/// is closed.
///
/// Returns null when:
///   • the scroll layout is not compiled in (comptime)
///   • the active layout is not .scroll
///   • no previous focus has been recorded yet
///
/// Consuming (clearing) prev_focused prevents a stale value from being
/// reused across multiple successive window closes.
pub fn takePrevFocusedForScroll() ?u32 {
    if (comptime !build.has_scroll) return null;
    const s = getState();
    if (s.layout != .scroll) return null;
    const prev = s.scroll.prev_focused orelse return null;
    s.scroll.prev_focused = null;
    return prev;
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
    if (build.has_leaf)       list = list ++ &[_]Layout{.leaf};
    if (build.has_scroll)     list = list ++ &[_]Layout{.scroll};
    if (list.len == 0) @compileError("No tiling layouts found. Add at least one .zig file to src/tiling/layouts/.");
    break :blk list;
};

// layoutFromString — plain if-else over 6 fixed strings.
// StaticStringMap carries comptime build complexity for no runtime gain at n=6.
inline fn layoutFromString(name: []const u8) ?Layout {
    if (std.mem.eql(u8, name, "master-stack") or
        std.mem.eql(u8, name, "master"))    return .master;
    if (std.mem.eql(u8, name, "monocle"))   return .monocle;
    if (std.mem.eql(u8, name, "grid"))      return .grid;
    if (std.mem.eql(u8, name, "fibonacci")) return .fibonacci;
    if (std.mem.eql(u8, name, "leaf"))       return .leaf;
    if (std.mem.eql(u8, name, "scroll"))     return .scroll;
    return null;
}

/// Build the runtime-enabled layout list from the config's `layouts` array,
/// keeping only entries whose .zig file is present on disk. Duplicates are
/// dropped. Falls back to `layout_cycle` when the config produces an empty list.
fn parseEnabledLayouts(layouts_cfg: []const []const u8) struct { arr: [6]Layout, len: u8 } {
    var arr: [6]Layout = undefined;
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

/// Compute the initial master pane width ratio from config, converting negative
/// pixel values to screen-relative fractions.
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
        .scroll           = .{},
        .cache            = .{},
        .scratch_wins     = undefined,
    };
}

// Layout dispatch helpers

/// Stable function-pointer target for `LayoutCtx.get_border_color`.
fn getBorderColorForWindow(win: u32) u32 {
    return getState().borderColor(win);
}

/// Build a LayoutCtx for a normal retile.  defer_configure and border_width
/// are left at their defaults (null); retileImpl sets them from RetileOpts
/// after this call returns, keeping the construction site minimal.
inline fn makeLayoutCtx(s: *State) layouts.LayoutCtx {
    return .{
        .conn             = core.conn,
        .cache            = &s.cache,
        .get_border_color = getBorderColorForWindow,
        .focused_win      = focus.getFocused(),
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
        .leaf       => leaf.tileWithOffset(ctx, s, wins, w, h, y),
        .scroll     => scroll.tileWithOffset(ctx, s, wins, w, h, y),
        .floating  => floating.tileWithOffset(ctx, s, wins, w, h, y),
    }
}

/// Screen area available for tiling, with bar height subtracted from the appropriate edge.
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
    if (!build.has_workspaces) return s.layout;
    if (is_global) return s.layout;
    const wss = ws_state orelse return s.layout;
    return if (ws_idx < wss.workspaces.len) wss.workspaces[ws_idx].layout else s.layout;
}

/// Returns the master width for `ws_idx` in per-workspace mode.
/// Falls back to the current global value for workspaces that have not yet
/// had their width adjusted (master_width == null).
inline fn resolveMasterWidth(s: *const State, ws_state: ?*WsState, ws_idx: u8) f32 {
    if (!build.has_workspaces) return s.master_width;
    if (core.config.tiling.global_layout) return s.master_width;
    const wss = ws_state orelse return s.master_width;
    if (ws_idx >= wss.workspaces.len) return s.master_width;
    if (wss.workspaces[ws_idx].master_width) |mw| return mw;
    return s.master_width;
}

/// Returns the master count for `ws_idx` in per-workspace mode.
/// Falls back to the current global value for workspaces that have no override.
inline fn resolveMasterCount(s: *const State, ws_state: ?*WsState, ws_idx: u8) u8 {
    if (!build.has_workspaces) return s.master_count;
    if (core.config.tiling.global_layout) return s.master_count;
    const wss = ws_state orelse return s.master_count;
    if (ws_idx >= wss.workspaces.len) return s.master_count;
    if (wss.workspaces[ws_idx].master_count) |mc| return mc;
    return s.master_count;
}

// Core retile

/// Options for the single core retile implementation.  All public retile
/// entry points are thin wrappers that fill in this struct and call retileImpl,
/// eliminating the near-duplicate logic that previously lived across four
/// private functions (retile, retileDeferred, retileCurrentWorkspaceReload,
/// retileCurrentWorkspaceDeferredPrebuilt).
const RetileOpts = struct {
    /// Target workspace.  Null = current workspace.
    for_ws:       ?u8           = null,
    /// When non-null, this window's configure_window call is emitted last
    /// within every column/stack group it belongs to.
    defer_win:    ?u32          = null,
    /// When non-null, XCB_CONFIG_WINDOW_BORDER_WIDTH is merged into the
    /// per-window geometry request.  Set only during reloadConfig.
    border_width: ?u16          = null,
    /// When non-null, skip collectWorkspaceWindows and use this list directly.
    /// The caller guarantees the slice contents match the current workspace.
    pre_built:    ?[]const u32  = null,
};

/// Single implementation underlying every public retile entry point.
fn retileImpl(screen: utils.Rect, opts: RetileOpts) void {
    const s = getState();

    const target_ws: u8 = opts.for_ws orelse
        @intCast(tracking.getCurrentWorkspace() orelse return);

    if (build.has_fullscreen) {
        if (fullscreen.getForWorkspace(target_ws)) |_| return;
    }

    const ws_windows: []const u32 = if (opts.pre_built) |pb| pb else blk: {
        const n = collectWorkspaceWindows(s, &s.scratch_wins, opts.for_ws);
        break :blk s.scratch_wins[0..n];
    };
    if (ws_windows.len == 0) return;

    var ctx = makeLayoutCtx(s);
    ctx.defer_configure = opts.defer_win;
    ctx.border_width    = opts.border_width;

    const wss = workspaces.getState();

    const saved_width = s.master_width;
    const saved_count = s.master_count;
    if (opts.for_ws != null) {
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

/// Change the border pixel for `win` only when `color` differs from the cached value.
fn applyBorderColor(s: *State, conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    const gop = s.cache.getOrPut(win);
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

/// Refresh border colors for all `ws_windows`, deduped via the cache.
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
    // Must iterate s.windows.items() (tiling order), not tracking.allWindows()
    // (registration order): swap/move operations reorder s.windows.buf, so
    // retile must observe the same sequence or swaps have no visual effect.
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

/// Move the element at `from_idx` to `to_idx` in `s.windows`, shifting intervening elements.
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

    // Single fused pass: find from_global (position of `win`) and to_global
    // (target filtered slot, skipping `win` itself) simultaneously with early
    // exit when both are found — replaces two separate O(N) scans.
    var from_global:    ?usize = null;
    var to_global:      ?usize = null;
    var filtered_count: usize  = 0;
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
    const tg = to_global   orelse return;
    const effective_to: usize = if (fg < tg) tg - 1 else tg;
    if (effective_to != fg) moveWindowToIndex(s, fg, effective_to);
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
    // Single fused pass — replaces two separate indexOfScalar O(N) scans.
    var idx_a: ?usize = null;
    var idx_b: ?usize = null;
    for (all, 0..) |w, i| {
        if (w == win_a) idx_a = i;
        if (w == win_b) idx_b = i;
        if (idx_a != null and idx_b != null) break;
    }
    swapWindowsInList(s, idx_a orelse return, idx_b orelse return);
    retileCurrentWorkspace();
}

/// Locates the focused window and the current workspace's master window in the
/// ordered window list. Returns null when preconditions are not met (nothing
/// focused, not tiled, not on current workspace, or fewer than 2 windows).
/// fp_global   — index of the focused window in s.windows.buf
/// mp_global   — index of the master window (ws_wins[0]) in s.windows.buf
/// fp_filtered — index of the focused window in the per-workspace ordered list
///               (0 means the focused window IS the current master)
/// ws_wins     — per-workspace filtered window slice, matching the order the
///               layout module receives; ws_wins[0] is always the layout master.
///               Points into s.scratch_wins; valid until the next call that
///               overwrites that buffer.
const FocusMasterPos = struct {
    fp_global:   usize,
    mp_global:   usize,
    /// Global index of ws_wins[1] — the first stack window.
    /// Pre-computed alongside fp/mp to avoid a third O(N) scan in swapWithMasterCore.
    ns_global:   usize,
    fp_filtered: usize,
    /// Mutable slice into s.scratch_wins; swapWithMasterCore keeps it in sync
    /// with s.windows.buf so callers can pass it directly to
    /// retileCurrentWorkspaceDeferredPrebuilt and skip a second collect.
    ws_wins:     []u32,
};

fn findFocusMasterPos(s: *State) ?FocusMasterPos {
    const focused = focus.getFocused() orelse return null;
    if (!s.windows.contains(focused) or !tracking.isOnCurrentWorkspace(focused)) return null;

    // Build the per-workspace filtered list exactly as retile does, so that
    // ws_wins[0] is the true layout master regardless of s.windows.buf
    // insertion order across workspaces.
    const ws_count = collectWorkspaceWindows(s, &s.scratch_wins, null);
    const ws_wins  = s.scratch_wins[0..ws_count];

    // Need at least two windows on this workspace for a meaningful swap.
    if (ws_wins.len < 2) return null;

    // Locate the focused window inside the filtered list.
    const fp_filtered = std.mem.indexOfScalar(u32, ws_wins, focused) orelse return null;

    // Single pass over s.windows.buf to find global indices for focused, master,
    // and next-stack windows — avoids three separate O(N) scans.
    const all    = s.windows.items();
    const master_xid = ws_wins[0];
    const next       = ws_wins[1]; // always valid: ws_wins.len >= 2 checked above

    var fp_global: ?usize = null;
    var mp_global: ?usize = null;
    var ns_global: ?usize = null;
    for (all, 0..) |w, i| {
        if (w == focused)     fp_global = i;
        if (w == master_xid)  mp_global = i;
        if (w == next)        ns_global = i;
        if (fp_global != null and mp_global != null and ns_global != null) break;
    }

    return .{
        .fp_global   = fp_global orelse return null,
        .mp_global   = mp_global orelse return null,
        .ns_global   = ns_global orelse return null,
        .fp_filtered = fp_filtered,
        .ws_wins     = ws_wins,
    };
}

/// Shared core for both swap-with-master variants.
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
        swapWindowsInList(s, pos.mp_global, pos.ns_global);
        std.mem.swap(u32, &pos.ws_wins[0], &pos.ws_wins[1]); // keep ws_wins in sync with buf
        return next_win;
    }
    const master_win = pos.ws_wins[0];
    swapWindowsInList(s, pos.fp_global, pos.mp_global);
    std.mem.swap(u32, &pos.ws_wins[0], &pos.ws_wins[pos.fp_filtered]); // keep ws_wins in sync
    return master_win;
}

fn updateCacheRect(s: *State, win: u32, rect: utils.Rect) void {
    s.cache.getOrPut(win).value_ptr.rect = rect;
}

/// Set the geometry-valid bit for `ws_idx`, indicating the cache is correct for that workspace.
inline fn markWorkspaceGeomValid(s: *State, ws_idx: anytype) void {
    if (ws_idx < max_workspaces) s.workspace_geom_valid_bits |= tracking.workspaceBit(ws_idx);
}

/// Step the layout forward or backward and apply it.
inline fn applyLayoutStep(comptime forward: bool) void {
    const s = getState();
    if (s.layout == .floating) return;
    applyLayout(s, stepLayout(s, s.layout, forward));
}

fn applyLayout(s: *State, layout: Layout) void {
    s.layout = layout;
    if (!core.config.tiling.global_layout) {
        if (build.has_workspaces) {
            if (workspaces.getCurrentWorkspaceObject()) |ws| ws.layout = layout;
        }
    }
    // In global mode all workspaces share the same layout; inactive caches are stale.
    if (core.config.tiling.global_layout) s.workspace_geom_valid_bits = 0;
    retileCurrentWorkspace();
    bar.scheduleFullRedraw();
    debug.info("Layout: {s}", .{@tagName(layout)});
}

/// Advance a finite enum field to its next variant, wrapping around.
inline fn cycleEnum(v: anytype) void {
    const T = @TypeOf(v.*);
    v.* = @enumFromInt((@intFromEnum(v.*) + 1) % std.meta.fields(T).len);
}
