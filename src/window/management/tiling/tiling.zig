//! Tiling window management: delegates to layout modules.

const std        = @import("std");
const core       = @import("core");
const xcb        = core.xcb;
const utils      = @import("utils");
const constants  = @import("constants");
const workspaces = @import("workspaces");
const focus      = @import("focus");
const bar        = @import("bar");
const Tracking   = @import("tracking").Tracking;
const debug      = @import("debug");
const scale      = @import("scale");
const layouts    = @import("layouts");

const build_options = @import("build_options");

const LayoutStub = struct {
    pub fn tileWithOffset(
        _: *const layouts.LayoutCtx,
        _: anytype,
        _: []const u32,
        _: u16, _: u16, _: u16,
    ) void {}
};

const master_layout    = if (build_options.has_master)    @import("master")    else LayoutStub;
const monocle_layout   = if (build_options.has_monocle)   @import("monocle")   else LayoutStub;
const grid_layout      = if (build_options.has_grid)      @import("grid")      else LayoutStub;
const fibonacci_layout = if (build_options.has_fibonacci) @import("fibonacci") else LayoutStub;
// floating is always present — it is a first-class built-in, not an optional
// disk-discovered layout, so it does not go through the layout_flags mechanism.
const floating_layout = @import("floating");
const fullscreen = @import("fullscreen");

const MAX_MASTER_WIDTH: f32 = 0.95;
const DEFAULT_MAX_WS_WINDOWS: usize = 128;  // default per-retile window list capacity
const DEFAULT_MAX_WS: usize         = 64;   // default workspace limit; matches u64 ws_geom_valid bitmask

inline fn wsBit(ws_idx: anytype) u64 { return @as(u64, 1) << @intCast(ws_idx); }

const ZERO_RECT: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub const Layout = enum {
    master,
    monocle,
    grid,
    fibonacci,
    /// Windows are left at their current positions; no tiling is applied.
    /// Entered and exited via toggleFloating(); never part of the normal cycle.
    floating,
};

// Layouts present on disk at build time. toggleLayout/toggleLayoutReverse walk
// this list so missing layouts are never visited during cycling.
// A compile error fires if every layout file has been removed.
const LAYOUT_CYCLE: []const Layout = blk: {
    var list: []const Layout = &.{};
    if (build_options.has_master)    list = list ++ &[_]Layout{.master};
    if (build_options.has_monocle)   list = list ++ &[_]Layout{.monocle};
    if (build_options.has_grid)      list = list ++ &[_]Layout{.grid};
    if (build_options.has_fibonacci) list = list ++ &[_]Layout{.fibonacci};
    if (list.len == 0) @compileError("No tiling layouts found. Add at least one .zig file to src/tiling/layouts/.");
    break :blk list;
};

pub inline fn defaultLayout() Layout { return LAYOUT_CYCLE[0]; }

const LAYOUT_NAME_MAP = std.StaticStringMap(Layout).initComptime(.{
    .{ "master-stack", .master }, .{ "master", .master },
    .{ "monocle",      .monocle },
    .{ "grid",         .grid    },
    .{ "fibonacci",    .fibonacci },
});

inline fn layoutFromString(name: []const u8) ?Layout { return LAYOUT_NAME_MAP.get(name); }

/// Build the runtime-enabled layout list from the config's `layouts` array,
/// keeping only entries whose .zig file is present on disk. Duplicates are
/// dropped. Falls back to LAYOUT_CYCLE when the config produces an empty list.
fn buildEnabledLayouts(layouts_cfg: []const []const u8) struct { arr: [4]Layout, len: u8 } {
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
        for (LAYOUT_CYCLE) |l| { arr[len] = l; len += 1; }
    }
    return .{ .arr = arr, .len = len };
}

pub inline fn isLayoutAvailable(layout: Layout) bool {
    return switch (layout) {
        .master    => build_options.has_master,
        .monocle   => build_options.has_monocle,
        .grid      => build_options.has_grid,
        .fibonacci => build_options.has_fibonacci,
        // Floating is always built-in; no disk-presence check needed.
        .floating  => true,
    };
}

// Walk the runtime-enabled layout list to find `current`, then step forward or
// backward. Falls back to LAYOUT_CYCLE if state has no enabled layouts (should
// not happen after init, but guarded defensively).
inline fn stepCycle(s: *const State, current: Layout, comptime forward: bool) Layout {
    const cycle: []const Layout = if (s.enabled_layouts_len > 0)
        s.enabled_layouts[0..s.enabled_layouts_len]
    else
        LAYOUT_CYCLE;
    for (cycle, 0..) |l, i| {
        if (l != current) continue;
        return cycle[if (forward) (i + 1) % cycle.len else (cycle.len + i - 1) % cycle.len];
    }
    return cycle[0]; // current not in list (layout disabled at reload) — jump to first
}

// Variation enums are defined in core.zig to allow config.zig to parse them
// without a circular import. Re-exported here for convenience.
pub const MasterVariation  = core.MasterVariation;
pub const MonocleVariation = core.MonocleVariation;
pub const GridVariation    = core.GridVariation;

pub const LayoutVariations = struct {
    master:  MasterVariation  = .lifo,
    monocle: MonocleVariation = .gapless,
    grid:    GridVariation    = .rigid,
};

pub const State = struct {
    allocator:        std.mem.Allocator,
    enabled:          bool,
    layout:           Layout,
    /// The layout active before floating mode was entered.
    /// Restored by toggleFloating() when switching back from floating.
    /// Defaults to the first entry in LAYOUT_CYCLE.
    prev_layout:      Layout,
    layout_variations: LayoutVariations,
    /// 3-character indicator shown in the bar for the fibonacci layout.
    master_side:      core.MasterSide,
    master_width:     f32,
    master_count:     u8,
    gap_width:        u16,
    border_width:     u16,
    border_focused:   u32,
    border_unfocused: u32,
    windows:          Tracking,
    dirty:            bool,

    /// Runtime layout cycle: intersection of config `layouts` and disk-present
    /// layout files. stepCycle walks this so layouts omitted from the config
    /// are invisible at runtime even if their .zig file exists on disk.
    enabled_layouts:     [4]Layout,
    enabled_layouts_len: u8,

    /// Per-workspace geometry validity bitmask (64 bits -> up to 64 workspaces).
    ///
    /// Bit N is set when workspace N's geometry has been pre-computed and the
    /// cache holds correct on-screen positions for all its windows.
    ///
    /// Cleared by: addWindow, removeWindow, adjustMasterWidth, syncLayoutFromWorkspace.
    /// Set by the retile call that immediately follows each of those.
    ws_geom_valid:    u64,

    /// Screen area used in the most recent retile call. restoreWorkspaceGeom
    /// rejects the cache when this differs from the current area (e.g. after a
    /// bar height or position change).
    last_retile_screen: utils.Rect,

    /// Per-window cache storing last geometry AND last border color in a single
    /// hash table. Populated by configureSafe (rect) and sendBorderColor (border).
    cache: layouts.CacheMap,

    // Scratch buffers (heap-allocated, sized from max_ws_windows / max_ws) 
    //
    // Reused across retile calls to avoid per-call stack pressure.  All four
    // slices are allocated in buildState and freed in deinit.
    //
    //   scratch_wins   — [max_ws_windows]u32   single-workspace window list
    //   scratch_rects  — [max_ws_windows]Rect  parallel rect array for restore path
    //   retile_wins    — [max_ws * max_ws_windows]u32  flattened 2-D per-workspace lists
    //   retile_lens    — [max_ws]usize          fill counters for retile_wins rows

    max_ws_windows: usize,
    max_ws:         usize,
    scratch_wins:   []u32,
    scratch_rects:  []utils.Rect,
    retile_wins:    []u32,
    retile_lens:    []usize,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gap_width, .border = self.border_width };
    }

    pub inline fn borderColor(self: *const State, win: u32) u32 {
        if (fullscreen.isFullscreen(win)) return 0;
        return if (focus.getFocused() == win) self.border_focused else self.border_unfocused;
    }

    pub fn deinit(self: *State) void {
        self.windows.deinit();
        self.cache.deinit(self.allocator);
        self.allocator.free(self.retile_lens);
        self.allocator.free(self.retile_wins);
        self.allocator.free(self.scratch_rects);
        self.allocator.free(self.scratch_wins);
    }
};

// Module singleton -- guaranteed live after init(), never null during normal operation.
// g_initialized guards debug assertions; production builds pay zero cost.
var g_state:       State = undefined;
var g_initialized: bool  = false;

/// Returns a pointer to the live state. Asserts in Debug builds that init() has been called.
pub inline fn getState() *State {
    std.debug.assert(g_initialized);
    return &g_state;
}

/// Safe pre-init query for code that may run before the event loop starts.
/// Returns null only during the narrow startup window before init() is called.
pub inline fn getStateOpt() ?*State {
    return if (g_initialized) &g_state else null;
}

fn computeMasterWidth() f32 {
    const raw = scale.scaleMasterWidth(core.config.tiling.master_width);
    if (raw < 0) {
        const ratio = -raw / @as(f32, @floatFromInt(core.screen.width_in_pixels));
        return @min(MAX_MASTER_WIDTH, @max(constants.MIN_MASTER_WIDTH, ratio));
    }
    return raw;
}

fn buildState() !State {
    const alloc            = core.alloc;
    const max_ws_windows   = DEFAULT_MAX_WS_WINDOWS;
    const max_ws           = DEFAULT_MAX_WS;
    const screen_height    = core.screen.height_in_pixels;
    const el               = buildEnabledLayouts(core.config.tiling.layouts.items);

    const scratch_wins  = try alloc.alloc(u32,         max_ws_windows);
    errdefer alloc.free(scratch_wins);
    const scratch_rects = try alloc.alloc(utils.Rect,  max_ws_windows);
    errdefer alloc.free(scratch_rects);
    const retile_wins   = try alloc.alloc(u32,         max_ws * max_ws_windows);
    errdefer alloc.free(retile_wins);
    const retile_lens   = try alloc.alloc(usize,       max_ws);
    errdefer alloc.free(retile_lens);

    return .{
        .allocator        = alloc,
        .enabled          = core.config.tiling.enabled,
        .layout           = blk: {
            const requested = std.meta.stringToEnum(Layout, core.config.tiling.layout)
                orelse LAYOUT_CYCLE[0];
            break :blk if (isLayoutAvailable(requested)) requested else LAYOUT_CYCLE[0];
        },
        .prev_layout         = LAYOUT_CYCLE[0],
        .enabled_layouts     = el.arr,
        .enabled_layouts_len = el.len,
        .layout_variations = .{
            .master  = core.config.tiling.master_variation,
            .monocle = core.config.tiling.monocle_variation,
            .grid    = core.config.tiling.grid_variation,
        },
        .master_side      = core.config.tiling.master_side,
        .master_width     = computeMasterWidth(),
        .master_count     = core.config.tiling.master_count,
        .gap_width        = scale.scaleBorderWidth(core.config.tiling.gap_width, screen_height),
        .border_width     = scale.scaleBorderWidth(core.config.tiling.border_width, screen_height),
        .border_focused   = core.config.tiling.border_focused,
        .border_unfocused = core.config.tiling.border_unfocused,
        .windows          = Tracking{ .allocator = alloc },
        .dirty            = false,
        .ws_geom_valid    = 0,
        .last_retile_screen = ZERO_RECT,
        .cache            = .{},
        .max_ws_windows   = max_ws_windows,
        .max_ws           = max_ws,
        .scratch_wins     = scratch_wins,
        .scratch_rects    = scratch_rects,
        .retile_wins      = retile_wins,
        .retile_lens      = retile_lens,
    };
}

pub fn init() !void {
    g_state       = try buildState();
    g_initialized = true;
}

pub fn deinit() void {
    if (!g_initialized) return;
    g_state.deinit();
    g_initialized = false;
}

pub fn reloadConfig() void {
    const s = getState();

    const saved_windows = s.windows;

    // Clear the combined cache in-place, retaining the allocated capacity so
    // the next retile does not pay for a fresh heap allocation. The old data
    // is intentionally discarded: config changes (gaps, border width, colors)
    // make every cached rect and border color stale.
    var saved_cache = s.cache;
    saved_cache.clearRetainingCapacity();
    // Disown before buildState overwrites g_state; s is a dangling pointer
    // from this point forward and must not be used.
    s.cache = .{};

    // Save scratch buffers: buildState allocates fresh ones, but we reuse the
    // existing allocations (same capacity) to avoid needless churn.
    const saved_scratch_wins  = s.scratch_wins;
    const saved_scratch_rects = s.scratch_rects;
    const saved_retile_wins   = s.retile_wins;
    const saved_retile_lens   = s.retile_lens;

    var new_state = buildState() catch |err| {
        // buildState failed before overwriting g_state — restore what we saved.
        s.cache   = saved_cache;
        s.windows = saved_windows;
        debug.err("tiling: out of memory during reload: {}", .{err});
        return;
    };

    // Free the freshly allocated scratch bufs from new_state (same sizes as
    // the saved ones) and replace them with the saved allocations.
    const alloc = new_state.allocator;
    alloc.free(new_state.retile_lens);
    alloc.free(new_state.retile_wins);
    alloc.free(new_state.scratch_rects);
    alloc.free(new_state.scratch_wins);
    new_state.scratch_wins  = saved_scratch_wins;
    new_state.scratch_rects = saved_scratch_rects;
    new_state.retile_wins   = saved_retile_wins;
    new_state.retile_lens   = saved_retile_lens;
    // Discard the empty Tracking allocated by buildState (no items, no heap).
    new_state.windows = saved_windows;
    new_state.cache   = saved_cache;

    g_state = new_state;
    const ns = &g_state;

    // Reset all workspace layouts and master widths to the new config defaults
    // on reload. Per-workspace adjustments made at runtime are intentionally
    // discarded so the reloaded config values take effect immediately.
    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces) |*ws| {
            ws.layout       = ns.layout;
            ws.master_width = null;
        }
    }

    if (ns.enabled) {
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
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    }
}

/// Cache WM_NORMAL_HINTS minimum size constraints for `win`. Called from window.zig at MapRequest time.
pub const cacheSizeHints = layouts.cacheSizeHints;
/// Evict the size-hint entry for `win`. Called from window.zig at unmanage time.
pub const evictSizeHints = layouts.evictSizeHints;

pub fn addWindow(window_id: u32) void {
    std.debug.assert(window_id != 0);
    const s = getState();
    if (!s.enabled) return;

    const result = if (s.layout == .master and s.layout_variations.master == .fifo)
        s.windows.addFront(window_id)
    else
        s.windows.add(window_id);
    result catch |err| { debug.logError(err, window_id); return; };
    s.dirty = true;
    s.ws_geom_valid = 0;

    const border_color = s.borderColor(window_id);
    _ = xcb.xcb_change_window_attributes(core.conn, window_id,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{border_color});
    _ = xcb.xcb_configure_window(core.conn, window_id,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{s.border_width});

    // Pre-populate the cache so the immediately-following retile does not
    // re-send the border pixel.
    const gop = s.cache.getOrPut(s.allocator, window_id) catch return;
    gop.value_ptr.border = border_color;
    if (!gop.found_existing) gop.value_ptr.rect = ZERO_RECT;
}

pub fn removeWindow(window_id: u32) void {
    const s = getState();
    if (s.windows.remove(window_id)) {
        s.dirty = true;
        s.ws_geom_valid = 0;
        _ = s.cache.remove(window_id);
    }
}

/// Returns the position of `win` in the current-workspace-filtered window
/// list — the same slice the master layout receives as its `windows` argument.
/// Index 0 is the master slot; indices >= master_count are stack slots.
///
/// Must be called BEFORE removeWindow so the window is still tracked.
/// Returns null when tiling is disabled or `win` is not in the tiling list.
pub fn getWindowFilteredIndex(win: u32) ?usize {
    const s = getStateOpt() orelse return null;
    if (!s.enabled) return null;
    // Only windows on the current workspace have a meaningful filtered index.
    // minimizeWindow always minimizes a focused window on the current workspace,
    // so this assertion documents and enforces the expected call-site contract.
    std.debug.assert(workspaces.isOnCurrentWorkspace(win));
    var filtered_idx: usize = 0;
    for (s.windows.items()) |w| {
        if (w == win) return filtered_idx;
        if (workspaces.isOnCurrentWorkspace(w)) filtered_idx += 1;
    }
    return null;
}

/// Add `win` to the tiling list and place it at workspace-filtered position
/// `target_filtered_idx`.  If `target_filtered_idx` exceeds the current
/// filtered length the window is left at the back (natural addWindow position).
///
/// Used by the unminimize path to restore a window to its original layout
/// slot.  The index is captured by minimizeWindow via getWindowFilteredIndex
/// before the window is removed.
///
/// Works correctly for both LIFO (default, addWindow appends to end) and
/// FIFO (addFront prepends to front) layout variations.
pub fn addWindowAtFilteredIndex(win: u32, target_filtered_idx: usize) void {
    addWindow(win);
    moveWindowToFilteredSlot(getState(), win, target_filtered_idx);
}

/// Reposition `win` within the global window list so that it lands at
/// workspace-filtered index `target` (0 = master slot).
///
/// Background — the shift arithmetic:
///   moveWindowToIndex(from, to) removes the source element first, then
///   inserts it at position `to` in the *shortened* list.  When `from` lies
///   before `to` in the original list, the removal shifts every subsequent
///   element left by one, so the effective insertion point is `tg - 1`.
///   When `from` lies after `to` no shift occurs.
///
/// Example (global list [A B C D], workspace = all, target = 1 = "B's slot"):
///   addWindow appended win W -> [A B C D W], from_global = 4
///   target window at filtered[1] = B -> to_global = 1
///   from(4) > to(1) -> effective_to = 1, no shift
///   moveWindowToIndex(4, 1) -> [A W B C D]  ✓  filtered[1] = W
///
/// Example (FIFO: addFront prepended W -> [W A B C D], from_global = 0):
///   target window at filtered[1] = B -> to_global = 2
///   from(0) < to(2) -> effective_to = 2 - 1 = 1
///   moveWindowToIndex(0, 1) -> [A W B C D]  ✓  filtered[1] = W
fn moveWindowToFilteredSlot(s: *State, win: u32, target: usize) void {
    const items = s.windows.items();

    var from_global: ?usize = null;
    for (items, 0..) |w, i| {
        if (w == win) { from_global = i; break; }
    }
    const fg = from_global orelse return; // win not in list — shouldn't happen

    // Find the global index of the workspace window currently at `target`
    // (excluding win itself).  That window should end up immediately AFTER win,
    // so inserting win just before it places win at the desired filtered slot.
    var filtered_count: usize = 0;
    var to_global: ?usize = null;
    for (items, 0..) |w, i| {
        if (w == win) continue;
        if (!workspaces.isOnCurrentWorkspace(w)) continue;
        if (filtered_count == target) { to_global = i; break; }
        filtered_count += 1;
    }

    const tg = to_global orelse return; // target at/past end — already correct
    const effective_to: usize = if (fg < tg) tg - 1 else tg;
    if (effective_to != fg) moveWindowToIndex(s, fg, effective_to);
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
    if (!s.enabled) return;

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

/// Save geometry for any window (tiled or floating) into the shared cache.
/// Called by the workspace switcher before pushing windows off-screen so that
/// floating windows can be restored to their exact position on return.
pub fn saveWindowGeom(window_id: u32, rect: utils.Rect) void {
    const s = getState();
    const gop = s.cache.getOrPut(s.allocator, window_id) catch return;
    gop.value_ptr.rect = rect;
    if (!gop.found_existing) gop.value_ptr.border = 0;
}

/// Return the cached geometry for any window. Returns null when no entry exists
/// or the entry has been invalidated (zeroed rect).
pub inline fn getWindowGeom(window_id: u32) ?utils.Rect {
    const s = getStateOpt() orelse return null;
    const wd = s.cache.get(window_id) orelse return null;
    if (wd.rect.width == 0 and wd.rect.height == 0) return null;
    return wd.rect;
}

// Evict a window's rect from the cache without removing it from tiling.
// Call whenever a window's position is changed outside the normal retile path
// (e.g. pushed offscreen during fullscreen) so the next retile does not find a
// stale cache hit and skip configure_window. The border entry is preserved.
pub fn invalidateGeomCache(window_id: u32) void {
    const s = getState();
    if (s.cache.getPtr(window_id)) |wd| wd.rect = ZERO_RECT;
}

/// Clear the workspace-valid bit for `ws_idx` so the next restoreWorkspaceGeom
/// for that workspace triggers a full retile. Used when a window's tag changes
/// for an inactive workspace without touching the current one.
pub inline fn invalidateWsGeomBit(ws_idx: u8) void {
    const s = getState();
    if (ws_idx < s.max_ws) s.ws_geom_valid &= ~wsBit(ws_idx);
}

pub inline fn dirty() void {
    getState().dirty = true;
}

// Restore windows on the current workspace to their cached tiled positions,
// bypassing the layout algorithm.
// Returns true if the cache is valid and positions have been replayed.
// Returns false if the cache is stale; caller must fall back to retileCurrentWorkspace.
pub fn restoreWorkspaceGeom() bool {
    const s = getStateOpt() orelse return false;

    const ws_count = filterWorkspaceWindows(s, s.scratch_wins, null);
    const ws_windows = s.scratch_wins[0..ws_count];
    if (ws_windows.len == 0) return true;

    const current_ws = workspaces.getCurrentWorkspace() orelse return false;
    if (current_ws >= s.max_ws) return false;
    if (s.ws_geom_valid & wsBit(current_ws) == 0) return false;

    const current_screen = calculateScreenArea();
    if (!layouts.rectsEqual(current_screen, s.last_retile_screen)) return false;

    // Verify every window is cached before emitting any XCB calls.
    const rects = s.scratch_rects[0..ws_windows.len];
    for (ws_windows, 0..) |win, i| {
        const wd = s.cache.get(win) orelse return false;
        if (wd.rect.width == 0 and wd.rect.height == 0) return false; // stale entry
        rects[i] = wd.rect;
    }

    for (ws_windows, rects) |win, rect| {
        utils.configureWindow(core.conn, win, rect);
    }
    updateBorders(s, ws_windows);
    return true;
}

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
/// the window is managed by the tiler. Use this in handleConfigureRequest instead
/// of `core.config.tiling.enabled and isWindowTiled(win)` so that toggling tiling
/// off at runtime actually frees applications to reposition themselves.
pub inline fn isWindowActiveTiled(window_id: u32) bool {
    const s = getStateOpt() orelse return false;
    return s.enabled and s.windows.contains(window_id);
}

fn resolveLayout(s: *State, ws_state: ?*workspaces.State, ws_idx: u8, global: bool) Layout {
    if (global) return s.layout;
    const wss = ws_state orelse return s.layout;
    return if (ws_idx < wss.workspaces.len) wss.workspaces[ws_idx].layout else s.layout;
}

/// Returns the master width for `ws_idx` when in per-workspace mode.
/// Falls back to the current global value for workspaces that have not yet
/// had their width adjusted (master_width == null).
inline fn resolveMasterWidth(s: *const State, ws_state: ?*workspaces.State, ws_idx: u8) f32 {
    if (core.config.tiling.global_layout) return s.master_width;
    const wss = ws_state orelse return s.master_width;
    if (ws_idx < wss.workspaces.len) {
        if (wss.workspaces[ws_idx].master_width) |mw| return mw;
    }
    return s.master_width;
}

inline fn makeLayoutCtx(s: *State) layouts.LayoutCtx {
    return .{ .conn = core.conn, .cache = &s.cache, .allocator = s.allocator };
}

fn dispatchLayout(layout: Layout, ctx: *const layouts.LayoutCtx, s: *State, wins: []const u32, screen: utils.Rect) void {
    const w = screen.width;
    const h = screen.height;
    const y: u16 = @intCast(screen.y);
    switch (layout) {
        .master    => master_layout.tileWithOffset(ctx, s, wins, w, h, y),
        .monocle   => monocle_layout.tileWithOffset(ctx, s, wins, w, h, y),
        .grid      => grid_layout.tileWithOffset(ctx, s, wins, w, h, y),
        .fibonacci => fibonacci_layout.tileWithOffset(ctx, s, wins, w, h, y),
        // No-op: windows remain at their current positions.
        .floating  => floating_layout.tileWithOffset(ctx, s, wins, w, h, y),
    }
}

inline fn calculateScreenArea() utils.Rect {
    const bar_height: u16 = if (bar.isVisible()) bar.getBarHeight() else 0;
    const bar_at_bottom   = core.config.bar.vertical_position == .bottom;
    return .{
        .x      = 0,
        .y      = if (bar_at_bottom) 0 else @intCast(bar_height),
        .width  = core.screen.width_in_pixels,
        .height = core.screen.height_in_pixels -| bar_height,
    };
}

pub fn retileAllWorkspaces() void {
    const s = getState();
    if (!s.enabled) return;

    const screen     = calculateScreenArea();
    const ws_count   = workspaces.getWorkspaceCount();
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    const ws_state_opt = if (!core.config.tiling.global_layout) workspaces.getState() else null;

    const ctx          = makeLayoutCtx(s);
    const effective_ws = @min(ws_count, s.max_ws);

    // Zero the per-workspace fill counters.
    @memset(s.retile_lens[0..effective_ws], 0);

    for (s.windows.items()) |win| {
        const ws_idx = workspaces.getWorkspaceForWindow(win) orelse continue;
        if (ws_idx >= effective_ws) continue;
        if (s.retile_lens[ws_idx] < s.max_ws_windows) {
            s.retile_wins[ws_idx * s.max_ws_windows + s.retile_lens[ws_idx]] = win;
            s.retile_lens[ws_idx] += 1;
        }
    }

    var ws_idx: u8 = 0;
    while (ws_idx < effective_ws) : (ws_idx += 1) {
        if (ws_idx == current_ws) continue;
        if (fullscreen.getForWorkspace(ws_idx)) |_| continue;

        const n          = s.retile_lens[ws_idx];
        const ws_windows = s.retile_wins[ws_idx * s.max_ws_windows .. ws_idx * s.max_ws_windows + n];
        if (ws_windows.len == 0) continue;

        const saved_width  = s.master_width;
        s.master_width = resolveMasterWidth(s, ws_state_opt, ws_idx);
        dispatchLayout(resolveLayout(s, ws_state_opt, ws_idx, core.config.tiling.global_layout), &ctx, s, ws_windows, screen);
        s.master_width = saved_width;
        updateBorders(s, ws_windows);
        markWsGeomValid(s, ws_idx);
    }

    s.last_retile_screen = screen;
}

pub fn retileIfDirty() void {
    const s = getState();
    if (!s.enabled or !s.dirty) return;
    retileCurrentWorkspace();
}

pub fn retileCurrentWorkspace() void {
    const s = getState();
    if (!s.enabled) {
        // Tiling is disabled at runtime but windows are still tracked in
        // s.windows.  The workspace switcher routes them through this function
        // for restore, so we must bring them back to their last known on-screen
        // positions via the geometry cache instead of running the layout engine.
        // restoreWorkspaceGeom is a no-op when the cache is missing or stale,
        // so there is no risk of clobbering an already-correct state.
        _ = restoreWorkspaceGeom();
        return;
    }
    retile(calculateScreenArea(), null);
    s.dirty = false;
}

/// Compute and apply tiled geometry for the current workspace without the
/// !s.enabled guard.  Called by the workspace switcher when floating mode is
/// active and the geometry cache is stale (it was zeroed when we last left this
/// workspace while tiling was still active).  This restores correct tiled
/// positions to the cache so the subsequent float-restore path in
/// restoreWorkspaceWindows can use getWindowGeom instead of falling back to the
/// default float position.
///
/// The layout is temporarily set to prev_layout for the duration of the retile
/// so that resolveLayout dispatches the real tiling algorithm (not the floating
/// no-op) and actually computes positions.
pub fn retileForRestore() void {
    const s = &g_state;
    const saved = s.layout;
    s.layout = s.prev_layout;
    retile(calculateScreenArea(), null);
    s.layout = saved;
    s.dirty = false;
}

/// Retile a specific inactive workspace so its geometry cache is correct before
/// the user switches to it.
///
/// MUST be called inside a server grab: retile transiently moves windows to
/// their on-screen positions.
pub fn retileInactiveWorkspace(ws_idx: u8) void {
    const s = getState();
    if (!s.enabled) return;

    const ws_state = workspaces.getState() orelse return;

    if (ws_idx == ws_state.current) {
        retileCurrentWorkspace();
        return;
    }

    retile(calculateScreenArea(), ws_idx);

    // Push windows back offscreen while their workspace is inactive.
    // Do NOT invalidate the cache: restoreWorkspaceGeom will find the
    // ws_geom_valid bit set, a complete cache, and a matching screen rect,
    // and replay positions in one batch.
    for (ws_state.workspaces[ws_idx].windows.items()) |win| {
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
    }
}

// Core retile. `for_ws`: when non-null, process that specific workspace instead
// of the current one.
fn retile(screen: utils.Rect, for_ws: ?u8) void {
    const s = getState();

    const target_ws: u8 = for_ws orelse
        @intCast(workspaces.getCurrentWorkspace() orelse return);

    if (fullscreen.getForWorkspace(target_ws)) |_| return;

    const ws_count = filterWorkspaceWindows(s, s.scratch_wins, for_ws);
    const ws_windows = s.scratch_wins[0..ws_count];
    if (ws_windows.len == 0) return;

    const ctx = makeLayoutCtx(s);
    // For inactive workspaces (for_ws != null) in per-workspace mode, temporarily
    // substitute that workspace's saved master width so the layout is computed
    // correctly. The current workspace's width (s.master_width) was already applied
    // by syncLayoutFromWorkspace at switch time, so the for_ws == null path is fine.
    const saved_width = s.master_width;
    if (for_ws != null) s.master_width = resolveMasterWidth(s, workspaces.getState(), target_ws);
    defer s.master_width = saved_width;
    dispatchLayout(resolveLayout(s, workspaces.getState(), target_ws, core.config.tiling.global_layout), &ctx, s, ws_windows, screen);

    s.last_retile_screen = screen;
    updateBorders(s, ws_windows);
    markWsGeomValid(s, target_ws);
}

// Send border pixel only if color changed since last send.
fn sendBorderColor(s: *State, conn: *xcb.xcb_connection_t, win: u32, color: u32) void {
    const gop = s.cache.getOrPut(s.allocator, win) catch {
        _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
        return;
    };
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    if (!gop.found_existing) gop.value_ptr.rect = ZERO_RECT;
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

inline fn updateBorders(s: *State, ws_windows: []const u32) void {
    for (ws_windows) |win| sendBorderColor(s, core.conn, win, s.borderColor(win));
}

pub fn updateWindowFocus(old_focused: ?u32, new_focused: ?u32) void {
    const s = getState();
    for ([2]?u32{ old_focused, new_focused }) |opt| {
        const win = opt orelse continue;
        if (!s.windows.contains(win)) continue;
        sendBorderColor(s, core.conn, win, s.borderColor(win));
    }
}

fn moveWindowToIndex(s: *State, from_idx: usize, to_idx: usize) void {
    if (from_idx == to_idx) return;
    const current = s.windows.items();

    const temp = s.scratch_wins;
    if (current.len > temp.len) {
        debug.warn("moveWindowToIndex: too many windows ({})", .{current.len});
        return;
    }

    const win = current[from_idx];
    var j: usize = 0;
    for (current, 0..) |w, i| {
        if (i == from_idx) continue;
        if (j == to_idx) { temp[j] = win; j += 1; }
        temp[j] = w;
        j += 1;
    }
    if (to_idx >= j) { temp[j] = win; j += 1; }
    s.windows.reorder(temp[0..j]);
}

/// Locates the focused window and the current workspace's master window in the
/// ordered window list. Returns null when preconditions are not met (nothing
/// focused, not tiled, not on current workspace, or fewer than 2 windows).
const FocusMasterPos = struct { fp: usize, mp: usize, all: []const u32 };
fn findFocusMasterPos(s: *State) ?FocusMasterPos {
    const focused = focus.getFocused() orelse return null;
    if (!s.windows.contains(focused) or !workspaces.isOnCurrentWorkspace(focused)) return null;
    const all = s.windows.items();
    if (all.len < 2) return null;
    var fp: ?usize = null;
    var mp: ?usize = null;
    for (all, 0..) |win, i| {
        if (win == focused) fp = i;
        if (mp == null and workspaces.isOnCurrentWorkspace(win)) mp = i;
        if (fp != null and mp != null) break;
    }
    return .{ .fp = fp orelse return null, .mp = mp orelse return null, .all = all };
}

pub fn swapWithMaster() void {
    const s = getState();
    const pos = findFocusMasterPos(s) orelse return;
    if (pos.fp == pos.mp) {
        for (pos.all[pos.mp + 1..], pos.mp + 1..) |win, i| {
            if (workspaces.isOnCurrentWorkspace(win)) { moveWindowToIndex(s, i, pos.mp); break; }
        }
    } else moveWindowToIndex(s, pos.fp, pos.mp);
    retileCurrentWorkspace();
}

/// Like swapWithMaster, but focus transfers to the displaced window rather than
/// staying on the window that was moved.
pub fn swapWithMasterFocusSwap() void {
    const s = getState();
    const pos = findFocusMasterPos(s) orelse return;
    var other_win: ?u32 = null;
    if (pos.fp == pos.mp) {
        // Focused is already master — swap with next window; focus follows to it.
        for (pos.all[pos.mp + 1..], pos.mp + 1..) |win, i| {
            if (workspaces.isOnCurrentWorkspace(win)) {
                other_win = win;
                moveWindowToIndex(s, i, pos.mp);
                break;
            }
        }
    } else {
        // Focused is a slave — swap into master; focus follows to the old master.
        other_win = pos.all[pos.mp];
        moveWindowToIndex(s, pos.fp, pos.mp);
    }
    retileCurrentWorkspace();
    if (other_win) |win| focus.setFocus(win, .tiling_operation);
}

/// Swap the on-screen positions of the currently focused window and the most
/// recently previously focused window.
///
/// In tiling mode both windows exchange their slots in the tracking list so the
/// layout engine places each one exactly where the other was — a true two-way
/// swap rather than a move-to-master.  This is correct for every tiling layout
/// (grid, master-stack, fibonacci, monocle, …).
///
/// In floating mode (layout == .floating or individually floated windows) there
/// is no tracking-list order to manipulate, so the function exchanges the actual
/// X11 geometries directly via configure_window and keeps the geometry cache in
/// sync so workspace-switch restore sees the updated positions.
pub fn swapFocusedWithPrevious() void {
    const s = getState();
    const focused = focus.getFocused() orelse return;
    const history = focus.historyItems();
    if (history.len == 0) return;
    const prev = history[0];
    if (prev == focused) return;

    // Both windows must be on the current workspace.
    if (!workspaces.isOnCurrentWorkspace(focused)) return;
    if (!workspaces.isOnCurrentWorkspace(prev)) return;

    const focused_tiled = s.enabled and s.windows.contains(focused);
    const prev_tiled    = s.enabled and s.windows.contains(prev);

    if (focused_tiled and prev_tiled) {
        // Both are under tiler control: swap their positions in the tracking
        // list so the next retile assigns each window to the other's cell.
        const all = s.windows.items();
        var idx_focused: ?usize = null;
        var idx_prev:    ?usize = null;
        for (all, 0..) |win, i| {
            if (win == focused) idx_focused = i;
            if (win == prev)    idx_prev    = i;
            if (idx_focused != null and idx_prev != null) break;
        }
        const if_ = idx_focused orelse return;
        const ip  = idx_prev    orelse return;
        swapWindowsInList(s, if_, ip);
        retileCurrentWorkspace();
    } else {
        // One or both windows are floating: exchange their on-screen geometries
        // directly without touching the tiling list.
        swapWindowGeometriesDirectly(s, focused, prev);
        _ = xcb.xcb_flush(core.conn);
    }
}

/// Swap the two elements at `idx_a` and `idx_b` inside the tracking list.
/// Uses scratch_wins as a temporary buffer — same pattern as moveWindowToIndex.
fn swapWindowsInList(s: *State, idx_a: usize, idx_b: usize) void {
    if (idx_a == idx_b) return;
    const current = s.windows.items();
    if (current.len > s.scratch_wins.len) {
        debug.warn("swapWindowsInList: too many windows ({})", .{current.len});
        return;
    }
    @memcpy(s.scratch_wins[0..current.len], current);
    const tmp               = s.scratch_wins[idx_a];
    s.scratch_wins[idx_a]   = s.scratch_wins[idx_b];
    s.scratch_wins[idx_b]   = tmp;
    s.windows.reorder(s.scratch_wins[0..current.len]);
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

/// Write `rect` into the geometry cache for `win`, allocating a fresh entry if
/// one does not already exist.  Preserves the existing border color.
fn updateCacheRect(s: *State, win: u32, rect: utils.Rect) void {
    const gop = s.cache.getOrPut(s.allocator, win) catch return;
    gop.value_ptr.rect = rect;
    if (!gop.found_existing) gop.value_ptr.border = 0;
}

/// Exchange the on-screen positions of `win_a` and `win_b` by sending
/// configure_window requests and updating the geometry cache.  Geometry is
/// sourced from the cache when available; an XCB get_geometry round-trip is
/// used as a fallback for windows that have never been through a retile pass
/// (e.g. individually floated windows whose cache entry was evicted).
fn swapWindowGeometriesDirectly(s: *State, win_a: u32, win_b: u32) void {
    const rect_a: utils.Rect = blk: {
        if (s.cache.get(win_a)) |wd| if (wd.hasValidRect()) break :blk wd.rect;
        break :blk queryWindowRect(win_a) orelse return;
    };
    const rect_b: utils.Rect = blk: {
        if (s.cache.get(win_b)) |wd| if (wd.hasValidRect()) break :blk wd.rect;
        break :blk queryWindowRect(win_b) orelse return;
    };

    if (layouts.rectsEqual(rect_a, rect_b)) return; // nothing to do

    utils.configureWindow(core.conn, win_a, rect_b);
    utils.configureWindow(core.conn, win_b, rect_a);

    // Keep the cache coherent so workspace-switch restore replays correct positions.
    updateCacheRect(s, win_a, rect_b);
    updateCacheRect(s, win_b, rect_a);
}

/// Toggle the floating layout.
///
/// Entering floating: sets s.enabled = false so every existing !s.enabled
/// guard throughout the codebase (retile*, addWindow, isWindowActiveTiled,
/// the workspace-switch tiling block in workspaces.zig, etc.) fires
/// automatically — no additional per-call floating checks needed.
/// s.layout is set to .floating purely for bar display.
///
/// Exiting floating: re-enables the tiling engine, restores the correct
/// layout (from the current workspace in per-workspace mode, or from
/// prev_layout in global mode), and retiles.
pub fn toggleFloating() void {
    const s = getState();
    if (s.layout == .floating) {
        s.enabled = true;
        // In per-workspace mode read the layout from the workspace we are
        // currently on, so the bar stays correct even if the user switched
        // workspaces while floating.  Fall back to prev_layout in global mode.
        const restore: Layout = if (!core.config.tiling.global_layout)
            if (workspaces.getCurrentWorkspaceObject()) |ws| ws.layout else s.prev_layout
        else
            s.prev_layout;
        s.layout = restore;
        retileCurrentWorkspace();
        bar.scheduleFullRedraw();
        debug.info("Floating disabled, restored layout: {s}", .{@tagName(restore)});
    } else {
        s.prev_layout = s.layout;
        s.layout      = .floating;
        s.enabled     = false;
        debug.info("Floating enabled (was: {s})", .{@tagName(s.prev_layout)});
    }
}

pub fn syncLayoutFromWorkspace(ws: *const workspaces.Workspace) void {
    const s = getState();
    const layout = ws.layout;
    const needs_retile = s.layout != layout or ws.variation != null;
    s.layout = layout;
    // Apply the workspace-pinned master width when present; fall back to the
    // current global value so unvisited workspaces inherit the config default.
    if (ws.master_width) |mw| s.master_width = mw;
    // Apply the workspace-pinned variation override when present. A null
    // variation means "use the global default", so leave layout_variations alone.
    if (ws.variation) |v| {
        switch (v) {
            .master  => |mv| s.layout_variations.master  = mv,
            .monocle => |mv| s.layout_variations.monocle = mv,
            .grid    => |gv| s.layout_variations.grid    = gv,
        }
    }
    if (needs_retile) {
        s.dirty = true;
        s.ws_geom_valid = 0;
    }
}

fn applyLayout(s: *State, layout: Layout) void {
    s.layout = layout;
    if (!core.config.tiling.global_layout)
        if (workspaces.getCurrentWorkspaceObject()) |ws| { ws.layout = layout; };
    retileCurrentWorkspace();
    bar.scheduleFullRedraw();
    debug.info("Layout: {s}", .{@tagName(layout)});
}

pub fn toggleLayout() void {
    const s = getState();
    if (s.layout == .floating) return; // layout cycling is inactive in floating mode
    applyLayout(s, stepCycle(s, s.layout, true));
}

pub fn toggleLayoutReverse() void {
    const s = getState();
    if (s.layout == .floating) return;
    applyLayout(s, stepCycle(s, s.layout, false));
}

pub fn adjustMasterCount(delta: i8) void {
    const s = getState();
    const new: i16 = @as(i16, s.master_count) + delta;
    if (new < 0) return;
    const clamped: u8 = @intCast(@min(new, 10));
    if (clamped == s.master_count) return;
    s.master_count = clamped;
    retileCurrentWorkspace();
}

pub inline fn increaseMasterCount() void {
    adjustMasterCount(1);
}
pub inline fn decreaseMasterCount() void { adjustMasterCount(-1); }

pub fn adjustMasterWidth(delta: f32) void {
    const s = getState();
    s.master_width = @max(constants.MIN_MASTER_WIDTH, @min(MAX_MASTER_WIDTH, s.master_width + delta));
    // In per-workspace layout mode, persist the new width onto the current
    // workspace so it is restored when switching back to this workspace.
    if (!core.config.tiling.global_layout) {
        if (workspaces.getCurrentWorkspaceObject()) |ws| ws.master_width = s.master_width;
    }
    s.dirty = true;
    s.ws_geom_valid = 0;
    retileCurrentWorkspace();
}

pub inline fn increaseMasterWidth() void { adjustMasterWidth( 0.025); }
pub inline fn decreaseMasterWidth() void { adjustMasterWidth(-0.025); }

pub fn cycleLayoutVariation() void {
    const s = getState();
    switch (s.layout) {
        .master => {
            s.layout_variations.master = switch (s.layout_variations.master) {
                .lifo => .fifo,
                .fifo => .lifo,
            };
            debug.info("Master variation: {s}", .{@tagName(s.layout_variations.master)});
        },
        .monocle => {
            s.layout_variations.monocle = switch (s.layout_variations.monocle) {
                .gapless => .gaps,
                .gaps    => .gapless,
            };
            debug.info("Monocle variation: {s}", .{@tagName(s.layout_variations.monocle)});
        },
        .grid => {
            s.layout_variations.grid = switch (s.layout_variations.grid) {
                .rigid   => .relaxed,
                .relaxed => .rigid,
            };
            debug.info("Grid variation: {s}", .{@tagName(s.layout_variations.grid)});
        },
        .fibonacci => {
            debug.info("Fibonacci has no variations", .{});
            return;
        },
        .floating => {
            debug.info("Floating has no variations", .{});
            return;
        },
    }
    retileCurrentWorkspace();
}

inline fn markWsGeomValid(s: *State, ws_idx: anytype) void {
    if (ws_idx < s.max_ws) s.ws_geom_valid |= wsBit(ws_idx);
}

// Collect windows belonging to the target workspace into buf.
// `for_ws`: when non-null, filter by that workspace index; when null, use current.
fn filterWorkspaceWindows(s: *State, buf: []u32, for_ws: ?u8) usize {
    var n: usize = 0;
    for (s.windows.items()) |win| {
        if (n >= buf.len) break;
        const on_ws = if (for_ws) |idx|
            workspaces.isWindowOnWorkspace(win, idx)
        else
            workspaces.isOnCurrentWorkspace(win);
        if (on_ws) { buf[n] = win; n += 1; }
    }
    return n;
}
