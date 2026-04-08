//! Workspace management — creation, window assignment, and workspace switching.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const utils     = @import("utils");
const types     = @import("types");
const constants = @import("constants");

const debug = @import("debug");

const window   = @import("window");
const tracking = @import("tracking");
const focus    = @import("focus");

const fullscreen = if (build.has_fullscreen) @import("fullscreen") else struct {};
const minimize   = if (build.has_minimize) @import("minimize") else struct {};

const tiling       = if (build.has_tiling) @import("tiling") else struct {};
const TilingLayout = if (build.has_tiling) tiling.Layout else u0; //TODO: this and the previous line is confusing

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn scheduleRedraw() void {}
    pub fn raiseBar() void {}
    pub fn redrawInsideGrab() void {}
    pub fn setBarState(_: anytype) void {}
};


/// Shim so call-sites don't need to repeat the has_minimize comptime guard.
/// Returns false when minimize is absent — windows are never considered minimized.
inline fn isMinimized(win: u32) bool {
    return if (comptime build.has_minimize) minimize.isMinimized(win) else false;
}

pub const Workspace = struct {
    id:      u8,
    windows: tracking.Tracking,
    name:    []const u8,
    // The tiling layout active on this workspace.
    // Initialized from config; updated when the user switches layouts
    // in per-workspace mode.
    layout: TilingLayout,
    // Optional layout variants override set via the layouts array in config.
    // Applied on every workspace switch; null means use the global defaults.
    variants: ?types.LayoutVariantOverride = null,
    // Per-workspace master width override (master-stack layout).
    // null = use the global default from tiling state.
    // Set when the user adjusts master width in per-workspace layout mode;
    // loaded back into tiling state on every workspace switch-in.
    master_width: ?f32 = null,
    // Per-workspace master count override (master-stack layout).
    // null = use the global default from config / tiling state.
    // Populated at init from [tiling.layouts.master-stack.counts] and updated
    // when the user adjusts the count via keybind in per-workspace layout mode.
    master_count: ?u8 = null,
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
    /// Windows temporarily patched into the current workspace by switchToAll().
    /// Non-empty iff all-workspaces view is active.
    /// Cleared (and their bitmasks restored) on the next switchToAll() or switchTo().
    all_view_temp_wins: std.ArrayListUnmanaged(u32) = .empty,
};

var g_state: ?State = null;

pub inline fn getState() ?*State { return if (g_state) |*s| s else null; }

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

/// Push `win` offscreen and evict its geometry cache entry.
/// Used when a window leaves the current workspace.
inline fn evictWindow(win: u32) void {
    utils.pushWindowOffscreen(core.conn, win);
    if (build.has_tiling) tiling.invalidateGeomCache(win);
}

/// Resolves a layout name (e.g. "master-stack", "monocle") to tiling.Layout.
fn layoutFromName(name: []const u8) TilingLayout {
    if (!build.has_tiling) return 0;
    return if (std.mem.eql(u8, name, "master-stack")) .master
        else std.meta.stringToEnum(tiling.Layout, name) orelse tiling.defaultLayout();
}

/// Initializes global workspace state.  Returns error.OutOfMemory if the
/// workspace slice cannot be allocated; callers should treat this as fatal.
pub fn init() !void {
    const count = core.config.workspaces.count;
    const wss   = try core.alloc.alloc(Workspace, count);

    const default_layout: TilingLayout = if (build.has_tiling) tiling.getState().layout else 0;
    const cfg_tiling = &core.config.tiling;

    // Build a flat lookup table so each workspace's override is O(1) to find,
    // instead of the original O(overrides) inner-loop scan per workspace.
    // The u64 bitmask caps us at 64 workspaces, so a fixed-size array suffices.
    const MAX_WS = 64;
    const OverrideLookup = struct {
        layout_idx: usize,
        variant:    ?types.LayoutVariantOverride,
    };
    var override_lookup: [MAX_WS]?OverrideLookup = .{null} ** MAX_WS;
    if (build.has_tiling) {
        for (cfg_tiling.workspace_layout_overrides.items) |o| {
            if (o.workspace_idx < MAX_WS)
                override_lookup[o.workspace_idx] = .{
                    .layout_idx = o.layout_idx,
                    .variant    = o.variant,
                };
        }
    }

    // Per-workspace master count overrides from [tiling.layouts.master-stack.counts].
    var master_count_lookup: [MAX_WS]?u8 = .{null} ** MAX_WS;
    if (build.has_tiling) {
        for (cfg_tiling.workspace_master_count_overrides.items) |o| {
            if (o.workspace_idx < MAX_WS)
                master_count_lookup[o.workspace_idx] = o.count;
        }
    }

    for (wss, 0..) |*ws, i| {
        const id: u8 = @intCast(i);
        const name = if (i < tracking.WORKSPACE_LABELS.len) tracking.WORKSPACE_LABELS[i] else "?";

        // Apply any workspace-specific layout + variants override from the
        // layouts array (e.g. `"monocle", "gapless", "4,8"` in config.toml).
        var ws_layout   = default_layout;
        var ws_variant: ?types.LayoutVariantOverride = null;
        if (build.has_tiling) {
            if (override_lookup[id]) |o| {
                if (o.layout_idx < cfg_tiling.layouts.items.len)
                    ws_layout = layoutFromName(cfg_tiling.layouts.items[o.layout_idx]);
                ws_variant = o.variant;
            }
        }

        ws.* = Workspace.init(id, name, ws_layout);
        ws.variants = ws_variant;
        if (build.has_tiling) {
            if (master_count_lookup[id]) |mc| ws.master_count = mc;
        }
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
    if (g_state) |*s| {
        s.all_view_temp_wins.deinit(s.allocator);
        s.allocator.free(s.workspaces);
    }
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

    const target_bit = tracking.workspaceBit(target_ws);
    if (mask == target_bit) return;

    var new_mask = (mask & ~tracking.workspaceBit(s.current)) | target_bit;
    if (new_mask == 0) new_mask = target_bit; // safety: never leave mask empty

    // Route through setWindowMask so every workspace's window list stays in sync,
    // including any extra workspaces the window was tagged to beyond the current one.
    setWindowMask(s, win, new_mask);

    if (isMinimized(win)) {
        if (comptime build.has_minimize) minimize.moveToWorkspace(win, target_ws);
    }

    // If this window is fullscreen on the current workspace, clean up the
    // fullscreen side-effects on the source workspace (bar, floating windows,
    // border) and transfer the record to target_ws so the window is still
    // fullscreen when you switch there.
    if (comptime build.has_fullscreen) fs_blk: {
        const src_ws = fullscreen.workspaceFor(win) orelse break :fs_blk;
        if (src_ws != s.current) break :fs_blk;
        const info = fullscreen.getForWorkspace(src_ws).?;
        fullscreen.cleanupFullscreenForMove(win, src_ws);
        fullscreen.removeForWorkspace(src_ws);
        fullscreen.setForWorkspace(target_ws, info);
    }

    evictWindow(win);
    if (focus.getFocused() == win) focus.clearFocus();
    if (build.has_tiling and core.config.tiling.enabled) tiling.markDirty();
    bar.scheduleRedraw();
    _ = xcb.xcb_flush(core.conn);
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
    if (mask == tracking.workspaceBit(target_ws)) return; // already exclusively on target — no-op

    // Transfer fullscreen record to the target workspace so the window
    // remains fullscreen wherever it lands, not just on the source workspace.
    // When the window is actually leaving the current workspace (src_ws !=
    // target_ws), also run the cleanup that exitFullscreenCommit would have
    // done: restore the bar, bring back offscreen floating windows, and
    // restore the window's border. Without this the bar stays hidden on the
    // source workspace and floating peers remain invisible there indefinitely.
    if (comptime build.has_fullscreen) fs_blk: {
        const src_ws = fullscreen.workspaceFor(win) orelse break :fs_blk;
        if (src_ws != target_ws) fullscreen.cleanupFullscreenForMove(win, src_ws);
        const info = fullscreen.getForWorkspace(src_ws).?;
        fullscreen.removeForWorkspace(src_ws);
        fullscreen.setForWorkspace(target_ws, info);
    }

    setWindowMask(s, win, tracking.workspaceBit(target_ws));

    if (target_ws != s.current) {
        evictWindow(win);
        if (focus.getFocused() == win) focus.clearFocus();
    }

    if (build.has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
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
    const tbit = tracking.workspaceBit(target_ws);

    if (mask & tbit != 0) {
        // Remove tag N.
        if (@popCount(mask) <= 1) return; // last workspace — protect
        const new_mask = mask & ~tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            // Window is leaving the current workspace; if it was fullscreen here
            // transfer the record to whichever workspace it still belongs to.
            if (comptime build.has_fullscreen) {
                if (fullscreen.workspaceFor(win)) |src_ws| {
                    if (src_ws == current) {
                        const info = fullscreen.getForWorkspace(src_ws).?;
                        fullscreen.removeForWorkspace(src_ws);
                        // Land on the lowest-set-bit workspace still in the new mask.
                        const dst: u8 = @intCast(@ctz(new_mask));
                        fullscreen.setForWorkspace(dst, info);
                    }
                }
            }
            evictWindow(win);
            if (build.has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
        } else {
            if (build.has_tiling) tiling.invalidateWsGeomBit(target_ws);
        }
    } else {
        // Add tag N. In protected mode, always keep the current workspace set too.
        const new_mask = if (protect_current) mask | tbit | tracking.workspaceBit(current) else mask | tbit;
        setWindowMask(s, win, new_mask);
        if (target_ws == current) {
            _ = xcb.xcb_map_window(core.conn, win);
            if (build.has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
        } else {
            if (build.has_tiling) tiling.invalidateWsGeomBit(target_ws);
        }
    }

    bar.scheduleRedraw();
    _ = xcb.xcb_flush(core.conn);
}

// Workspace switch

pub fn switchTo(ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    exitAllWorkspacesView(s); // no-op when list is empty
    const old = s.current;
    s.current = ws_id;
    tracking.setCurrentWorkspace(ws_id);
    executeSwitch(old, ws_id);
}

/// Strips the current_ws bit from every window in `s.all_view_temp_wins`,
/// evicts each one, and clears the list.  No-op when the list is empty.
fn exitAllWorkspacesView(s: *State) void {
    if (s.all_view_temp_wins.items.len == 0) return;
    const current = s.current;
    for (s.all_view_temp_wins.items) |win| {
        const mask = tracking.getWindowWorkspaceMask(win) orelse continue;
        const restored = mask & ~tracking.workspaceBit(current);
        if (restored == 0) continue; // shouldn't happen, but never leave mask empty
        setWindowMask(s, win, restored);
        evictWindow(win);
    }
    s.all_view_temp_wins.clearRetainingCapacity();
}

/// `all_workspaces` action — Mod+5.
/// Toggles a view where every window from every workspace is visible at once.
///
/// Enter: for each non-minimized window not already on the current workspace,
///        adds the current-workspace bit to its tracking mask and appends it
///        to `all_view_temp_wins`.  With all windows genuinely on the current
///        workspace, `tiling.retileCurrentWorkspace()` tiles them normally.
///
/// Exit:  calls `exitAllWorkspacesView` which strips the temporary bit from
///        each saved window and evicts it, then retiles to restore normal layout.
pub fn switchToAll() void {
    const s = getState() orelse return;

    if (s.all_view_temp_wins.items.len > 0) {
        // Exit all-workspaces view 
        const ptr_cookie = xcb.xcb_query_pointer(core.conn, core.root);
        _ = xcb.xcb_grab_server(core.conn);

        exitAllWorkspacesView(s);

        if (build.has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
        applyPostSwitchFocus(s.current, &s.workspaces[s.current], ptr_cookie);
        bar.raiseBar();
        bar.redrawInsideGrab();
        utils.ungrabAndFlush(core.conn);
    } else {
        // Enter all-workspaces view 
        _ = xcb.xcb_grab_server(core.conn);

        for (s.workspaces) |*ws| {
            if (ws.id == s.current) continue;
            for (ws.windows.items()) |win| {
                if (tracking.isWindowOnWorkspace(win, s.current)) continue; // already here
                if (isMinimized(win)) continue;

                const mask = tracking.getWindowWorkspaceMask(win) orelse continue;
                // Patch the mask: window is now genuinely on the current workspace,
                // so tiling, focus, and every other subsystem sees it naturally.
                setWindowMask(s, win, mask | tracking.workspaceBit(s.current));
                s.all_view_temp_wins.append(s.allocator, win) catch {
                    // OOM: undo the mask patch so we stay consistent.
                    setWindowMask(s, win, mask);
                    continue;
                };
            }
        }

        // All foreign windows are now genuinely on the current workspace.
        // Retile handles mapping + positioning for tiled windows in one pass.
        if (build.has_tiling and core.config.tiling.enabled) {
            tiling.retileCurrentWorkspace();
        } else {
            // Floating layout: map and restore geometry manually.
            for (s.all_view_temp_wins.items) |win| {
                _ = xcb.xcb_map_window(core.conn, win);
                if (window.getWindowGeom(win)) |rect| {
                    utils.configureWindow(core.conn, win, rect);
                } else {
                    _ = xcb.xcb_configure_window(core.conn, win,
                        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                        &[_]u32{
                            @intCast(core.screen.width_in_pixels  / 4),
                            @intCast(core.screen.height_in_pixels / 4),
                        });
                }
            }
        }

        bar.scheduleRedraw();
        utils.ungrabAndFlush(core.conn);
    }
}

/// Common implementation for moveWindowToAll and tagToggleAll:
/// toggles a window between "pinned to every workspace" and "current workspace only".
fn pinToAllWorkspacesToggle(s: *State, win: u32) void {
    const all_mask = tracking.allWorkspacesMask(s.workspaces.len);
    const mask = tracking.getWindowWorkspaceMask(win) orelse return;

    if (mask == all_mask) {
        // Pinned everywhere — shrink back to current workspace only.
        setWindowMask(s, win, tracking.workspaceBit(s.current));
    } else {
        // Pin to every workspace.
        setWindowMask(s, win, all_mask);
        _ = xcb.xcb_map_window(core.conn, win);
    }

    if (build.has_tiling and core.config.tiling.enabled) tiling.retileCurrentWorkspace();
    bar.scheduleRedraw();
    _ = xcb.xcb_flush(core.conn);
}

/// `move_to_all_workspaces` action — Mod+Shift+5.
/// Toggles the focused window between pinned-to-all-workspaces and current-workspace-only.
/// First press: sets all workspace bits — the window appears on every workspace.
/// Second press: clears back to just the current workspace bit.
pub fn moveWindowToAll(win: u32) void {
    const s = getState() orelse return;
    if (isMinimized(win)) return;
    pinToAllWorkspacesToggle(s, win);
}

/// `toggle_tag_all` action — Mod+Alt+5.
/// Flips between "pinned to every workspace" and "current workspace only".
pub fn tagToggleAll(win: u32) void {
    const s = getState() orelse return;
    if (isMinimized(win)) return;
    pinToAllWorkspacesToggle(s, win);
}

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
// Clears last_focused when it refers to a minimized window so the stale pointer
// is not rechecked on every subsequent call.
inline fn lastFocusedOrFirst(ws: *Workspace) ?u32 {
    if (ws.last_focused) |win| {
        if (!isMinimized(win)) return win;
        ws.last_focused = null; // stale — clear so future calls skip it
    }
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

// Step 1 (of the workspace-switch pipeline): move old-workspace windows offscreen.
// Windows ALSO tagged to `new_ws` stay on screen — they're visible on both.
// Steps 2/3a are performed inside tiling.applyWorkspaceLayout and
// tiling.restoreWorkspaceGeom, called from restoreWorkspaceWindows below.
fn hideWorkspaceWindows(ws: *const Workspace, new_ws: u8) void {
    // For each floating window leaving this workspace we need to save its geometry
    // before it is pushed offscreen.  We fire all XCB geometry requests up-front,
    // push every window offscreen in the same pass, then consume all replies by
    // index — eliminating the iteration-order dependency of the old two-pass design.
    // Windows beyond MAX_FLOAT still go offscreen; they just lose their saved geom.
    const MAX_FLOAT = 64;
    const GeomEntry = struct { win: u32, cookie: xcb.xcb_get_geometry_cookie_t };
    var pending:   [MAX_FLOAT]GeomEntry = undefined;
    var pending_n: usize                = 0;

    for (ws.windows.items()) |win| {
        if (tracking.isWindowOnWorkspace(win, new_ws)) continue; // stays visible

        if ((!build.has_tiling or !tiling.isWindowActiveTiled(win)) and !isMinimized(win)) {
            if (pending_n < MAX_FLOAT) {
                pending[pending_n] = .{ .win = win, .cookie = xcb.xcb_get_geometry(core.conn, win) };
                pending_n += 1;
            } else {
                // Warn exactly once — when the first window is being skipped,
                // not when the last slot is filled (Issue: cap warning per-window).
                if (pending_n == MAX_FLOAT) {
                    debug.warn("hideWorkspaceWindows: geometry-save cap ({d}) reached; " ++
                        "additional floating windows will not have geometry saved", .{MAX_FLOAT});
                    pending_n += 1; // advance past MAX_FLOAT so the warning fires only once
                }
            }
        }

        utils.pushWindowOffscreen(core.conn, win);
        if (build.has_tiling and tiling.isWindowActiveTiled(win)) tiling.invalidateGeomCache(win);
    }

    // Consume geometry replies by index — independent of window iteration order.
    for (pending[0..pending_n]) |e| {
        if (xcb.xcb_get_geometry_reply(core.conn, e.cookie, null)) |geom| {
            defer std.c.free(geom);
            window.saveWindowGeom(e.win, .{
                .x = geom.*.x, .y = geom.*.y,
                .width = geom.*.width, .height = geom.*.height,
            });
        }
    }
}

// Step 3b: restore geometry for the new workspace.
fn restoreWorkspaceWindows(ws: *const Workspace, old_ws: u8) void {
    const tiling_active = build.has_tiling and tiling.getState().is_enabled;

    if (tiling_active) {
        if (!core.config.tiling.global_layout) tiling.applyWorkspaceLayout(ws);

        if (tiling.restoreWorkspaceGeom()) {
            // Restore succeeded: invalidate only windows shared with the old workspace —
            // their cache holds stale tiling positions from that workspace.
            for (ws.windows.items()) |win| {
                if (tiling.isWindowTiled(win) and tracking.isWindowOnWorkspace(win, old_ws))
                    tiling.invalidateGeomCache(win);
            }
        } else {
            // Restore failed: invalidate all tiled windows and force a full retile.
            // (The shared-window subset above is a strict subset of this, so doing
            // it unconditionally up-front would be wasted work on the success path.)
            for (ws.windows.items()) |win| {
                if (tiling.isWindowTiled(win)) tiling.invalidateGeomCache(win);
            }
            tiling.retileCurrentWorkspace();
        }
    } else if (build.has_tiling and tiling.isFloatingLayout()) {
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
    const default_x: u32 = @intCast(core.screen.width_in_pixels  / 4);
    const default_y: u32 = @intCast(core.screen.height_in_pixels / 4);
    for (ws.windows.items()) |win| {
        _ = xcb.xcb_map_window(core.conn, win);
        if ((!build.has_tiling or !tiling.isWindowActiveTiled(win)) and !isMinimized(win) and
            !tracking.isWindowOnWorkspace(win, old_ws))
        {
            if (window.getWindowGeom(win)) |rect| {
                utils.configureWindow(core.conn, win, rect);
            } else {
                _ = xcb.xcb_configure_window(core.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ default_x, default_y });
            }
        }
    }
}

// Step 4: resolve the post-switch focus target and apply it.
// Skips the mapped-check and stack raise that focus.setFocus would do —
// all windows are already mapped and workspace_switch never raises.
// `ptr_cookie` is pre-fired before the server grab to overlap the round-trip.
fn applyPostSwitchFocus(new_ws: u8, new_ws_obj: *Workspace, ptr_cookie: xcb.xcb_query_pointer_cookie_t) void {
    const focus_target: ?u32 = blk: {
        const ptr = xcb.xcb_query_pointer_reply(core.conn, ptr_cookie, null)
            orelse break :blk lastFocusedOrFirst(new_ws_obj);
        defer std.c.free(ptr);
        const child = ptr.*.child;
        break :blk if (child != 0 and child != core.root and
            tracking.isWindowOnWorkspace(child, new_ws) and !isMinimized(child))
            child else lastFocusedOrFirst(new_ws_obj);
    };

    // Route through focus.setFocus / focus.clearFocus so that
    // commitFocusTransition runs its full side-effect list:
    //   • recordInHistory(old)       — MRU history kept correct for recovery
    //   • tiling.updateWindowFocus   — tiling border state updated
    //   • carousel.notifyFocusChanged — carousel UI notified
    //   • advertiseActiveWindow      — _NET_ACTIVE_WINDOW on root updated
    //   • grabButtons on old/new     — button grab ownership transferred
    //   • xcb_set_input_focus        — X server notified
    //
    // The previous direct focus.setFocused() call bypassed all of these,
    // leaving the MRU history stale and focus recovery broken after every
    // workspace switch.
    //
    // .workspace_switch skips the mapped-check round-trip and never raises
    // the window — both correct for this path since all windows are already
    // mapped and the stacking order is set by hide/restoreWorkspaceWindows.
    // bar.scheduleFocusRedraw() sets only a dirty bit here; the caller
    // calls bar.redrawInsideGrab() for the actual synchronous redraw.
    if (focus_target) |new_win| {
        focus.setFocus(new_win, .workspace_switch);
    } else {
        focus.clearFocus();
    }
}

fn executeSwitch(old_ws: u8, new_ws: u8) void {
    const s          = getState() orelse return;
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info    = if (comptime build.has_fullscreen) fullscreen.getForWorkspace(new_ws) else null;

    focus.setSuppressReason(.none);
    s.workspaces[old_ws].last_focused = focus.getFocused();

    // Pre-fire before the grab so the round-trip overlaps with hide+restore.
    const ptr_cookie = xcb.xcb_query_pointer(core.conn, core.root);

    _ = xcb.xcb_grab_server(core.conn);

    hideWorkspaceWindows(&s.workspaces[old_ws], new_ws);

    if (fs_info != null) bar.setBarState(.hide_fullscreen) else bar.setBarState(.show_fullscreen);

    if (fs_info) |info| {
        // Map and push offscreen every non-fullscreen window on this workspace.
        //
        // When a window is spawned onto an inactive workspace that already has
        // an active fullscreen, executeSwitch takes this branch and skips
        // restoreWorkspaceWindows — the only place that calls xcb_map_window
        // on switch-in. The spawned window therefore stays unmapped. On
        // fullscreen exit, tiling allocates a tile cell for it (it is in
        // s.windows and on this workspace) but the cell is invisible, leaving
        // an empty gap until the next workspace round-trip triggers a normal
        // restoreWorkspaceWindows path.
        //
        // Fix: map every non-fullscreen workspace window here, then push it
        // offscreen so it is hidden behind the fullscreen window. Invalidate
        // the tiling cache entry for tiled windows so the next retile after
        // fullscreen exit does not find a stale zero-rect and skip configure.
        for (new_ws_obj.windows.items()) |win| {
            if (win == info.window) continue;
            _ = xcb.xcb_map_window(core.conn, win);
            utils.pushWindowOffscreen(core.conn, win);
            if (comptime build.has_tiling) {
                if (tiling.isWindowActiveTiled(win)) tiling.invalidateGeomCache(win);
            }
        }
        _ = xcb.xcb_configure_window(core.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{ 0, 0,
                @intCast(core.screen.width_in_pixels),
                @intCast(core.screen.height_in_pixels),
                0 });
        _ = xcb.xcb_configure_window(core.conn, info.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    } else {
        restoreWorkspaceWindows(new_ws_obj, old_ws);
    }

    applyPostSwitchFocus(new_ws, new_ws_obj, ptr_cookie);

    bar.raiseBar();
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}
