// Workspace management

const std      = @import("std");
const defs     = @import("defs");
const xcb      = defs.xcb;
const WM       = defs.WM;
const utils    = @import("utils");
const focus    = @import("focus");
const bar      = @import("bar");
const tiling   = @import("tiling");
const Tracking = @import("tracking").Tracking;
const debug    = @import("debug");

// Comptime-generated workspace name strings ("1".."20"), never heap-allocated.
const WORKSPACE_NAMES = blk: {
    var names: [20][]const u8 = undefined;
    for (&names, 1..) |*name, i| name.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk names;
};

pub const Workspace = struct {
    id:      u8,
    windows: Tracking,
    name:    []const u8,

    pub fn init(allocator: std.mem.Allocator, id: u8, name: []const u8) !Workspace {
        return .{ .id = id, .windows = Tracking.init(allocator), .name = name };
    }

    pub fn deinit(self: *Workspace) void { self.windows.deinit(); }

    pub inline fn contains(self: *const Workspace, win: u32) bool { return self.windows.contains(win); }
    pub inline fn add(self: *Workspace, win: u32)  !void  { try self.windows.add(win); }
    pub inline fn remove(self: *Workspace, win: u32) bool { return self.windows.remove(win); }
};

pub const State = struct {
    workspaces:          []Workspace,
    current:             u8,
    window_to_workspace: std.AutoHashMap(u32, u8),
    allocator:           std.mem.Allocator,
};

// Module singleton ─────────────────────────────────────────────────────────

var g_state: ?State = null;

pub fn getState() ?*State { return if (g_state != null) &g_state.? else null; }

// Init / deinit 

pub fn init(wm: *WM) void {
    const count = wm.config.workspaces.count;
    const wss = wm.allocator.alloc(Workspace, count) catch {
        debug.err("Failed to allocate workspaces", .{});
        return;
    };

    for (wss, 0..) |*ws, i| {
        const id: u8     = @intCast(i);
        const name       = if (i < WORKSPACE_NAMES.len) WORKSPACE_NAMES[i] else "?";
        ws.* = Workspace.init(wm.allocator, id, name) catch {
            debug.err("Failed to init workspace {}", .{i});
            for (wss[0..i]) |*w| w.deinit();
            wm.allocator.free(wss);
            return;
        };
    }

    var w2ws = std.AutoHashMap(u32, u8).init(wm.allocator);
    w2ws.ensureTotalCapacity(32) catch {};

    g_state = .{
        .workspaces          = wss,
        .current             = 0,
        .window_to_workspace = w2ws,
        .allocator           = wm.allocator,
    };
}

pub fn deinit(wm: *WM) void {
    if (g_state) |*s| {
        for (s.workspaces) |*ws| ws.deinit();
        wm.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
    }
    g_state = null;
}

// Window tracking ──────────────────────────────────────────────────────────

pub fn removeWindow(win: u32) void {
    const s = getState() orelse return;
    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        if (entry.value < s.workspaces.len)
            _ = s.workspaces[entry.value].remove(win);
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: u8) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) {
        debug.err("Invalid target workspace: {}", .{target_ws});
        return;
    }

    const ts = if (wm.config.tiling.enabled) tiling.getState() else null;

    const from_ws = s.window_to_workspace.get(win) orelse {
        // Window not yet tracked — add it directly to the target.
        s.workspaces[target_ws].add(win) catch |err| {
            debug.err("Failed to add window to workspace {}: {}", .{ target_ws, err });
            if (ts) |t| _ = t.windows.remove(win);
            return;
        };
        s.window_to_workspace.put(win, target_ws) catch |e| debug.warnOnErr(e, "w2ws put");
        return;
    };

    if (from_ws == target_ws) return;

    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch |err| {
        debug.err("Failed to add window to workspace {}: {}", .{ target_ws, err });
        s.workspaces[from_ws].add(win) catch |e| debug.warnOnErr(e, "workspace rollback");
        if (ts) |t| _ = t.windows.remove(win);
        return;
    };
    s.window_to_workspace.put(win, target_ws) catch |e| debug.warnOnErr(e, "w2ws put after move");

    if (from_ws == s.current) {
        // Hide window by moving it off-screen (avoids an unmap/remap cycle).
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, -4000))});
        if (wm.focused_window == win) focus.clearFocus(wm);
        if (ts) |t| t.markDirty();
    } else if (target_ws == s.current) {
        // Map in case the window was deferred (spawned while this ws was inactive).
        _ = xcb.xcb_map_window(wm.conn, win);
        if (ts) |t| t.markDirty();
    }
}

// Workspace switching ──────────────────────────────────────────────────────

pub fn switchTo(wm: *WM, ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old    = s.current;
    s.current    = ws_id;
    executeSwitch(wm, old, ws_id);
}

fn executeSwitch(wm: *WM, old_ws: u8, new_ws: u8) void {
    const s          = getState().?;
    const old_ws_obj = &s.workspaces[old_ws];
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info    = wm.fullscreen.getForWorkspace(new_ws);

    wm.focused_window = new_ws_obj.windows.first();
    std.debug.assert(wm.focused_window == null or wm.hasWindow(wm.focused_window.?));

    // Grab the server so the switch is atomic — no intermediate frames visible.
    _ = xcb.xcb_grab_server(wm.conn);
    defer _ = xcb.xcb_ungrab_server(wm.conn);

    // Step 1: hide all windows from the old workspace.
    for (old_ws_obj.windows.items()) |win| {
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, -4000))});
    }

    // Step 2: Determine if we need to adjust bar visibility for the new workspace
    // If switching to a fullscreen workspace, hide the bar temporarily
    // Otherwise, show/hide based on global state
    if (fs_info != null) {
        bar.setBarState(wm, .hide_fullscreen);
    } else {
        bar.setBarState(wm, .show_fullscreen);
    }

    // Step 3: show windows for the new workspace.
    if (fs_info) |info| {
        // Fullscreen: configure the fs window to cover the screen and raise it.
        _ = xcb.xcb_configure_window(wm.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{ 0, 0,
                @intCast(wm.screen.width_in_pixels),
                @intCast(wm.screen.height_in_pixels), 0 });
        _ = xcb.xcb_configure_window(wm.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        // Map any deferred windows (spawned while this workspace was inactive).
        // xcb_map_window is a no-op for already-mapped windows.
        for (new_ws_obj.windows.items()) |win| _ = xcb.xcb_map_window(wm.conn, win);

        const ts            = tiling.getState();
        const tiling_active = if (ts) |t| t.enabled else false;

        if (tiling_active) {
            // Retile to position windows correctly on-screen
            // Windows should already have correct height from bar toggle, but need X positioning
            tiling.retileCurrentWorkspace(wm, true);
        } else {
            // Floating: move all windows to a sensible on-screen position.
            const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
            const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
            for (new_ws_obj.windows.items()) |win| {
                _ = xcb.xcb_configure_window(wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{ x, y });
            }
        }
    }

    utils.flush(wm.conn);
    bar.raiseBar();

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        wm.focused_window orelse wm.root, xcb.XCB_CURRENT_TIME);
    utils.flush(wm.conn);
    bar.markDirty();
}

// Queries───

pub inline fn getCurrentWindowsView() ?[]const u32 {
    const s = getState() orelse return null;
    return s.workspaces[s.current].windows.items();
}

pub inline fn getCurrentWorkspace() ?u8 {
    const s = getState() orelse return null;
    return s.current;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    const s = getState() orelse return false;
    const ws_idx = s.window_to_workspace.get(win) orelse return false;
    return ws_idx == s.current;
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = getState() orelse return null;
    return &s.workspaces[s.current];
}
