//! Tiling system - Delegates to layout modules

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const focus      = @import("focus");
const workspaces = @import("workspaces");
const batch      = @import("batch");
const bar        = @import("bar");

const master_layout = @import("master");
const monocle_layout = @import("monocle");
const grid_layout = @import("grid");

pub const Layout = enum { master, monocle, grid };

pub const State = struct {
    enabled:             bool,
    layout:              Layout,
    master_side:         defs.MasterSide,
    master_width_factor: f32,
    master_count:        usize,
    gaps:                u16,
    border_width:        u16,
    border_focused:      u32,
    border_normal:       u32,
    tiled_windows:       std.ArrayList(u32),
    tiled_set:           std.AutoHashMap(u32, void),
    allocator:           std.mem.Allocator,
    dirty:               bool,

    pub fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }

    pub fn borderColor(self: *const State, wm: *const WM, win: u32) u32 {
        if (!self.tiled_set.contains(win)) return self.border_normal;
        if (wm.fullscreen.isFullscreen(win)) return 0;
        return if (wm.focused_window == win) self.border_focused else self.border_normal;
    }

    pub fn markDirty(self: *State) void {
        self.dirty = true;
    }

    pub fn isDirty(self: *const State) bool {
        return self.dirty;
    }

    pub fn clearDirty(self: *State) void {
        self.dirty = false;
    }
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch {
        std.log.err("[tiling] Failed to allocate state", .{});
        return;
    };

    s.* = .{
        .enabled = wm.config.tiling.enabled,
        .layout  = parseLayout(wm.config.tiling.layout),
        .master_side         = wm.config.tiling.master_side,
        .master_width_factor = wm.config.tiling.master_width_factor,
        .master_count        = wm.config.tiling.master_count,
        .gaps           = wm.config.tiling.gaps,
        .border_width   = wm.config.tiling.border_width,
        .border_focused = wm.config.tiling.border_focused,
        .border_normal  = wm.config.tiling.border_normal,
        .tiled_windows = std.ArrayList(u32){},
        .tiled_set     = std.AutoHashMap(u32, void).init(wm.allocator),
        .allocator = wm.allocator,
        .dirty     = false,
    };

    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        s.tiled_windows.deinit(s.allocator);
        s.tiled_set.deinit();
        wm.allocator.destroy(s);
        state = null;
    }
}

fn parseLayout(name: []const u8) Layout {
    const map = std.StaticStringMap(Layout).initComptime(.{
        .{ "master", .master },
        .{ "monocle", .monocle },
        .{ "grid", .grid },
    });
    return map.get(name) orelse .master;
}

pub fn addWindow(wm: *WM, win: u32) void {
    const s = state orelse return;
    if (!s.enabled) return;

    if (wm.fullscreen.isFullscreen(win) or s.tiled_set.contains(win)) {
        s.markDirty();
        return;
    }

    s.tiled_windows.insert(s.allocator, 0, win) catch |err| {
        std.log.err("[tiling] Failed to add window to list: {}", .{err});
        return;
    };
    s.tiled_set.put(win, {}) catch |err| {
        std.log.err("[tiling] Failed to add window to set: {}", .{err});
        _ = s.tiled_windows.orderedRemove(0);
        return;
    };

    // Window is registered in the tiling lists regardless of which workspace it
    // lives on — retileCurrentWorkspace filters by workspace at layout time.
    // Skip focus and border setup for windows not on the current workspace;
    // those side-effects are applied when the workspace is switched to.
    if (!workspaces.isOnCurrentWorkspace(win)) {
        s.markDirty();
        return;
    }

    var b = batch.Batch.begin(wm) catch {
        utils.configureBorder(wm.conn, win, s.border_width, s.borderColor(wm, win));
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK,
            &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
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
    const s = state orelse return;

    _ = s.tiled_set.remove(win);

    for (s.tiled_windows.items, 0..) |w, i| {
        if (w == win) {
            _ = s.tiled_windows.orderedRemove(i);

            if (s.tiled_windows.items.len > 0 and wm.focused_window == win) {
                const next = s.tiled_windows.items[0];
                focus.setFocus(wm, next, .tiling_operation);
            }
            s.markDirty();
            return;
        }
    }
}

pub fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = state orelse return;
    if (!s.enabled) return;

    var b = batch.Batch.begin(wm) catch {
        updateWindowFocusDirect(wm, old_focused, new_focused);
        return;
    };
    defer b.deinit();

    if (old_focused) |old_win| {
        if (s.tiled_set.contains(old_win) and !wm.fullscreen.isFullscreen(old_win)) {
            b.setBorder(old_win, s.borderColor(wm, old_win)) catch {};
        }
    }

    if (new_focused) |new_win| {
        if (s.tiled_set.contains(new_win) and !wm.fullscreen.isFullscreen(new_win)) {
            b.setBorder(new_win, s.borderColor(wm, new_win)) catch {};
        }
    }

    b.execute();
}

fn updateWindowFocusDirect(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = state orelse return;

    if (old_focused) |old_win| {
        if (s.tiled_set.contains(old_win) and !wm.fullscreen.isFullscreen(old_win)) {
            utils.setBorder(wm.conn, old_win, s.borderColor(wm, old_win));
        }
    }

    if (new_focused) |new_win| {
        if (s.tiled_set.contains(new_win) and !wm.fullscreen.isFullscreen(new_win)) {
            utils.setBorder(wm.conn, new_win, s.borderColor(wm, new_win));
        }
    }

    utils.flush(wm.conn);
}

// Alias for compatibility (if anything calls it)
pub fn updateWindowFocusFast(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    updateWindowFocus(wm, old_focused, new_focused);
}

pub fn isWindowTiled(win: u32) bool {
    const s = state orelse return false;
    return s.enabled and s.tiled_set.contains(win);
}

pub fn retileIfDirty(wm: *WM) void {
    const s = state orelse return;
    if (!s.isDirty()) return;

    s.clearDirty();
    retileCurrentWorkspace(wm);
}

pub fn retileCurrentWorkspace(wm: *WM) void {
    const s = state orelse return;
    if (!s.enabled) return;

    const ws_state = workspaces.getState() orelse return;
    const current_ws = &ws_state.workspaces[ws_state.current];
    
    if (s.tiled_windows.items.len == 0) return;

    // Collect visible windows (O(1) lookup using workspace HashSet)
    var visible_buf: [128]u32 = undefined;
    var visible_count: usize = 0;

    for (s.tiled_windows.items) |win| {
        if (wm.fullscreen.isFullscreen(win)) continue;
        if (!s.tiled_set.contains(win)) continue;
        
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

    // Use new layout modules for tiling
    var b = batch.Batch.begin(wm) catch {
        std.log.err("[tiling] Failed to create batch, skipping retile", .{});
        return;
    };
    defer b.deinit();

    // Pass adjusted height and offset to layout functions
    switch (s.layout) {
        .master => master_layout.tileWithOffset(&b, s, visible, screen.width_in_pixels, available_height, y_offset),
        .monocle => monocle_layout.tileWithOffset(&b, s, visible, screen.width_in_pixels, available_height, y_offset),
        .grid => grid_layout.tileWithOffset(&b, s, visible, screen.width_in_pixels, available_height, y_offset),
    }

    // Set borders
    for (visible) |win| {
        const color = s.borderColor(wm, win);
        b.setBorderWidth(win, s.border_width) catch {};
        b.setBorder(win, color) catch {};
    }

    b.execute();
}

pub fn toggleLayout(wm: *WM) void {
    const s = state orelse return;
    s.layout = switch (s.layout) {
        .master => .monocle,
        .monocle => .grid,
        .grid => .master,
    };

    bar.markDirty();
    retileCurrentWorkspace(wm);
}

pub fn toggleLayoutReverse(wm: *WM) void {
    const s = state orelse return;
    s.layout = switch (s.layout) {
        .master => .grid,
        .grid => .monocle,
        .monocle => .master,
    };

    bar.markDirty();
    retileCurrentWorkspace(wm);
}

pub fn increaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @min(defs.MAX_MASTER_WIDTH, s.master_width_factor + 0.05);
    retileCurrentWorkspace(wm);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @max(defs.MIN_MASTER_WIDTH, s.master_width_factor - 0.05);
    retileCurrentWorkspace(wm);
}

pub fn increaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @min(s.tiled_windows.items.len, s.master_count + 1);
    bar.markDirty();
    retileCurrentWorkspace(wm);
}

pub fn decreaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @max(1, s.master_count -| 1);
    bar.markDirty();
    retileCurrentWorkspace(wm);
}

pub fn toggleTiling(wm: *WM) void {
    const s = state orelse return;
    s.enabled = !s.enabled;
    bar.markDirty();

    if (s.enabled) {
        retileCurrentWorkspace(wm);
    }
}

pub fn reloadConfig(wm: *WM) void {
    const s = state orelse return;

    s.enabled = wm.config.tiling.enabled;
    s.layout = parseLayout(wm.config.tiling.layout);
    s.master_side = wm.config.tiling.master_side;
    s.master_width_factor = wm.config.tiling.master_width_factor;
    s.master_count = wm.config.tiling.master_count;
    s.gaps = wm.config.tiling.gaps;
    s.border_width = wm.config.tiling.border_width;
    s.border_focused = wm.config.tiling.border_focused;
    s.border_normal = wm.config.tiling.border_normal;

    if (s.enabled) retileCurrentWorkspace(wm);
}

pub fn getState() ?*State {
    return state;
}
