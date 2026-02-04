// Workspace management - Optimized with batch operations

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const bar = @import("bar");
const tracking = @import("tracking").tracking;
const ModuleState = @import("module_state").ModuleState;

pub const Workspace = struct {
    id: usize,
    windows: tracking,
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, id: usize, name: []const u8) !Workspace {
        return .{
            .id = id,
            .windows = tracking.init(allocator),
            .name = name,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.windows.deinit();
    }

    pub inline fn contains(self: *const Workspace, win: u32) bool {
        return self.windows.contains(win);
    }

    pub inline fn add(self: *Workspace, win: u32) !void {
        try self.windows.add(win);
    }

    pub inline fn remove(self: *Workspace, win: u32) bool {
        return self.windows.remove(win);
    }
};

pub const State = struct {
    workspaces: []Workspace,
    current: usize,
    window_to_workspace: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,
    wm: *WM,
};

const StateManager = ModuleState(State);

inline fn cleanupWorkspaces(workspaces: []Workspace, allocator: std.mem.Allocator) void {
    for (workspaces) |*ws| {
        ws.deinit();
        allocator.free(ws.name);
    }
    allocator.free(workspaces);
}

pub fn init(wm: *WM) void {
    const count = wm.config.workspaces.count;
    const workspaces_array = wm.allocator.alloc(Workspace, count) catch {
        std.log.err("[workspaces] Failed to allocate workspaces", .{});
        return;
    };
    
    // OPTIMIZATION: Single loop for initialization
    for (workspaces_array, 0..) |*ws, i| {
        const name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?";
        ws.* = Workspace.init(wm.allocator, i, name) catch {
            std.log.err("[workspaces] Failed to init workspace {}", .{i});
            cleanupWorkspaces(workspaces_array[0..i], wm.allocator);
            return;
        };
    }
    
    const initial_state = State{
        .workspaces = workspaces_array,
        .current = 0,
        .window_to_workspace = std.AutoHashMap(u32, usize).init(wm.allocator),
        .allocator = wm.allocator,
        .wm = wm,
    };
    
    StateManager.init(wm.allocator, initial_state) catch |err| {
        std.log.err("[workspaces] Failed to initialize state: {}", .{err});
        cleanupWorkspaces(workspaces_array, wm.allocator);
    };
}

pub fn deinit(wm: *WM) void {
    if (StateManager.getMut()) |s| {
        for (s.workspaces) |*ws| {
            ws.deinit();
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
    }
    StateManager.deinit(wm.allocator);
}

pub fn addWindowToCurrentWorkspace(_: *WM, win: u32) void {
    const s = StateManager.getMut() orelse return;
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
    const s = StateManager.getMut() orelse return;
    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        const ws_idx = entry.value;
        if (ws_idx < s.workspaces.len) {
            _ = s.workspaces[ws_idx].remove(win);
        }
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = StateManager.getMut() orelse return;

    if (target_ws >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid target workspace: {}", .{target_ws});
        return;
    }

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
        s.workspaces[from_ws].add(win) catch {};
        return;
    };
    s.window_to_workspace.put(win, target_ws) catch {};

    // OPTIMIZATION: Simplified visibility handling
    const is_tiling = wm.config.tiling.enabled;
    if (from_ws == s.current) {
        _ = xcb.xcb_unmap_window(wm.conn, win);
        if (wm.focused_window == win) {
            focus.clearFocus(wm);
        }
        if (is_tiling) markTilingDirty();
    } else if (target_ws == s.current and is_tiling) {
        markTilingDirty();
    }
}

inline fn markTilingDirty() void {
    if (@import("tiling").getState()) |ts| {
        ts.markDirty();
    }
}

pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = StateManager.getMut() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old_ws = s.current;
    s.current = ws_id;
    executeSwitch(wm, old_ws, ws_id);
}

fn executeSwitch(wm: *WM, old_ws: usize, new_ws: usize) void {
    const s = StateManager.getMut() orelse return;

    const old_workspace = &s.workspaces[old_ws];
    const new_workspace = &s.workspaces[new_ws];
    const screen = wm.screen;

    // Pre-set focused_window for correct border colors
    wm.focused_window = if (new_workspace.windows.items().len > 0)
        new_workspace.windows.items()[0]
    else
        null;

    const fs_info = wm.fullscreen.getForWorkspace(new_ws);

    // OPTIMIZATION: Batch all XCB operations
    // Move old windows off-screen
    for (old_workspace.windows.items()) |win| {
        _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@intCast(screen.width_in_pixels)});
    }
    // Map new windows
    for (new_workspace.windows.items()) |win| {
        _ = xcb.xcb_map_window(wm.conn, win);
    }
    // Restore fullscreen window if present
    if (fs_info) |info| {
        const values = [_]u32{
            0, // x
            0, // y
            @intCast(screen.width_in_pixels), // width
            @intCast(screen.height_in_pixels), // height
            0, // border_width
        };
        _ = xcb.xcb_configure_window(wm.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
        _ = xcb.xcb_configure_window(wm.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    // Retile and flush
    if (wm.config.tiling.enabled) {
        @import("tiling").retileCurrentWorkspace(wm);
    } else {
        utils.flush(wm.conn);
    }

    // OPTIMIZATION: Combined bar state management
    if (fs_info != null) {
        bar.hideForFullscreen(wm);
        bar.raiseBar();
    } else {
        bar.showForFullscreen(wm);
    }

    // Set focus
    const focus_target = wm.focused_window orelse wm.root;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, focus_target, xcb.XCB_CURRENT_TIME);
    utils.flush(wm.conn);
    bar.markDirty();
}

pub inline fn getCurrentWindowsView() ?[]const u32 {
    const s = StateManager.getMut() orelse return null;
    return s.workspaces[s.current].windows.items();
}

pub inline fn getCurrentWorkspace() ?usize {
    const s = StateManager.getMut() orelse return null;
    return s.current;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    const s = StateManager.getMut() orelse return false;
    return s.workspaces[s.current].contains(win);
}

pub inline fn getState() ?*State {
    return StateManager.getMut();
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = StateManager.getMut() orelse return null;
    return &s.workspaces[s.current];
}
