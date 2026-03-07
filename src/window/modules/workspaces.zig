//! Workspace management — creation, window assignment, and workspace switching.

const std        = @import("std");
const fullscreen = @import("fullscreen");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const focus      = @import("focus");
const window     = @import("window");
const bar        = @import("bar");
const tiling     = @import("tiling");
const Tracking   = @import("tracking").Tracking;
const constants  = @import("constants");
const debug      = @import("debug");
const minimize   = @import("minimize");

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
    // Per-workspace master width override (master-stack layout).
    // null = use the global default from tiling state.
    // Set when the user adjusts master width in per-workspace layout mode;
    // loaded back into tiling state on every workspace switch-in.
    master_width: ?f32 = null,
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

    /// Removes `win` from this workspace and clears last_focused if it pointed to it.
    pub fn removeAndClearFocus(self: *Workspace, win: u32) void {
        _ = self.windows.remove(win);
        if (self.last_focused == win) self.last_focused = null;
    }
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

pub inline fn getState() ?*State { return if (g_state) |*s| s else null; }

/// Returns the bitmask with only the bit for `ws_idx` set.
inline fn workspaceBit(ws_idx: u8) u64 { return @as(u64, 1) << @intCast(ws_idx); }

/// Yields the index of each set bit in `mask`, lowest first.
const SetBitIterator = struct {
    bits: u64,
    pub fn next(self: *SetBitIterator) ?u8 {
        if (self.bits == 0) return null;
        const idx: u8 = @intCast(@ctz(self.bits));
        self.bits &= self.bits - 1;
        return idx;
    }
};
inline fn setBits(mask: u64) SetBitIterator { return .{ .bits = mask }; }

/// Moves `win` to the offscreen holding area (outside visible display bounds).
inline fn pushOffscreen(conn: *xcb.xcb_connection_t, win: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_X,
        &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
}

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

    const default_layout = tiling.getState().layout;

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
    w2ws.ensureTotalCapacity(32) catch |err| debug.err("workspaces: capacity pre-alloc failed: {}", .{err});

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
        var it = setBits(entry.value);
        while (it.next()) |ws_idx| {
            if (ws_idx < s.workspaces.len)
                s.workspaces[ws_idx].removeAndClearFocus(win);
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
        try s.window_to_workspaces.ensureUnusedCapacity(1);
        try s.workspaces[target_ws].add(win);
        s.window_to_workspaces.putAssumeCapacity(win, workspaceBit(target_ws));
        return;
    };

    const target_bit = workspaceBit(target_ws);
    if (mask == target_bit) return;

    const current     = s.current;
    var new_mask = (mask & ~workspaceBit(current)) | target_bit;
    if (new_mask == 0) new_mask = target_bit; // safety: never leave mask empty

    s.workspaces[current].removeAndClearFocus(win);
    s.workspaces[target_ws].add(win) catch |err| {
        s.workspaces[current].add(win) catch unreachable;
        return err;
    };
    s.window_to_workspaces.getPtr(win).?.* = new_mask;

    if (minimize.isMinimized(wm, win)) minimize.moveToWorkspace(wm, win, target_ws);

    pushOffscreen(wm.conn, win);
    if (focus.getFocused() == win) focus.clearFocus(wm);
    if (wm.config.tiling.enabled) tiling.dirty();
    tiling.invalidateGeomCache(win);
    bar.scheduleRedraw();
}

// Tag operations

/// Low-level: set a window's workspace bitmask and keep every workspace
/// Tracking consistent. Does NOT handle screen visibility or tiling.
fn setWindowMask(s: *State, win: u32, new_mask: u64) void {
    std.debug.assert(new_mask != 0);
    const ptr = s.window_to_workspaces.getPtr(win).?;
    const old_mask = ptr.*;
    ptr.* = new_mask;

    // Add to newly-set workspaces.
    var added_it = setBits(new_mask & ~old_mask);
    while (added_it.next()) |idx| {
        if (idx < s.workspaces.len) s.workspaces[idx].add(win) catch {};
    }

    // Remove from cleared workspaces.
    var removed_it = setBits(old_mask & ~new_mask);
    while (removed_it.next()) |idx| {
        if (idx < s.workspaces.len)
            s.workspaces[idx].removeAndClearFocus(win);
    }
}

/// `move_window` action — Mod+Shift+N.
///
/// Hard-moves `win` to `target_ws` exclusively: clears ALL workspace bits
/// and sets only the target. Unlike moveWindowTo, no other workspace tags
/// are preserved — the window ends up on exactly one workspace.
///
/// Visibility:
///   target == current → window stays on screen, current workspace retiled.
///   target != current → window pushed offscreen, focus cleared if needed.
///
/// Pair with tag_toggle (Mod+Alt+N) to accumulate extra workspaces after
/// the initial move.
pub fn moveWindowExclusive(wm: *WM, win: u32, target_ws: u8) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (minimize.isMinimized(wm, win)) return;

    const mask = s.window_to_workspaces.get(win) orelse return;
    if (mask == workspaceBit(target_ws)) return; // already exclusively on target — no-op

    setWindowMask(s, win, workspaceBit(target_ws));

    if (target_ws != s.current) {
        pushOffscreen(wm.conn, win);
        tiling.invalidateGeomCache(win);
        if (focus.getFocused() == win) focus.clearFocus(wm);
    }

    if (wm.config.tiling.enabled) tiling.retileCurrentWorkspace(wm);
    bar.scheduleRedraw();
    _ = xcb.xcb_flush(wm.conn);
}

/// Toggle workspace tag N on `win`.
///
/// Flips bit N in the window's mask. Focus is intentionally NOT changed so
/// the user can hold Mod and press 2, 3, 4 to tag/untag multiple workspaces
/// without losing track of which window they're operating on.
///
/// `protect_current` (Mod+Alt+N / tag_additive):
///   When true, the current workspace bit can never be cleared, and adding a
///   tag always keeps the current workspace set too. Use this to copy a window
///   to other workspaces while keeping it visible where you are.
///
/// • Bit N set   → clear it (window leaves N). If N == current and unprotected,
///                 pushed offscreen. If protected, no-op.
/// • Bit N clear → set it  (window gains N). Silently added to inactive workspace.
/// • Last workspace is always protected: cannot clear the final bit.
pub fn tagToggle(wm: *WM, win: u32, target_ws: u8, protect_current: bool) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (minimize.isMinimized(wm, win)) return;

    const current = s.current;
    const mask = s.window_to_workspaces.get(win) orelse return;
    const tbit = workspaceBit(target_ws);

    if (mask & tbit != 0) {
        // Remove tag N.
        if (protect_current and target_ws == current) return;
        if (@popCount(mask) <= 1) return; // last workspace — protect
        setWindowMask(s, win, mask & ~tbit);
        if (target_ws == current) {
            pushOffscreen(wm.conn, win);
            tiling.invalidateGeomCache(win);
            if (wm.config.tiling.enabled) tiling.retileCurrentWorkspace(wm);
        } else {
            tiling.invalidateWsGeomBit(target_ws);
        }
    } else {
        // Add tag N. In protected mode, always keep the current workspace set too.
        const new_mask = if (protect_current) mask | tbit | workspaceBit(current) else mask | tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            _ = xcb.xcb_map_window(wm.conn, win);
            if (wm.config.tiling.enabled) tiling.retileCurrentWorkspace(wm);
        } else {
            tiling.invalidateWsGeomBit(target_ws);
        }
    }

    bar.scheduleRedraw();
    _ = xcb.xcb_flush(wm.conn);
}

// Workspace switch

pub fn switchTo(wm: *WM, ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old = s.current;
    s.current = ws_id;
    executeSwitch(wm, old, ws_id);
}

// Query helpers

/// Returns the workspace bitmask for `win`, or null if unmanaged.
pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    const s = getState() orelse return null;
    return s.window_to_workspaces.get(win);
}

/// True when workspace `ws_idx` is set in `win`'s tag bitmask.
pub inline fn isWindowOnWorkspace(win: u32, ws_idx: u8) bool {
    const mask = getWindowWorkspaceMask(win) orelse return false;
    if (ws_idx >= 64) return false;
    return (mask >> @intCast(ws_idx)) & 1 != 0;
}

/// Returns the first non-minimized window in `windows`, or null if all are minimized.
pub inline fn firstNonMinimized(wm: *const WM, windows: []const u32) ?u32 {
    for (windows) |win| {
        if (!minimize.isMinimized(wm, win)) return win;
    }
    return null;
}

// Prefer the workspace's remembered focus target; fall back to firstNonMinimized.
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
    return @intCast(@ctz(mask));
}

pub fn isManaged(win: u32) bool {
    return getWindowWorkspaceMask(win) != null;
}

// Step 1: move old-workspace windows offscreen.
// Windows ALSO tagged to `new_ws` stay on screen — they're visible on both.
fn hideWorkspaceWindows(wm: *WM, ws: *const Workspace, new_ws: u8) void {
    // Capped at 64: covers the realistic upper bound for a single workspace.
    // Windows beyond this limit are moved offscreen without geometry save.
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

    // All cookies are fired above; consume replies and move windows offscreen
    // in one combined pass. Cursor `fi` advances only for float windows,
    // matching each to its cookie without an extra lookup.
    var fi: usize = 0;
    for (ws.windows.items()) |win| {
        if (isWindowOnWorkspace(win, new_ws)) continue;
        if (fi < float_n and float_wins[fi] == win) {
            if (xcb.xcb_get_geometry_reply(wm.conn, float_cookies[fi], null)) |geom| {
                defer std.c.free(geom);
                tiling.saveWindowGeom(win, .{
                    .x = geom.*.x, .y = geom.*.y,
                    .width = geom.*.width, .height = geom.*.height,
                });
            }
            fi += 1;
        }
        pushOffscreen(wm.conn, win);
        if (tiling.isWindowTiled(win)) tiling.invalidateGeomCache(win);
    }
}

// Step 3b: restore geometry for the new workspace.
fn restoreWorkspaceWindows(wm: *WM, ws: *const Workspace, old_ws: u8) void {
    const tiling_active = tiling.getState().enabled;

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

    // Single pass: map every window and restore floating geometry for windows
    // not already on screen. Both are fire-and-forget XCB writes with no
    // ordering dependency between them, so no separate map loop is needed.
    const pos = utils.floatDefaultPos(wm);
    for (ws.windows.items()) |win| {
        _ = xcb.xcb_map_window(wm.conn, win);
        if (!tiling.isWindowTiled(win) and !minimize.isMinimized(wm, win) and
            !isWindowOnWorkspace(win, old_ws))
        {
            if (tiling.getWindowGeom(win)) |rect| {
                utils.configureWindow(wm.conn, win, rect);
            } else {
                _ = xcb.xcb_configure_window(wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }
    }
}

// Step 4: resolve the post-switch focus target and apply it.
//
// Inlines the focus logic rather than calling focus.setFocus to avoid the
// blocking xcb_get_window_attributes mapped-check — all windows on the new
// workspace were mapped by restoreWorkspaceWindows moments earlier.
// The stack raise is also omitted (workspace_switch never raises).
//
// `ptr_cookie` is pre-fired by executeSwitch before the server grab so that
// the round-trip overlaps with hideWorkspaceWindows + restoreWorkspaceWindows.
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

    const old_focused = focus.getFocused();
    focus.setFocused(focus_target);

    tiling.updateWindowFocus(wm, old_focused, focus.getFocused());

    if (old_focused) |old_win| window.grabButtons(wm, old_win, false);

    if (focus.getFocused()) |new_win| {
        window.grabButtons(wm, new_win, true);

        const input_model = utils.getInputModelCached(wm.conn, new_win);
        if (input_model == .locally_active or input_model == .globally_active) {
            utils.sendWMTakeFocus(wm.conn, new_win, focus.getLastEventTime());
        }
    }

    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        focus.getFocused() orelse wm.root, focus.getLastEventTime());
}

fn executeSwitch(wm: *WM, old_ws: u8, new_ws: u8) void {
    const s          = getState().?;
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info    = fullscreen.getForWorkspace(new_ws);

    focus.setSuppressReason(.none);

    // Remember which window had focus on the outgoing workspace.
    s.workspaces[old_ws].last_focused = focus.getFocused();

    // Pre-fire the pointer query before the server grab so the round-trip
    // overlaps with hideWorkspaceWindows + restoreWorkspaceWindows.
    const ptr_cookie = xcb.xcb_query_pointer(wm.conn, wm.root);

    _ = xcb.xcb_grab_server(wm.conn);

    hideWorkspaceWindows(wm, &s.workspaces[old_ws], new_ws);

    bar.setBarState(wm, if (fs_info != null) .hide_fullscreen else .show_fullscreen);

    if (fs_info) |info| {
        utils.configureWindowGeom(wm.conn, info.window, .{
            .x = 0, .y = 0,
            .width        = @intCast(wm.screen.width_in_pixels),
            .height       = @intCast(wm.screen.height_in_pixels),
            .border_width = 0,
        });
        _ = xcb.xcb_configure_window(wm.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        restoreWorkspaceWindows(wm, new_ws_obj, old_ws);
    }

    applyPostSwitchFocus(wm, new_ws, new_ws_obj, ptr_cookie);

    bar.raiseBar();
    bar.redrawInsideGrab(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    _ = xcb.xcb_flush(wm.conn);
}
