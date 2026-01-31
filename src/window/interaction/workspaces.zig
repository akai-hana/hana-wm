//! Workspace management - Optimized with batch operations

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
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
        std.log.err("[workspaces] Failed to add window {x}: {}", .{ win, err });
        return;
    };
    s.window_to_workspace.put(win, s.current) catch |err| {
        std.log.warn("[workspaces] Failed to update window map for {x}: {}", .{ win, err });
    };
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

    // Find current workspace for this window
    const from_ws = s.window_to_workspace.get(win) orelse blk: {
        // Window not in map, search for it
        for (s.workspaces, 0..) |*ws, i| {
            if (ws.contains(win)) {
                s.window_to_workspace.put(win, i) catch {};
                break :blk i;
            }
        } else {
            // Window not found anywhere, just add to target
            s.workspaces[target_ws].add(win) catch |err| {
                std.log.err("[workspaces] Failed to add window to workspace {}: {}", .{ target_ws, err });
            };
            s.window_to_workspace.put(win, target_ws) catch {};
            return;
        }
    };

    if (from_ws == target_ws) return;

    // Move window between workspaces
    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch |err| {
        std.log.err("[workspaces] Failed to add window to workspace {}: {}", .{ target_ws, err });
        // Try to add back to original workspace
        s.workspaces[from_ws].add(win) catch {};
        return;
    };
    s.window_to_workspace.put(win, target_ws) catch {};

    // Handle visibility changes
    if (from_ws == s.current) {
        _ = xcb.xcb_unmap_window(wm.conn, win);

        if (wm.focused_window == win) {
            focus.clearFocus(wm);
        }

        // ISSUE #1 FIX: Retile current workspace when removing a window
        if (wm.config.tiling.enabled) {
            const tiling_mod = @import("tiling");
            if (tiling_mod.getState()) |ts| {
                ts.markDirty();
            }
        }
    } else if (target_ws == s.current) {
        // Moving to current workspace - mark tiling dirty
        if (wm.config.tiling.enabled) {
            const tiling_mod = @import("tiling");
            if (tiling_mod.getState()) |ts| {
                ts.markDirty();
            }
        }
    }
}

pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse return;

    if (ws_id >= s.workspaces.len or ws_id == s.current) return;

    executeSwitch(wm, s.current, ws_id);
    s.current = ws_id;
}

// Optimized workspace switching with batch operations
fn executeSwitch(wm: *WM, old_ws: usize, new_ws: usize) void {
    const s = state orelse return;

    const old_workspace = &s.workspaces[old_ws];
    const new_workspace = &s.workspaces[new_ws];

    // Use batch for efficient map/unmap operations
    var b = batch.Batch.begin(wm) catch {
        executeSwitchDirect(wm, old_workspace, new_workspace);
        return;
    };
    defer b.deinit();

    // Map new workspace windows FIRST to prevent flicker
    for (new_workspace.windows.items) |win| {
        b.map(win) catch {};
    }

    // Then unmap old workspace windows
    for (old_workspace.windows.items) |win| {
        b.unmap(win) catch {};
    }

    // Set focus to first window or root
    if (new_workspace.windows.items.len > 0) {
        const win = new_workspace.windows.items[0];
        b.setFocus(win) catch {};
        wm.focused_window = win;
    } else {
        wm.focused_window = null;
    }

    b.execute();

    // Mark tiling dirty for retiling on new workspace
    if (wm.config.tiling.enabled) {
        const tiling_mod = @import("tiling");
        if (tiling_mod.getState()) |ts| {
            ts.markDirty();
        }
    }

    bar.markDirty();
}

// Fallback direct implementation without batch
fn executeSwitchDirect(wm: *WM, old_workspace: *Workspace, new_workspace: *Workspace) void {
    // Map new workspace FIRST to prevent flicker
    for (new_workspace.windows.items) |win| {
        _ = xcb.xcb_map_window(wm.conn, win);
    }

    // Then unmap old workspace
    for (old_workspace.windows.items) |win| {
        _ = xcb.xcb_unmap_window(wm.conn, win);
    }

    // Set focus
    if (new_workspace.windows.items.len > 0) {
        const win = new_workspace.windows.items[0];
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, xcb.XCB_CURRENT_TIME);
        wm.focused_window = win;
    } else {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, wm.root, xcb.XCB_CURRENT_TIME);
        wm.focused_window = null;
    }

    utils.flush(wm.conn);

    // Mark tiling dirty
    if (wm.config.tiling.enabled) {
        const tiling_mod = @import("tiling");
        if (tiling_mod.getState()) |ts| {
            ts.markDirty();
        }
    }

    bar.markDirty();
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
