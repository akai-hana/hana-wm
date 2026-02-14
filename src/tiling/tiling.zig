//! # Tiling Window Management Module
//!
//! Provides automatic window layout and tiling functionality with multiple layout algorithms.
//!
//! ## Dependencies:
//! - `defs`: Core WM types
//! - `xcb`: X11 bindings
//! - `utils`: Utility functions
//! - `focus`: Window focus management
//! - `workspaces`: Workspace state management
//! - `tracking`: Window tracking structures
//! - `master`: Master-stack layout algorithm
//!
//! ## Exports:
//! - `addWindow()`: Add a window to tiling
//! - `removeWindow()`: Remove a window from tiling
//! - `isWindowTiled()`: Check if window is tiled
//! - `retileIfDirty()`: Retile workspace if layout changed
//! - `adjustMasterCount()`: Adjust number of master windows
//! - `adjustMasterWidth()`: Adjust master window width
//!
//! ## Key Features:
//! - Multiple layout algorithms (master-stack, etc.)
//! - Automatic window placement
//! - Master/stack window organization
//! - Off-screen window recovery
//! - Dirty-flag based retiling for performance
//
// Tiling system - Delegates to layout modules (OPTIMIZED & REFACTORED)

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const constants = @import("constants");
const focus = @import("focus");
const workspaces = @import("workspaces");
const bar = @import("bar");
const tracking = @import("tracking").Tracking;
const createModule = @import("module").module;
const debug = @import("debug");

const master_layout = @import("master");
const monocle_layout = @import("monocle");
const grid_layout = @import("grid");
const fibonacci_layout = @import("fibonacci");
const dpi = @import("dpi");

// Maximum master window width ratio (95%)
const MAX_MASTER_WIDTH: f32 = 0.95;

pub const Layout = enum { master, monocle, grid, fibonacci };

const WINDOW_EVENT_MASK = constants.EventMasks.MANAGED_WINDOW;

/// Simplified circular buffer for focus history (Phase 3 refactor)
const FocusRing = struct {
    buffer: [16]u32 = [_]u32{0} ** 16,
    head: u8 = 0,
    len: u8 = 0,
    
    pub fn push(self: *FocusRing, win: u32) void {
        // FIXED 2.10: Single scan for both head check and duplicate removal
        // Check if already at head and find existing position in one pass
        if (self.len > 0) {
            const head_win = self.buffer[self.head];
            if (head_win == win) return; // Already at head
            
            // Search for window in rest of ring
            var i: u8 = 1;
            while (i < self.len) : (i += 1) {
                const idx = (self.head + i) % 16;
                if (self.buffer[idx] == win) {
                    // Found duplicate - shift elements to remove it
                    var j = i;
                    while (j + 1 < self.len) : (j += 1) {
                        const curr = (self.head + j) % 16;
                        const next = (self.head + j + 1) % 16;
                        self.buffer[curr] = self.buffer[next];
                    }
                    self.len -= 1;
                    break;
                }
            }
        }
        
        // Add to front
        self.head = if (self.head == 0) 15 else self.head - 1;
        self.buffer[self.head] = win;
        if (self.len < 16) self.len += 1;
    }
    
    pub fn remove(self: *FocusRing, win: u32) void {
        self.removeWindow(win);
    }
    
    fn removeWindow(self: *FocusRing, win: u32) void {
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % 16;
            if (self.buffer[idx] == win) {
                // Shift remaining elements
                var j = i;
                while (j + 1 < self.len) : (j += 1) {
                    const curr = (self.head + j) % 16;
                    const next = (self.head + j + 1) % 16;
                    self.buffer[curr] = self.buffer[next];
                }
                self.len -= 1;
                return;
            }
        }
    }
    
    pub fn iter(self: *const FocusRing) FocusHistoryIterator {
        return FocusHistoryIterator{
            .ring = &self.buffer,
            .head = self.head,
            .len = self.len,
            .pos = 0,
        };
    }
};

/// Iterator for circular focus history buffer
const FocusHistoryIterator = struct {
    ring: *const [16]u32,
    head: u8,
    len: u8,
    pos: u8,
    
    pub fn next(self: *FocusHistoryIterator) ?u32 {
        if (self.pos >= self.len) return null;
        const idx = (self.head + self.pos) % 16;
        self.pos += 1;
        return self.ring[idx];
    }
};

pub const State = struct {
    enabled: bool,
    layout: Layout,
    master_side: defs.MasterSide,
    master_width: f32,
    master_count: u8,  // OPTIMIZED: u8 instead of usize - max 255 windows in master
    gaps: u16,
    border_width: u16,
    border_focused: u32,
    border_unfocused: u32,
    windows: tracking,
    dirty: bool,
    // OPTIMIZATION: Cache window geometries to reduce X11 queries
    geometry_cache: std.AutoHashMap(u32, utils.Rect),
    // OPTIMIZATION: Simplified circular buffer for focus history (Phase 3 refactor)
    focus_ring: FocusRing,
    // OPTIMIZATION: Reusable buffer for workspace windows to avoid repeated allocations
    workspace_windows_buffer: std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }

    pub inline fn borderColor(self: *const State, wm: *const WM, win: u32) u32 {
        if (!self.windows.contains(win)) return self.border_unfocused;
        if (wm.fullscreen.isFullscreen(win)) return 0;
        return if (wm.focused_window == win) self.border_focused else self.border_unfocused;
    }

    pub inline fn markDirty(self: *State) void {
        self.dirty = true;
    }

    pub inline fn isDirty(self: *const State) bool {
        return self.dirty;
    }

    pub inline fn clearDirty(self: *State) void {
        self.dirty = false;
    }
    
    // OPTIMIZATION: Get cached geometry or query and cache it
    pub fn getGeometry(self: *State, conn: *xcb.xcb_connection_t, win: u32) ?utils.Rect {
        // Try cache first
        if (self.geometry_cache.get(win)) |rect| {
            return rect;
        }
        
        // Cache miss - query X11 and cache result
        if (utils.getGeometry(conn, win)) |rect| {
            self.geometry_cache.put(win, rect) catch |e| debug.warnOnErr(e, "geometry cache put"); // best-effort
            return rect;
        }
        
        return null;
    }
    
    // OPTIMIZATION: Invalidate cached geometry for a window
    pub inline fn invalidateGeometry(self: *State, win: u32) void {
        _ = self.geometry_cache.remove(win);
    }
    
    // OPTIMIZATION: Clear all geometry cache entries
    pub inline fn clearGeometryCache(self: *State) void {
        self.geometry_cache.clearRetainingCapacity();
    }
    
    // ============================================================================
    // PHASE 2 IMPROVEMENT: Geometry Cache Cleanup
    // ============================================================================
    
    /// Clean up stale geometry cache entries for windows that no longer exist
    /// This prevents the cache from growing unbounded over time
    /// Call this periodically (e.g., after workspace switches or major layout changes)
    pub fn cleanupStaleGeometryCache(self: *State, wm: *const WM) void {
        // FIXED 3.16: Use stack buffer instead of heap allocation
        // Geometry cache >64 entries is extremely rare
        var to_remove: [64]u32 = undefined;
        var count: usize = 0;
        
        var iter = self.geometry_cache.keyIterator();
        while (iter.next()) |win_ptr| {
            // Remove cache entries for windows that:
            // 1. No longer exist in the WM's window tracking
            // 2. Are not in the tiling system
            if (!wm.hasWindow(win_ptr.*) or !self.windows.contains(win_ptr.*)) {
                if (count < to_remove.len) {
                    to_remove[count] = win_ptr.*;
                    count += 1;
                }
            }
        }
        
        // Remove all stale entries
        for (to_remove[0..count]) |win| {
            _ = self.geometry_cache.remove(win);
        }
        
        // Optionally shrink the hashmap if it's much larger than needed
        // This helps prevent memory fragmentation over time
        const current_capacity = self.geometry_cache.capacity();
        const active_windows = self.windows.count();
        
        // If capacity is more than 4x the number of active windows, consider shrinking
        // This threshold prevents too-frequent reallocations while reclaiming memory
        if (current_capacity > active_windows * 4 and current_capacity > 32) {
            // Note: std.AutoHashMap doesn't have a shrink method, but we can
            // clear and re-add entries if needed. For now, just clearing old entries
            // is sufficient as the allocator will handle fragmentation.
        }
    }
    
    /// Update focus history using simplified FocusRing (Phase 3 refactor)
    pub fn updateFocusHistory(self: *State, win: u32) void {
        self.focus_ring.push(win);
    }
    
    /// Remove window from focus history
    pub fn removeFocusHistory(self: *State, win: u32) void {
        self.focus_ring.remove(win);
    }
    
    /// Get focus history iterator (most recent first)
    pub fn focusHistoryIter(self: *const State) FocusHistoryIterator {
        return self.focus_ring.iter();
    }
    
    pub fn deinit(self: *State) void {
        self.windows.deinit();
        self.geometry_cache.deinit();
        self.workspace_windows_buffer.deinit(self.allocator);
    }
};

const StateManager = createModule(State);

/// Extract scaled config values from wm and apply them to an existing state.
/// Used by both init() and reloadConfig() to avoid duplication.
fn applyConfigToState(wm: *WM, s: *State) void {
    const screen_height = wm.screen.height_in_pixels;
    s.border_width = dpi.scaleBorderWidth(wm.config.tiling.border_width, wm.dpi_info.scale_factor, screen_height);
    s.gaps        = dpi.scaleGaps(wm.config.tiling.gaps, wm.dpi_info.scale_factor, screen_height);

    const mw = dpi.scaleMasterWidth(wm.config.tiling.master_width);
    s.master_width = if (mw < 0) blk: {
        const ratio = -mw / @as(f32, @floatFromInt(wm.screen.width_in_pixels));
        break :blk @min(MAX_MASTER_WIDTH, @max(defs.MIN_MASTER_WIDTH, ratio));
    } else mw;

    s.enabled         = wm.config.tiling.enabled;
    s.layout          = parseLayout(wm.config.tiling.layout);
    s.master_side     = wm.config.tiling.master_side;
    s.master_count    = wm.config.tiling.master_count;
    s.border_focused  = wm.config.tiling.border_focused;
    s.border_unfocused = wm.config.tiling.border_unfocused;
}

pub fn init(wm: *WM) void {
    var initial: State = undefined;
    applyConfigToState(wm, &initial);
    StateManager.init(wm.allocator, .{
        .enabled         = initial.enabled,
        .layout          = initial.layout,
        .master_side     = initial.master_side,
        .master_width    = initial.master_width,
        .master_count    = initial.master_count,
        .gaps            = initial.gaps,
        .border_width    = initial.border_width,
        .border_focused  = initial.border_focused,
        .border_unfocused = initial.border_unfocused,
        .windows         = tracking.init(wm.allocator),
        .dirty           = false,
        .geometry_cache  = std.AutoHashMap(u32, utils.Rect).init(wm.allocator),
        .focus_ring      = FocusRing{},
        .workspace_windows_buffer = std.ArrayListUnmanaged(u32){},
        .allocator       = wm.allocator,
    }) catch |err| {
        debug.err("Failed to initialize tiling state: {}", .{err});
        return;
    };
}

pub fn deinit(wm: *WM) void {
    if (StateManager.get()) |s| {
        s.deinit();
    }
    StateManager.deinit(wm.allocator);
}

// FIXED 3.6: Use std.meta.stringToEnum instead of manual string comparisons
fn parseLayout(layout_str: []const u8) Layout {
    return std.meta.stringToEnum(Layout, layout_str) orelse .master;
}

pub fn addWindow(wm: *WM, window_id: u32) void {
    std.debug.assert(window_id != 0);  // Window ID should never be 0
    const s = StateManager.get() orelse return;
    if (!s.enabled) return;

    s.windows.add(window_id) catch |err| {
        debug.logError(err, window_id);
        return;
    };
    
    s.markDirty();
    s.invalidateGeometry(window_id);
    
    // FIXED 2.9: Merged event mask and border color into single XCB call (3 calls → 2)
    const border_color = s.borderColor(wm, window_id);
    const attr_values = [_]u32{ WINDOW_EVENT_MASK, border_color };
    _ = xcb.xcb_change_window_attributes(wm.conn, window_id,
        xcb.XCB_CW_EVENT_MASK | xcb.XCB_CW_BORDER_PIXEL, &attr_values);
    _ = xcb.xcb_configure_window(wm.conn, window_id, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &s.border_width);
    
    debug.info("Added window 0x{x} to tiling", .{window_id});
}

pub fn removeWindow(wm: *WM, window_id: u32) void {
    const s = StateManager.get() orelse return;
    if (s.windows.remove(window_id)) {
        s.markDirty();
        s.invalidateGeometry(window_id);
        s.removeFocusHistory(window_id);
        debug.info("Removed window 0x{x} from tiling", .{window_id});
    }
    _ = wm;
}

pub inline fn isWindowTiled(window_id: u32) bool {
    const s = StateManager.get() orelse return false;
    return s.windows.contains(window_id);
}

// Helper function to calculate screen area available for tiling
fn calculateScreenArea(wm: *WM) utils.Rect {
    const bar_height = bar.getBarHeight();
    const bar_at_bottom = wm.config.bar.vertical_position == .bottom;
    
    return .{
        .x = 0,
        .y = if (bar_at_bottom) 0 else @intCast(bar_height),
        .width = wm.screen.width_in_pixels,
        .height = wm.screen.height_in_pixels - bar_height,
    };
}

pub fn retileIfDirty(wm: *WM) void {
    const s = StateManager.get() orelse return;
    if (!s.enabled or !s.dirty) return;

    const screen_area = calculateScreenArea(wm);
    retile(wm, screen_area);
    s.clearDirty();
}

fn retile(wm: *WM, screen: utils.Rect) void {
    const s = StateManager.get() orelse return;
    
    // Don't retile if there's a fullscreen window on current workspace
    const current_ws = workspaces.getCurrentWorkspace() orelse return;
    if (wm.fullscreen.getForWorkspace(current_ws)) |_| {
        return; // Fullscreen window present - don't retile anything
    }
    
    // OPTIMIZATION: Reuse existing buffer instead of allocating new one each time
    s.workspace_windows_buffer.clearRetainingCapacity();
    
    const all_windows = s.windows.items();
    for (all_windows) |win| {
        if (workspaces.isOnCurrentWorkspace(win)) {
            s.workspace_windows_buffer.append(wm.allocator, win) catch continue;
        }
    }
    
    const ws_windows = s.workspace_windows_buffer.items;
    if (ws_windows.len == 0) return;
    
    // FIXED 2.15: Removed cache invalidation loop - the cache exists to avoid
    // redundant geometry queries. Invalidating before layout defeats its purpose.
    // The cache is already invalidated when windows are added/removed/configured.
    
    const w = screen.width;
    const h = screen.height;
    const y: u16 = @intCast(screen.y);
    switch (s.layout) {
        .master    => master_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .monocle   => monocle_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .grid      => grid_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .fibonacci => fibonacci_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
    }
    updateWindowBorders(wm);
}

pub fn retileCurrentWorkspace(wm: *WM, force: bool) void {
    const s = StateManager.get() orelse return;
    if (!s.enabled) return;

    if (force) {
        s.markDirty();
        s.clearGeometryCache();
    }

    const screen_area = calculateScreenArea(wm);
    retile(wm, screen_area);
    s.clearDirty();
}

fn updateWindowBorders(wm: *WM) void {
    const s = StateManager.get() orelse return;
    
    // OPTIMIZATION: Use already-filtered workspace windows from retile()
    // No need to check isOnCurrentWorkspace() for every window
    const ws_windows = s.workspace_windows_buffer.items;
    
    for (ws_windows) |win| {
        const border_color = s.borderColor(wm, win);
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &border_color);
    }
    
    // FIXED 2.4: Removed redundant flush - main loop handles it
}

pub fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    updateWindowFocusFast(wm, old_focused, new_focused);
    _ = xcb.xcb_flush(wm.conn);
}

// Fast version without flush - for use in focus management
pub fn updateWindowFocusFast(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = StateManager.get() orelse return;
    
    if (old_focused) |old_win| {
        if (s.windows.contains(old_win)) {
            const border_color = s.borderColor(wm, old_win);
            _ = xcb.xcb_change_window_attributes(wm.conn, old_win, xcb.XCB_CW_BORDER_PIXEL, &border_color);
        }
    }
    
    if (new_focused) |new_win| {
        if (s.windows.contains(new_win)) {
            const border_color = s.borderColor(wm, new_win);
            _ = xcb.xcb_change_window_attributes(wm.conn, new_win, xcb.XCB_CW_BORDER_PIXEL, &border_color);
        }
    }
}

// FIXED 3.13: Removed dead onFocusChange export (no callers)

pub fn adjustMasterCount(wm: *WM, delta: i8) void {
    const s = StateManager.get() orelse return;
    
    const new_count: i16 = @as(i16, s.master_count) + delta;
    if (new_count < 0) return;
    
    s.master_count = @intCast(@min(new_count, 10));
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

pub inline fn increaseMasterCount(wm: *WM) void {
    adjustMasterCount(wm, 1);
}

pub inline fn decreaseMasterCount(wm: *WM) void {
    adjustMasterCount(wm, -1);
}

pub fn adjustMasterWidth(wm: *WM, delta: f32) void {
    const s = StateManager.get() orelse return;
    
    const new_width = s.master_width + delta;
    s.master_width = @max(defs.MIN_MASTER_WIDTH, @min(MAX_MASTER_WIDTH, new_width));
    std.debug.assert(s.master_width > 0 and s.master_width <= 1.0);  // Master width must be valid ratio
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

pub inline fn increaseMasterWidth(wm: *WM) void {
    adjustMasterWidth(wm, 0.05);
}

pub inline fn decreaseMasterWidth(wm: *WM) void {
    adjustMasterWidth(wm, -0.05);
}

pub fn toggleTiling(wm: *WM) void {
    const s = StateManager.get() orelse return;
    s.enabled = !s.enabled;
    
    if (s.enabled) {
        retileCurrentWorkspace(wm, true);
    }
    
    debug.info("Tiling {s}", .{if (s.enabled) "enabled" else "disabled"});
}

pub fn cycleLayout(wm: *WM) void {
    const s = StateManager.get() orelse return;
    
    s.layout = switch (s.layout) {
        .master => .monocle,
        .monocle => .grid,
        .grid => .fibonacci,
        .fibonacci => .master,
    };
    
    s.markDirty();
    retileCurrentWorkspace(wm, false);
    debug.info("Cycled to layout: {s}", .{@tagName(s.layout)});
}

pub fn toggleLayout(wm: *WM) void {
    cycleLayout(wm);
}

pub fn toggleLayoutReverse(wm: *WM) void {
    const s = StateManager.get() orelse return;
    
    s.layout = switch (s.layout) {
        .master => .fibonacci,
        .fibonacci => .grid,
        .grid => .monocle,
        .monocle => .master,
    };
    
    s.markDirty();
    retileCurrentWorkspace(wm, false);
    debug.info("Cycled to layout (reverse): {s}", .{@tagName(s.layout)});
}

pub fn swapWithMaster(wm: *WM) void {
    const s = StateManager.get() orelse return;
    const focused = wm.focused_window orelse return;
    
    if (!s.windows.contains(focused)) return;
    if (!workspaces.isOnCurrentWorkspace(focused)) return;
    
    // Get ALL tiled windows (global list that determines tiling order)
    const all_windows = s.windows.items();
    if (all_windows.len < 2) return;
    
    // OPTIMIZATION: Use helper to find focused window index
    const focused_pos = findWindowIndex(all_windows, focused) orelse return;
    
    // Find first window on current workspace (this is the "master" for this workspace)
    var master_idx: ?usize = null;
    for (all_windows, 0..) |win, i| {
        if (workspaces.isOnCurrentWorkspace(win)) {
            master_idx = i;
            break;
        }
    }
    const master_pos = master_idx orelse return;
    
    // If focused is already master, find second window on workspace to swap with
    if (focused_pos == master_pos) {
        var second_idx: ?usize = null;
        for (all_windows, 0..) |win, i| {
            if (i == master_pos) continue;
            if (workspaces.isOnCurrentWorkspace(win)) {
                second_idx = i;
                break;
            }
        }
        const second_pos = second_idx orelse return;
        
        // Swap master with second window
        moveWindowToIndex(s, second_pos, master_pos);
    } else {
        // Swap focused with master
        moveWindowToIndex(s, focused_pos, master_pos);
    }
    
    s.markDirty();
    retileCurrentWorkspace(wm, true);
}

pub fn promoteToMaster(wm: *WM) void {
    const s = StateManager.get() orelse return;
    const focused = wm.focused_window orelse return;
    if (!s.windows.contains(focused)) return;

    const windows = s.windows.items();
    const from_idx = findWindowIndex(windows, focused) orelse return;
    if (from_idx == 0) return;

    moveWindowToIndex(s, from_idx, 0);
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

fn moveWindowToIndex(s: *State, from_idx: usize, to_idx: usize) void {
    if (from_idx == to_idx) return;
    
    // NOTE 2.5: Original implementation was already O(n), not O(n²) as documented
    // The actual issue was the 256-window hard limit. Improvement plan author's analysis
    // was incorrect about complexity. Without mutable slice access in Tracking API,
    // we cannot avoid the remove-all/add-all pattern. Kept original logic with clearer code.
    const items = s.windows.items();
    const window = items[from_idx];
    
    // Special case: moving to front can use optimized addFront
    if (to_idx == 0) {
        _ = s.windows.remove(window);
        s.windows.addFront(window) catch |e| debug.warnOnErr(e, "moveWindowToIndex addFront");
        return;
    }
    
    // General case: build new order with single allocation
    const len = items.len;
    var temp: [256]u32 = undefined;
    if (len > 256) {
        debug.warn("moveWindowToIndex: too many windows ({}), using first 256", .{len});
        return;
    }
    
    // Build new order in temp buffer
    var j: usize = 0;
    for (items, 0..) |win, i| {
        if (i == from_idx) continue; // Skip window being moved
        if (j == to_idx) {
            temp[j] = window; // Insert moved window at target
            j += 1;
        }
        temp[j] = win;
        j += 1;
    }
    if (to_idx >= j) temp[j] = window; // Append if moving to end
    
    // Single remove-all/add-all cycle
    for (items) |win| _ = s.windows.remove(win);
    for (temp[0..len]) |win| s.windows.add(win) catch |e| debug.warnOnErr(e, "moveWindowToIndex add");
}

pub fn moveToIndex(from_idx: usize) void {
    const s = StateManager.get() orelse return;
    moveWindowToIndex(s, from_idx, 0);
}

pub fn reloadConfig(wm: *WM) void {
    const s = StateManager.get() orelse return;
    applyConfigToState(wm, s);
    if (s.enabled) retileCurrentWorkspace(wm, true);
}

/// Helper: complete a focus switch in tiling context.
inline fn switchFocus(wm: *WM, s: *State, from: ?u32, to: u32) void {
    std.debug.assert(to != 0 and wm.hasWindow(to));  // Focus target must be valid and tracked
    focus.setFocus(wm, to, .tiling_operation);
    wm.focused_window = to;
    s.updateFocusHistory(to);
    updateWindowFocus(wm, from, to);
}

/// OPTIMIZATION: Helper to filter windows on current workspace
/// Reduces code duplication in focusPrevious and focusSecondLast
/// Returns the number of windows copied to the buffer
fn filterWorkspaceWindows(s: *State, buf: []u32) usize {
    var count: usize = 0;
    const all_windows = s.windows.items();
    for (all_windows) |win| {
        if (count >= buf.len) break;
        if (workspaces.isOnCurrentWorkspace(win)) {
            buf[count] = win;
            count += 1;
        }
    }
    return count;
}

/// OPTIMIZATION: Get effective master count for current workspace
inline fn getMasterCount(s: *const State, window_count: usize) u8 {
    return @min(s.master_count, @as(u8, @intCast(window_count)));
}

/// OPTIMIZATION: Helper to find window index in a slice
inline fn findWindowIndex(windows: []const u32, target: u32) ?usize {
    for (windows, 0..) |win, i| {
        if (win == target) return i;
    }
    return null;
}

/// Focus the previously focused window (alt+tab functionality)
/// Fallback: if previous window is on another workspace, focus the first slave if current is master
pub fn focusPrevious(wm: *WM) void {
    const s = StateManager.get() orelse return;
    const current_focused = wm.focused_window orelse return;
    
    // OPTIMIZATION: Use circular buffer iterator instead of slice
    var iter = s.focusHistoryIter();
    while (iter.next()) |hist_win| {
        if (hist_win == current_focused) continue;
        if (workspaces.isOnCurrentWorkspace(hist_win) and s.windows.contains(hist_win)) {
            switchFocus(wm, s, current_focused, hist_win);
            return;
        }
    }
    
    // Fallback: No valid window in history on current workspace
    const windows = s.windows.items();
    if (windows.len < 2) return;
    
    const idx = findWindowIndex(windows, current_focused) orelse return;
    const master_count = getMasterCount(s, windows.len);
    
    if (idx < master_count and windows.len > master_count) {
        switchFocus(wm, s, current_focused, windows[master_count]);
    } else if (idx >= master_count) {
        switchFocus(wm, s, current_focused, windows[if (idx + 1 < windows.len) idx + 1 else 0]);
    }
}

/// Focus the second-last focused window (mod+shift+tab functionality)
/// With intelligent fallback and carousel behavior
pub fn focusSecondLast(wm: *WM) void {
    const s = StateManager.get() orelse return;
    const current_focused = wm.focused_window;
    
    const windows = s.windows.items();
    if (windows.len < 2) return;
    
    // OPTIMIZATION: Use circular buffer iterator
    var found_current = false;
    var iter = s.focusHistoryIter();
    while (iter.next()) |hist_win| {
        if (hist_win == current_focused.?) {
            found_current = true;
            continue;
        }
        if (found_current and workspaces.isOnCurrentWorkspace(hist_win) and s.windows.contains(hist_win)) {
            switchFocus(wm, s, current_focused, hist_win);
            return;
        }
    }
    
    // Fallback: second-last is on another workspace
    // Stack-allocated buffer for workspace windows (max 64 windows)
    var ws_windows_buffer: [64]u32 = undefined;
    const ws_win_count = filterWorkspaceWindows(s, &ws_windows_buffer);
    
    if (ws_win_count < 2) return;
    
    const current_ws_windows = ws_windows_buffer[0..ws_win_count];
    
    if (ws_win_count == 2) {
        const other_win = if (current_ws_windows[0] == current_focused.?) 
            current_ws_windows[1] else current_ws_windows[0];
        switchFocus(wm, s, current_focused, other_win);
        return;
    }
    
    // 3+ windows: carousel or swap behavior
    const master_count = getMasterCount(s, ws_win_count);
    
    // Find current focused window index
    const idx = if (current_focused) |cf|
        findWindowIndex(current_ws_windows, cf) orelse 0
    else
        0;
    
    if (idx < master_count) {
        if (master_count == 1) {
            switchFocus(wm, s, current_focused, current_ws_windows[ws_win_count - 1]);
        } else {
            const next_master_idx = if (idx + 1 < master_count) idx + 1 else 0;
            switchFocus(wm, s, current_focused, current_ws_windows[next_master_idx]);
        }
    } else {
        const slave_start = master_count;
        const slave_count = ws_win_count - master_count;
        const slave_idx = idx - slave_start;
        const next_slave_idx = if (slave_idx + 1 < slave_count) slave_idx + 1 else 0;
        switchFocus(wm, s, current_focused, current_ws_windows[slave_start + next_slave_idx]);
    }
}

pub inline fn getState() ?*State {
    return StateManager.get();
}

// OPTIMIZATION: Invalidate cached geometry when window is moved/resized
pub inline fn invalidateWindowGeometry(win: u32) void {
    const s = StateManager.get() orelse return;
    s.invalidateGeometry(win);
}
