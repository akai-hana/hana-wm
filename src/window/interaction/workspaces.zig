// Workspace management - FIXED: Immediate, event-driven switching

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const bar = @import("bar");
const batch = @import("batch");

pub const Workspace = struct {
    id: usize,
    windows: std.ArrayList(u32),
    window_set: std.AutoHashMap(u32, void),
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize, name: []const u8) !Workspace {
        return .{
            .id = id,
            .windows = std.ArrayList(u32){},
            .window_set = std.AutoHashMap(u32, void).init(allocator),
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.windows.deinit(self.allocator);
        self.window_set.deinit();
    }

    pub inline fn contains(self: *const Workspace, win: u32) bool {
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
    window_to_workspace: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,
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
    const s = state orelse return;
    if (@import("bar").isBarWindow(win)) return;

    const ws = &s.workspaces[s.current];
    ws.add(win) catch |err| {
        std.log.err("[workspaces] Failed to add window {}: {}", .{ win, err });
        return;
    };
    s.window_to_workspace.put(win, s.current) catch {};
}

pub fn removeWindow(win: u32) void {
    const s = state orelse return;

    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        const ws_idx = entry.value;
        if (ws_idx < s.workspaces.len) {
            _ = s.workspaces[ws_idx].remove(win);
        }
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = state orelse return;

    if (target_ws >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid target workspace: {}", .{target_ws});
        return;
    }

    const from_ws = s.window_to_workspace.get(win) orelse blk: {
        for (s.workspaces, 0..) |*ws, i| {
            if (ws.contains(win)) {
                s.window_to_workspace.put(win, i) catch {};
                break :blk i;
            }
        } else {
            s.workspaces[target_ws].add(win) catch {};
            s.window_to_workspace.put(win, target_ws) catch {};
            return;
        }
    };

    if (from_ws == target_ws) return;

    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch {};
    s.window_to_workspace.put(win, target_ws) catch {};

    if (from_ws == s.current) {
        _ = xcb.xcb_unmap_window(wm.conn, win);

        if (wm.focused_window == win) {
            utils.clearFocus(wm);
        }
    } else if (target_ws == s.current) {
        if (wm.config.tiling.enabled) {
            const tiling_mod = @import("tiling");
            if (tiling_mod.getState()) |ts| {
                ts.markDirty();
            }
        }
    }
}

// IMMEDIATE execution - no queuing, no delays
pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse return;

    if (ws_id >= s.workspaces.len or ws_id == s.current) return;

    executeSwitch(wm, s.current, ws_id);
    s.current = ws_id;
}

// Fast execution with minimal XCB calls
fn executeSwitch(wm: *WM, old_ws: usize, new_ws: usize) void {
    const s = state orelse return;

    // OPTIMIZATION: Use stack arrays for speed
    var unmapped: [128]u32 = undefined;
    var unmapped_count: usize = 0;
    var mapped: [128]u32 = undefined;
    var mapped_count: usize = 0;

    // Collect windows to unmap
    for (s.workspaces[old_ws].windows.items) |win| {
        if (unmapped_count < unmapped.len) {
            unmapped[unmapped_count] = win;
            unmapped_count += 1;
        }
    }

    // Collect windows to map
    for (s.workspaces[new_ws].windows.items) |win| {
        if (mapped_count < mapped.len) {
            mapped[mapped_count] = win;
            mapped_count += 1;
        }
    }

    const conn = wm.conn;

    // Unmap old workspace (fast!)
    for (unmapped[0..unmapped_count]) |win| {
        _ = xcb.xcb_unmap_window(conn, win);
    }

    // Map new workspace (fast!)
    for (mapped[0..mapped_count]) |win| {
        _ = xcb.xcb_map_window(conn, win);
    }

    // Set focus
    if (mapped_count > 0) {
        const win = mapped[0];
        _ = xcb.xcb_set_input_focus(conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
        wm.focused_window = win;
    } else {
        _ = xcb.xcb_set_input_focus(conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);
        wm.focused_window = null;
    }

    // Mark dirty for retiling (happens later in main loop)
    if (wm.config.tiling.enabled) {
        const tiling_mod = @import("tiling");
        if (tiling_mod.getState()) |ts| {
            ts.markDirty();
        }
    }

    @import("bar").markDirty();
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

pub inline fn getState() ?*State {
    return state;
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = state orelse return null;
    return &s.workspaces[s.current];
}
