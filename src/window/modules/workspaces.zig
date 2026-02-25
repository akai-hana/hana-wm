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
const constants = @import("constants");
const debug    = @import("debug");
const minimize = @import("minimize");

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
    // The tiling layout active on this workspace.
    // Initialized from config; updated when the user switches layouts
    // in per-workspace mode.
    layout:  tiling.Layout,

    pub fn init(allocator: std.mem.Allocator, id: u8, name: []const u8, default_layout: tiling.Layout) Workspace {
        return .{ .id = id, .windows = Tracking.init(allocator), .name = name, .layout = default_layout };
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

var g_state: ?State = null;

pub fn getState() ?*State { return if (g_state) |*s| s else null; }

pub fn init(wm: *WM) void {
    const count = wm.config.workspaces.count;
    const wss = wm.allocator.alloc(Workspace, count) catch {
        debug.err("Failed to allocate workspaces", .{});
        return;
    };

    // Derive the default layout from the tiling state so every workspace
    // starts on the same layout as the global default. Falls back to .master.
    const default_layout: tiling.Layout =
        if (tiling.getState()) |ts| ts.layout else .master;

    for (wss, 0..) |*ws, i| {
        const id: u8 = @intCast(i);
        const name   = if (i < WORKSPACE_NAMES.len) WORKSPACE_NAMES[i] else "?";
        ws.* = Workspace.init(wm.allocator, id, name, default_layout);
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

pub fn deinit() void {
    if (g_state) |*s| {
        for (s.workspaces) |*ws| ws.deinit();
        s.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
    }
    g_state = null;
}

pub fn removeWindow(win: u32) void {
    const s = getState() orelse return;
    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        if (entry.value < s.workspaces.len)
            _ = s.workspaces[entry.value].remove(win);
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: u8) !void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) {
        debug.err("Invalid target workspace: {}", .{target_ws});
        return;
    }

    const ts = if (wm.config.tiling.enabled) tiling.getState() else null;

    const from_ws = s.window_to_workspace.get(win) orelse {
        // Not yet tracked: add directly to the target.
        try s.workspaces[target_ws].add(win);
        s.window_to_workspace.put(win, target_ws) catch |e| {
            _ = s.workspaces[target_ws].remove(win);
            return e;
        };
        return;
    };

    if (from_ws == target_ws) return;

    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch |err| {
        debug.err("Failed to add window to workspace {}: {}", .{ target_ws, err });
        s.workspaces[from_ws].add(win) catch |e| debug.warnOnErr(e, "workspace rollback after move failure");
        if (ts) |t| _ = t.windows.remove(win);
        return;
    };
    s.window_to_workspace.put(win, target_ws) catch |e| {
        // INVARIANT BREAK: workspaces[target_ws] now contains `win` but
        // window_to_workspace still maps win -> from_ws (or retains whatever
        // value it had before). Rolling back the Tracking move here would
        // require a second fallible add; given that OOM at this point usually
        // means the session is dying, we log and accept the stale entry.
        // Callers that rely on getWorkspaceForWindow should treat a mismatch
        // between the map and the workspace's window list as a degenerate-but-
        // non-crashing state.
        debug.warnOnErr(e, "w2ws put after move: window_to_workspace is stale");
    };

    if (minimize.isMinimized(wm, win)) minimize.moveToWorkspace(wm, win, from_ws, target_ws);

    if (from_ws == s.current) {
        // If the window is fullscreen on the current workspace, tear down the
        // fullscreen state before hiding it: without this, the bar stays hidden
        // and siblings remain offscreen on the old workspace.
        if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
            if (fs_ws == from_ws) {
                wm.fullscreen.removeForWorkspace(fs_ws);
                bar.setBarState(wm, .show_fullscreen);
            }
        }

        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
        if (wm.focused_window == win) focus.clearFocus(wm);
        if (ts) |t| t.dirty = true;
        // Evict the stale geometry cache entry. The window has been moved to
        // target_ws so the current-workspace retile will not refresh it, and
        // without eviction restoreWorkspaceGeom replays the old geometry.
        tiling.invalidateGeomCache(win);
    } else if (target_ws == s.current) {
        // Map in case the window was deferred (spawned while this ws was inactive).
        _ = xcb.xcb_map_window(wm.conn, win);
        if (ts) |t| t.dirty = true;
    }
}

pub fn switchTo(wm: *WM, ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old = s.current;
    s.current = ws_id;
    executeSwitch(wm, old, ws_id);
}

// Returns the first non-minimized window in `windows`, or null if all are
// minimized. Takes a plain slice so it is decoupled from Workspace and easier
// to test in isolation.
pub inline fn firstNonMinimized(wm: *const WM, windows: []const u32) ?u32 {
    for (windows) |win| {
        if (!minimize.isMinimized(wm, win)) return win;
    }
    return null;
}

// Step 1: move all old-workspace windows offscreen and evict their geom cache.
// Without eviction, the next retile finds cache hits and skips configure_window,
// leaving windows stranded offscreen when the user switches back.
fn hideWorkspaceWindows(wm: *WM, ws: *const Workspace) void {
    for (ws.windows.items()) |win| {
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
        tiling.invalidateGeomCache(win);
    }
}

// Step 3a: show the new workspace's fullscreen window at full extent.
fn showFullscreenWindow(wm: *WM, info: defs.FullscreenInfo) void {
    utils.configureWindowGeom(wm.conn, info.window, .{
        .x            = 0,
        .y            = 0,
        .width        = @intCast(wm.screen.width_in_pixels),
        .height       = @intCast(wm.screen.height_in_pixels),
        .border_width = 0,
    });
    _ = xcb.xcb_configure_window(wm.conn, info.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

// Step 3b: restore tiled or floating geometry for the new workspace.
fn restoreWorkspaceWindows(wm: *WM, ws: *const Workspace) void {
    // Map any deferred windows (spawned while this workspace was inactive).
    // xcb_map_window is a no-op for already-mapped windows.
    for (ws.windows.items()) |win| _ = xcb.xcb_map_window(wm.conn, win);

    const tiling_active = if (tiling.getState()) |t| t.enabled else false;

    if (tiling_active) {
        // Per-workspace layout: restore the layout this workspace was last
        // using so the right algorithm runs and the bar shows the correct icon.
        if (!wm.config.tiling.global_layout) {
            tiling.syncLayoutFromWorkspace(ws.layout);
        }

        // Fast path: replay cached tiled positions without running the layout
        // algorithm. Falls back to a full retile only if the cache is cold,
        // the workspace's valid bit is unset, or the screen area changed.
        // restoreWorkspaceGeom calls utils.configureWindow directly, bypassing
        // the geom cache: windows were moved to OFFSCREEN_X_POSITION in step 1
        // so the cache holds correct rects but the server does not.
        if (!tiling.restoreWorkspaceGeom(wm)) {
            // Evict new workspace cache entries before retriling.
            // retileInactiveWorkspace may have pre-populated them with correct
            // on-screen positions. Without eviction, configureSafe finds
            // cache[win] == computed_geom and skips configure_window, leaving
            // windows stranded at OFFSCREEN_X_POSITION.
            for (ws.windows.items()) |win| tiling.invalidateGeomCache(win);
            tiling.retileCurrentWorkspace(wm);
        }
    } else {
        // Floating: move all non-minimized windows to the default position.
        const pos = utils.floatDefaultPos(wm);
        for (ws.windows.items()) |win| {
            if (minimize.isMinimized(wm, win)) continue;
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{ pos.x, pos.y });
        }
    }
}

// Step 4: resolve the post-switch focus target and apply it.
// Query the pointer inside the grab, after all configure_window calls have
// been queued. XCB sends pending requests before blocking on the reply, so
// the server sees the fully repositioned layout when evaluating which window
// is under the pointer. This avoids the master-flash: we never eagerly focus
// the master and then correct it after the grab releases.
//
// NOTE: wm.focused_window is written directly (not via focus.setFocus) because
// we are inside a server grab and focus.setFocus may issue a blocking
// xcb_get_window_attributes round-trip for the mapped check.
fn applyPostSwitchFocus(wm: *WM, new_ws: u8, new_ws_obj: *const Workspace) void {
    const s = getState().?;

    const focus_target: ?u32 = blk: {
        const ptr = xcb.xcb_query_pointer_reply(
            wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
        ) orelse break :blk firstNonMinimized(wm, new_ws_obj.windows.items());
        defer std.c.free(ptr);

        const child = ptr.*.child;
        if (child != 0 and child != wm.root and
            s.window_to_workspace.get(child) == new_ws and
            !minimize.isMinimized(wm, child))
        {
            break :blk child;
        }
        break :blk firstNonMinimized(wm, new_ws_obj.windows.items());
    };

    const old_focused = wm.focused_window;
    wm.focused_window = focus_target;
    std.debug.assert(wm.focused_window == null or isManaged(wm.focused_window.?));

    // Paint borders inside the grab so the focused window gets border_focused
    // before any frame is composited: no border flash on the master window.
    tiling.updateWindowFocus(wm, old_focused, wm.focused_window);

    if (wm.focused_window) |new_win| {
        _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, new_win, xcb.XCB_MOD_MASK_ANY);
    }

    // ICCCM §4.1.7: xcb_set_input_focus must carry the timestamp of the user
    // action that triggered the switch. Globally-active windows (Electron)
    // silently ignore focus messages with timestamp 0.
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        wm.focused_window orelse wm.root, wm.last_event_time);
}

fn executeSwitch(wm: *WM, old_ws: u8, new_ws: u8) void {
    const s          = getState().?;
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info    = wm.fullscreen.getForWorkspace(new_ws);

    wm.suppress_focus_reason = .none;

    // Grab the server so the switch is atomic: no intermediate frames visible.
    // NOTE: no defer for ungrab; we queue it explicitly before the flush so that
    // grab + all changes + raiseBar + ungrab land in a single write.
    _ = xcb.xcb_grab_server(wm.conn);

    hideWorkspaceWindows(wm, &s.workspaces[old_ws]);

    // Step 2: adjust bar visibility for the new workspace.
    bar.setBarState(wm, if (fs_info != null) .hide_fullscreen else .show_fullscreen);

    // Step 3: show windows for the new workspace.
    if (fs_info) |info| {
        showFullscreenWindow(wm, info);
    } else {
        restoreWorkspaceWindows(wm, new_ws_obj);
    }

    applyPostSwitchFocus(wm, new_ws, new_ws_obj);

    // Redraw the bar inside the grab so picom composites the updated workspace
    // highlight atomically; deferring via markDirty shows one stale frame first.
    bar.raiseBar();
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
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

pub inline fn getWorkspaceCount() usize {
    const s = getState() orelse return 0;
    return s.workspaces.len;
}

pub inline fn getWorkspaceForWindow(win: u32) ?u8 {
    const s = getState() orelse return null;
    return s.window_to_workspace.get(win);
}

// Predicate form used by utils.findManagedWindow to check membership without
// creating a circular import between utils and workspaces.
pub fn isManaged(win: u32) bool {
    return getWorkspaceForWindow(win) != null;
}
