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
    /// The tiling layout active on this workspace.
    /// Initialized to the default from config; updated whenever the user
    /// switches layouts while on this workspace (in per-workspace mode).
    layout:  tiling.Layout,

    pub fn init(allocator: std.mem.Allocator, id: u8, name: []const u8, default_layout: tiling.Layout) !Workspace {
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

// Module singleton

var g_state: ?State = null;

pub fn getState() ?*State { return if (g_state) |*s| s else null; }

// Init / deinit

pub fn init(wm: *WM) void {
    const count = wm.config.workspaces.count;
    const wss = wm.allocator.alloc(Workspace, count) catch {
        debug.err("Failed to allocate workspaces", .{});
        return;
    };

    // Derive the default layout from the tiling state (already initialized by
    // the time workspaces.init runs) so every workspace starts on the same
    // layout as the global default.  Falls back to .master if tiling is off.
    const default_layout: tiling.Layout =
        if (tiling.getState()) |ts| ts.layout else .master;

    for (wss, 0..) |*ws, i| {
        const id: u8     = @intCast(i);
        const name       = if (i < WORKSPACE_NAMES.len) WORKSPACE_NAMES[i] else "?";
        ws.* = Workspace.init(wm.allocator, id, name, default_layout) catch {
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

pub fn deinit() void {
    if (g_state) |*s| {
        for (s.workspaces) |*ws| ws.deinit();
        s.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
    }
    g_state = null;
}

// Window tracking

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
        // Window not yet tracked — add it directly to the target.
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
        s.workspaces[from_ws].add(win) catch |e| debug.warnOnErr(e, "workspace rollback");
        if (ts) |t| _ = t.windows.remove(win);
        return;
    };
    s.window_to_workspace.put(win, target_ws) catch |e| debug.warnOnErr(e, "w2ws put after move");

    // Keep minimize tracking coherent when a minimized window is moved.
    if (minimize.isMinimized(win)) minimize.moveToWorkspace(win, from_ws, target_ws);

    if (from_ws == s.current) {
        // Bug fix: if the window is fullscreen on this workspace, tear down
        // the fullscreen state before hiding it.  Without this the bar stays
        // hidden and sibling windows remain off-screen on the old workspace.
        // Window tracking has already been updated above, so the retile that
        // bar.setBarState triggers will not re-tile the moved window.
        if (wm.fullscreen.isFullscreen(win)) {
            if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
                if (fs_ws == from_ws) {
                    wm.fullscreen.removeForWorkspace(fs_ws);
                    bar.setBarState(wm, .show_fullscreen);
                }
            }
        }

        // Hide window by moving it off-screen (avoids an unmap/remap cycle).
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
        if (wm.focused_window == win) focus.clearFocus(wm);
        if (ts) |t| t.dirty = true;
        // Evict the window's stale geometry cache entry.
        //
        // The cache holds the rect from the window's last retile on this workspace.
        // markDirty() above triggers a retile of the current workspace via
        // retileIfDirty() in the event loop, but that retile only covers windows
        // still on the current workspace — win has already been moved to target_ws,
        // so its cache entry is never refreshed and remains stale.
        //
        // Without this eviction, restoreWorkspaceGeom finds a cache hit for win
        // when the user later switches to target_ws, replays the old geometry
        // (e.g. right-half stack position from its previous workspace), and the
        // window appears mis-tiled instead of filling its new workspace correctly.
        // A full retile then fixes it — which is exactly what switching away and
        // back triggered, explaining why that workaround worked.
        tiling.invalidateGeomCache(win);
    } else if (target_ws == s.current) {
        // Map in case the window was deferred (spawned while this ws was inactive).
        _ = xcb.xcb_map_window(wm.conn, win);
        if (ts) |t| t.dirty = true;
    }
}

// Workspace switching

pub fn switchTo(wm: *WM, ws_id: u8) void {
    const s = getState() orelse return;
    if (ws_id >= s.workspaces.len or ws_id == s.current) return;
    const old    = s.current;
    s.current    = ws_id;
    executeSwitch(wm, old, ws_id);
}

/// Return the first non-minimized window in `windows`, or null if all are
/// minimized (or the slice is empty).  Used when switching workspaces so
/// that a minimized-only workspace never receives keyboard focus.
/// Takes a plain slice rather than *Workspace so it is decoupled from the
/// workspace data structure and easier to test in isolation.
pub fn firstNonMinimized(windows: []const u32) ?u32 {
    for (windows) |win| {
        if (!minimize.isMinimized(win)) return win;
    }
    return null;
}

fn executeSwitch(wm: *WM, old_ws: u8, new_ws: u8) void {
    const s          = getState().?;
    const old_ws_obj = &s.workspaces[old_ws];
    const new_ws_obj = &s.workspaces[new_ws];
    const fs_info    = wm.fullscreen.getForWorkspace(new_ws);

    wm.suppress_focus_reason = .none;

    // Grab the server so the switch is atomic — no intermediate frames visible.
    _ = xcb.xcb_grab_server(wm.conn);
    // NOTE: no defer for ungrab — we queue it explicitly before the flush so
    // that grab + all commands + raiseBar + ungrab all land in a single write.
    // A deferred ungrab would run after the flush, leaving the server locked
    // for an extra event-loop cycle and delaying when picom can composite.

    // Step 1: hide all windows from the old workspace.
    // Also invalidate each window's geom_cache entry.  The cache holds their
    // last tiled positions; we're about to move them to OFFSCREEN_X_POSITION
    // via a partial configure (X only).  Without invalidation, the next
    // retileCurrentWorkspace on this workspace would compute the same tiled
    // positions, find cache hits, and skip the configure_window calls —
    // leaving windows stranded offscreen when the user switches back.
    for (old_ws_obj.windows.items()) |win| {
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
        tiling.invalidateGeomCache(win);
    }

    // Step 2: adjust bar visibility for the new workspace.
    bar.setBarState(wm, if (fs_info != null) .hide_fullscreen else .show_fullscreen);

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

        const tiling_active = if (tiling.getState()) |t| t.enabled else false;

        if (tiling_active) {
            // Per-workspace layout mode: restore the layout this workspace was
            // last using before switching to it.  This must happen before any
            // retile/geom-cache restore so the right layout algorithm runs and
            // the bar segment shows the correct layout icon.
            if (!wm.config.tiling.global_layout) {
                tiling.syncLayoutFromWorkspace(new_ws_obj.layout);
            }

            // Fast path: replay cached tiled positions without running the layout
            // algorithm.  Falls back to a full retile only if this workspace's
            // ws_geom_valid bit is not set (window added/removed/layout changed
            // while away), the cache is cold, or the screen area changed.
            // restoreWorkspaceGeom calls utils.configureWindow directly, bypassing
            // the geom cache — this is intentional: the windows were moved to
            // OFFSCREEN_X_POSITION in step 1, so the cache has their correct tiled
            // rects but the server does not.
            if (!tiling.restoreWorkspaceGeom(wm)) {
                // Evict the new workspace's geom cache entries before retriling.
                // retileInactiveWorkspace may have pre-populated them with correct
                // on-screen positions.  If we skip straight to retileCurrentWorkspace
                // without evicting, configureSafe finds cache[win] == computed_geom
                // (both are the correct on-screen rect), treats it as "no change",
                // and skips the configure_window call — leaving windows stranded at
                // OFFSCREEN_X_POSITION instead of moving them back on-screen.
                for (new_ws_obj.windows.items()) |win| tiling.invalidateGeomCache(win);
                tiling.retileCurrentWorkspace(wm);
            }
        } else {
            // Floating: move all non-minimized windows to a sensible on-screen position.
            // Minimized windows stay at the offscreen X position — do not touch them.
            const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
            const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
            for (new_ws_obj.windows.items()) |win| {
                if (minimize.isMinimized(win)) continue;
                _ = xcb.xcb_configure_window(wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y, &[_]u32{ x, y });
            }
        }
    }

    // Step 4: determine focus target.
    //
    // We must not eagerly focus the master window and then correct it after the
    // server grab releases — doing so causes a visible border flicker as the
    // master briefly gets the focused border colour before focus moves to the
    // window under the cursor.
    //
    // Instead, query the pointer NOW (inside the grab, after all configure_window
    // calls have been queued).  XCB sends all pending requests before blocking on
    // the reply, so the server sees the fully repositioned layout when it evaluates
    // which window is under the pointer.  If the child is a managed, non-minimized
    // window on the new workspace we focus it directly.  Only if no such window is
    // found do we fall back to the first non-minimized window (master).
    const focus_target: ?u32 = blk: {
        const ptr = xcb.xcb_query_pointer_reply(
            wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null,
        ) orelse break :blk firstNonMinimized(new_ws_obj.windows.items());
        defer std.c.free(ptr);

        const child = ptr.*.child;
        if (child != 0 and child != wm.root and
            s.window_to_workspace.contains(child) and
            new_ws_obj.contains(child) and
            !minimize.isMinimized(child))
        {
            break :blk child;
        }
        break :blk firstNonMinimized(new_ws_obj.windows.items());
    };

    const old_focused    = wm.focused_window;
    wm.focused_window = focus_target;
    std.debug.assert(wm.focused_window == null or isManaged(wm.focused_window.?));

    // Paint borders with the correct focused/unfocused colours before the
    // server grab releases.  This is what prevents the master-flash: the
    // focused window gets its border set to border_focused here, inside the
    // grab, so there is never a frame where the wrong window has a focused border.
    tiling.updateWindowFocus(wm, old_focused, wm.focused_window);

    // Ungrab buttons on the focused window so clicks reach it directly.
    if (wm.focused_window) |new_win| {
        _ = xcb.xcb_ungrab_button(wm.conn, xcb.XCB_BUTTON_INDEX_ANY, new_win, xcb.XCB_MOD_MASK_ANY);
    }

    // ICCCM §4.1.7: xcb_set_input_focus must carry the timestamp of the
    // user action that triggered the switch — not XCB_CURRENT_TIME (0).
    // Globally-active windows (Electron, Chrome) validate this timestamp
    // and silently ignore focus messages that arrive with timestamp 0.
    // wm.last_event_time was set by handleKeyPress when the switch keybind
    // was pressed, so it is always valid here.
    _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        wm.focused_window orelse wm.root, wm.last_event_time);

    // Raise the bar, redraw it with the new workspace highlighted, then release
    // the grab — all before the flush so everything lands in a single write.
    //
    // Redrawing here (instead of deferring via markDirty) is critical: if we
    // defer, picom composites one frame showing the old workspace highlighted
    // in the bar before the deferred redraw fires.  Drawing inside the grab is
    // safe — Cairo/XCB rendering goes to the bar's backing pixmap; picom
    // composites the updated content the moment it unfreezes.
    //
    // ws_state.current was already set to new_ws in switchTo() before this
    // function was called, so the draw correctly highlights the new workspace.
    bar.raiseBar();
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// Queries

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

/// Predicate form of getWorkspaceForWindow for use as a function pointer.
/// Used by utils.findManagedWindow to check window membership without
/// creating a circular import between utils and workspaces.
pub fn isManaged(win: u32) bool {
    return getWorkspaceForWindow(win) != null;
}
