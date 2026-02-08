// Tiling system - Delegates to layout modules (OPTIMIZED & REFACTORED)

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const workspaces = @import("workspaces");
const batch = @import("batch");
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
    
    pub fn deinit(self: *State) void {
        self.windows.deinit();
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

    // Try batch first, fall back to direct XCB
    var b = batch.Batch.begin(wm) catch {
        utils.configureBorder(wm.conn, win, s.border_width, s.borderColor(wm, win));
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &[_]u32{WINDOW_EVENT_MASK});
        focus.setFocus(wm, win, .tiling_operation);
        s.markDirty();
        return;
    };
    defer b.deinit();

    const color = s.borderColor(wm, win);
    b.setBorderWidth(win, s.border_width) catch {};
    b.setBorder(win, color) catch {};
    b.setFocus(win) catch {};
    b.execute();

    wm.focused_window = win;
    s.markDirty();
}

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

    var b = batch.Batch.begin(wm) catch {
        updateWindowFocusDirect(wm, old_focused, new_focused);
        return;
    };
    defer b.deinit();

    if (old_focused) |old_win| {
        if (isTileable(s, wm, old_win)) {
            b.setBorder(old_win, s.borderColor(wm, old_win)) catch {};
        }
    }
    if (new_focused) |new_win| {
        if (isTileable(s, wm, new_win)) {
            b.setBorder(new_win, s.borderColor(wm, new_win)) catch {};
        }
    }
    b.execute();
}

fn updateWindowFocusDirect(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = StateManager.get(true) orelse return;
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
    retileCurrentWorkspace(wm);
}

pub fn retileCurrentWorkspace(wm: *WM) void {
    retileCurrentWorkspaceInternal(wm, true);
}

// NO-FLUSH variant for atomic workspace switching
pub fn retileCurrentWorkspaceNoFlush(wm: *WM) void {
    retileCurrentWorkspaceInternal(wm, false);
}

fn retileCurrentWorkspaceInternal(wm: *WM, should_flush: bool) void {
    const s = StateManager.get(true) orelse return;
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
    const bar_height = if (wm.config.bar.show) bar.getBarHeight() else 0;
    const available_height = screen.height_in_pixels - bar_height;
    const y_offset: u16 = if (wm.config.bar.show and wm.config.bar.vertical_position == .top)
        bar_height
    else
        0;

    // Create batch for all layout operations
    var b = batch.Batch.begin(wm) catch {
        logError(error.BatchFailed, null);
        return;
    };
    defer b.deinit();

    // Delegate to layout module
    switch (s.layout) {
        .master => master_layout.tileWithOffset(&b, s, visible, screen.width_in_pixels, available_height, y_offset),
        .monocle => monocle_layout.tileWithOffset(&b, s, visible, screen.width_in_pixels, available_height, y_offset),
        .grid => grid_layout.tileWithOffset(&b, s, visible, screen.width_in_pixels, available_height, y_offset),
    }

    // Set borders in single pass
    for (visible) |win| {
        const color = s.borderColor(wm, win);
        b.setBorderWidth(win, s.border_width) catch {};
        b.setBorder(win, color) catch {};
    }
    
    // CRITICAL FIX: Safety check for windows that might be in workspace but not in tiling list
    // This prevents windows from being stuck off-screen at x=-4000
    // Check all windows in current workspace and ensure they're on-screen
    for (current_ws.windows.items()) |ws_win| {
        // Skip if already in visible list
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
        if (check_geom.x < -1000 or check_geom.x > 10000) {
            // Window is off-screen! Position it at a default location
            debug.warn("Recovering window 0x{x} from off-screen position", .{ws_win});
            const default_x: i16 = @divTrunc(@as(i16, @intCast(screen.width_in_pixels)), 4);
            const default_y: i16 = @divTrunc(@as(i16, @intCast(available_height)), 4) + @as(i16, @intCast(y_offset));
            const default_w: u16 = @divTrunc(screen.width_in_pixels, 2);
            const default_h: u16 = @divTrunc(available_height, 2);
            const default_rect = utils.Rect{ .x = default_x, .y = default_y, .width = default_w, .height = default_h };
            b.configure(ws_win, default_rect) catch {};
        }
    }
    
    // Only flush if requested (for atomic workspace switching, caller will flush)
    if (should_flush) {
        b.execute();
    } else {
        b.executeNoFlush();
    }
    
    // Clear tiling suppression after retile completes
    // This allows focus-follows-mouse to work during normal operation
    // but preserves .window_spawn suppression set during window creation
    if (wm.suppress_focus_reason == .tiling_operation) {
        wm.suppress_focus_reason = .none;
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
    retileCurrentWorkspace(wm);
}

pub fn toggleLayout(wm: *WM) void { cycleLayout(wm, true); }
pub fn toggleLayoutReverse(wm: *WM) void { cycleLayout(wm, false); }

fn adjustMasterWidth(wm: *WM, delta: f32) void {
    const s = StateManager.get(true) orelse return;
    s.master_width = @max(s.master_width + delta, defs.MIN_MASTER_WIDTH);
    retileCurrentWorkspace(wm);
}

pub fn increaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm, 0.05); }
pub fn decreaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm, -0.05); }

fn adjustMasterCount(wm: *WM, delta: isize) void {
    const s = StateManager.get(true) orelse return;
    const win_count: u8 = @intCast(@min(255, s.windows.count()));
    const new_count: u8 = if (delta > 0)
        @min(win_count, s.master_count +| @as(u8, @intCast(delta)))
    else
        @max(1, s.master_count -| @as(u8, @intCast(-delta)));
    if (new_count != s.master_count) {
        s.master_count = new_count;
        bar.markDirty();
        retileCurrentWorkspace(wm);
    }
}

pub fn increaseMasterCount(wm: *WM) void { adjustMasterCount(wm, 1); }
pub fn decreaseMasterCount(wm: *WM) void { adjustMasterCount(wm, -1); }

pub fn toggleTiling(wm: *WM) void {
    const s = StateManager.get(true) orelse return;
    s.enabled = !s.enabled;
    bar.markDirty();
    if (s.enabled) {
        retileCurrentWorkspace(wm);
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
    if (s.enabled) retileCurrentWorkspace(wm);
}

pub inline fn getState() ?*State {
    return StateManager.get(true);
}
