//! Virtual desktop management.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const focus = @import("focus");
const atomic = @import("atomic");
const async = @import("async");

pub const Workspace = struct {
    id: usize,
    windows: std.ArrayList(u32),
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn contains(self: *const Workspace, win: u32) bool {
        for (self.windows.items) |w| {
            if (w == win) return true;
        }
        return false;
    }

    pub fn remove(self: *Workspace, win: u32) bool {
        for (self.windows.items, 0..) |w, i| {
            if (w == win) {
                _ = self.windows.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

pub const State = struct {
    workspaces: []Workspace,
    current: usize,
    allocator: std.mem.Allocator,
    switching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch return;
    s.allocator = wm.allocator;
    s.current = 0;

    const count = wm.config.workspaces.count;
    s.workspaces = wm.allocator.alloc(Workspace, count) catch {
        wm.allocator.destroy(s);
        return;
    };

    for (s.workspaces, 0..) |*ws, i| {
        ws.* = .{
            .id = i,
            .windows = .{},
            .name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?",
            .allocator = wm.allocator,
        };
    }

    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        for (s.workspaces) |*ws| {
            ws.windows.deinit(ws.allocator);
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(s.workspaces);
        wm.allocator.destroy(s);
        state = null;
    }
}

pub fn addWindowToCurrentWorkspace(_: *WM, win: u32) void {
    const s = state orelse return;
    const ws = &s.workspaces[s.current];
    if (ws.contains(win)) return;
    ws.windows.append(ws.allocator, win) catch return;
}

pub fn removeWindow(win: u32) void {
    const s = state orelse return;
    for (s.workspaces) |*ws| {
        if (ws.remove(win)) return;
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = state orelse return;

    if (target_ws >= s.workspaces.len) return;

    const from_ws = for (s.workspaces, 0..) |*ws, i| {
        if (ws.contains(win)) break i;
    } else {
        s.workspaces[target_ws].windows.append(s.workspaces[target_ws].allocator, win) catch return;
        return;
    };

    if (from_ws == target_ws) return;

    atomic.atomicMoveWindow(wm, win, from_ws, target_ws) catch |err| {
        std.log.err("[workspace] Failed to move window atomically: {}", .{err});
    };
}

pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse return;

    if (ws_id >= s.workspaces.len or ws_id == s.current) return;

    if (s.switching.swap(true, .acq_rel)) return;

    const old_ws = s.current;
    s.current = ws_id;

    async.submitGlobal(
        .workspace_switch,
        .{ .workspace_switch = .{ .from = old_ws, .to = ws_id } },
        9,
    ) catch |err| {
        std.log.err("[workspace] Failed to submit async switch: {}", .{err});
        s.switching.store(false, .release);
        switchToImmediate(wm, ws_id);
    };
}

/// Immediate workspace switch (called by async processor or as fallback)
pub fn switchToImmediate(wm: *WM, ws_id: usize) void {
    const s = state orelse return;
    defer s.switching.store(false, .release);

    if (ws_id >= s.workspaces.len) return;

    var old_ws: usize = s.current;
    for (s.workspaces, 0..) |*ws, i| {
        if (i != ws_id and ws.windows.items.len > 0) {
            for (ws.windows.items) |win| {
                if (utils.isWindowMapped(wm.conn, win)) {
                    old_ws = i;
                    break;
                }
            }
            if (old_ws != s.current) break;
        }
    }

    atomic.atomicSwitchWorkspace(wm, old_ws, ws_id) catch |err| {
        std.log.err("[workspace] Failed to switch workspace atomically: {}", .{err});
        return;
    };

    focus.markLayoutOperation();

    if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
}

pub fn getCurrentWindowsView() ?[]const u32 {
    const s = state orelse return null;
    return s.workspaces[s.current].windows.items;
}

pub fn getCurrentWorkspace() ?usize {
    const s = state orelse return null;
    return s.current;
}

pub fn isOnCurrentWorkspace(win: u32) bool {
    const s = state orelse return false;
    return s.workspaces[s.current].contains(win);
}

pub fn getState() ?*State {
    return state;
}
