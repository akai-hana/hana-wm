//! Workspace management — creation, window assignment, and workspace switching.

const std      = @import("std");
const defs     = @import("defs");
const xcb      = defs.xcb;
const WM       = defs.WM;
const utils    = @import("utils");
const focus    = @import("focus");
const window   = @import("window");
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
    layout:    tiling.Layout,
    // Optional layout variation override set via the layouts array in config.
    // Applied on every workspace switch; null means use the global defaults.
    variation: ?defs.LayoutVariationOverride = null,

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

/// Resolves a canonical layout name string (e.g. "master-stack", "monocle")
/// to the tiling.Layout enum. Falls back to the first available layout.
fn layoutFromName(name: []const u8) tiling.Layout {
    if (std.mem.eql(u8, name, "master-stack")) return .master;
    return std.meta.stringToEnum(tiling.Layout, name) orelse tiling.defaultLayout();
}

pub fn init(wm: *WM) void {
    const count = wm.config.workspaces.count;
    const wss = wm.allocator.alloc(Workspace, count) catch {
        debug.err("Failed to allocate workspaces", .{});
        return;
    };

    const default_layout: tiling.Layout =
        if (tiling.getState()) |ts| ts.layout else .master;

    const cfg_tiling = &wm.config.tiling;

    for (wss, 0..) |*ws, i| {
        const id: u8 = @intCast(i);
        const name   = if (i < WORKSPACE_NAMES.len) WORKSPACE_NAMES[i] else "?";

        // Apply any workspace-specific layout + variation override from the
        // layouts array (e.g. `"monocle", "gapless", "4,8"` in config.toml).
        var ws_layout    = default_layout;
        var ws_variation: ?defs.LayoutVariationOverride = null;
        for (cfg_tiling.workspace_layout_overrides.items) |override| {
            if (override.workspace_idx == id) {
                if (override.layout_idx < cfg_tiling.layouts.items.len) {
                    ws_layout = layoutFromName(cfg_tiling.layouts.items[override.layout_idx]);
                }
                ws_variation = override.variation;
                break;
            }
        }

        ws.* = Workspace.init(wm.allocator, id, name, ws_layout);
        ws.variation = ws_variation;
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
        // Pre-reserve map capacity before touching Tracking so that if the
        // put would fail, we haven't already mutated the workspace's window
        // list (no INVARIANT BREAK).
        try s.window_to_workspace.ensureUnusedCapacity(1);
        try s.workspaces[target_ws].add(win);
        // ensureUnusedCapacity above guarantees this cannot fail.
        s.window_to_workspace.putAssumeCapacity(win, target_ws);
        return;
    };

    if (from_ws == target_ws) return;

    // Pre-reserve map capacity before any Tracking mutations.  This closes the
    // INVARIANT BREAK window: if the reservation fails we have not yet touched
    // either workspace's Tracking, so the rollback path is clean.
    try s.window_to_workspace.ensureUnusedCapacity(1);

    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch |err| {
        debug.err("Failed to add window to workspace {}: {}", .{ target_ws, err });
        // Attempt to roll back by re-adding to the source workspace.
        // Only evict the window from tiling if the rollback itself also fails —
        // if the rollback succeeds the window is coherently back in from_ws and
        // tiling must be left intact.
        s.workspaces[from_ws].add(win) catch |e| {
            debug.warnOnErr(e, "workspace rollback after move failure");
            // Both workspaces rejected the window; tiling and window_to_workspace
            // must also be cleaned up so isManaged returns false and no further
            // operations attempt to reference this orphaned window.
            if (ts) |t| _ = t.windows.remove(win);
            _ = s.window_to_workspace.remove(win);
        };
        return;
    };
    // Capacity was pre-reserved above — this cannot fail.
    s.window_to_workspace.putAssumeCapacity(win, target_ws);

    // minimize.moveToWorkspace reads the old workspace from minimized_info
    // directly, so we no longer pass from_ws here.
    if (minimize.isMinimized(wm, win)) minimize.moveToWorkspace(wm, win, target_ws);

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
    for (ws.windows.items()) |win| _ = xcb.xcb_map_window(wm.conn, win);

    const tiling_active = if (tiling.getState()) |t| t.enabled else false;

    if (tiling_active) {
        // Per-workspace layout: restore the layout this workspace was last using.
        if (!wm.config.tiling.global_layout) {
            tiling.syncLayoutFromWorkspace(ws);
        }

        // Fast path: replay cached tiled positions without running the layout
        // algorithm. Falls back to a full retile only if the cache is cold,
        // the workspace's valid bit is unset, or the screen area changed.
        //
        // The eviction loop only runs in the fallback branch — it does not
        // discard pre-computed entries (written by retileInactiveWorkspace)
        // unless restoreWorkspaceGeom has already determined those entries
        // are stale or absent. This preserves the pre-computation fast path.
        if (!tiling.restoreWorkspaceGeom(wm)) {
            // Evict before retriling: windows are at OFFSCREEN_X_POSITION,
            // not their cached positions. Without eviction, configureSafe
            // finds matching rects and skips configure_window, leaving
            // windows stranded offscreen.
            for (ws.windows.items()) |win| tiling.invalidateGeomCache(win);
            tiling.retileCurrentWorkspace(wm);
        }
    } else {
        // Floating: move all non-minimized windows to the default position.
        // NOTE: all windows land at the same coordinate because per-window
        // pre-hide geometry is not saved.  In practice this means two or more
        // floating windows will stack on top of each other after a workspace
        // switch.  Saving each window's last known x/y on hide (similar to
        // MinimizedEntry.saved_fs) would fix this.
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
//
// Why this does not call focus.setFocus:
//   focus.setFocus calls isWindowMapped, which issues a blocking
//   xcb_get_window_attributes round-trip.  That check is unnecessary here
//   because all windows on the new workspace were mapped by
//   restoreWorkspaceWindows moments earlier.  We therefore inline the
//   relevant side-effects, omitting only the mapped-check and the stack raise
//   (workspace_switch never raises).
//
// Note on xcb_grab_server: XGrabServer only prevents *other* X clients from
// communicating with the server.  The grabbing client (this WM) can still
// make blocking round-trips inside the grab without any issue — the
// restriction is client-to-client, not self-imposed.  getInputModelCached's
// slow path (two blocking requests on a cache miss) is therefore safe here.
//
// `ptr_cookie` is pre-fired by executeSwitch before the server grab so that
// the round-trip runs concurrently with hideWorkspaceWindows +
// restoreWorkspaceWindows.  By the time we consume it here the reply is
// already sitting in the receive buffer — zero additional wait.
fn applyPostSwitchFocus(wm: *WM, new_ws: u8, new_ws_obj: *const Workspace, ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const s = getState().?;

    const focus_target: ?u32 = blk: {
        const ptr = xcb.xcb_query_pointer_reply(wm.conn, ptr_cookie, null)
            orelse break :blk firstNonMinimized(wm, new_ws_obj.windows.items());
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

    tiling.updateWindowFocus(wm, old_focused, wm.focused_window);

    // Restore click-to-focus grab on whichever window just lost focus.
    // Without this, the previously-focused window on the old workspace has no
    // button grab, so clicking it after switching back would not focus it.
    if (old_focused) |old_win| window.grabButtons(wm, old_win, false);

    if (wm.focused_window) |new_win| {
        // Remove click-to-focus grab from the newly focused window.
        window.grabButtons(wm, new_win, true);

        // For WM_PROTOCOLS-aware windows (e.g. Electron/Chromium using the
        // globally_active input model) xcb_set_input_focus alone is not
        // sufficient — the app must also receive a WM_TAKE_FOCUS ClientMessage.
        const input_model = utils.getInputModelCached(wm.conn, new_win);
        if (input_model == .locally_active or input_model == .globally_active) {
            utils.sendWMTakeFocus(wm.conn, new_win, wm.last_event_time);
        }
    }

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        wm.focused_window orelse wm.root, wm.last_event_time);
}

fn executeSwitch(wm: *WM, old_ws: u8, new_ws: u8) void {
    const s          = getState().?;
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info    = wm.fullscreen.getForWorkspace(new_ws);

    wm.suppress_focus_reason = .none;

    // Pre-fire the pointer query before the server grab.
    //
    // hideWorkspaceWindows + restoreWorkspaceWindows queue many configure_window
    // calls but perform no blocking round-trips themselves.  By the time
    // applyPostSwitchFocus consumes the reply it has been in-flight for the
    // entire duration of those operations and is already sitting in the receive
    // buffer — the round-trip cost is fully hidden behind the switch work.
    //
    // Both requests (query_pointer and grab_server) are sent together in the
    // same TCP segment on the first implicit flush, so grab_server is still
    // the first request the server acts on from a multi-client correctness
    // perspective (the server processes requests in sequence).
    const ptr_cookie = xcb.xcb_query_pointer(wm.conn, wm.root);

    _ = xcb.xcb_grab_server(wm.conn);

    hideWorkspaceWindows(wm, &s.workspaces[old_ws]);

    bar.setBarState(wm, if (fs_info != null) .hide_fullscreen else .show_fullscreen);

    if (fs_info) |info| {
        showFullscreenWindow(wm, info);
    } else {
        restoreWorkspaceWindows(wm, new_ws_obj);
    }

    applyPostSwitchFocus(wm, new_ws, new_ws_obj, ptr_cookie);

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

pub fn isManaged(win: u32) bool {
    return getWorkspaceForWindow(win) != null;
}
