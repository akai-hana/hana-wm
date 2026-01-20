//! Workspace management optimized for responsivity
const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const tiling = @import("tiling");
const focus = @import("focus");

pub const Workspace = struct {
    id: usize,
    windows: std.ArrayList(u32),
    name: []const u8,

    fn contains(self: *const Workspace, win: u32) bool {
        for (self.windows.items) |w| {
            if (w == win) return true;
        }
        return false;
    }

    fn remove(self: *Workspace, win: u32) bool {
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
            .windows = std.ArrayList(u32){},
            .name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?",
        };
    }

    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        for (s.workspaces) |*ws| {
            ws.windows.deinit(wm.allocator);
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
    ws.windows.append(s.allocator, win) catch return;
}

pub fn removeWindow(win: u32) void {
    const s = state orelse return;
    for (s.workspaces) |*ws| {
        if (ws.remove(win)) return;
    }
}

/// Move window to workspace (handles both current and async moves)
pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = state orelse return;
    if (target_ws >= s.workspaces.len or target_ws == s.current) return;

    const is_focused = wm.focused_window == win;
    
    // Remove from all workspaces
    for (s.workspaces) |*ws| _ = ws.remove(win);
    
    // Add to target
    s.workspaces[target_ws].windows.append(s.allocator, win) catch return;
    
    // Only handle focus if it was the focused window
    if (is_focused) {
        _ = xcb.xcb_unmap_window(wm.conn, win);
        if (s.workspaces[s.current].windows.items.len > 0) {
            focus.setFocus(wm, s.workspaces[s.current].windows.items[0], .window_destroyed);
        } else {
            focus.clearFocus(wm);
        }
    }
    
    focus.markLayoutOperation();
    utils.flush(wm.conn);
    tiling.retileCurrentWorkspace(wm);
}

pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;

    const old_ws = &s.workspaces[s.current];
    const new_ws = &s.workspaces[ws_id];

    utils.batchUnmap(wm.conn, old_ws.windows.items);
    s.current = ws_id;
    utils.batchMap(wm.conn, new_ws.windows.items);

    focus.markLayoutOperation();
    utils.flush(wm.conn);

    if (wm.config.tiling.enabled) {
        for (new_ws.windows.items) |win| {
            tiling.notifyWindowMapped(wm, win);
        }
        tiling.retileCurrentWorkspace(wm);
    }

    if (new_ws.windows.items.len > 0) {
        focus.setFocus(wm, new_ws.windows.items[0], .workspace_switch);
    } else {
        focus.clearFocus(wm);
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
