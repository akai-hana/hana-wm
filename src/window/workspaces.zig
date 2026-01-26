//! Virtual desktop management.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const atomic = @import("atomic");
const async = @import("async");
const bar = @import("bar");

pub const Workspace = struct {
    id: usize,
    windows: std.ArrayList(u32),
    window_set: std.AutoHashMap(u32, void),
    window_positions: std.AutoHashMap(u32, utils.Rect),
    window_borders: std.AutoHashMap(u32, u32),
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize, name: []const u8) !Workspace {
        return .{
            .id = id,
            .windows = std.ArrayList(u32){},
            .window_set = std.AutoHashMap(u32, void).init(allocator),
            .window_positions = std.AutoHashMap(u32, utils.Rect).init(allocator),
            .window_borders = std.AutoHashMap(u32, u32).init(allocator),
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.windows.deinit(self.allocator);
        self.window_set.deinit();
        self.window_positions.deinit();
        self.window_borders.deinit();
    }

    pub fn contains(self: *const Workspace, win: u32) bool {
        return self.window_set.contains(win);
    }

    pub fn add(self: *Workspace, win: u32) !void {
        if (!self.contains(win)) {
            try self.windows.append(self.allocator, win);
            try self.window_set.put(win, {});
        }
    }

    pub fn remove(self: *Workspace, win: u32) bool {
        if (!self.window_set.remove(win)) return false;

        _ = self.window_positions.remove(win);
        _ = self.window_borders.remove(win);

        for (self.windows.items, 0..) |w, i| {
            if (w == win) {
                _ = self.windows.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn saveWindowState(self: *Workspace, win: u32, rect: utils.Rect, border_color: u32) !void {
        try self.window_positions.put(win, rect);
        try self.window_borders.put(win, border_color);
    }

    pub fn getWindowPosition(self: *const Workspace, win: u32) ?utils.Rect {
        return self.window_positions.get(win);
    }

    pub fn getWindowBorder(self: *const Workspace, win: u32) ?u32 {
        return self.window_borders.get(win);
    }

    pub fn clearPositions(self: *Workspace) void {
        self.window_positions.clearRetainingCapacity();
        self.window_borders.clearRetainingCapacity();
    }
};

pub const State = struct {
    workspaces: []Workspace,
    current: usize,
    window_to_workspace: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,
    switching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wm: *WM,
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch {
        std.log.err("[workspaces] Failed to allocate state", .{});
        return;
    };
    s.allocator = wm.allocator;
    s.current = 0;
    s.window_to_workspace = std.AutoHashMap(u32, usize).init(wm.allocator);
    s.wm = wm;

    const count = wm.config.workspaces.count;
    s.workspaces = wm.allocator.alloc(Workspace, count) catch {
        std.log.err("[workspaces] Failed to allocate workspaces", .{});
        wm.allocator.destroy(s);
        return;
    };

    for (s.workspaces, 0..) |*ws, i| {
        const name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?";
        ws.* = Workspace.init(wm.allocator, i, name) catch {
            std.log.err("[workspaces] Failed to init workspace {}", .{i});
            for (s.workspaces[0..i]) |*prev_ws| {
                prev_ws.deinit();
                wm.allocator.free(prev_ws.name);
            }
            wm.allocator.free(s.workspaces);
            wm.allocator.destroy(s);
            return;
        };
    }

    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        for (s.workspaces) |*ws| {
            ws.deinit();
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
        wm.allocator.destroy(s);
        state = null;
    }
}

pub fn addWindowToCurrentWorkspace(_: *WM, win: u32) void {
    const s = state orelse {
        std.log.warn("[workspaces] Cannot add window: state not initialized", .{});
        return;
    };
    const ws = &s.workspaces[s.current];
    ws.add(win) catch |err| {
        std.log.err("[workspaces] Failed to add window {} to workspace {}: {}", .{ win, s.current, err });
        return;
    };
    s.window_to_workspace.put(win, s.current) catch {};
    
    // Update bar to show new window count
    bar.update(s.wm) catch |err| {
        std.log.err("[workspaces] Failed to update bar: {}", .{err});
    };
}

pub fn removeWindow(win: u32) void {
    const s = state orelse return;

    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        const ws_idx = entry.value;
        if (ws_idx < s.workspaces.len) {
            _ = s.workspaces[ws_idx].remove(win);
            
            // Update bar to show new window count
            bar.update(s.wm) catch |err| {
                std.log.err("[workspaces] Failed to update bar: {}", .{err});
            };
        }
        return;
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = state orelse {
        std.log.warn("[workspaces] Cannot move window: state not initialized", .{});
        return;
    };

    if (target_ws >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid target workspace: {} (max: {})", .{ target_ws, s.workspaces.len - 1 });
        return;
    }

    const from_ws = s.window_to_workspace.get(win) orelse blk: {
        for (s.workspaces, 0..) |*ws, i| {
            if (ws.contains(win)) {
                s.window_to_workspace.put(win, i) catch {};
                break :blk i;
            }
        } else {
            s.workspaces[target_ws].add(win) catch |err| {
                std.log.err("[workspaces] Failed to add window to workspace: {}", .{err});
            };
            s.window_to_workspace.put(win, target_ws) catch {};
            
            // Update bar
            bar.update(wm) catch |err| {
                std.log.err("[workspaces] Failed to update bar: {}", .{err});
            };
            return;
        }
    };

    if (from_ws == target_ws) return;

    atomic.atomicMoveWindow(wm, win, from_ws, target_ws) catch |err| {
        std.log.err("[workspace] Failed to move window atomically: {}", .{err});
        return;
    };

    s.window_to_workspace.put(win, target_ws) catch {};
    
    // Update bar
    bar.update(wm) catch |err| {
        std.log.err("[workspaces] Failed to update bar: {}", .{err});
    };
}

pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse {
        std.log.warn("[workspaces] Cannot switch workspace: state not initialized", .{});
        return;
    };

    if (ws_id >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid workspace id: {} (max: {})", .{ ws_id, s.workspaces.len - 1 });
        return;
    }

    if (ws_id == s.current) return;

    if (s.switching.swap(true, .acq_rel)) {
        std.log.warn("[workspaces] Workspace switch already in progress", .{});
        return;
    }

    const old_ws = s.current;

    _ = async.submitGlobal(
        .workspace_switch,
        .{ .workspace_switch = .{ .from = old_ws, .to = ws_id } },
        9,
    ) catch |err| {
        std.log.err("[workspace] Failed to submit async switch: {}", .{err});
        s.switching.store(false, .release);
        switchToImmediate(wm, ws_id);
    };
}

pub fn switchToImmediate(wm: *WM, ws_id: usize) void {
    const s = state orelse {
        std.log.warn("[workspaces] Cannot switch workspace: state not initialized", .{});
        return;
    };
    defer s.switching.store(false, .release);

    if (ws_id >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid workspace id: {} (max: {})", .{ ws_id, s.workspaces.len - 1 });
        return;
    }

    const old_ws = s.current;

    atomic.atomicSwitchWorkspace(wm, old_ws, ws_id) catch |err| {
        std.log.err("[workspace] Failed to switch workspace atomically: {}", .{err});
        return;
    };

    s.current = ws_id;

    const tiling = @import("tiling");

    for (s.workspaces[ws_id].windows.items) |win| {
        if (!tiling.isWindowTiled(win) and wm.config.tiling.enabled) {
            tiling.addWindowToTiling(wm, win);
        }
    }

    if (!tiling.restoreWindowPositions(wm)) {
        tiling.retileCurrentWorkspace(wm);
    }

    // Update bar to show new workspace
    bar.update(wm) catch |err| {
        std.log.err("[workspaces] Failed to update bar after workspace switch: {}", .{err});
    };
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

pub fn getCurrentWorkspaceObject() ?*Workspace {
    const s = state orelse return null;
    return &s.workspaces[s.current];
}

pub fn clearAllPositions() void {
    const s = state orelse return;
    for (s.workspaces) |*ws| {
        ws.clearPositions();
    }
}
