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
    // Last window that held focus on this workspace before the user left it.
    // Restored on re-entry when the cursor is not hovering over any window.
    last_focused: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, id: u8, name: []const u8, default_layout: tiling.Layout) Workspace {
        return .{ .id = id, .windows = Tracking.init(allocator), .name = name, .layout = default_layout };
    }

    pub fn deinit(self: *Workspace) void { self.windows.deinit(); }

    pub inline fn contains(self: *const Workspace, win: u32) bool { return self.windows.contains(win); }
    pub inline fn add(self: *Workspace, win: u32)  !void  { try self.windows.add(win); }
    pub inline fn remove(self: *Workspace, win: u32) bool { return self.windows.remove(win); }
};

pub const State = struct {
    workspaces:           []Workspace,
    current:              u8,
    /// Maps each managed window to a u64 bitmask of workspaces it belongs to.
    /// Bit N is set when the window is tagged to workspace N (0-indexed).
    /// A window must always have at least one bit set while managed.
    window_to_workspaces: std.AutoHashMap(u32, u64),
    allocator:            std.mem.Allocator,
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

    var w2ws = std.AutoHashMap(u32, u64).init(wm.allocator);
    w2ws.ensureTotalCapacity(32) catch {};

    g_state = .{
        .workspaces           = wss,
        .current              = 0,
        .window_to_workspaces = w2ws,
        .allocator            = wm.allocator,
    };
}

pub fn deinit() void {
    if (g_state) |*s| {
        for (s.workspaces) |*ws| ws.deinit();
        s.allocator.free(s.workspaces);
        s.window_to_workspaces.deinit();
    }
    g_state = null;
}

pub fn removeWindow(win: u32) void {
    const s = getState() orelse return;
    if (s.window_to_workspaces.fetchRemove(win)) |entry| {
        // Remove from every workspace Tracking the window belonged to.
        var remaining = entry.value;
        while (remaining != 0) {
            const ws_idx: u8 = @intCast(@ctz(remaining));
            remaining &= remaining - 1;
            if (ws_idx < s.workspaces.len) {
                _ = s.workspaces[ws_idx].remove(win);
                if (s.workspaces[ws_idx].last_focused == win)
                    s.workspaces[ws_idx].last_focused = null;
            }
        }
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: u8) !void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) {
        debug.err("Invalid target workspace: {}", .{target_ws});
        return;
    }

    const mask = s.window_to_workspaces.get(win) orelse {
        // Not yet tracked (new window): add directly to target workspace.
        // This is the common case — a window spawning on the current workspace.
        try s.window_to_workspaces.ensureUnusedCapacity(1);
        try s.workspaces[target_ws].add(win);
        const target_bit: u64 = @as(u64, 1) << @intCast(target_ws);
        s.window_to_workspaces.putAssumeCapacity(win, target_bit);
        return;
    };

    // Already tracked. Check if already on target and nowhere else — no-op.
    const target_bit: u64 = @as(u64, 1) << @intCast(target_ws);
    if (mask == target_bit) return;

    const current     = s.current;
    const current_bit: u64 = @as(u64, 1) << @intCast(current);
    var new_mask = (mask & ~current_bit) | target_bit;
    if (new_mask == 0) new_mask = target_bit; // safety: never leave mask empty

    try s.window_to_workspaces.ensureUnusedCapacity(1);
    _ = s.workspaces[current].remove(win);
    if (s.workspaces[current].last_focused == win) s.workspaces[current].last_focused = null;
    s.workspaces[target_ws].add(win) catch |err| {
        s.workspaces[current].add(win) catch {};
        return err;
    };
    s.window_to_workspaces.putAssumeCapacity(win, new_mask);

    if (minimize.isMinimized(wm, win)) minimize.moveToWorkspace(wm, win, target_ws);

    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
    if (wm.focused_window == win) focus.clearFocus(wm);
    if (wm.config.tiling.enabled) tiling.dirty();
    tiling.invalidateGeomCache(win);
    bar.markDirty();
}

// ── Tag operations ────────────────────────────────────────────────────────────

/// Low-level: set a window's workspace bitmask and keep every workspace
/// Tracking consistent. Does NOT handle screen visibility or tiling.
fn setWindowMask(s: *State, win: u32, new_mask: u64) void {
    std.debug.assert(new_mask != 0);
    const old_mask = s.window_to_workspaces.get(win) orelse 0;
    s.window_to_workspaces.put(win, new_mask) catch return;

    // Add to newly-set workspaces.
    var added = new_mask & ~old_mask;
    while (added != 0) {
        const idx: u8 = @intCast(@ctz(added));
        added &= added - 1;
        if (idx < s.workspaces.len) s.workspaces[idx].add(win) catch {};
    }

    // Remove from cleared workspaces.
    var removed = old_mask & ~new_mask;
    while (removed != 0) {
        const idx: u8 = @intCast(@ctz(removed));
        removed &= removed - 1;
        if (idx < s.workspaces.len) {
            _ = s.workspaces[idx].remove(win);
            if (s.workspaces[idx].last_focused == win)
                s.workspaces[idx].last_focused = null;
        }
    }
}

/// Mod+Shift+N: toggle workspace tag N on the focused window.
///
/// • If window IS on N   → remove tag N (unless it's the only workspace).
/// • If window NOT on N  → remove from current workspace, add N.
///   (If N == current, both paths behave identically as a pure toggle.)
pub fn tagToggle(wm: *WM, win: u32, target_ws: u8) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (minimize.isMinimized(wm, win)) return;

    const current = s.current;
    const mask    = s.window_to_workspaces.get(win) orelse return;
    const tbit:  u64 = @as(u64, 1) << @intCast(target_ws);
    const cbit:  u64 = @as(u64, 1) << @intCast(current);

    if (mask & tbit != 0) {
        // Window already on target: toggle it off.
        if (@popCount(mask) <= 1) return; // last workspace — do nothing
        const new_mask = mask & ~tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            // Window leaving the visible workspace.
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            tiling.invalidateGeomCache(win);
            if (wm.focused_window == win) minimize.focusBestAvailable(wm);
            if (wm.config.tiling.enabled) tiling.retileCurrentWorkspace(wm);
        } else {
            // Window removed from an inactive workspace: just invalidate its cache there.
            tiling.invalidateWsGeomBit(target_ws);
        }
    } else {
        // Window not on target: move it there (remove from current, add to target).
        var new_mask = mask | tbit;
        if (target_ws != current and (mask & cbit) != 0) {
            new_mask &= ~cbit; // remove from current when sending elsewhere
        }
        if (new_mask == 0) new_mask = tbit; // safety
        setWindowMask(s, win, new_mask);
        if (target_ws != current) {
            // Window moving away from the current view.
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            tiling.invalidateGeomCache(win);
            if (wm.focused_window == win) minimize.focusBestAvailable(wm);
            if (wm.config.tiling.enabled) tiling.retileCurrentWorkspace(wm);
        }
        // If target == current: adding to a workspace you're already viewing is a
        // no-op visually (the window is already on screen).
    }

    bar.markDirty();
    utils.flush(wm.conn);
}

/// Mod+Alt+N: toggle workspace tag N on the focused window, additive style.
///
/// • If window IS on N   → same as tagToggle (remove N, if count > 1).
/// • If window NOT on N  → add N while keeping the current workspace too.
pub fn tagAdditive(wm: *WM, win: u32, target_ws: u8) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (minimize.isMinimized(wm, win)) return;

    const current = s.current;
    const mask    = s.window_to_workspaces.get(win) orelse return;
    const tbit: u64 = @as(u64, 1) << @intCast(target_ws);

    if (mask & tbit != 0) {
        // Already on target: toggle off (same logic as tagToggle removal path).
        if (@popCount(mask) <= 1) return;
        const new_mask = mask & ~tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            tiling.invalidateGeomCache(win);
            if (wm.focused_window == win) minimize.focusBestAvailable(wm);
            if (wm.config.tiling.enabled) tiling.retileCurrentWorkspace(wm);
        } else {
            tiling.invalidateWsGeomBit(target_ws);
        }
    } else {
        // Not on target: add it without removing current.
        const new_mask = mask | tbit;
        setWindowMask(s, win, new_mask);
        // Window stays on screen (still on current). Only the target workspace's
        // layout cache needs invalidation.
        if (target_ws != current) {
            tiling.invalidateWsGeomBit(target_ws);
        }
        // If target == current: window wasn't on current (shouldn't normally happen
        // for a focused window) — just add it, no visibility change needed.
    }

    bar.markDirty();
    utils.flush(wm.conn);
}

// ── Workspace switch ──────────────────────────────────────────────────────────

pub fn switchTo(wm: *WM, ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old = s.current;
    s.current = ws_id;
    executeSwitch(wm, old, ws_id);
}

// ── Query helpers ─────────────────────────────────────────────────────────────

/// Returns the workspace bitmask for `win`, or null if unmanaged.
pub fn getWindowWorkspaceMask(win: u32) ?u64 {
    const s = getState() orelse return null;
    return s.window_to_workspaces.get(win);
}

/// True when workspace `ws_idx` is set in `win`'s tag bitmask.
pub fn isWindowOnWorkspace(win: u32, ws_idx: u8) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    if (ws_idx >= 64) return false;
    return (mask >> @intCast(ws_idx)) & 1 != 0;
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

// Prefer the workspace's remembered focus target; fall back to firstNonMinimized.
// Used by applyPostSwitchFocus when the cursor is not over a window.
inline fn lastFocusedOrFirst(wm: *const WM, ws: *const Workspace) ?u32 {
    if (ws.last_focused) |win|
        if (!minimize.isMinimized(wm, win)) return win;
    return firstNonMinimized(wm, ws.windows.items());
}

pub inline fn getCurrentWorkspace() ?u8 {
    const s = getState() orelse return null;
    return s.current;
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    const s = getState() orelse return false;
    return isWindowOnWorkspace(win, s.current);
}

pub inline fn getCurrentWorkspaceObject() ?*Workspace {
    const s = getState() orelse return null;
    return &s.workspaces[s.current];
}

pub inline fn getWorkspaceCount() usize {
    const s = getState() orelse return 0;
    return s.workspaces.len;
}

/// Returns the lowest-set-bit workspace index for `win`.
/// Used by code that needs a single canonical workspace (e.g. tiling bucket).
pub inline fn getWorkspaceForWindow(win: u32) ?u8 {
    const mask = getWindowWorkspaceMask(win) orelse return null;
    if (mask == 0) return null;
    return @intCast(@ctz(mask));
}

pub fn isManaged(win: u32) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    return mask != 0;
}
// Step 1: move old-workspace windows offscreen.
// Windows ALSO tagged to `new_ws` stay on screen — they're visible on both.
fn hideWorkspaceWindows(wm: *WM, ws: *const Workspace, new_ws: u8) void {
    const MAX_FLOAT = 64;
    var float_wins:    [MAX_FLOAT]u32                            = undefined;
    var float_cookies: [MAX_FLOAT]xcb.xcb_get_geometry_cookie_t = undefined;
    var float_n: usize = 0;

    for (ws.windows.items()) |win| {
        if (isWindowOnWorkspace(win, new_ws)) continue; // stays visible
        if (!tiling.isWindowTiled(win) and !minimize.isMinimized(wm, win)) {
            if (float_n < MAX_FLOAT) {
                float_wins[float_n]    = win;
                float_cookies[float_n] = xcb.xcb_get_geometry(wm.conn, win);
                float_n += 1;
            }
        }
    }

    for (float_wins[0..float_n], float_cookies[0..float_n]) |win, cookie| {
        const geom = xcb.xcb_get_geometry_reply(wm.conn, cookie, null) orelse continue;
        defer std.c.free(geom);
        tiling.saveWindowGeom(win, .{
            .x = geom.*.x, .y = geom.*.y,
            .width = geom.*.width, .height = geom.*.height,
        });
    }

    for (ws.windows.items()) |win| {
        if (isWindowOnWorkspace(win, new_ws)) continue; // stay on screen
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
        // Invalidate tiled windows; floating windows keep their saved geometry.
        if (tiling.isWindowTiled(win)) tiling.invalidateGeomCache(win);
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

// Step 3b: restore geometry for the new workspace.
// `old_ws`: the workspace we just left, so we can skip windows already on screen.
fn restoreWorkspaceWindows(wm: *WM, ws: *const Workspace, old_ws: u8) void {
    for (ws.windows.items()) |win| _ = xcb.xcb_map_window(wm.conn, win);

    const tiling_active = if (tiling.getState()) |t| t.enabled else false;

    if (tiling_active) {
        if (!wm.config.tiling.global_layout) tiling.syncLayoutFromWorkspace(ws);

        // Invalidate geometry for windows that were also on the old workspace —
        // their cache holds old-workspace tiling positions which are now stale.
        for (ws.windows.items()) |win| {
            if (tiling.isWindowTiled(win) and isWindowOnWorkspace(win, old_ws))
                tiling.invalidateGeomCache(win);
        }

        if (!tiling.restoreWorkspaceGeom(wm)) {
            for (ws.windows.items()) |win| {
                if (tiling.isWindowTiled(win)) tiling.invalidateGeomCache(win);
            }
            tiling.retileCurrentWorkspace(wm);
        }
    }

    // Restore floating windows that were NOT already on screen.
    const pos = utils.floatDefaultPos(wm);
    for (ws.windows.items()) |win| {
        if (tiling.isWindowTiled(win)) continue;
        if (minimize.isMinimized(wm, win)) continue;
        if (isWindowOnWorkspace(win, old_ws)) continue; // already on screen
        if (tiling.getWindowGeom(win)) |rect| {
            utils.configureWindow(wm.conn, win, rect);
        } else {
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
    const focus_target: ?u32 = blk: {
        const ptr = xcb.xcb_query_pointer_reply(wm.conn, ptr_cookie, null)
            orelse break :blk lastFocusedOrFirst(wm, new_ws_obj);
        defer std.c.free(ptr);

        const child = ptr.*.child;
        if (child != 0 and child != wm.root and
            isWindowOnWorkspace(child, new_ws) and
            !minimize.isMinimized(wm, child))
        {
            break :blk child;
        }
        break :blk lastFocusedOrFirst(wm, new_ws_obj);
    };

    const old_focused = wm.focused_window;
    wm.focused_window = focus_target;

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

    // Remember which window had focus on the outgoing workspace so it can be
    // restored if the cursor is not hovering over a window on return.
    s.workspaces[old_ws].last_focused = wm.focused_window;

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

    hideWorkspaceWindows(wm, &s.workspaces[old_ws], new_ws);

    bar.setBarState(wm, if (fs_info != null) .hide_fullscreen else .show_fullscreen);

    if (fs_info) |info| {
        showFullscreenWindow(wm, info);
    } else {
        restoreWorkspaceWindows(wm, new_ws_obj, old_ws);
    }

    applyPostSwitchFocus(wm, new_ws, new_ws_obj, ptr_cookie);

    bar.raiseBar();
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}


