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
const fibonacci_layout = @import("fibonacci");
const dpi = @import("dpi");

// Maximum master window width ratio (95%)
const MAX_MASTER_WIDTH: f32 = 0.95;

pub const Layout = enum { master, monocle, grid, fibonacci };

const WINDOW_EVENT_MASK = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW | xcb.XCB_EVENT_MASK_PROPERTY_CHANGE;

// Layout parameter struct
const LayoutParams = struct {
    windows: []const u32,
    screen: utils.Rect,
    master_count: u8,
    master_width: f32,
    master_side: defs.MasterSide,
    margins: utils.Margins,
};

// Layout wrapper functions to adapt old interface to new
fn layoutMaster(wm: *WM, params: LayoutParams) void {
    const s = StateManager.get(true) orelse return;
    master_layout.tileWithOffset(wm.conn, s, params.windows, params.screen.width, params.screen.height, @intCast(params.screen.y));
}

fn layoutMonocle(wm: *WM, params: LayoutParams) void {
    const s = StateManager.get(true) orelse return;
    monocle_layout.tileWithOffset(wm.conn, s, params.windows, params.screen.width, params.screen.height, @intCast(params.screen.y));
}

fn layoutGrid(wm: *WM, params: LayoutParams) void {
    const s = StateManager.get(true) orelse return;
    grid_layout.tileWithOffset(wm.conn, s, params.windows, params.screen.width, params.screen.height, @intCast(params.screen.y));
}

fn layoutFibonacci(wm: *WM, params: LayoutParams) void {
    const s = StateManager.get(true) orelse return;
    fibonacci_layout.tileWithOffset(wm.conn, s, params.windows, params.screen.width, params.screen.height, @intCast(params.screen.y));
}

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

// Custom BoundedArray implementation to replace std.BoundedArray (which was removed)
fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buffer: [capacity]T,
        len: usize,

        const Self = @This();

        pub fn init(initial_len: usize) error{Overflow}!Self {
            if (initial_len > capacity) return error.Overflow;
            return Self{
                .buffer = undefined,
                .len = initial_len,
            };
        }

        pub fn slice(self: *const Self) []const T {
            return self.buffer[0..self.len];
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }
    };
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
    // Focus history for alt+tab functionality (most recent first)
    focus_history: BoundedArray(u32, 16),
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
    
    /// Update focus history when a window gains focus
    pub fn updateFocusHistory(self: *State, win: u32) void {
        // Remove window from history if it exists
        var i: usize = 0;
        while (i < self.focus_history.len) {
            if (self.focus_history.buffer[i] == win) {
                // Shift all elements after this one left
                var j = i;
                while (j + 1 < self.focus_history.len) : (j += 1) {
                    self.focus_history.buffer[j] = self.focus_history.buffer[j + 1];
                }
                self.focus_history.len -= 1;
                break;
            }
            i += 1;
        }
        
        // Insert at front (most recent)
        if (self.focus_history.len < 16) {
            // Shift everything right
            var j = self.focus_history.len;
            while (j > 0) : (j -= 1) {
                self.focus_history.buffer[j] = self.focus_history.buffer[j - 1];
            }
            self.focus_history.buffer[0] = win;
            self.focus_history.len += 1;
        } else {
            // Already at capacity, shift left and insert at front
            var j: usize = 15;
            while (j > 0) : (j -= 1) {
                self.focus_history.buffer[j] = self.focus_history.buffer[j - 1];
            }
            self.focus_history.buffer[0] = win;
        }
    }
    
    /// Remove window from focus history
    pub fn removeFocusHistory(self: *State, win: u32) void {
        var i: usize = 0;
        while (i < self.focus_history.len) {
            if (self.focus_history.buffer[i] == win) {
                // Shift all elements after this one left
                var j = i;
                while (j + 1 < self.focus_history.len) : (j += 1) {
                    self.focus_history.buffer[j] = self.focus_history.buffer[j + 1];
                }
                self.focus_history.len -= 1;
                return;
            }
            i += 1;
        }
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
        break :blk @min(MAX_MASTER_WIDTH, @max(defs.MIN_MASTER_WIDTH, ratio));
    } else master_width_value;
    
    StateManager.init(wm.allocator, .{
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
        .focus_history = BoundedArray(u32, 16).init(0) catch unreachable,
        .allocator = wm.allocator,
    }) catch |err| {
        debug.err("Failed to initialize tiling state: {}", .{err});
        return;
    };
}

pub fn deinit(wm: *WM) void {
    if (StateManager.get(true)) |s| {
        s.deinit();
    }
    StateManager.deinit(wm.allocator);
}

fn parseLayout(layout_str: []const u8) Layout {
    if (std.mem.eql(u8, layout_str, "monocle")) {
        return .monocle;
    } else if (std.mem.eql(u8, layout_str, "grid")) {
        return .grid;
    } else if (std.mem.eql(u8, layout_str, "fibonacci")) {
        return .fibonacci;
    } else {
        return .master;
    }
}

pub fn addWindow(wm: *WM, window_id: u32) void {
    const s = StateManager.get(true) orelse return;
    if (!s.enabled) return;

    s.windows.add(window_id) catch |err| {
        logError(err, window_id);
        return;
    };
    
    s.markDirty();
    s.invalidateGeometry(window_id);
    
    // Register window events
    const values = [_]u32{WINDOW_EVENT_MASK};
    _ = xcb.xcb_change_window_attributes(wm.conn, window_id, xcb.XCB_CW_EVENT_MASK, &values);
    
    // Apply initial border
    const border_color = s.borderColor(wm, window_id);
    _ = xcb.xcb_change_window_attributes(wm.conn, window_id, xcb.XCB_CW_BORDER_PIXEL, &border_color);
    _ = xcb.xcb_configure_window(wm.conn, window_id, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &s.border_width);
    
    debug.info("Added window 0x{x} to tiling", .{window_id});
}

pub fn removeWindow(wm: *WM, window_id: u32) void {
    const s = StateManager.get(true) orelse return;
    if (s.windows.remove(window_id)) {
        s.markDirty();
        s.invalidateGeometry(window_id);
        s.removeFocusHistory(window_id);
        debug.info("Removed window 0x{x} from tiling", .{window_id});
    }
    _ = wm;
}

pub fn isWindowTiled(window_id: u32) bool {
    const s = StateManager.get(true) orelse return false;
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
    const s = StateManager.get(true) orelse return;
    if (!s.enabled or !s.dirty) return;

    const screen_area = calculateScreenArea(wm);
    retile(wm, screen_area);
    s.clearDirty();
}

fn retile(wm: *WM, screen: utils.Rect) void {
    const s = StateManager.get(true) orelse return;
    
    // Don't retile if there's a fullscreen window on current workspace
    const current_ws = workspaces.getCurrentWorkspace() orelse return;
    if (wm.fullscreen.getForWorkspace(current_ws)) |_| {
        return; // Fullscreen window present - don't retile anything
    }
    
    // Get windows on current workspace
    var ws_windows = std.ArrayListUnmanaged(u32){};
    defer ws_windows.deinit(wm.allocator);
    
    const all_windows = s.windows.items();
    for (all_windows) |win| {
        if (workspaces.isOnCurrentWorkspace(win)) {
            ws_windows.append(wm.allocator, win) catch continue;
        }
    }
    
    if (ws_windows.items.len == 0) return;
    
    // Clear geometry cache for current workspace windows
    for (ws_windows.items) |win| {
        s.invalidateGeometry(win);
    }
    
    const layout_fn: *const fn (*WM, LayoutParams) void = switch (s.layout) {
        .master => layoutMaster,
        .monocle => layoutMonocle,
        .grid => layoutGrid,
        .fibonacci => layoutFibonacci,
    };
    
    const params = LayoutParams{
        .windows = ws_windows.items,
        .screen = screen,
        .master_count = s.master_count,
        .master_width = s.master_width,
        .master_side = s.master_side,
        .margins = s.margins(),
    };
    
    layout_fn(wm, params);
    updateWindowBorders(wm);
}

pub fn retileCurrentWorkspace(wm: *WM, force: bool) void {
    const s = StateManager.get(true) orelse return;
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
    const s = StateManager.get(true) orelse return;
    const windows = s.windows.items();
    
    for (windows) |win| {
        if (!workspaces.isOnCurrentWorkspace(win)) continue;
        
        const border_color = s.borderColor(wm, win);
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &border_color);
    }
    
    _ = xcb.xcb_flush(wm.conn);
}

pub fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = StateManager.get(true) orelse return;
    
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
    
    _ = xcb.xcb_flush(wm.conn);
}

// Fast version without flush - for use in focus management
pub fn updateWindowFocusFast(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = StateManager.get(true) orelse return;
    
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

pub fn onFocusChange(wm: *WM, window_id: u32) void {
    const s = StateManager.get(true) orelse return;
    const old_focused = wm.focused_window;
    
    s.updateFocusHistory(window_id);
    updateWindowFocus(wm, old_focused, window_id);
}

pub fn adjustMasterCount(wm: *WM, delta: i8) void {
    const s = StateManager.get(true) orelse return;
    
    const new_count: i16 = @as(i16, s.master_count) + delta;
    if (new_count < 0) return;
    
    s.master_count = @intCast(@min(new_count, 10));
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

pub fn increaseMasterCount(wm: *WM) void {
    adjustMasterCount(wm, 1);
}

pub fn decreaseMasterCount(wm: *WM) void {
    adjustMasterCount(wm, -1);
}

pub fn adjustMasterWidth(wm: *WM, delta: f32) void {
    const s = StateManager.get(true) orelse return;
    
    const new_width = s.master_width + delta;
    s.master_width = @max(defs.MIN_MASTER_WIDTH, @min(MAX_MASTER_WIDTH, new_width));
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

pub fn increaseMasterWidth(wm: *WM) void {
    adjustMasterWidth(wm, 0.05);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    adjustMasterWidth(wm, -0.05);
}

pub fn toggleTiling(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    s.enabled = !s.enabled;
    
    if (s.enabled) {
        retileCurrentWorkspace(wm, true);
    }
    
    debug.info("Tiling {s}", .{if (s.enabled) "enabled" else "disabled"});
}

pub fn cycleLayout(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    
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
    const s = StateManager.get(true) orelse return;
    
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
    const s = StateManager.get(true) orelse return;
    const focused = wm.focused_window orelse return;
    
    if (!s.windows.contains(focused)) return;
    if (!workspaces.isOnCurrentWorkspace(focused)) return;
    
    // Get ALL tiled windows (global list that determines tiling order)
    const all_windows = s.windows.items();
    if (all_windows.len < 2) return;
    
    // Find focused window index in global list
    var focused_idx: ?usize = null;
    for (all_windows, 0..) |win, i| {
        if (win == focused) {
            focused_idx = i;
            break;
        }
    }
    const focused_pos = focused_idx orelse return;
    
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
    const s = StateManager.get(true) orelse return;
    const focused = wm.focused_window orelse return;
    
    if (!s.windows.contains(focused)) return;
    
    const windows = s.windows.items();
    
    var focused_idx: ?usize = null;
    for (windows, 0..) |win, i| {
        if (win == focused) {
            focused_idx = i;
            break;
        }
    }
    
    const from_idx = focused_idx orelse return;
    if (from_idx == 0) return;  // Already at front
    
    // Move window to front (index 0)
    if (s.windows.small) |*small| {
        std.debug.assert(from_idx < small.items.len);
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
    
    s.markDirty();
    retileCurrentWorkspace(wm, false);
}

fn moveWindowToIndex(s: *State, from_idx: usize, to_idx: usize) void {
    if (from_idx == to_idx) return;
    
    if (s.windows.small) |*small| {
        std.debug.assert(from_idx < small.items.len);
        std.debug.assert(to_idx < small.items.len);
        const window = small.items[from_idx];
        
        if (from_idx < to_idx) {
            var i = from_idx;
            while (i < to_idx) : (i += 1) {
                small.items[i] = small.items[i + 1];
            }
        } else {
            var i = from_idx;
            while (i > to_idx) : (i -= 1) {
                small.items[i] = small.items[i - 1];
            }
        }
        small.items[to_idx] = window;
    } else if (s.windows.large) |*large| {
        std.debug.assert(from_idx < large.list.items.len);
        std.debug.assert(to_idx < large.list.items.len);
        const window = large.list.items[from_idx];
        
        if (from_idx < to_idx) {
            var i = from_idx;
            while (i < to_idx) : (i += 1) {
                large.list.items[i] = large.list.items[i + 1];
            }
        } else {
            var i = from_idx;
            while (i > to_idx) : (i -= 1) {
                large.list.items[i] = large.list.items[i - 1];
            }
        }
        large.list.items[to_idx] = window;
    }
}

pub fn moveToIndex(from_idx: usize) void {
    const s = StateManager.get(true) orelse return;
    
    // Move window at from_idx to front
    if (s.windows.small) |*small| {
        std.debug.assert(from_idx < small.items.len);
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
        break :blk @min(MAX_MASTER_WIDTH, @max(defs.MIN_MASTER_WIDTH, ratio));
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

/// Focus the previously focused window (alt+tab functionality)
/// Fallback: if previous window is on another workspace, focus the first slave if current is master
pub fn focusPrevious(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    const current_focused = wm.focused_window orelse return;
    
    // Try to find the previously focused window that's on the current workspace
    for (s.focus_history.slice()) |hist_win| {
        if (hist_win == current_focused) continue;
        if (workspaces.isOnCurrentWorkspace(hist_win) and s.windows.contains(hist_win)) {
            focus.setFocus(wm, hist_win, .tiling_operation);
            wm.focused_window = hist_win;
            s.updateFocusHistory(hist_win);
            updateWindowFocus(wm, current_focused, hist_win);
            return;
        }
    }
    
    // Fallback: No valid window in history on current workspace
    // If currently focused is a master window, switch to first slave
    const windows = s.windows.items();
    if (windows.len < 2) return; // Need at least 2 windows
    
    var focused_idx: ?usize = null;
    for (windows, 0..) |win, i| {
        if (win == current_focused) {
            focused_idx = i;
            break;
        }
    }
    
    const idx = focused_idx orelse return;
    const master_count = @min(s.master_count, @as(u8, @intCast(windows.len)));
    
    // If focused is in master area and there are slaves, focus first slave
    if (idx < master_count and windows.len > master_count) {
        const first_slave = windows[master_count];
        focus.setFocus(wm, first_slave, .tiling_operation);
        wm.focused_window = first_slave;
        s.updateFocusHistory(first_slave);
        updateWindowFocus(wm, current_focused, first_slave);
    } else if (idx >= master_count) {
        // If focused is a slave, cycle to next slave (or wrap to first master)
        const next_idx = if (idx + 1 < windows.len) idx + 1 else 0;
        const next_win = windows[next_idx];
        focus.setFocus(wm, next_win, .tiling_operation);
        wm.focused_window = next_win;
        s.updateFocusHistory(next_win);
        updateWindowFocus(wm, current_focused, next_win);
    }
}

/// Focus the second-last focused window (mod+shift+tab functionality)
/// With intelligent fallback and carousel behavior
pub fn focusSecondLast(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    const current_focused = wm.focused_window;
    
    const windows = s.windows.items();
    if (windows.len < 2) return; // Need at least 2 windows
    
    // Try to find the second-last focused window that's on current workspace
    var found_current = false;
    for (s.focus_history.slice()) |hist_win| {
        if (hist_win == current_focused.?) {
            found_current = true;
            continue;
        }
        if (found_current and workspaces.isOnCurrentWorkspace(hist_win) and s.windows.contains(hist_win)) {
            // Found valid second-last window on current workspace
            focus.setFocus(wm, hist_win, .tiling_operation);
            wm.focused_window = hist_win;
            s.updateFocusHistory(hist_win);
            updateWindowFocus(wm, current_focused, hist_win);
            return;
        }
    }
    
    // Fallback: second-last is on another workspace
    // Filter windows to only those on current workspace
    var current_ws_windows = BoundedArray(u32, 256).init(0) catch unreachable;
    for (windows) |win| {
        if (workspaces.isOnCurrentWorkspace(win)) {
            current_ws_windows.append(win) catch break;
        }
    }
    
    const ws_win_count = current_ws_windows.len;
    if (ws_win_count < 2) return;
    
    // Special case: exactly 2 windows - behave like mod+tab
    if (ws_win_count == 2) {
        const other_win = if (current_ws_windows.buffer[0] == current_focused.?) 
            current_ws_windows.buffer[1] 
        else 
            current_ws_windows.buffer[0];
        focus.setFocus(wm, other_win, .tiling_operation);
        wm.focused_window = other_win;
        s.updateFocusHistory(other_win);
        updateWindowFocus(wm, current_focused, other_win);
        return;
    }
    
    // 3+ windows: carousel or swap behavior
    const master_count = @min(s.master_count, @as(u8, @intCast(ws_win_count)));
    
    // Find current focused window index
    var focused_idx: ?usize = null;
    for (current_ws_windows.slice(), 0..) |win, i| {
        if (current_focused) |cf| {
            if (win == cf) {
                focused_idx = i;
                break;
            }
        }
    }
    
    const idx = focused_idx orelse 0;
    
    if (idx < master_count) {
        // Focused on master area
        if (master_count == 1) {
            // Single master - swap with oldest window (last in list)
            const oldest_win = current_ws_windows.buffer[ws_win_count - 1];
            focus.setFocus(wm, oldest_win, .tiling_operation);
            wm.focused_window = oldest_win;
            s.updateFocusHistory(oldest_win);
            updateWindowFocus(wm, current_focused, oldest_win);
        } else {
            // Multiple masters - carousel masters
            // Move to next master, or wrap to first master
            const next_master_idx = if (idx + 1 < master_count) idx + 1 else 0;
            const next_win = current_ws_windows.buffer[next_master_idx];
            focus.setFocus(wm, next_win, .tiling_operation);
            wm.focused_window = next_win;
            s.updateFocusHistory(next_win);
            updateWindowFocus(wm, current_focused, next_win);
        }
    } else {
        // Focused on slave area - carousel slaves
        const slave_start = master_count;
        const slave_count = ws_win_count - master_count;
        const slave_idx = idx - slave_start;
        const next_slave_idx = if (slave_idx + 1 < slave_count) slave_idx + 1 else 0;
        const next_win = current_ws_windows.buffer[slave_start + next_slave_idx];
        focus.setFocus(wm, next_win, .tiling_operation);
        wm.focused_window = next_win;
        s.updateFocusHistory(next_win);
        updateWindowFocus(wm, current_focused, next_win);
    }
}

pub inline fn getState() ?*State {
    return StateManager.get(true);
}

// OPTIMIZATION: Invalidate cached geometry when window is moved/resized
pub inline fn invalidateWindowGeometry(win: u32) void {
    const s = StateManager.get(true) orelse return;
    s.invalidateGeometry(win);
}
