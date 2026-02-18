//! Window minimization — per-workspace ordered hide/restore.
//!
//! Minimized windows remain in their workspace's window list so the bar's
//! title segment keeps rendering them (with a distinct configurable accent
//! colour), but they are moved off-screen and removed from the tiling layout
//! so the remaining windows fill the freed space.
//!
//! Three restore operations are provided, all scoped to the current workspace:
//!   · unminimize_lifo  — restore the most recently minimized window (stack pop)
//!   · unminimize_fifo  — restore the least recently minimized window (queue dequeue)
//!   · unminimize_all   — restore every minimized window
//!
//! Fullscreen interaction:
//!   Minimizing a fullscreen window tears down the fullscreen state (so the bar
//!   and sibling windows come back) but saves the pre-fullscreen geometry.
//!   Restoring such a window puts it back into fullscreen exactly as it was.

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

// Types

/// Saved pre-fullscreen geometry for a window that was fullscreen when minimized.
/// Stored so we can reconstruct the fullscreen state faithfully on restore
/// without querying the window (which is off-screen at that point).
pub const SavedGeometry = struct {
    x:            i16,
    y:            i16,
    width:        u16,
    height:       u16,
    border_width: u16,
};

pub const State = struct {
    /// Fixed array (one slot per workspace) of insertion-ordered window ID lists.
    /// Indexed directly by workspace id — no hashing overhead.
    /// LIFO restore = pop from tail; FIFO restore = remove from head.
    per_workspace:  []std.ArrayList(u32),
    /// Maps minimized window -> saved fullscreen geometry, or null if the window
    /// was not fullscreen when minimized.  Doubles as the O(1) membership set:
    /// a window is minimized iff it has an entry here.
    minimized_info: std.AutoHashMap(u32, ?SavedGeometry),
    allocator:      std.mem.Allocator,
};

// Module singleton

var g_state: ?State = null;

pub fn getState() ?*State {
    return if (g_state != null) &g_state.? else null;
}

// Init / deinit

pub fn init(allocator: std.mem.Allocator, workspace_count: u8) void {
    const lists = allocator.alloc(std.ArrayList(u32), workspace_count) catch {
        debug.err("minimize: failed to allocate per-workspace lists", .{});
        return;
    };
    for (lists) |*l| l.* = .{};

    var info_map = std.AutoHashMap(u32, ?SavedGeometry).init(allocator);
    // Reserve for a handful of minimized windows — typical workload is tiny.
    info_map.ensureTotalCapacity(8) catch {};

    g_state = State{
        .per_workspace  = lists,
        .minimized_info = info_map,
        .allocator      = allocator,
    };
}

pub fn deinit() void {
    if (g_state) |*s| {
        for (s.per_workspace) |*list| list.deinit(s.allocator);
        s.allocator.free(s.per_workspace);
        s.minimized_info.deinit();
    }
    g_state = null;
}

// Public queries

pub fn isMinimized(win: u32) bool {
    const s = g_state orelse return false;
    return s.minimized_info.contains(win);
}

// Internal helpers

/// Record win as minimized in the per-workspace ordered list and in the info
/// map.  saved_fs is non-null iff the window was fullscreen when minimized.
/// Returns false on allocation failure; caller must roll back any side-effects.
fn trackMinimized(s: *State, ws_idx: u8, win: u32, saved_fs: ?SavedGeometry) bool {
    s.per_workspace[ws_idx].append(s.allocator, win) catch return false;
    s.minimized_info.put(win, saved_fs) catch {
        _ = s.per_workspace[ws_idx].pop();
        return false;
    };
    return true;
}

/// Move win off-screen using the same XConfigure technique as workspace
/// switching — no unmap/remap cycle, so the compositor never frees the buffer.
inline fn hideWindow(wm: *WM, win: u32) void {
    _ = xcb.xcb_configure_window(
        wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X,
        &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))},
    );
}

/// Focus the best available non-minimized window on the current workspace,
/// or clear focus if none exists.
fn refocusAfterMinimize(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse {
        focus.clearFocus(wm);
        return;
    };
    for (ws.windows.items()) |win| {
        if (!isMinimized(win)) {
            focus.setFocus(wm, win, .window_destroyed);
            return;
        }
    }
    focus.clearFocus(wm);
}

// Minimize

pub fn minimizeWindow(wm: *WM) void {
    const win    = wm.focused_window                orelse return;
    const s      = getState()                       orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return; // idempotent

    // Phase 1: exit fullscreen if active, saving geometry for restoration.
    // Single map lookup covers both the "is fullscreen?" check and the ws lookup.
    var saved_fs: ?SavedGeometry = null;
    if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
        if (wm.fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = .{
                .x            = info.saved_geometry.x,
                .y            = info.saved_geometry.y,
                .width        = info.saved_geometry.width,
                .height       = info.saved_geometry.height,
                .border_width = info.saved_geometry.border_width,
            };
            wm.fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    // Phase 2: remove from tiling (before retile so the layout excludes it).
    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    // Phase 3: move off-screen.
    hideWindow(wm, win);

    // Phase 4: track.  On failure, roll back tiling membership and abort.
    if (!trackMinimized(s, ws_idx, win, saved_fs)) {
        debug.err("minimize: allocation failure tracking window 0x{x} — rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        return;
    }

    // Phase 5: update focus (must precede retile so border colours are correct).
    refocusAfterMinimize(wm);

    // Phase 6: bring remaining windows back on-screen / retile.
    if (was_fullscreen) {
        // setBarState(.show_fullscreen) restores the bar and, for tiled
        // workspaces, triggers a retile.  The minimized window is not in the
        // tiling list so it will not receive a tile position.
        bar.setBarState(wm, .show_fullscreen);
    } else if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }

    utils.flush(wm.conn);
    bar.markDirty();
}

// Restore

/// Bring win back on-screen and re-enter fullscreen if it was fullscreen when
/// minimized.  The caller is responsible for removing win from the ordered
/// per-workspace list; this function only handles the info map and X11 state.
fn restoreWindow(wm: *WM, win: u32) void {
    const s = getState() orelse return;

    // Remove from the info map and retrieve any saved fullscreen geometry.
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    const saved_fs = entry.value;

    if (saved_fs) |geom| {
        // Restore pre-fullscreen geometry so enterFullscreenForWindow reads
        // accurate on-screen coordinates from xcb_get_geometry.
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{
                @bitCast(@as(i32, geom.x)),
                @bitCast(@as(i32, geom.y)),
                geom.width,
                geom.height,
                geom.border_width,
            },
        );
        utils.flush(wm.conn);

        // Re-enter fullscreen — covers the screen, hides the bar, and pushes
        // sibling windows off-screen.
        wm.focused_window = win;
        fullscreen.enterFullscreenForWindow(wm, win);
        bar.markDirty();
        return;
    }

    // Non-fullscreen restore.
    if (wm.config.tiling.enabled) {
        tiling.addWindow(wm, win);
        tiling.retileCurrentWorkspace(wm);
    } else {
        const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
        const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ x, y },
        );
    }

    focus.setFocus(wm, win, .window_spawn);
    utils.flush(wm.conn);
    bar.markDirty();
}

// Public unminimize API
//
// In all three cases the caller removes win from the ordered list before
// calling restoreWindow, which only touches the info map and X11.

/// Restore the most recently minimized window on the current workspace (LIFO).
pub fn unminimizeLifo(wm: *WM) void {
    const s      = getState()                       orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    const win    = list.pop()                       orelse return;
    restoreWindow(wm, win);
}

/// Restore the least recently minimized window on the current workspace (FIFO).
pub fn unminimizeFifo(wm: *WM) void {
    const s      = getState()                       orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    if (list.items.len == 0) return;
    const win = list.orderedRemove(0);
    restoreWindow(wm, win);
}

/// Restore every minimized window on the current workspace.
pub fn unminimizeAll(wm: *WM) void {
    const s      = getState()                       orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    if (list.items.len == 0) return;

    // Snapshot then clear before iterating: the list is our responsibility,
    // and clearing up-front keeps state consistent even if a restore fails.
    var snapshot: std.ArrayList(u32) = .{};
    defer snapshot.deinit(s.allocator);
    snapshot.appendSlice(s.allocator, list.items) catch |err| {
        debug.warnOnErr(err, "unminimize_all: snapshot allocation failed");
        return;
    };
    list.clearRetainingCapacity();

    for (snapshot.items) |win| restoreWindow(wm, win);
}

// Lifecycle hooks

/// Called by window.zig on unmap/destroy to keep state coherent.
/// No-op when the window was not minimized.
pub fn forceUntrack(win: u32) void {
    const s = getState() orelse return;
    // fetchRemove is a single lookup — avoids the double contains+remove hit.
    if (s.minimized_info.fetchRemove(win) == null) return;
    // Scan workspace lists to remove the orphaned entry.
    for (s.per_workspace) |*list| {
        for (list.items, 0..) |w, i| {
            if (w != win) continue;
            _ = list.orderedRemove(i);
            return;
        }
    }
}

/// Called by workspaces.zig when a minimized window is moved to another
/// workspace, so the ordered per-workspace list stays coherent.
pub fn moveToWorkspace(win: u32, old_ws: u8, new_ws: u8) void {
    const s = getState() orelse return;
    if (!s.minimized_info.contains(win)) return;
    if (old_ws >= s.per_workspace.len or new_ws >= s.per_workspace.len) return;

    // Remove from old workspace list.
    const old_list = &s.per_workspace[old_ws];
    for (old_list.items, 0..) |w, i| {
        if (w != win) continue;
        _ = old_list.orderedRemove(i);
        break;
    }

    // Append to new workspace list.
    s.per_workspace[new_ws].append(s.allocator, win) catch |err| {
        debug.warnOnErr(err, "minimize.moveToWorkspace: failed to append");
    };
}
