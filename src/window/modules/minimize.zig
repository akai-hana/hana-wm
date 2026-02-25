//! Window minimization: per-workspace ordered hide/restore.
//!
//! Minimized windows remain in their workspace's window list so the bar
//! keeps rendering them, but they are moved offscreen and removed from
//! tiling so remaining windows fill the freed space.
//!
//! Three restore operations are provided, all scoped to the current workspace:
//!   unminimize(.lifo): restore the most recently minimized window (stack pop)
//!   unminimize(.fifo): restore the least recently minimized window (queue dequeue)
//!   unminimizeAll:     restore every minimized window
//!
//! Fullscreen interaction: minimizing a fullscreen window tears down the
//! fullscreen state but saves the pre-fullscreen geometry. Restoring such
//! a window puts it back into fullscreen exactly as it was.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const focus      = @import("focus");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const fullscreen = @import("fullscreen");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");

// MinimizeState and MinimizedEntry are defined in defs.zig so WM can own them
// without circular imports. deinit is handled by WM.deinit.

/// Returns a pointer to the minimize state, or null when uninitialized.
inline fn getMinState(wm: *WM) ?*defs.MinimizeState {
    return if (wm.minimize) |*s| s else null;
}

/// Read-only variant for functions that take *const WM (e.g. isMinimized).
inline fn getMinStateConst(wm: *const WM) ?*const defs.MinimizeState {
    return if (wm.minimize) |*s| s else null;
}

/// Ordered removal of `win` from `list`. No-op if absent.
fn removeFromList(list: *std.ArrayListUnmanaged(u32), win: u32) void {
    for (list.items, 0..) |w, i| {
        if (w != win) continue;
        _ = list.orderedRemove(i);
        return;
    }
}

/// Initialise the minimize subsystem and store state in wm.minimize.
/// Called by events.initModules before the event loop starts.
pub fn init(wm: *WM) void {
    const lists = wm.allocator.alloc(std.ArrayListUnmanaged(u32), wm.config.workspaces.count) catch {
        debug.err("minimize: failed to allocate per-workspace lists", .{});
        return;
    };
    for (lists) |*l| l.* = .{};

    var info_map = std.AutoHashMap(u32, defs.MinimizedEntry).init(wm.allocator);
    info_map.ensureTotalCapacity(8) catch {};

    wm.minimize = defs.MinimizeState{
        .per_workspace  = lists,
        .minimized_info = info_map,
        .allocator      = wm.allocator,
    };
}

pub fn isMinimized(wm: *const WM, win: u32) bool {
    const s = getMinStateConst(wm) orelse return false;
    return s.minimized_info.contains(win);
}

// Record win as minimized in the per-workspace list and the info map.
// Returns false on allocation failure; caller must roll back any side-effects.
fn trackMinimized(s: *defs.MinimizeState, ws_idx: u8, win: u32, saved_fs: ?defs.WindowGeometry) bool {
    s.per_workspace[ws_idx].append(s.allocator, win) catch return false;
    s.minimized_info.put(win, .{ .saved_fs = saved_fs, .workspace = ws_idx }) catch {
        _ = s.per_workspace[ws_idx].pop();
        return false;
    };
    return true;
}

// Move win offscreen using the same technique as workspace switching:
// no unmap/remap, so the compositor never frees the buffer.
inline fn hideWindow(wm: *WM, win: u32) void {
    _ = xcb.xcb_configure_window(
        wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X,
        &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))},
    );
}

// Focus the best available non-minimized window on the current workspace,
// or clear focus if none exists. Used by the minimize path and window.zig.
pub fn focusBestAvailable(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse {
        focus.clearFocus(wm);
        return;
    };
    if (workspaces.firstNonMinimized(wm, ws.windows.items())) |win| {
        focus.setFocus(wm, win, .window_destroyed);
    } else {
        focus.clearFocus(wm);
    }
}

pub fn minimizeWindow(wm: *WM) void {
    const win    = wm.focused_window                orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const s      = getMinState(wm)                  orelse return;

    if (isMinimized(wm, win)) return;

    // Exit fullscreen if active, saving geometry for restoration.
    // Single map lookup covers both the "is fullscreen?" check and the ws lookup.
    var saved_fs: ?defs.WindowGeometry = null;
    if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
        if (wm.fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = info.saved_geometry;
            wm.fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    // Track before entering the grab so we can abort cleanly on allocation
    // failure without having to handle a partial grab state.
    if (!trackMinimized(s, ws_idx, win, saved_fs)) {
        debug.err("minimize: allocation failure tracking window 0x{x} -- rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        return;
    }

    // Wrap hide + focus + retile in a single grab so picom never composites
    // an intermediate state.
    _ = xcb.xcb_grab_server(wm.conn);
    hideWindow(wm, win);
    focusBestAvailable(wm);
    if (was_fullscreen) {
        // setBarState(.show_fullscreen) restores the bar and triggers a retile.
        // The minimized window is not in tiling so it gets no tile position.
        bar.setBarState(wm, .show_fullscreen);
    } else if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
    // Redraw inside the grab so the bar update is composited atomically with
    // the window hide; otherwise picom shows one stale frame first.
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// Bring win back onscreen and re-enter fullscreen if it was fullscreen when
// minimized. The caller is responsible for removing win from the ordered
// per-workspace list; this function only handles the info map and X11 state.
fn restoreWindow(wm: *WM, win: u32) void {
    const s = getMinState(wm) orelse return;

    const entry = s.minimized_info.fetchRemove(win) orelse return;

    if (entry.value.saved_fs) |geom| {
        // Pass saved geometry directly to enterFullscreenWithSavedGeom so the
        // window goes from offscreen to fullscreen in a single atomic grab with
        // no intermediate compositor frame at the small saved size.
        wm.focused_window = win;
        fullscreen.enterFullscreenWithSavedGeom(wm, win, geom);
        bar.markDirty();
        return;
    }

    // Non-fullscreen: wrap addWindow + retile + focus in a single grab so picom
    // never composites a frame where the window has appeared but neighbours have
    // not yet been repositioned.
    _ = xcb.xcb_grab_server(wm.conn);

    if (wm.config.tiling.enabled) {
        tiling.addWindow(wm, win);
        tiling.retileCurrentWorkspace(wm);
    } else {
        const pos = utils.floatDefaultPos(wm);
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ pos.x, pos.y },
        );
    }

    // .window_spawn skips the isWindowMapped round-trip, keeping the grab
    // scope free of avoidable blocking calls.
    focus.setFocus(wm, win, .window_spawn);
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

pub const RestoreOrder = enum { lifo, fifo };

/// Restore one minimized window from the current workspace.
/// .lifo pops the most recently minimized (stack); .fifo takes the oldest (queue).
pub fn unminimize(wm: *WM, order: RestoreOrder) void {
    const s      = getMinState(wm)                  orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    const win = switch (order) {
        .lifo => list.pop() orelse return,
        .fifo => blk: {
            if (list.items.len == 0) return;
            break :blk list.orderedRemove(0);
        },
    };
    restoreWindow(wm, win);
}

// Restore every minimized window on the current workspace.
pub fn unminimizeAll(wm: *WM) void {
    const s      = getMinState(wm)                  orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    if (list.items.len == 0) return;

    // Snapshot then clear the ordered list before iterating.
    // Pre-size before clearing: an OOM here leaves `list` intact so the windows
    // remain minimized and the user can retry. The old appendSlice approach
    // could clear the list first and then fail, leaving info_map entries with
    // no corresponding per-workspace list entry.
    var snapshot: std.ArrayListUnmanaged(u32) = .{};
    defer snapshot.deinit(s.allocator);
    snapshot.ensureTotalCapacity(s.allocator, list.items.len) catch |err| {
        debug.warnOnErr(err, "unminimize_all: snapshot allocation failed, no windows restored");
        return;
    };
    snapshot.appendSliceAssumeCapacity(list.items);
    list.clearRetainingCapacity();

    // If any window was fullscreen when minimized, fall back to per-window
    // restoreWindow. Re-entering fullscreen involves its own grab + bar hide +
    // sibling offscreen, and this case is rare enough that N separate grabs is fine.
    for (snapshot.items) |w| {
        if (s.minimized_info.get(w).?.saved_fs != null) {
            for (snapshot.items) |win| restoreWindow(wm, win);
            return;
        }
    }

    // Common case: no fullscreen windows. Batch all additions, retile, focus,
    // and bar redraw into a single grab so picom composites exactly one frame
    // with all windows at their correct positions.
    _ = xcb.xcb_grab_server(wm.conn);

    // tiling.enabled is loop-invariant: hoist the branch outside.
    if (wm.config.tiling.enabled) {
        for (snapshot.items) |win| {
            _ = s.minimized_info.fetchRemove(win);
            tiling.addWindow(wm, win);
        }
        tiling.retileCurrentWorkspace(wm);
    } else {
        const pos = utils.floatDefaultPos(wm);
        for (snapshot.items) |win| {
            _ = s.minimized_info.fetchRemove(win);
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{ pos.x, pos.y });
        }
    }

    // Focus the most-recently-minimized window (last in snapshot).
    // .window_spawn skips the isWindowMapped round-trip inside the grab.
    focus.setFocus(wm, snapshot.items[snapshot.items.len - 1], .window_spawn);

    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

/// Called by window.zig on unmap/destroy to keep state coherent.
/// O(n) in minimized windows on the specific workspace — workspace index comes
/// from MinimizedEntry directly, so we never scan across all workspace lists.
/// No-op if win is not minimized.
pub fn forceUntrack(wm: *WM, win: u32) void {
    const s     = getMinState(wm) orelse return;
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    removeFromList(&s.per_workspace[entry.value.workspace], win);
}

// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(wm: *WM, win: u32, old_ws: u8, new_ws: u8) void {
    const s = getMinState(wm) orelse return;
    if (!s.minimized_info.contains(win)) return;
    if (old_ws >= s.per_workspace.len or new_ws >= s.per_workspace.len) return;

    removeFromList(&s.per_workspace[old_ws], win);

    s.per_workspace[new_ws].append(s.allocator, win) catch |err| {
        // INVARIANT BREAK: win has been removed from per_workspace[old_ws] above
        // but cannot be added to per_workspace[new_ws]. minimized_info still maps
        // win -> old_ws, so forceUntrack will find a mismatched entry: it tries
        // removeFromList(old_ws, win) (no-op, already gone) and then removes the
        // info entry. The window silently disappears from the minimized list without
        // being restored to screen — an acceptable loss under OOM.
        debug.warnOnErr(err, "minimize.moveToWorkspace: failed to append, window lost from minimize list");
        return;
    };

    // Update the cached workspace index so forceUntrack stays accurate after moves.
    if (s.minimized_info.getPtr(win)) |e| e.workspace = new_ws;
}
