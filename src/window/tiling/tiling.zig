//! Tiling system optimized for maximum responsivity
//! - No blocking X11 calls during retile
//! - Trust workspace state instead of querying
//! - Async property lookups where needed
const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const workspaces = @import("workspaces");
const builtin = @import("builtin");

pub const Layout = enum { master_left, monocle, grid };

pub const State = struct {
    enabled: bool,
    layout: Layout,
    master_width_factor: f32,
    master_count: usize,
    gaps: u16,
    border_width: u16,
    border_focused: u32,
    border_normal: u32,

    tiled_windows: std.ArrayList(u32),
    visible_cache: std.ArrayList(u32),
    needs_retile: bool = true,

    pub fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch return;
    s.* = .{
        .enabled = wm.config.tiling.enabled,
        .layout = parseLayout(wm.config.tiling.layout),
        .master_width_factor = wm.config.tiling.master_width_factor,
        .master_count = wm.config.tiling.master_count,
        .gaps = wm.config.tiling.gaps,
        .border_width = wm.config.tiling.border_width,
        .border_focused = wm.config.tiling.border_focused,
        .border_normal = wm.config.tiling.border_normal,
        .tiled_windows = std.ArrayList(u32).init(wm.allocator),
        .visible_cache = std.ArrayList(u32).init(wm.allocator),
    };
    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        s.tiled_windows.deinit();
        s.visible_cache.deinit();
        wm.allocator.destroy(s);
        state = null;
    }
}

fn parseLayout(name: []const u8) Layout {
    const map = std.StaticStringMap(Layout).initComptime(.{
        .{ "master_left", .master_left },
        .{ "monocle", .monocle },
        .{ "grid", .grid },
    });
    return map.get(name) orelse .master_left;
}

pub fn notifyWindowMapped(wm: *WM, win: u32) void {
    const s = state orelse return;
    if (!s.enabled) return;

    if (!workspaces.isOnCurrentWorkspace(win)) return;

    // Check if already tiled
    for (s.tiled_windows.items) |w| {
        if (w == win) {
            s.needs_retile = true;
            retile(wm, s);
            return;
        }
    }

    s.tiled_windows.insert(0, win) catch return;

    // Setup window - non-blocking configuration
    const attrs = utils.WindowAttrs{
        .border_width = s.border_width,
        .border_color = s.border_focused,
        .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
    };
    attrs.configure(wm.conn, win);

    wm.focused_window = win;
    s.needs_retile = true;
    retile(wm, s);
}

pub fn notifyWindowDestroyed(wm: *WM, win: u32) void {
    const s = state orelse return;

    for (s.tiled_windows.items, 0..) |w, i| {
        if (w == win) {
            _ = s.tiled_windows.orderedRemove(i);
            s.needs_retile = true;

            if (s.tiled_windows.items.len > 0) {
                if (wm.focused_window == win) {
                    const next = s.tiled_windows.items[0];
                    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
                        next, xcb.XCB_CURRENT_TIME);
                    wm.focused_window = next;
                }
                retile(wm, s);
            }
            return;
        }
    }
}

pub fn updateWindowFocus(wm: *WM, focused: u32) void {
    const s = state orelse return;
    if (!s.enabled) return;
    updateBorders(wm, s, focused);
}

pub fn isWindowTiled(win: u32) bool {
    const s = state orelse return false;
    if (!s.enabled) return false;
    for (s.tiled_windows.items) |w| {
        if (w == win) return true;
    }
    return false;
}

// ============================================================================
// LAYOUT ENGINE - OPTIMIZED FOR RESPONSIVITY
// ============================================================================

fn retile(wm: *WM, s: *State) void {
    if (!s.needs_retile) return;
    s.needs_retile = false;

    s.visible_cache.clearRetainingCapacity();

    const ws_windows = workspaces.getCurrentWindowsView() orelse return;
    
    // CRITICAL: Build visible window list - validate each window still exists
    for (s.tiled_windows.items) |win| {
        // Check workspace membership
        const on_ws = for (ws_windows) |w| {
            if (w == win) break true;
        } else false;

        if (!on_ws) continue;
        
        // CRITICAL: Verify window still exists in X11 before adding to visible cache
        const cookie = xcb.xcb_get_window_attributes(wm.conn, win);
        const attrs = xcb.xcb_get_window_attributes_reply(wm.conn, cookie, null);
        if (attrs) |a| {
            defer std.c.free(a);
            // Only include if window is valid and viewable
            if (a.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE or 
                a.*.map_state == xcb.XCB_MAP_STATE_UNMAPPED) {
                s.visible_cache.append(wm.allocator, win) catch continue;
            }
        }
    }

    if (s.visible_cache.items.len == 0) {
        utils.flush(wm.conn);
        return;
    }

    const screen = wm.screen;
    switch (s.layout) {
        .master_left => tileMasterLeft(wm, s, s.visible_cache.items, screen.width_in_pixels, screen.height_in_pixels),
        .monocle => tileMonocle(wm, s, s.visible_cache.items, screen.width_in_pixels, screen.height_in_pixels),
        .grid => tileGrid(wm, s, s.visible_cache.items, screen.width_in_pixels, screen.height_in_pixels),
    }

    if (wm.focused_window) |f| updateBorders(wm, s, f);
    utils.flush(wm.conn);
}

fn tileMasterLeft(wm: *WM, s: *State, windows: []const u32, sw: u16, sh: u16) void {
    const n = windows.len;
    const m = s.margins();
    const m_count: u16 = @intCast(@min(s.master_count, n));
    const s_count: u16 = @intCast(if (n > m_count) n - m_count else 0);

    const master_w: u16 = if (s_count == 0) sw else @intFromFloat(@as(f32, @floatFromInt(sw)) * s.master_width_factor);

    const m_layout = utils.calcColumnLayout(sh, m_count, m);
    
    // CRITICAL FIX: Use @TypeOf to ensure struct literal matches return type
    const s_layout = if (s_count > 0) 
        utils.calcColumnLayout(sh, s_count, m) 
    else 
        @TypeOf(m_layout){ .item_h = 0, .spacing = 0 };

    for (windows, 0..) |win, i| {
        const rect = if (i < m_count) blk: {
            const row: u16 = @intCast(i);
            break :blk utils.Rect{
                .x = @intCast(m.gap),
                .y = @intCast(m.gap + row * m_layout.spacing),
                .width = if (master_w > m.total()) master_w - m.total() else utils.MIN_WINDOW_DIM,
                .height = m_layout.item_h,
            };
        } else blk: {
            const row: u16 = @intCast(i - m_count);
            const stack_w = sw - master_w;
            break :blk utils.Rect{
                .x = @intCast(master_w),
                .y = @intCast(m.gap + row * s_layout.spacing),
                .width = if (stack_w > m.gap + 2 * m.border) stack_w - m.gap - 2 * m.border else utils.MIN_WINDOW_DIM,
                .height = s_layout.item_h,
            };
        };

        utils.configureWindow(wm.conn, win, rect);
    }
}

fn tileMonocle(wm: *WM, s: *State, windows: []const u32, sw: u16, sh: u16) void {
    const inner = s.margins().innerRect(sw, sh);
    for (windows) |win| {
        utils.configureWindow(wm.conn, win, inner);
    }
    _ = xcb.xcb_configure_window(wm.conn, windows[windows.len - 1],
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

fn tileGrid(wm: *WM, s: *State, windows: []const u32, sw: u16, sh: u16) void {
    const dims = utils.calcGridDims(windows.len);
    const m = s.margins();

    const cell_w = (sw -| (dims.cols + 1) * m.gap) / dims.cols;
    const cell_h = (sh -| (dims.rows + 1) * m.gap) / dims.rows;
    const win_w = if (cell_w > 2 * m.border) cell_w - 2 * m.border else utils.MIN_WINDOW_DIM;
    const win_h = if (cell_h > 2 * m.border) cell_h - 2 * m.border else utils.MIN_WINDOW_DIM;

    for (windows, 0..) |win, idx| {
        const col: u16 = @intCast(idx % dims.cols);
        const row: u16 = @intCast(idx / dims.cols);

        utils.configureWindow(wm.conn, win, .{
            .x = @intCast(m.gap + col * (cell_w + m.gap)),
            .y = @intCast(m.gap + row * (cell_h + m.gap)),
            .width = win_w,
            .height = win_h,
        });
    }
}

fn updateBorders(wm: *WM, s: *State, focused: u32) void {
    const ws_windows = workspaces.getCurrentWindowsView() orelse return;

    for (s.tiled_windows.items) |win| {
        const on_ws = for (ws_windows) |w| {
            if (w == win) break true;
        } else false;

        if (!on_ws) continue;

        const color = if (win == focused) s.border_focused else s.border_normal;
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    }
    utils.flush(wm.conn);
}

pub fn retileCurrentWorkspace(wm: *WM) void {
    if (state) |s| {
        if (s.enabled) {
            s.needs_retile = true;
            retile(wm, s);
        }
    }
}

pub fn toggleLayout(wm: *WM) void {
    const s = state orelse return;
    s.layout = switch (s.layout) {
        .master_left => .monocle,
        .monocle => .grid,
        .grid => .master_left,
    };
    s.needs_retile = true;
    retile(wm, s);
}

pub fn increaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @min(0.95, s.master_width_factor + 0.05);
    s.needs_retile = true;
    retile(wm, s);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @max(0.05, s.master_width_factor - 0.05);
    s.needs_retile = true;
    retile(wm, s);
}

pub fn increaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @min(s.tiled_windows.items.len, s.master_count + 1);
    s.needs_retile = true;
    retile(wm, s);
}

pub fn decreaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @max(1, s.master_count -| 1);
    s.needs_retile = true;
    retile(wm, s);
}

pub fn toggleTiling(wm: *WM) void {
    const s = state orelse return;
    s.enabled = !s.enabled;
    if (s.enabled) {
        s.needs_retile = true;
        retile(wm, s);
    }
}

pub fn reloadConfig(wm: *WM) void {
    const s = state orelse return;
    s.enabled = wm.config.tiling.enabled;
    s.layout = parseLayout(wm.config.tiling.layout);
    s.master_width_factor = wm.config.tiling.master_width_factor;
    s.master_count = wm.config.tiling.master_count;
    s.gaps = wm.config.tiling.gaps;
    s.border_width = wm.config.tiling.border_width;
    s.border_focused = wm.config.tiling.border_focused;
    s.border_normal = wm.config.tiling.border_normal;
    s.needs_retile = true;
    if (s.enabled) retile(wm, s);
}

pub fn getState() ?*State {
    return state;
}
