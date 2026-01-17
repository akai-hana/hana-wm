//! Virtual desktop workspace management.
//!
//! Provides multiple independent workspaces (virtual desktops) where windows
//! can be organized. Each workspace maintains its own window list, and only
//! windows on the current workspace are visible.
//!
//! Features:
//! - Configurable number of workspaces (default: 9)
//! - Switch between workspaces
//! - Move windows between workspaces
//! - Windows persist when switching workspaces

const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const log = @import("logging");
const tiling = @import("tiling");
const xcb = defs.xcb;
const WM = defs.WM;

/// A single workspace containing windows
pub const Workspace = struct {
    /// Workspace index (0-based)
    id: usize,

    /// Windows currently on this workspace
    windows: std.ArrayList(u32),

    /// Human-readable name
    name: []const u8,
};

/// Global workspace state
pub const WorkspaceState = struct {
    /// All available workspaces
    workspaces: []Workspace,

    /// Index of currently visible workspace
    current: usize,

    allocator: std.mem.Allocator,
};

var workspace_state: ?*WorkspaceState = null;

pub fn init(wm: *WM) void {
    const state = wm.allocator.create(WorkspaceState) catch {
        std.log.err("Failed to allocate workspace state", .{});
        return;
    };

    state.allocator = wm.allocator;
    state.current = 0;

    // Initialize workspaces based on config
    const ws_count = wm.config.workspaces.count;
    state.workspaces = wm.allocator.alloc(Workspace, ws_count) catch {
        std.log.err("Failed to allocate workspaces", .{});
        wm.allocator.destroy(state);
        return;
    };

    for (state.workspaces, 0..) |*ws, i| {
        ws.* = .{
            .id = i,
            .windows = std.ArrayList(u32){},
            .name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?",
        };
    }

    workspace_state = state;

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Initialized {} workspaces", .{ws_count});
    }
}

pub fn deinit(wm: *WM) void {
    if (workspace_state) |state| {
        for (state.workspaces) |*ws| {
            ws.windows.deinit(wm.allocator);
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(state.workspaces);
        wm.allocator.destroy(state);
        workspace_state = null;
    }
}

pub fn handleEvent(_: u8, _: *anyopaque, _: *WM) void {
    // Workspaces don't handle X events directly
}

/// Add window to current workspace
pub fn addWindow(window_id: u32) void {
    const state = workspace_state orelse return;
    const ws = &state.workspaces[state.current];

    // Check if already exists
    for (ws.windows.items) |win| {
        if (win == window_id) return;
    }

    ws.windows.append(state.allocator, window_id) catch return;

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Added window {x} to workspace {}", .{window_id, state.current + 1});
    }
}

/// Remove window from all workspaces
pub fn removeWindow(window_id: u32) void {
    const state = workspace_state orelse return;

    for (state.workspaces) |*ws| {
        for (ws.windows.items, 0..) |win, i| {
            if (win == window_id) {
                _ = ws.windows.orderedRemove(i);
                if (builtin.mode == .Debug) {
                    std.log.info("[workspaces] Removed window {x} from workspace {}", .{window_id, ws.id + 1});
                }
                return;
            }
        }
    }
}

/// Switch to a different workspace
pub fn switchTo(wm: *WM, workspace_id: usize) void {
    const state = workspace_state orelse return;

    if (workspace_id >= state.workspaces.len or workspace_id == state.current) return;

    // Hide all windows on current workspace
    const current_ws = &state.workspaces[state.current];
    for (current_ws.windows.items) |win| {
        _ = xcb.xcb_unmap_window(wm.conn, win);
    }

    // Switch to new workspace
    const old_workspace = state.current;
    state.current = workspace_id;

    // Show all windows on new workspace
    const new_ws = &state.workspaces[state.current];
    for (new_ws.windows.items) |win| {
        _ = xcb.xcb_map_window(wm.conn, win);
    }

    // Focus first window if any exist
    wm.focused_window = if (new_ws.windows.items.len > 0) new_ws.windows.items[0] else null;

    if (wm.focused_window) |focused| {
        _ = xcb.xcb_set_input_focus(
            wm.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            focused,
            xcb.XCB_CURRENT_TIME
        );
    }

    _ = xcb.xcb_flush(wm.conn);

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Switched from workspace {} to {}", .{old_workspace + 1, workspace_id + 1});
    }
}

/// Move focused window to another workspace
pub fn moveWindowTo(wm: *WM, target_workspace: usize) void {
    const state = workspace_state orelse return;
    const focused = wm.focused_window orelse return;

    if (target_workspace >= state.workspaces.len or target_workspace == state.current) return;

    // Remove from current workspace
    const current_ws = &state.workspaces[state.current];
    for (current_ws.windows.items, 0..) |win, i| {
        if (win == focused) {
            _ = current_ws.windows.orderedRemove(i);
            break;
        }
    }

    // Add to target workspace
    const target_ws = &state.workspaces[target_workspace];
    target_ws.windows.append(wm.allocator, focused) catch return;

    // Hide the window since it's no longer on current workspace
    _ = xcb.xcb_unmap_window(wm.conn, focused);

    // Focus next window in current workspace
    wm.focused_window = if (current_ws.windows.items.len > 0) current_ws.windows.items[0] else null;

    _ = xcb.xcb_flush(wm.conn);

    if (builtin.mode == .Debug) {
        std.log.info("[workspaces] Moved window {x} to workspace {}", .{focused, target_workspace + 1});
    }
}

/// Get current workspace's window list
pub fn getCurrentWindows() ?[]const u32 {
    const state = workspace_state orelse return null;
    return state.workspaces[state.current].windows.items;
}

/// Get current workspace ID
pub fn getCurrentWorkspace() ?usize {
    const state = workspace_state orelse return null;
    return state.current;
}

pub const EVENT_TYPES = [_]u8{};

pub fn createModule() defs.Module {
    return defs.Module{
        .name = "workspaces",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
        .deinit_fn = deinit,
    };
}
