//! Workspace management — creation, window assignment, and workspace switching.

const std          = @import("std");
const tracking     = @import("tracking");
const build_options = @import("build_options");
const fullscreen   = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const core         = @import("core");
const xcb          = core.xcb;
const utils        = @import("utils");
const focus        = @import("focus");
const window       = @import("window");
const bar          = @import("bar");
const has_tiling   = @import("build_options").has_tiling;
const tiling       = if (has_tiling) @import("tiling") else struct {};
const TilingLayout = if (has_tiling) tiling.Layout else u0;
const Tracking     = @import("tracking").Tracking;
const constants    = @import("constants");
const debug        = @import("debug");
const minimize     = if (build_options.has_minimize) @import("minimize") else struct {};

/// Shim so call-sites don't need to repeat the has_minimize comptime guard.
/// Returns false when minimize is absent — windows are never considered minimized.
inline fn isMinimized(win: u32) bool {
    return if (comptime build_options.has_minimize) minimize.isMinimized(win) else false;
}

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
    layout: TilingLayout,
    // Optional layout variants override set via the layouts array in config.
    // Applied on every workspace switch; null means use the global defaults.
    variants: ?core.LayoutVariantOverride = null,
    // Per-workspace master width override (master-stack layout).
    // null = use the global default from tiling state.
    // Set when the user adjusts master width in per-workspace layout mode;
    // loaded back into tiling state on every workspace switch-in.
    master_width: ?f32 = null,
    // Last window that held focus on this workspace before the user left it.
    // Restored on re-entry when the cursor is not hovering over any window.
    last_focused: ?u32 = null,

    pub fn init(id: u8, name: []const u8, default_layout: TilingLayout) Workspace {
        return .{ .id = id, .windows = .{}, .name = name, .layout = default_layout };
    }

    /// Removes `win` from this workspace and clears last_focused if it pointed to it.
    pub fn removeAndClearFocus(self: *Workspace, win: u32) void {
        _ = self.windows.remove(win);
        if (self.last_focused == win) self.last_focused = null;
    }
};

pub const State = struct {
    workspaces: []Workspace,
    current:    u8,
    allocator:  std.mem.Allocator,
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

/// Push `win` offscreen and evict its geometry cache entry.
/// Used when a window leaves the current workspace.
inline fn evictWindow(win: u32) void {
    pushOffscreen(core.conn, win);
    if (has_tiling) tiling.invalidateGeomCache(win);
}

/// Resolves a layout name (e.g. "master-stack", "monocle") to tiling.Layout.
fn layoutFromName(name: []const u8) TilingLayout {
    if (!has_tiling) return 0;
    return if (std.mem.eql(u8, name, "master-stack")) .master
        else std.meta.stringToEnum(tiling.Layout, name) orelse tiling.defaultLayout();
}

pub fn init() void {
    const count = core.config.workspaces.count;
    const wss = core.alloc.alloc(Workspace, count) catch {
        debug.err("Failed to allocate workspaces", .{});
        return;
    };

    const default_layout: TilingLayout = if (has_tiling) tiling.getState().layout else 0;
    const cfg_tiling = &core.config.tiling;

    for (wss, 0..) |*ws, i| {
        const id: u8 = @intCast(i);
        const name   = if (i < WORKSPACE_NAMES.len) WORKSPACE_NAMES[i] else "?";

        // Apply any workspace-specific layout + variants override from the
        // layouts array (e.g. `"monocle", "gapless", "4,8"` in config.toml).
        var ws_layout    = default_layout;
        var ws_variant: ?core.LayoutVariantOverride = null;
        if (has_tiling) {
            for (cfg_tiling.workspace_layout_overrides.items) |override| {
                if (override.workspace_idx == id) {
                    if (override.layout_idx < cfg_tiling.layouts.items.len) {
                        ws_layout = layoutFromName(cfg_tiling.layouts.items[override.layout_idx]);
                    }
                    ws_variant = override.variant;
                    break;
                }
            }
        }

        ws.* = Workspace.init(id, name, ws_layout);
        ws.variants = ws_variant;
    }

    tracking.setWorkspaceCount(count);
    tracking.setCurrentWorkspace(0);

    g_state = .{
        .workspaces = wss,
        .current    = 0,
        .allocator  = core.alloc,
    };
}

pub fn deinit() void {
    if (g_state) |*s| s.allocator.free(s.workspaces);
    g_state = null;
    tracking.setWorkspaceCount(1);
    tracking.setCurrentWorkspace(0);
}

pub fn removeWindow(win: u32) void {
    const s = getState() orelse {
        tracking.removeWindow(win);
        return;
    };
    if (tracking.getWindowWorkspaceMask(win)) |mask| {
        var it = setBits(mask);
        while (it.next()) |ws_idx| {
            if (ws_idx < s.workspaces.len)
                s.workspaces[ws_idx].removeAndClearFocus(win);
        }
    }
    tracking.removeWindow(win);
}

pub fn moveWindowTo(win: u32, target_ws: u8) !void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) {
        debug.err("Invalid target workspace: {}", .{target_ws});
        return;
    }

    const mask = tracking.getWindowWorkspaceMask(win) orelse {
        // Not yet tracked (new window): register in tracking and workspace list.
        try tracking.registerWindow(win, target_ws);
        s.workspaces[target_ws].windows.add(win);
        return;
    };

    const target_bit = workspaceBit(target_ws);
    if (mask == target_bit) return;

    const current = s.current;
    var new_mask = (mask & ~workspaceBit(current)) | target_bit;
    if (new_mask == 0) new_mask = target_bit; // safety: never leave mask empty

    s.workspaces[current].removeAndClearFocus(win);
    s.workspaces[target_ws].windows.add(win);
    tracking.setWindowMask(win, new_mask);

    if (isMinimized(win)) {
        if (comptime build_options.has_minimize) minimize.moveToWorkspace(win, target_ws);
    }

    evictWindow(win);
    if (focus.getFocused() == win) focus.clearFocus();
    if (has_tiling and core.config.tiling.enabled) tiling.dirty();
    bar.scheduleRedraw();
}

// Tag operations

/// Low-level: set a window's workspace bitmask and keep every workspace
/// Tracking consistent. Does NOT handle screen visibility or tiling.
fn setWindowMask(s: *State, win: u32, new_mask: u64) void {
    std.debug.assert(new_mask != 0);
    const old_mask = tracking.getWindowWorkspaceMask(win) orelse 0;
    tracking.setWindowMask(win, new_mask);

    // Add to newly-set workspaces.
    var added_it = setBits(new_mask & ~old_mask);
    while (added_it.next()) |idx| {
        if (idx < s.workspaces.len) s.workspaces[idx].windows.add(win);
    }

    // Remove from cleared workspaces.
    var removed_it = setBits(old_mask & ~new_mask);
    while (removed_it.next()) |idx| {
        if (idx < s.workspaces.len)
            s.workspaces[idx].removeAndClearFocus(win);
    }
}

/// `move_window` action — Mod+Shift+N. Hard-moves `win` to `target_ws` exclusively,
/// clearing all other workspace bits. Pair with tagToggle (Mod+Alt+N) to add more.
pub fn moveWindowExclusive(win: u32, target_ws: u8) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (isMinimized(win)) return;

    const mask = tracking.getWindowWorkspaceMask(win) orelse return;
    if (mask == workspaceBit(target_ws)) return; // already exclusively on target — no-op

    // Transfer fullscreen record to the target workspace so the window
    // remains fullscreen wherever it lands, not just on the source workspace.
    if (comptime build_options.has_fullscreen) {
        if (fullscreen.workspaceFor(win)) |src_ws| {
            const info = fullscreen.getForWorkspace(src_ws).?;
            fullscreen.removeForWorkspace(src_ws);
            fullscreen.setForWorkspace(target_ws, info);
        }
    }

    setWindowMask(s, win, workspaceBit(target_ws));

    if (target_ws != s.current) {
        evictWindow(win);
        if (focus.getFocused() == win) focus.clearFocus();
    }

    if (has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
    bar.scheduleRedraw();
    _ = xcb.xcb_flush(core.conn);
}

/// Toggle workspace tag N on `win` (Mod+Alt+N). Flips bit N in the window's mask;
/// focus is not changed so the user can tag multiple workspaces in one gesture.
/// When `protect_current` is true, adding a tag keeps the current workspace set too.
/// The last remaining workspace tag is always protected and cannot be cleared.
pub fn tagToggle(win: u32, target_ws: u8, protect_current: bool) void {
    const s = getState() orelse return;
    if (target_ws >= s.workspaces.len) return;
    if (isMinimized(win)) return;

    const current = s.current;
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;
    const tbit = workspaceBit(target_ws);

    if (mask & tbit != 0) {
        // Remove tag N.
        if (@popCount(mask) <= 1) return; // last workspace — protect
        setWindowMask(s, win, mask & ~tbit);
        if (target_ws == current) {
            // Window is leaving the current workspace; if it was fullscreen here
            // transfer the record to whichever workspace it still belongs to.
            if (comptime build_options.has_fullscreen) {
                if (fullscreen.workspaceFor(win)) |src_ws| {
                    if (src_ws == current) {
                        const info = fullscreen.getForWorkspace(src_ws).?;
                        fullscreen.removeForWorkspace(src_ws);
                        // Land on the lowest-set-bit workspace still in the new mask.
                        const new_mask = mask & ~tbit;
                        const dst: u8 = @intCast(@ctz(new_mask));
                        fullscreen.setForWorkspace(dst, info);
                    }
                }
            }
            evictWindow(win);
            if (has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
        } else {
            if (has_tiling) tiling.invalidateWsGeomBit(target_ws);
        }
    } else {
        // Add tag N. In protected mode, always keep the current workspace set too.
        const new_mask = if (protect_current) mask | tbit | workspaceBit(current) else mask | tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            _ = xcb.xcb_map_window(core.conn, win);
            if (has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
        } else {
            if (has_tiling) tiling.invalidateWsGeomBit(target_ws);
        }
    }

    bar.scheduleRedraw();
    _ = xcb.xcb_flush(core.conn);
}

// Workspace switch

pub fn switchTo(ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old = s.current;
    s.current = ws_id;
    tracking.setCurrentWorkspace(ws_id);
    executeSwitch(old, ws_id);
}

// Query helpers

/// Returns the workspace bitmask for `win`, or null if unmanaged.
/// Delegates to tracking which owns the map.
pub inline fn getWindowWorkspaceMask(win: u32) ?u64 {
    return tracking.getWindowWorkspaceMask(win);
}

/// True when workspace `ws_idx` is set in `win`'s tag bitmask.
pub inline fn isWindowOnWorkspace(win: u32, ws_idx: u8) bool {
    return tracking.isWindowOnWorkspace(win, ws_idx);
}

/// Returns the first non-minimized window in `windows`, or null if all minimized.
pub inline fn firstNonMinimized(windows: []const u32) ?u32 {
    return tracking.firstNonMinimized(windows);
}

// Prefer the workspace's remembered focus target; fall back to firstNonMinimized.
inline fn lastFocusedOrFirst(ws: *const Workspace) ?u32 {
    if (ws.last_focused) |win|
        if (!isMinimized(win)) return win;
    return firstNonMinimized(ws.windows.items());
}

pub inline fn getCurrentWorkspace() ?u8 {
    return tracking.getCurrentWorkspace();
}

pub inline fn isOnCurrentWorkspace(win: u32) bool {
    return tracking.isOnCurrentWorkspace(win);
}

/// Returns true when `win` is on the current workspace and is not minimized.
///
/// The combined predicate used by focus.focusBestAvailable for post-unmanage
/// and post-minimize focus recovery.  Combining the two checks into one
/// function lets it serve as a typed *const fn(u32) bool without a closure.
pub fn isOnCurrentWorkspaceAndVisible(win: u32) bool {
    return tracking.isOnCurrentWorkspaceAndVisible(win);
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
pub inline fn getWorkspaceForWindow(win: u32) ?u8 {
    return tracking.getWorkspaceForWindow(win);
}

pub fn isManaged(win: u32) bool {
    return tracking.isManaged(win);
}

// Step 1: move old-workspace windows offscreen.
// Windows ALSO tagged to `new_ws` stay on screen — they're visible on both.
fn hideWorkspaceWindows(ws: *const Workspace, new_ws: u8) void {
    // Capped at 64 windows; beyond this limit geometry is not saved before offscreen move.
    const MAX_FLOAT = 64;
    var float_wins:    [MAX_FLOAT]u32                            = undefined;
    var float_cookies: [MAX_FLOAT]xcb.xcb_get_geometry_cookie_t = undefined;
    var float_n: usize = 0;

    for (ws.windows.items()) |win| {
        if (tracking.isWindowOnWorkspace(win, new_ws)) continue; // stays visible
        if ((!has_tiling or !tiling.isWindowActiveTiled(win)) and !isMinimized(win)) {
            if (float_n < MAX_FLOAT) {
                float_wins[float_n]    = win;
                float_cookies[float_n] = xcb.xcb_get_geometry(core.conn, win);
                float_n += 1;
            }
        }
    }

    // Consume geometry replies and push all leaving windows offscreen in one pass.
    var fi: usize = 0;
    for (ws.windows.items()) |win| {
        if (tracking.isWindowOnWorkspace(win, new_ws)) continue;
        if (fi < float_n and float_wins[fi] == win) {
            if (xcb.xcb_get_geometry_reply(core.conn, float_cookies[fi], null)) |geom| {
                defer std.c.free(geom);
                window.saveWindowGeom(win, .{
                    .x = geom.*.x, .y = geom.*.y,
                    .width = geom.*.width, .height = geom.*.height,
                });
            }
            fi += 1;
        }
        pushOffscreen(core.conn, win);
        if (has_tiling and tiling.isWindowActiveTiled(win)) tiling.invalidateGeomCache(win);
    }
}

// Step 3b: restore geometry for the new workspace.
fn restoreWorkspaceWindows(ws: *const Workspace, old_ws: u8) void {
    const tiling_active = has_tiling and tiling.getState().enabled;

    if (tiling_active) {
        if (!core.config.tiling.global_layout) tiling.syncLayoutFromWorkspace(ws);

        // Invalidate geometry for windows also on the old workspace —
        // their cache holds stale tiling positions from that workspace.
        for (ws.windows.items()) |win| {
            if (tiling.isWindowTiled(win) and tracking.isWindowOnWorkspace(win, old_ws))
                if (has_tiling) tiling.invalidateGeomCache(win);
        }

        if (!tiling.restoreWorkspaceGeom()) {
            for (ws.windows.items()) |win| {
                if (tiling.isWindowTiled(win)) if (has_tiling) tiling.invalidateGeomCache(win);
            }
            tiling.retileCurrentWorkspace();
        }
    } else if (has_tiling and tiling.isFloatingLayout()) {
        // Floating layout: the tiling engine is disabled for window management
        // but windows on inactive workspaces may have had their geometry cache
        // zeroed the last time they were left while tiling was still active.
        // Attempt a fast cache restore first; if that fails, run a silent retile
        // that bypasses the !s.enabled guard to recompute the correct tiled
        // positions without changing the active layout or moving any windows
        // permanently.
        if (!tiling.restoreWorkspaceGeom()) {
            tiling.retileForRestore();
        }
    }

    // Map every window; restore floating geometry for those not already on screen.
    const pos = utils.floatDefaultPos();
    for (ws.windows.items()) |win| {
        _ = xcb.xcb_map_window(core.conn, win);
        if ((!has_tiling or !tiling.isWindowActiveTiled(win)) and !isMinimized(win) and
            !tracking.isWindowOnWorkspace(win, old_ws))
        {
            var restored = false;
            if (window.getWindowGeom(win)) |rect| {
                utils.configureWindow(core.conn, win, rect);
                restored = true;
            }
            if (!restored) {
                _ = xcb.xcb_configure_window(core.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }
    }
}

// Step 4: resolve the post-switch focus target and apply it.
// Skips the mapped-check and stack raise that focus.setFocus would do —
// all windows are already mapped and workspace_switch never raises.
// `ptr_cookie` is pre-fired before the server grab to overlap the round-trip.
fn applyPostSwitchFocus(new_ws: u8, new_ws_obj: *const Workspace, ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const focus_target: ?u32 = blk: {
        const ptr = xcb.xcb_query_pointer_reply(core.conn, ptr_cookie, null)
            orelse break :blk lastFocusedOrFirst(new_ws_obj);
        defer std.c.free(ptr);
        const child = ptr.*.child;
        break :blk if (child != 0 and child != core.root and
            tracking.isWindowOnWorkspace(child, new_ws) and !isMinimized(child))
            child else lastFocusedOrFirst(new_ws_obj);
    };

    const old_focused = focus.getFocused();
    focus.setFocused(focus_target);

    window.updateFocusBorders(old_focused, focus_target);

    if (old_focused) |old_win| window.grabButtons(old_win, false);

    if (focus_target) |new_win| {
        window.grabButtons(new_win, true);

        const input_model = utils.getInputModelCached(core.conn, new_win);
        if (input_model == .locally_active or input_model == .globally_active) {
            utils.sendWMTakeFocus(core.conn, new_win, focus.getLastEventTime());
        }
    }

    _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        focus_target orelse core.root, focus.getLastEventTime());
}

fn executeSwitch(old_ws: u8, new_ws: u8) void {
    const s          = getState().?;
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info    = if (comptime build_options.has_fullscreen) fullscreen.getForWorkspace(new_ws) else null;

    focus.setSuppressReason(.none);
    s.workspaces[old_ws].last_focused = focus.getFocused();

    // Pre-fire before the grab so the round-trip overlaps with hide+restore.
    const ptr_cookie = xcb.xcb_query_pointer(core.conn, core.root);

    _ = xcb.xcb_grab_server(core.conn);

    hideWorkspaceWindows(&s.workspaces[old_ws], new_ws);

    bar.setBarState(if (fs_info != null) .hide_fullscreen else .show_fullscreen);

    if (fs_info) |info| {
        utils.configureWindowGeom(core.conn, info.window, .{
            .x = 0, .y = 0,
            .width        = @intCast(core.screen.width_in_pixels),
            .height       = @intCast(core.screen.height_in_pixels),
            .border_width = 0,
        });
        _ = xcb.xcb_configure_window(core.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        restoreWorkspaceWindows(new_ws_obj, old_ws);
    }

    applyPostSwitchFocus(new_ws, new_ws_obj, ptr_cookie);

    bar.raiseBar();
    bar.redrawInsideGrab();
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}
