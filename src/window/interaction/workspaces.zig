// Workspace management - Optimized with batch operations (OPTIMIZED)

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const bar = @import("bar");

pub const Workspace = struct {
    id: usize,
    windows: std.ArrayList(u32),
    window_set: std.AutoHashMap(u32, void),
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize, name: []const u8) !Workspace {
        return .{
            .id = id,
            .windows = .{},
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
                _ = self.windows.swapRemove(i);
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

// OPTIMIZATION: Streamlined window movement with O(1) lookups
pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = state orelse return;

    if (target_ws >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid target workspace: {}", .{target_ws});
        return;
    }

    // O(1) lookup for current workspace
    const from_ws = s.window_to_workspace.get(win) orelse {
        // Window not tracked, just add to target
        s.workspaces[target_ws].add(win) catch |err| {
            std.log.err("[workspaces] Failed to add window to workspace {}: {}", .{ target_ws, err });
        };
        s.window_to_workspace.put(win, target_ws) catch {};
        return;
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

        // Mark tiling dirty when removing from current workspace
        if (wm.config.tiling.enabled) {
            markTilingDirty();
        }
    } else if (target_ws == s.current) {
        // Moving to current workspace - mark tiling dirty
        if (wm.config.tiling.enabled) {
            markTilingDirty();
        }
    }
}

inline fn markTilingDirty() void {
    if (@import("tiling").getState()) |ts| {
        ts.markDirty();
    }
}

pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse return;

    if (ws_id >= s.workspaces.len or ws_id == s.current) return;

    const old_ws = s.current;
    // Set current before switch so retileCurrentWorkspace uses the new workspace
    s.current = ws_id;
    executeSwitch(wm, old_ws, ws_id);
}

// OPTIMIZATION: Flicker-free workspace switch with atomic XCB batch
// See detailed explanation in original workspaces.zig
fn executeSwitch(wm: *WM, old_ws: usize, new_ws: usize) void {
    const s = state orelse return;

    const old_workspace = &s.workspaces[old_ws];
    const new_workspace = &s.workspaces[new_ws];
    const screen = wm.screen;

    // Pre-set focused_window so retile assigns correct border color
    if (new_workspace.windows.items.len > 0) {
        wm.focused_window = new_workspace.windows.items[0];
    } else {
        wm.focused_window = null;
    }

    // Cache fullscreen info (single lookup instead of 3)
    const fs_info = wm.fullscreen.getForWorkspace(new_ws);

    // OPTIMIZATION: Batch all XCB operations for atomic flush

    // (a) Move old-workspace windows off-screen (preserves content)
    for (old_workspace.windows.items) |win| {
        _ = xcb.xcb_configure_window(
            wm.conn,
            win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@intCast(screen.width_in_pixels)},
        );
    }

    // (b) Map new-workspace windows (no-op if already mapped off-screen)
    for (new_workspace.windows.items) |win| {
        _ = xcb.xcb_map_window(wm.conn, win);
    }

    // (c) Restore fullscreen window geometry if present
    if (fs_info) |info| {
        _ = xcb.xcb_configure_window(
            wm.conn,
            info.window,
            xcb.XCB_CONFIG_WINDOW_X |
                xcb.XCB_CONFIG_WINDOW_Y |
                xcb.XCB_CONFIG_WINDOW_WIDTH |
                xcb.XCB_CONFIG_WINDOW_HEIGHT |
                xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{
                0, // x
                0, // y
                @intCast(screen.width_in_pixels), // width
                @intCast(screen.height_in_pixels), // height
                0, // border_width
            },
        );
        _ = xcb.xcb_configure_window(
            wm.conn,
            info.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
        );
    }

    // (d) Retile: configures tiled windows and flushes
    // All queued operations from (a)-(c) flush in one atomic batch
    if (wm.config.tiling.enabled) {
        const tiling_mod = @import("tiling");
        tiling_mod.retileCurrentWorkspace(wm);
    } else {
        // Only flush if tiling didn't run (which already flushes)
        utils.flush(wm.conn);
    }

    // Handle bar visibility based on fullscreen state
    if (fs_info != null) {
        bar.hideForFullscreen(wm);
    } else {
        bar.showForFullscreen(wm);
    }

    // Raise bar above fullscreen window (after main flush)
    if (fs_info != null) {
        bar.raiseBar();
    }

    // Set focus
    const focus_target = if (wm.focused_window) |win| win else wm.root;
    _ = xcb.xcb_set_input_focus(
        wm.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        focus_target,
        xcb.XCB_CURRENT_TIME,
    );
    utils.flush(wm.conn);

    bar.markDirty();
}

pub inline fn getCurrentWindowsView() ?[]const u32 {
    const s = state orelse return null;
    return s.workspaces[s.current].windows.items;
}

pub inline fn getCurrentWorkspace() ?usize {
    const s = state orelse return null;
    return s.current;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
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
