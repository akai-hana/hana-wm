//! Tiling system

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
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

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }

    pub inline fn borderColor(self: *const State, wm: *const WM, win: u32) u32 {
        if (!self.tiled_set.contains(win)) return self.border_normal;
        if (wm.fullscreen_window == win) return 0;
        return if (wm.focused_window == win) self.border_focused else self.border_normal;
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
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch {
        std.log.err("[tiling] Failed to allocate state", .{});
        return;
    };

    s.* = .{
        // Setup
        .enabled = wm.config.tiling.enabled,
        .layout  = parseLayout(wm.config.tiling.layout),

        // Geometry
        .master_side         = wm.config.tiling.master_side,
        .master_width_factor = wm.config.tiling.master_width_factor,
        .master_count        = wm.config.tiling.master_count,

        // Aesthetics
        .gaps           = wm.config.tiling.gaps,
        .border_width   = wm.config.tiling.border_width,
        .border_focused = wm.config.tiling.border_focused,
        .border_normal  = wm.config.tiling.border_normal,

        // Tracking
        .tiled_windows = std.ArrayList(u32){},
        .tiled_set     = std.AutoHashMap(u32, void).init(wm.allocator),

        // Infrastructure
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
    if (!s.enabled or !workspaces.isOnCurrentWorkspace(win)) return;

    if (wm.fullscreen_window == win or s.tiled_set.contains(win)) {
        s.markDirty();
        return;
    }

    s.tiled_windows.insert(s.allocator, 0, win) catch |err| {
        std.log.err("[tiling] Failed to add window: {}", .{err});
        return;
    };
    s.tiled_set.put(win, {}) catch |err| {
        std.log.err("[tiling] Failed to add to set: {}", .{err});
        _ = s.tiled_windows.orderedRemove(0);
        return;
    };

    var b = batch.Batch.begin(wm) catch {
        utils.configureBorder(wm.conn, win, s.border_width, s.borderColor(wm, win));
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK,
            &[_]u32{xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW});
        utils.setFocus(wm, win, true);
        s.markDirty();
        return;
    };
    defer b.deinit();

    const color = s.borderColor(wm, win);
    b.setBorderWidth(win, s.border_width) catch {};
    b.setBorder(win, color) catch {};
    b.setFocus(win) catch {};
    b.execute(); // Flushes immediately

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
                utils.setFocus(wm, next, false);
            }
            s.markDirty();
            return;
        }
    }
}

pub inline fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = state orelse return;
    if (!s.enabled) return;

    var b = batch.Batch.begin(wm) catch {
        updateWindowFocusSlow(wm, old_focused, new_focused);
        return;
    };
    defer b.deinit();

    if (old_focused) |old_win| {
        if (s.tiled_set.contains(old_win) and wm.fullscreen_window != old_win) {
            b.setBorder(old_win, s.borderColor(wm, old_win)) catch {};
        }
    }

    if (new_focused) |new_win| {
        if (s.tiled_set.contains(new_win) and wm.fullscreen_window != new_win) {
            b.setBorder(new_win, s.borderColor(wm, new_win)) catch {};
        }
    }

    b.execute();  // Flushes immediately
}

fn updateWindowFocusSlow(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = state orelse return;

    if (old_focused) |old_win| {
        if (s.tiled_set.contains(old_win) and wm.fullscreen_window != old_win) {
            utils.setBorder(wm.conn, old_win, s.borderColor(wm, old_win));
        }
    }

    if (new_focused) |new_win| {
        if (s.tiled_set.contains(new_win) and wm.fullscreen_window != new_win) {
            utils.setBorder(wm.conn, new_win, s.borderColor(wm, new_win));
        }
    }

    utils.flush(wm.conn);  // Flush immediately
}

pub inline fn updateWindowFocusFast(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    updateWindowFocus(wm, old_focused, new_focused);
}

pub inline fn isWindowTiled(win: u32) bool {
    const s = state orelse return false;
    return s.enabled and s.tiled_set.contains(win);
}

// Immediate retiling when dirty
pub fn retileIfDirty(wm: *WM) void {
    const s = state orelse return;
    if (!s.isDirty()) return;

    s.clearDirty();
    retileCurrentWorkspace(wm); // This flushes
}

pub fn retileCurrentWorkspace(wm: *WM) void {
    const s = state orelse return;
    if (!s.enabled) return;

    const ws_windows = workspaces.getCurrentWindowsView() orelse return;
    if (s.tiled_windows.items.len == 0) return;

    var visible_buf: [128]u32 = undefined;
    var visible_count: usize = 0;

    for (s.tiled_windows.items) |win| {
        if (wm.fullscreen_window == win) continue;
        if (!s.tiled_set.contains(win)) continue;

        for (ws_windows) |ws_win| {
            if (ws_win == win) {
                if (visible_count < visible_buf.len) {
                    visible_buf[visible_count] = win;
                    visible_count += 1;
                }
                break;
            }
        }
    }

    if (visible_count == 0) return;

    const visible = visible_buf[0..visible_count];
    const screen = wm.screen;

    var geometries: [128]utils.Rect = undefined;
    var borders: [128]u32 = undefined;

    switch (s.layout) {
        .master => calculateMasterLayout(s, visible, screen.width_in_pixels, screen.height_in_pixels, &geometries),
        .monocle => calculateMonocleLayout(s, visible, screen.width_in_pixels, screen.height_in_pixels, &geometries),
        .grid => calculateGridLayout(s, visible, screen.width_in_pixels, screen.height_in_pixels, &geometries),
    }

    for (visible, 0..) |win, i| {
        borders[i] = s.borderColor(wm, win);
    }

    var b = batch.Batch.begin(wm) catch {
        retileDirect(wm, visible, &geometries, &borders, s.border_width);
        return;
    };
    defer b.deinit();

    for (visible, 0..) |win, i| {
        b.configure(win, geometries[i]) catch continue;
        b.setBorderWidth(win, s.border_width) catch continue;
        b.setBorder(win, borders[i]) catch continue;
    }

    if (s.layout == .monocle and visible.len > 0) {
        b.raise(visible[visible.len - 1]) catch {};
    }

    b.execute();  // Flushes immediately
}

fn retileDirect(wm: *WM, visible: []const u32, geometries: *[128]utils.Rect, borders: *[128]u32, border_width: u16) void {
    const conn = wm.conn;

    for (visible, 0..) |win, i| {
        const rect = geometries[i].clamp();
        const values = [_]u32{
            @bitCast(@as(i32, rect.x)),
            @bitCast(@as(i32, rect.y)),
            rect.width,
            rect.height,
        };
        _ = xcb.xcb_configure_window(conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
            &values);
        _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{border_width});
        _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borders[i]});
    }

    utils.flush(conn);  // Flush immediately
}

fn calculateMasterLayout(s: *const State, windows: []const u32, screen_w: u16, screen_h: u16, geometries: *[128]utils.Rect) void {
    const bar_height = bar.getHeight();
    const usable_h = screen_h - bar_height;

    const n = windows.len;
    const m = s.margins();
    const m_count: u16 = @intCast(@min(s.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    const master_w: u16 = if (s_count > 0)
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * s.master_width_factor)
    else
        screen_w;

    const master_on_right = s.master_side == .right;
    const master_x: u16 = if (master_on_right) screen_w - master_w else 0;
    const stack_x: u16 = if (master_on_right) 0 else master_w;

    const master_h = if (m_count > 0) blk: {
        const overhead = m.gap * (m_count + 1) + m.border * 2 * m_count;
        const available = if (usable_h > overhead) usable_h - overhead else m_count * defs.MIN_WINDOW_DIM;
        break :blk @max(defs.MIN_WINDOW_DIM, available / m_count);
    } else defs.MIN_WINDOW_DIM;

    const master_inner_w = if (s_count > 0) blk: {
        const total_margin = m.gap + m.gap / 2 + 2 * m.border;
        break :blk if (master_w > total_margin) master_w - total_margin else defs.MIN_WINDOW_DIM;
    } else blk: {
        const total_margin = 2 * m.gap + 2 * m.border;
        break :blk if (master_w > total_margin) master_w - total_margin else defs.MIN_WINDOW_DIM;
    };

    var i: usize = 0;
    while (i < m_count) : (i += 1) {
        geometries[i] = utils.Rect{
            .x = @intCast(master_x + m.gap),
            .y = @intCast(bar_height + m.gap + i * (master_h + 2 * m.border + m.gap)),
            .width = master_inner_w,
            .height = master_h,
        };
    }

    if (s_count == 0) return;

    const stack_w = screen_w - master_w;
    const stack_h = if (s_count > 0) blk: {
        const overhead = m.gap * (s_count + 1) + m.border * 2 * s_count;
        const available = if (usable_h > overhead) usable_h - overhead else s_count * defs.MIN_WINDOW_DIM;
        break :blk @max(defs.MIN_WINDOW_DIM, available / s_count);
    } else defs.MIN_WINDOW_DIM;

    const stack_inner_w = if (stack_w > m.gap / 2 + m.gap + 2 * m.border)
        @max(defs.MIN_WINDOW_DIM, stack_w - (m.gap / 2 + m.gap + 2 * m.border))
    else
        defs.MIN_WINDOW_DIM;

    i = 0;
    while (i < s_count) : (i += 1) {
        geometries[m_count + i] = utils.Rect{
            .x = @intCast(stack_x + m.gap / 2),
            .y = @intCast(bar_height + m.gap + i * (stack_h + 2 * m.border + m.gap)),
            .width = stack_inner_w,
            .height = stack_h,
        };
    }
}

fn calculateMonocleLayout(_: *const State, windows: []const u32, screen_w: u16, screen_h: u16, geometries: *[128]utils.Rect) void {
    const bar_height = bar.getHeight();
    const usable_h = screen_h - bar_height;

    const rect = utils.Rect{
        .x = 0,
        .y = @intCast(bar_height),
        .width = screen_w,
        .height = usable_h,
    };

    for (0..windows.len) |i| {
        geometries[i] = rect;
    }
}

fn calculateGridLayout(s: *const State, windows: []const u32, screen_w: u16, screen_h: u16, geometries: *[128]utils.Rect) void {
    const bar_height = bar.getHeight();
    const usable_h = screen_h - bar_height;

    const n = windows.len;
    const m = s.margins();

    const cols = @as(u16, @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(n))))));
    const rows: u16 = @intCast((n + cols - 1) / cols);

    const cell_w = (screen_w -| (cols + 1) * m.gap) / cols;
    const cell_h = (usable_h -| (rows + 1) * m.gap) / rows;

    const border_margin = 2 * m.border;
    const win_w = if (cell_w > border_margin) cell_w - border_margin else defs.MIN_WINDOW_DIM;
    const win_h = if (cell_h > border_margin) cell_h - border_margin else defs.MIN_WINDOW_DIM;

    for (0..windows.len) |idx| {
        const col: u16 = @intCast(idx % cols);
        const row: u16 = @intCast(idx / cols);

        geometries[idx] = utils.Rect{
            .x = @intCast(m.gap + col * (cell_w + m.gap)),
            .y = @intCast(bar_height + m.gap + row * (cell_h + m.gap)),
            .width = win_w,
            .height = win_h,
        };
    }
}

pub fn toggleLayout(wm: *WM) void {
    const s = state orelse return;
    s.layout = switch (s.layout) {
        .master => .monocle,
        .monocle => .grid,
        .grid => .master,
    };

    // Mark bar dirty to update layout indicator
    bar.markDirty();

    retileCurrentWorkspace(wm);  // Flushes immediately
}

pub fn increaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @min(defs.MAX_MASTER_WIDTH, s.master_width_factor + 0.05);
    retileCurrentWorkspace(wm);  // Flushes immediately
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @max(defs.MIN_MASTER_WIDTH, s.master_width_factor - 0.05);
    retileCurrentWorkspace(wm);  // Flushes immediately
}

pub fn increaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @min(s.tiled_windows.items.len, s.master_count + 1);

    // Mark bar dirty to update layout indicator
    bar.markDirty();

    retileCurrentWorkspace(wm);  // Flushes immediately
}

pub fn decreaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @max(1, s.master_count -| 1);

    // Mark bar dirty to update layout indicator
    bar.markDirty();

    retileCurrentWorkspace(wm);  // Flushes immediately
}

pub fn toggleTiling(wm: *WM) void {
    const s = state orelse return;
    s.enabled = !s.enabled;

    // Mark bar dirty to update layout indicator
    bar.markDirty();

    if (s.enabled) {
        retileCurrentWorkspace(wm);  // Flushes immediately
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

    if (s.enabled) retileCurrentWorkspace(wm);  // Flushes immediately
}

pub inline fn getState() ?*State {
    return state;
}
