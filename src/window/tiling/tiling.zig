//! Core tiling system implementation.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const workspaces = @import("workspaces");
const focus = @import("focus");
const atomic = @import("atomic");
const async = @import("async");
const bar = @import("bar");

const master_layout = @import("master");
const monocle_layout = @import("monocle");
const grid_layout = @import("grid");

pub const Layout = enum { master, monocle, grid };

pub const State = struct {
    enabled: bool,
    layout: Layout,
    master_side: defs.MasterSide,
    master_width_factor: f32,
    master_count: usize,
    gaps: u16,
    border_width: u16,
    border_focused: u32,
    border_normal: u32,
    tiled_windows: std.ArrayList(u32),
    visible_cache: std.ArrayList(u32),
    needs_retile: bool = true,
    retile_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }
};

var state: ?*State = null;
var state_mutex = std.Thread.Mutex{};

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch {
        std.log.err("[tiling] Failed to allocate state", .{});
        return;
    };

    s.* = .{
        .enabled = wm.config.tiling.enabled,
        .layout = parseLayout(wm.config.tiling.layout),
        .master_side = wm.config.tiling.master_side,
        .master_width_factor = wm.config.tiling.master_width_factor,
        .master_count = wm.config.tiling.master_count,
        .gaps = wm.config.tiling.gaps,
        .border_width = wm.config.tiling.border_width,
        .border_focused = wm.config.tiling.border_focused,
        .border_normal = wm.config.tiling.border_normal,
        .tiled_windows = std.ArrayList(u32){},
        .visible_cache = std.ArrayList(u32){},
        .allocator = wm.allocator,
    };

    state_mutex.lock();
    defer state_mutex.unlock();
    state = s;
}

pub fn deinit(wm: *WM) void {
    state_mutex.lock();
    defer state_mutex.unlock();

    if (state) |s| {
        s.tiled_windows.deinit(s.allocator);
        s.visible_cache.deinit(s.allocator);
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

pub fn notifyWindowMapped(wm: *WM, win: u32) void {
    const s = state orelse return;
    if (!s.enabled or !workspaces.isOnCurrentWorkspace(win)) return;

    if (wm.fullscreen_window == win) {
        s.needs_retile = true;
        retileAsync(wm, s);
        return;
    }

    for (s.tiled_windows.items) |w| {
        if (w == win) {
            s.needs_retile = true;
            retileAsync(wm, s);
            return;
        }
    }

    s.tiled_windows.insert(s.allocator, 0, win) catch |err| {
        std.log.err("[tiling] Failed to add tiled window: {}", .{err});
        return;
    };

    const attrs = utils.WindowAttrs{
        .border_width = s.border_width,
        .border_color = s.border_focused,
        .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
    };
    attrs.configure(wm.conn, win);

    wm.focused_window = win;
    s.needs_retile = true;
    retileAsync(wm, s);
}

pub fn addWindowToTiling(wm: *WM, win: u32) void {
    const s = state orelse return;
    if (!s.enabled) return;

    for (s.tiled_windows.items) |w| {
        if (w == win) return;
    }

    s.tiled_windows.insert(s.allocator, 0, win) catch |err| {
        std.log.err("[tiling] Failed to add window to tiling: {}", .{err});
        return;
    };

    const attrs = utils.WindowAttrs{
        .border_width = s.border_width,
        .border_color = if (wm.focused_window == win) s.border_focused else s.border_normal,
        .event_mask = xcb.XCB_EVENT_MASK_ENTER_WINDOW | xcb.XCB_EVENT_MASK_LEAVE_WINDOW,
    };
    attrs.configure(wm.conn, win);

    s.needs_retile = true;
}

pub fn notifyWindowDestroyed(wm: *WM, win: u32) void {
    const s = state orelse return;

    for (s.tiled_windows.items, 0..) |w, i| {
        if (w == win) {
            _ = s.tiled_windows.orderedRemove(i);
            s.needs_retile = true;

            if (s.tiled_windows.items.len > 0 and wm.focused_window == win) {
                const next = s.tiled_windows.items[0];
                _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, next, xcb.XCB_CURRENT_TIME);
                wm.focused_window = next;
            }
            retileAsync(wm, s);
            return;
        }
    }
}

pub fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = state orelse return;
    if (!s.enabled) return;

    if (old_focused) |old_win| {
        if (isWindowTiled(old_win) and wm.fullscreen_window != old_win) {
            _ = xcb.xcb_change_window_attributes(wm.conn, old_win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{s.border_normal});
        }
    }

    if (new_focused) |new_win| {
        if (isWindowTiled(new_win) and wm.fullscreen_window != new_win) {
            _ = xcb.xcb_change_window_attributes(wm.conn, new_win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{s.border_focused});
        }
    }

    bar.update() catch {};
}

pub fn isWindowTiled(win: u32) bool {
    const s = state orelse return false;
    if (!s.enabled) return false;
    for (s.tiled_windows.items) |w| {
        if (w == win) return true;
    }
    return false;
}

fn retileAsync(wm: *WM, s: *State) void {
    if (s.retile_pending.swap(true, .acq_rel)) return;

    _ = async.submitGlobal(.retile, .{ .retile = {} }, 10) catch |err| {
        std.log.err("[tiling] Failed to submit async retile: {}", .{err});
        s.retile_pending.store(false, .release);
        retile(wm, s);
    };
}

fn retile(wm: *WM, s: *State) void {
    defer s.retile_pending.store(false, .release);

    if (!s.needs_retile) return;
    s.needs_retile = false;

    var tx = atomic.Transaction.begin(wm) catch |err| {
        std.log.err("[tiling] Failed to begin retile transaction: {}", .{err});
        return;
    };
    defer tx.deinit();

    s.visible_cache.clearRetainingCapacity();

    const ws_windows = workspaces.getCurrentWindowsView() orelse return;

    for (s.tiled_windows.items) |win| {
        if (wm.fullscreen_window == win) continue;

        const on_ws = for (ws_windows) |w| {
            if (w == win) break true;
        } else false;

        if (on_ws) {
            s.visible_cache.append(s.allocator, win) catch |err| {
                std.log.err("[tiling] Failed to add window to visible cache: {}", .{err});
                continue;
            };
        }
    }

    if (s.visible_cache.items.len == 0) {
        tx.commit() catch |err| {
            std.log.err("[tiling] Failed to commit empty retile transaction: {}", .{err});
        };
        bar.update() catch {};
        return;
    }

    const screen = wm.screen;

    switch (s.layout) {
        .master => master_layout.tile(&tx, s, s.visible_cache.items, screen.width_in_pixels, screen.height_in_pixels),
        .monocle => monocle_layout.tile(&tx, s, s.visible_cache.items, screen.width_in_pixels, screen.height_in_pixels),
        .grid => grid_layout.tile(&tx, s, s.visible_cache.items, screen.width_in_pixels, screen.height_in_pixels),
    }

    if (wm.focused_window) |focused| {
        updateBorders(&tx, s, focused);
    }

    saveWindowPositionsFromTransaction(wm, s, &tx);

    tx.commit() catch |err| {
        std.log.err("[tiling] Retile transaction failed: {}", .{err});
        tx.rollback() catch |rollback_err| {
            std.log.err("[tiling] Rollback also failed: {}", .{rollback_err});
        };
        return;
    };

    bar.update() catch {};
}

fn updateBorders(tx: *atomic.Transaction, s: *State, focused: u32) void {
    const ws_windows = workspaces.getCurrentWindowsView() orelse return;

    for (s.tiled_windows.items) |win| {
        const on_workspace = for (ws_windows) |w| {
            if (w == win) break true;
        } else false;

        if (!on_workspace) continue;

        const color = if (win == focused) s.border_focused else s.border_normal;
        tx.setBorder(win, color) catch |err| {
            std.log.err("[tiling] Failed to set border for window {}: {}", .{ win, err });
            continue;
        };
    }
}

fn saveWindowPositionsFromTransaction(wm: *WM, s: *State, tx: *atomic.Transaction) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse return;

    for (s.visible_cache.items) |win| {
        if (tx.getConfiguredRect(win)) |rect| {
            const border_color = if (wm.focused_window == win) s.border_focused else s.border_normal;
            ws.saveWindowState(win, rect, border_color) catch |err| {
                std.log.err("[tiling] Failed to save window position: {}", .{err});
            };
        }
    }
}

pub fn restoreWindowPositions(wm: *WM) bool {
    const s = state orelse return false;
    if (!s.enabled) return false;

    const ws = workspaces.getCurrentWorkspaceObject() orelse return false;
    const ws_windows = workspaces.getCurrentWindowsView() orelse return false;

    var tiled_count: usize = 0;
    var restored_count: usize = 0;

    for (ws_windows) |win| {
        if (wm.fullscreen_window == win) continue;
        if (!isWindowTiled(win)) continue;

        tiled_count += 1;

        if (ws.getWindowPosition(win)) |rect| {
            utils.configureWindow(wm.conn, win, rect);
            restored_count += 1;

            if (ws.getWindowBorder(win)) |border_color| {
                _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{border_color});
            }
        }
    }

    if (tiled_count > 0 and restored_count == tiled_count) {
        utils.flush(wm.conn);
        return true;
    }

    return false;
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
        .master => .monocle,
        .monocle => .grid,
        .grid => .master,
    };
    s.needs_retile = true;

    workspaces.clearAllPositions();

    _ = async.submitGlobal(.layout_change, .{ .layout_change = {} }, 8) catch |err| {
        std.log.err("[tiling] Failed to submit async layout change: {}", .{err});
        retile(wm, s);
    };
}

pub fn increaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @min(defs.MAX_MASTER_WIDTH, s.master_width_factor + 0.05);
    s.needs_retile = true;

    workspaces.clearAllPositions();

    retileAsync(wm, s);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const s = state orelse return;
    s.master_width_factor = @max(defs.MIN_MASTER_WIDTH, s.master_width_factor - 0.05);
    s.needs_retile = true;

    workspaces.clearAllPositions();

    retileAsync(wm, s);
}

pub fn increaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @min(s.tiled_windows.items.len, s.master_count + 1);
    s.needs_retile = true;

    workspaces.clearAllPositions();

    retileAsync(wm, s);
}

pub fn decreaseMasterCount(wm: *WM) void {
    const s = state orelse return;
    s.master_count = @max(1, s.master_count -| 1);
    s.needs_retile = true;

    workspaces.clearAllPositions();

    retileAsync(wm, s);
}

pub fn toggleTiling(wm: *WM) void {
    const s = state orelse return;
    s.enabled = !s.enabled;
    if (s.enabled) {
        s.needs_retile = true;
        retileAsync(wm, s);
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
    s.needs_retile = true;

    workspaces.clearAllPositions();

    if (s.enabled) retileAsync(wm, s);
}

pub inline fn getState() ?*State {
    return state;
}
