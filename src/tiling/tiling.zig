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
const focus = @import("focus");
const workspaces = @import("workspaces");
const bar = @import("bar");
const tracking = @import("tracking").tracking;
const createModule = @import("module").module;
const debug = @import("debug");

const master_layout = @import("master");
const monocle_layout = @import("monocle");
const grid_layout = @import("grid");
const dpi = @import("dpi");

pub const Layout = enum { master, monocle, grid };

const WINDOW_EVENT_MASK = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW;

// FIXED: Magic numbers replaced with named constants (shared with window.zig)
/// Minimum X coordinate threshold for detecting off-screen windows
const OFFSCREEN_THRESHOLD_MIN: i32 = -1000;

/// Maximum X coordinate threshold for detecting off-screen windows  
const OFFSCREEN_THRESHOLD_MAX: i32 = 10000;

// OPTIMIZATION: Merged error handling directly into this module
inline fn logError(err: anyerror, window: ?u32) void {
    if (window) |win| {
        debug.err("Failed: {} (window: 0x{x})", .{ err, win });
    } else {
        debug.err("Failed: {}", .{err});
    }
}

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
            self.geometry_cache.put(win, rect) catch {};  // Best-effort caching
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
    
    pub fn deinit(self: *State) void {
        self.windows.deinit();
        self.geometry_cache.deinit();
    }
};

const StateManager = createModule(State);

pub fn init(wm: *WM) void {
    // Scale border widths and gaps based on DPI
    // For percentage values, use screen height as reference dimension
    const screen_height = wm.screen.height_in_pixels;
    const scaled_border_width = dpi.scaleBorderWidth(wm.config.tiling.border_width, wm.dpi_info.scale_factor, screen_height);
    const scaled_gaps = dpi.scaleGaps(wm.config.tiling.gaps, wm.dpi_info.scale_factor, screen_height);
    
    // Handle master_width (can be percentage or absolute pixels)
    const master_width_value = dpi.scaleMasterWidth(wm.config.tiling.master_width);
    const master_width: f32 = if (master_width_value < 0) blk: {
        // Negative means it's absolute pixels - convert to ratio
        const abs_pixels = -master_width_value;
        const screen_width_f: f32 = @floatFromInt(wm.screen.width_in_pixels);
        const ratio = abs_pixels / screen_width_f;
        break :blk @min(0.95, @max(defs.MIN_MASTER_WIDTH, ratio));
    } else master_width_value;
    
    debug.info("DPI-scaled tiling: border {}px{s}, gaps {}px{s}, master_width {d:.2}", .{
        scaled_border_width, 
        if (wm.config.tiling.border_width.is_percentage) "%" else "",
        scaled_gaps,
        if (wm.config.tiling.gaps.is_percentage) "%" else "",
        master_width,
    });
    
    const initial_state = State{
        .enabled = wm.config.tiling.enabled,
        .layout = parseLayout(wm.config.tiling.layout),
        .master_side = wm.config.tiling.master_side,
        .master_width = master_width,
        .master_count = wm.config.tiling.master_count,
        .gaps = scaled_gaps,
        .border_width = scaled_border_width,
        .border_focused = wm.config.tiling.border_focused,
        .border_unfocused = wm.config.tiling.border_unfocused,
        .windows = tracking.init(wm.allocator),
        .dirty = false,
        .geometry_cache = std.AutoHashMap(u32, utils.Rect).init(wm.allocator),
        .allocator = wm.allocator,
    };

    StateManager.init(wm.allocator, initial_state) catch |err| {
        logError(err, null);
    };
}

pub fn deinit(wm: *WM) void {
    if (StateManager.get(true)) |s| {
        s.deinit();
    }
    StateManager.deinit(wm.allocator);
}

fn parseLayout(name: []const u8) Layout {
    const map = std.StaticStringMap(Layout).initComptime(.{
        .{ "master", .master },
        .{ "monocle", .monocle },
        .{ "grid", .grid },
    });
    return map.get(name) orelse .master;
}

inline fn isTileable(s: *const State, wm: *const WM, win: u32) bool {
    return !wm.fullscreen.isFullscreen(win) and s.windows.contains(win);
}

/// Adds a window to the tiling system.
/// 
/// If the window is already tiled or in fullscreen mode, only marks
/// the layout as dirty. Otherwise, prepends the window to the tiled
/// list and applies initial border/focus setup for windows on the current workspace.
///
/// Side effects: May retile workspace if dirty flag is set later
pub fn addWindow(wm: *WM, win: u32) void {
    const s = StateManager.get(true) orelse return;
    if (!s.enabled) return;

    if (wm.fullscreen.isFullscreen(win) or s.windows.contains(win)) {
        s.markDirty();
        return;
    }

    // Add to tiled windows (prepend for focus ordering)
    s.windows.addFront(win) catch |err| {
        logError(err, win);
        return;
    };

    // Skip border/focus setup if not on current workspace
    if (!workspaces.isOnCurrentWorkspace(win)) {
        s.markDirty();
        return;
    }

    // Direct XCB calls - no batch overhead
    utils.configureBorder(wm.conn, win, s.border_width, s.borderColor(wm, win));
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
    focus.setFocus(wm, win, .tiling_operation);
    wm.focused_window = win;
    s.markDirty();
}

/// Removes a window from the tiling system.
/// 
/// If the removed window was focused, focuses the next window in the tiled list.
/// Marks the layout as dirty to trigger retiling.
///
/// Side effects: May change focused window, triggers retiling
pub fn removeWindow(wm: *WM, win: u32) void {
    const s = StateManager.get(true) orelse return;

    if (s.windows.remove(win)) {
        if (s.windows.count() > 0 and wm.focused_window == win) {
            const next = s.windows.items()[0];
            focus.setFocus(wm, next, .tiling_operation);
        }
        s.markDirty();
    }
}

pub fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = StateManager.get(true) orelse return;
    if (!s.enabled) return;

    // Direct XCB calls - no batch overhead
    if (old_focused) |old_win| {
        if (isTileable(s, wm, old_win)) {
            utils.setBorder(wm.conn, old_win, s.borderColor(wm, old_win));
        }
    }
    if (new_focused) |new_win| {
        if (isTileable(s, wm, new_win)) {
            utils.setBorder(wm.conn, new_win, s.borderColor(wm, new_win));
        }
    }
    utils.flush(wm.conn);
}

pub const updateWindowFocusFast = updateWindowFocus;

pub inline fn isWindowTiled(win: u32) bool {
    const s = StateManager.get(false) orelse return false;
    return s.enabled and s.windows.contains(win);
}

pub fn retileIfDirty(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    if (!s.isDirty()) return;
    s.clearDirty();
    retileCurrentWorkspaceWithState(wm, s, true);
}

/// Retile the current workspace with optional flush control
/// flush: true = flush XCB connection after retiling (default for most operations)
///        false = skip flush (used for atomic workspace switching)
pub fn retileCurrentWorkspace(wm: *WM, flush: bool) void {
    retileCurrentWorkspaceInternal(wm, flush, null);
}

/// OPTIMIZATION: Accept state to avoid redundant StateManager.get() calls
inline fn retileCurrentWorkspaceWithState(wm: *WM, s: *State, flush: bool) void {
    retileCurrentWorkspaceInternal(wm, flush, s);
}

/// OPTIMIZATION: Accept optional state parameter to reduce redundant StateManager.get() calls
/// Internal implementation - use public API functions instead
fn retileCurrentWorkspaceInternal(wm: *WM, should_flush: bool, state_opt: ?*State) void {
    const s = state_opt orelse StateManager.get(true) orelse return;
    if (!s.enabled or s.windows.count() == 0) return;

    const ws_state = workspaces.getState() orelse return;
    const current_ws = &ws_state.workspaces[ws_state.current];

    // Stack-allocated buffer for visible windows (typical max is ~20-30)
    var visible_buf: [128]u32 = undefined;
    var visible_count: usize = 0;

    // OPTIMIZATION: Direct iteration without redundant checks
    for (s.windows.items()) |win| {
        if (wm.fullscreen.isFullscreen(win)) continue;
        if (current_ws.contains(win)) {
            if (visible_count < visible_buf.len) {
                visible_buf[visible_count] = win;
                visible_count += 1;
            }
        }
    }

    if (visible_count == 0) return;

    const visible = visible_buf[0..visible_count];
    const screen = wm.screen;

    // Calculate available space accounting for bar
    const bar_height = if (wm.config.bar.enabled) bar.getBarHeight() else 0;
    const available_height = screen.height_in_pixels - bar_height;
    const y_offset: u16 = if (wm.config.bar.enabled and wm.config.bar.vertical_position == .top)
        bar_height
    else
        0;

    // Direct XCB calls - delegate to layout module
    // XCB buffers internally, so no need for batch wrapper
    switch (s.layout) {
        .master => master_layout.tileWithOffset(wm.conn, s, visible, screen.width_in_pixels, available_height, y_offset),
        .monocle => monocle_layout.tileWithOffset(wm.conn, s, visible, screen.width_in_pixels, available_height, y_offset),
        .grid => grid_layout.tileWithOffset(wm.conn, s, visible, screen.width_in_pixels, available_height, y_offset),
    }

    // Set borders in single pass
    for (visible) |win| {
        const color = s.borderColor(wm, win);
        utils.setBorderWidth(wm.conn, win, s.border_width);
        utils.setBorder(wm.conn, win, color);
    }
    
    recoverOffscreenWindows(wm, current_ws, visible, screen, y_offset);
    
    // Flush if requested (for atomic workspace switching, caller will flush)
    if (should_flush) {
        utils.flush(wm.conn);
    }
    
    // Clear tiling suppression after retile completes
    // This allows focus-follows-mouse to work during normal operation
    // but preserves .window_spawn suppression set during window creation
    if (wm.suppress_focus_reason == .tiling_operation) {
        wm.suppress_focus_reason = .none;
    }
}

// OPTIMIZATION: Extracted window recovery to reduce retile() size
fn recoverOffscreenWindows(wm: *WM, current_ws: *workspaces.Workspace, visible: []const u32,
                           screen: *xcb.xcb_screen_t, y_offset: u16) void {
    // CRITICAL FIX: Safety check for windows that might be in workspace but not in tiling list
    // This prevents windows from being stuck off-screen at x=-4000
    const available_height = if (bar.isBarVisible()) screen.height_in_pixels - bar.getBarHeight() else screen.height_in_pixels;
    
    for (current_ws.windows.items()) |ws_win| {
        // Skip if already in visible list or fullscreen
        var found = false;
        for (visible) |v_win| {
            if (v_win == ws_win) {
                found = true;
                break;
            }
        }
        if (found or wm.fullscreen.isFullscreen(ws_win)) continue;
        
        // This window is in workspace but wasn't retiled - check if it's off-screen
        const check_geom = utils.getGeometry(wm.conn, ws_win) orelse continue;
        if (check_geom.x < OFFSCREEN_THRESHOLD_MIN or check_geom.x > OFFSCREEN_THRESHOLD_MAX) {
            // Window is off-screen! Position it at a default location
            debug.warn("Recovering window 0x{x} from off-screen position", .{ws_win});
            const default_x: i16 = @divTrunc(@as(i16, @intCast(screen.width_in_pixels)), 4);
            const default_y: i16 = @divTrunc(@as(i16, @intCast(available_height)), 4) + @as(i16, @intCast(y_offset));
            const default_w: u16 = @divTrunc(screen.width_in_pixels, 2);
            const default_h: u16 = @divTrunc(available_height, 2);
            const default_rect = utils.Rect{ .x = default_x, .y = default_y, .width = default_w, .height = default_h };
            utils.configureWindow(wm.conn, ws_win, default_rect);
        }
    }
}

fn cycleLayout(wm: *WM, forward: bool) void {
    const s = StateManager.get(true) orelse return;
    s.layout = if (forward) switch (s.layout) {
        .master => .monocle,
        .monocle => .grid,
        .grid => .master,
    } else switch (s.layout) {
        .master => .grid,
        .grid => .monocle,
        .monocle => .master,
    };
    bar.markDirty();
    retileCurrentWorkspaceWithState(wm, s, true); // OPTIMIZATION: Pass state to avoid redundant fetch
}

pub fn toggleLayout(wm: *WM) void { cycleLayout(wm, true); }
pub fn toggleLayoutReverse(wm: *WM) void { cycleLayout(wm, false); }

fn adjustMasterWidth(wm: *WM, delta: f32) void {
    const s = StateManager.get(true) orelse return;
    s.master_width = @max(s.master_width + delta, defs.MIN_MASTER_WIDTH);
    retileCurrentWorkspaceWithState(wm, s, true); // OPTIMIZATION: Pass state to avoid redundant fetch
}

pub fn increaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm, 0.05); }
pub fn decreaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm, -0.05); }

// FIXED: Changed delta type from isize to i8 to prevent overflow issues
// Only ever called with 1 or -1, so i8 is sufficient and safer
fn adjustMasterCount(wm: *WM, delta: i8) void {
    const s = StateManager.get(true) orelse return;
    const win_count: u8 = @intCast(@min(255, s.windows.count()));
    const new_count: u8 = if (delta > 0)
        @min(win_count, s.master_count +| @as(u8, @intCast(delta)))
    else
        @max(1, s.master_count -| @as(u8, @intCast(-delta)));
    if (new_count != s.master_count) {
        s.master_count = new_count;
        bar.markDirty();
        retileCurrentWorkspaceWithState(wm, s, true); // OPTIMIZATION: Pass state to avoid redundant fetch
    }
}

pub fn increaseMasterCount(wm: *WM) void { adjustMasterCount(wm, 1); }
pub fn decreaseMasterCount(wm: *WM) void { adjustMasterCount(wm, -1); }

pub fn toggleTiling(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    s.enabled = !s.enabled;
    bar.markDirty();
    if (s.enabled) {
        retileCurrentWorkspaceWithState(wm, s, true); // OPTIMIZATION: Pass state to avoid redundant fetch
    }
}

// NEW: Swap focused window with master or move slave to master
pub fn swapWithMaster(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    if (!s.enabled or s.windows.count() < 2) return;
    
    const focused = wm.focused_window orelse return;
    if (!s.windows.contains(focused)) return;
    
    const windows = s.windows.items();
    const master_count: usize = @intCast(s.master_count);
    
    // Find position of focused window
    var focused_idx: ?usize = null;
    for (windows, 0..) |win, i| {
        if (win == focused) {
            focused_idx = i;
            break;
        }
    }
    
    const idx = focused_idx orelse return;
    
    // Suppress focus to prevent mouse from stealing it during the swap
    wm.suppress_focus_reason = .tiling_operation;
    
    if (idx < master_count) {
        // Focused window is in master area
        // Swap with the first window after master area (if it exists)
        if (windows.len > master_count) {
            // Swap master with first slave
            swapWindows(s, idx, master_count);
            s.markDirty();
            retileCurrentWorkspaceWithState(wm, s, true); // OPTIMIZATION: Pass state to avoid redundant fetch
            // Keep focus on the window (it's now in slave position)
            focus.setFocus(wm, focused, .tiling_operation);
        }
    } else {
        // Focused window is in slave area
        // Move it to first master position (pushing previous master to slaves)
        moveToFront(s, idx);
        s.markDirty();
        retileCurrentWorkspaceWithState(wm, s, true); // OPTIMIZATION: Pass state to avoid redundant fetch
        // Keep focus on the window (it's now in master position)
        focus.setFocus(wm, focused, .tiling_operation);
    }
}

// Helper: Swap two windows in the tracking list
inline fn swapWindows(s: *State, idx1: usize, idx2: usize) void {
    // FIXED: Add bounds checking to prevent out-of-bounds access
    if (s.windows.small) |*small| {
        std.debug.assert(idx1 < small.len);
        std.debug.assert(idx2 < small.len);
        const temp = small.items[idx1];
        small.items[idx1] = small.items[idx2];
        small.items[idx2] = temp;
    } else if (s.windows.large) |*large| {
        std.debug.assert(idx1 < large.list.items.len);
        std.debug.assert(idx2 < large.list.items.len);
        const temp = large.list.items[idx1];
        large.list.items[idx1] = large.list.items[idx2];
        large.list.items[idx2] = temp;
    }
}

// Helper: Move window from idx to front (index 0)
inline fn moveToFront(s: *State, from_idx: usize) void {
    if (from_idx == 0) return;
    
    // FIXED: Add bounds checking to prevent out-of-bounds access
    if (s.windows.small) |*small| {
        std.debug.assert(from_idx < small.len);
        const window = small.items[from_idx];
        // Shift everything from 0..from_idx one position right
        var i = from_idx;
        while (i > 0) : (i -= 1) {
            small.items[i] = small.items[i - 1];
        }
        small.items[0] = window;
    } else if (s.windows.large) |*large| {
        std.debug.assert(from_idx < large.list.items.len);
        const window = large.list.items[from_idx];
        // Shift everything from 0..from_idx one position right
        var i = from_idx;
        while (i > 0) : (i -= 1) {
            large.list.items[i] = large.list.items[i - 1];
        }
        large.list.items[0] = window;
    }
}

pub fn reloadConfig(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    
    // Scale border widths and gaps based on DPI
    const screen_height = wm.screen.height_in_pixels;
    const scaled_border_width = dpi.scaleBorderWidth(wm.config.tiling.border_width, wm.dpi_info.scale_factor, screen_height);
    const scaled_gaps = dpi.scaleGaps(wm.config.tiling.gaps, wm.dpi_info.scale_factor, screen_height);
    
    // Handle master_width (can be percentage or absolute pixels)
    const master_width_value = dpi.scaleMasterWidth(wm.config.tiling.master_width);
    const master_width: f32 = if (master_width_value < 0) blk: {
        // Negative means it's absolute pixels - convert to ratio
        const abs_pixels = -master_width_value;
        const screen_width_f: f32 = @floatFromInt(wm.screen.width_in_pixels);
        const ratio = abs_pixels / screen_width_f;
        break :blk @min(0.95, @max(defs.MIN_MASTER_WIDTH, ratio));
    } else master_width_value;
    
    s.enabled = wm.config.tiling.enabled;
    s.layout = parseLayout(wm.config.tiling.layout);
    s.master_side = wm.config.tiling.master_side;
    s.master_width = master_width;
    s.master_count = wm.config.tiling.master_count;
    s.gaps = scaled_gaps;
    s.border_width = scaled_border_width;
    s.border_focused = wm.config.tiling.border_focused;
    s.border_unfocused = wm.config.tiling.border_unfocused;
    if (s.enabled) retileCurrentWorkspace(wm, true);
}

pub inline fn getState() ?*State {
    return StateManager.get(true);
}

// OPTIMIZATION: Invalidate cached geometry when window is moved/resized
pub inline fn invalidateWindowGeometry(win: u32) void {
    const s = StateManager.get(true) orelse return;
    s.invalidateGeometry(win);
}
