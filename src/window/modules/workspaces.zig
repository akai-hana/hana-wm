// Workspace management - MEMORY OPTIMIZED with u8 indices

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const bar = @import("bar");
const tiling = @import("tiling");
const tracking = @import("tracking").Tracking;
const createModule = @import("module").module;
const debug = @import("debug");

pub const Workspace = struct {
    id: u8,  // OPTIMIZED: u8 instead of usize
    windows: tracking,
    name: []const u8,

    pub fn init(allocator: std.mem.Allocator, id: u8, name: []const u8) !Workspace {
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
    current: u8,  // OPTIMIZED: u8 instead of usize
    window_to_workspace: std.AutoHashMap(u32, u8),  // OPTIMIZED: u8 values
    allocator: std.mem.Allocator,
    wm: *WM,
};

const StateManager = createModule(State);

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
        debug.err("Failed to allocate workspaces", .{});
        return;
    };
    
    // OPTIMIZATION: Single loop for initialization
    for (workspaces_array, 0..) |*ws, i| {
        const ws_id: u8 = @intCast(i);
        const name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?";
        ws.* = Workspace.init(wm.allocator, ws_id, name) catch {
            debug.err("Failed to init workspace {}", .{i});
            cleanupWorkspaces(workspaces_array[0..i], wm.allocator);
            return;
        };
    }
    
    // OPTIMIZATION: Pre-allocate hash map capacity
    // Typical workload: 32 windows across all workspaces
    var window_to_workspace = std.AutoHashMap(u32, u8).init(wm.allocator);
    window_to_workspace.ensureTotalCapacity(32) catch {}; // Best-effort pre-allocation
    
    const initial_state = State{
        .workspaces = workspaces_array,
        .current = 0,
        .window_to_workspace = window_to_workspace,
        .allocator = wm.allocator,
        .wm = wm,
    };
    
    StateManager.init(wm.allocator, initial_state) catch |err| {
        debug.err("Failed to initialize state: {}", .{err});
        cleanupWorkspaces(workspaces_array, wm.allocator);
    };
}

pub fn deinit(wm: *WM) void {
    if (StateManager.get()) |s| {
        for (s.workspaces) |*ws| {
            ws.deinit();
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
    }
    StateManager.deinit(wm.allocator);
}

// FIXED 3.12: Removed dead addWindowToCurrentWorkspace function (no callers)

pub fn removeWindow(win: u32) void {
    const s = StateManager.get() orelse return;
    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        const ws_idx = entry.value;
        if (ws_idx < s.workspaces.len) {
            _ = s.workspaces[ws_idx].remove(win);
        }
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: u8) void {
    const s = StateManager.get() orelse return;

    if (target_ws >= s.workspaces.len) {
        debug.err("Invalid target workspace: {}", .{target_ws});
        return;
    }

    // OPTIMIZATION: Get tiling state once if needed
    const tiling_state = if (wm.config.tiling.enabled) @import("tiling").getState() else null;

    const from_ws = s.window_to_workspace.get(win) orelse {
        // Window not tracked, just add to target
        s.workspaces[target_ws].add(win) catch |err| {
            debug.err("Failed to add window to workspace {}: {}", .{ target_ws, err });
            // CRITICAL: If we can't add to workspace, remove from tiling to stay consistent
            if (tiling_state) |ts| {
                _ = ts.windows.remove(win);
            }
            return;
        };
        s.window_to_workspace.put(win, target_ws) catch |e| debug.warnOnErr(e, "window_to_workspace after untracked add");
        return;
    };

    if (from_ws == target_ws) return;

    // Move window between workspaces
    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch |err| {
        debug.err("Failed to add window to workspace {}: {}", .{ target_ws, err });
        // CRITICAL: Rollback - add back to original workspace to maintain consistency
        s.workspaces[from_ws].add(win) catch |e| debug.warnOnErr(e, "workspace rollback re-add");
        // Also ensure it's removed from tiling if add failed
        if (tiling_state) |ts| {
            _ = ts.windows.remove(win);
        }
        return;
    };
    s.window_to_workspace.put(win, target_ws) catch |e| debug.warnOnErr(e, "window_to_workspace after move");

    // OPTIMIZATION: Simplified visibility handling using dwm approach
    if (from_ws == s.current) {
        // Move window off-screen instead of unmapping
        hideWindow(wm, win);
        if (wm.focused_window == win) {
            focus.clearFocus(wm);
        }
        if (tiling_state) |ts| ts.markDirty();
    } else if (target_ws == s.current) {
        // Window moving to current workspace - will be shown on next retile
        if (tiling_state) |ts| ts.markDirty();
    }
}

// OPTIMIZATION: Removed markTilingDirty() - inlined to reduce function call overhead

pub fn switchTo(wm: *WM, ws_id: u8) void {
    const s = StateManager.get() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old_ws = s.current;
    s.current = ws_id;
    std.debug.assert(s.current < s.workspaces.len);  // Current workspace must be valid index
    executeSwitch(wm, old_ws, ws_id);
}

// Helper: Move window off-screen (DWM-style hiding)
inline fn hideWindow(wm: *WM, win: u32) void {
    const values = [_]u32{@bitCast(@as(i32, -4000))};
    _ = xcb.xcb_configure_window(wm.conn, win, xcb.XCB_CONFIG_WINDOW_X, &values);
}

// Helper: Configure fullscreen window
inline fn configureFullscreen(wm: *WM, info: defs.FullscreenInfo) void {
    const screen = wm.screen;
    const values = [_]u32{
        0, // x
        0, // y
        @intCast(screen.width_in_pixels),
        @intCast(screen.height_in_pixels),
        0, // border_width
    };
    _ = xcb.xcb_configure_window(wm.conn, info.window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &values);
    _ = xcb.xcb_configure_window(wm.conn, info.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

// DWM-STYLE: Atomic workspace switching with server grab
fn executeSwitch(wm: *WM, old_ws: u8, new_ws: u8) void {
    const s = StateManager.get().?; // Must exist if we got here
    const old_workspace = &s.workspaces[old_ws];
    const new_workspace = &s.workspaces[new_ws];

    const fs_info = wm.fullscreen.getForWorkspace(new_ws);

    // Pre-set focused_window for correct border colors
    wm.focused_window = if (new_workspace.windows.items().len > 0)
        new_workspace.windows.items()[0] else null;
    std.debug.assert(wm.focused_window == null or wm.hasWindow(wm.focused_window.?));  // Focused window must be valid if set

    // CRITICAL: Grab server for atomic switching (no intermediate frames)
    _ = xcb.xcb_grab_server(wm.conn);
    defer _ = xcb.xcb_ungrab_server(wm.conn);

    // Step 1: Hide ALL old workspace windows
    for (old_workspace.windows.items()) |win| {
        hideWindow(wm, win);
    }

    // Step 2: If there's a fullscreen window, configure it FIRST and ONLY
    // Don't position any other windows - they should stay hidden
    if (fs_info) |info| {
        configureFullscreen(wm, info);
    } else {
        // No fullscreen - position windows based on RUNTIME tiling state
        // CRITICAL FIX: Check tiling.State.enabled, not config.tiling.enabled!
        // When user toggles tiling with Mod+N, it changes State.enabled, not config
        const tiling_state = tiling.getState();
        const tiling_enabled = if (tiling_state) |ts| ts.enabled else false;
        
        if (tiling_enabled) {
            // Tiling enabled - let tiling system position windows
            tiling.retileCurrentWorkspace(wm, false);
        } else {
            // FIXED 2.6: Pre-batch geometry cookies BEFORE positioning
            // Prevents blocking geometry queries during server grab
            const GeometryInfo = struct { cookie: xcb.xcb_get_geometry_cookie_t, win: u32 };
            var geom_infos = std.ArrayList(GeometryInfo).empty;
            defer geom_infos.deinit(wm.allocator);
            
            // Send all geometry requests first (non-blocking)
            for (new_workspace.windows.items()) |win| {
                const cookie = xcb.xcb_get_geometry(wm.conn, win);
                geom_infos.append(wm.allocator, .{ .cookie = cookie, .win = win }) catch continue;
            }
            
            // Tiling disabled - manually position windows to visible locations
            const x: i16 = @divTrunc(@as(i16, @intCast(wm.screen.width_in_pixels)), 4);
            const y: i16 = @divTrunc(@as(i16, @intCast(wm.screen.height_in_pixels)), 4);
            
            for (geom_infos.items) |info| {
                const geom_reply = xcb.xcb_get_geometry_reply(wm.conn, info.cookie, null);
                if (geom_reply) |reply| {
                    defer std.c.free(reply);
                    
                    const values = [_]u32{
                        @bitCast(@as(i32, x)),
                        @bitCast(@as(i32, y)),
                    };
                    _ = xcb.xcb_configure_window(wm.conn, info.win,
                        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y, &values);
                }
            }
        }
    }

    // Step 3: NOW flush everything atomically
    utils.flush(wm.conn);

    // Bar state management (after positioning complete)
    if (fs_info != null) {
        bar.setBarState(wm, .hide_fullscreen);
        bar.raiseBar();
    } else {
        bar.setBarState(wm, .show_fullscreen);
    }

    // Set focus
    const focus_target = wm.focused_window orelse wm.root;
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, focus_target, xcb.XCB_CURRENT_TIME);
    utils.flush(wm.conn);
    bar.markDirty();
}

pub inline fn getCurrentWindowsView() ?[]const u32 {
    const s = StateManager.get() orelse return null;
    return s.workspaces[s.current].windows.items();
}

pub inline fn getCurrentWorkspace() ?u8 {
    const s = StateManager.get() orelse return null;
    return s.current;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    const s = StateManager.get() orelse return false;
    // FIXED 2.13: O(1) hashmap lookup instead of O(n) linear scan
    const ws_idx = s.window_to_workspace.get(win) orelse return false;
    return ws_idx == s.current;
}

pub inline fn getState() ?*State {
    return StateManager.get();
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = StateManager.get() orelse return null;
    return &s.workspaces[s.current];
}
