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

pub const State = struct {
    /// Fixed array (one slot per workspace) of insertion-ordered window ID lists.
    /// Indexed directly by workspace id — no hashing overhead.
    /// LIFO restore = pop from tail; FIFO restore = remove from head.
    per_workspace:  []std.ArrayListUnmanaged(u32),
    /// Maps minimized window -> saved fullscreen geometry, or null if the window
    /// was not fullscreen when minimized.  Doubles as the O(1) membership set:
    /// a window is minimized iff it has an entry here.
    minimized_info: std.AutoHashMap(u32, ?defs.WindowGeometry),
    allocator:      std.mem.Allocator,
};

// Module singleton

var g_state: ?State = null;

pub fn getState() ?*State { return if (g_state) |*s| s else null; }

// Init / deinit

pub fn init(allocator: std.mem.Allocator, workspace_count: u8) void {
    const lists = allocator.alloc(std.ArrayListUnmanaged(u32), workspace_count) catch {
        debug.err("minimize: failed to allocate per-workspace lists", .{});
        return;
    };
    for (lists) |*l| l.* = .{};

    var info_map = std.AutoHashMap(u32, ?defs.WindowGeometry).init(allocator);
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
fn trackMinimized(s: *State, ws_idx: u8, win: u32, saved_fs: ?defs.WindowGeometry) bool {
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
/// Shared by the minimize path and the window unmanage path in window.zig.
pub fn focusBestAvailable(wm: *WM) void {
    const ws = workspaces.getCurrentWorkspaceObject() orelse {
        focus.clearFocus(wm);
        return;
    };
    if (workspaces.firstNonMinimized(ws.windows.items())) |win| {
        focus.setFocus(wm, win, .window_destroyed);
    } else {
        focus.clearFocus(wm);
    }
}

// Minimize

pub fn minimizeWindow(wm: *WM) void {
    const win    = wm.focused_window                orelse return;
    const s      = getState()                       orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return; // idempotent

    // Step 1: exit fullscreen if active, saving geometry for restoration.
    // Single map lookup covers both the "is fullscreen?" check and the ws lookup.
    var saved_fs: ?defs.WindowGeometry = null;
    if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
        if (wm.fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = info.saved_geometry;
            wm.fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    // Step 2: remove from tiling (before retile so the layout excludes it).
    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    // Step 3: track — attempted before the grab so we can abort cleanly on
    // allocation failure without ever having entered the grab.
    if (!trackMinimized(s, ws_idx, win, saved_fs)) {
        debug.err("minimize: allocation failure tracking window 0x{x} — rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        return;
    }

    // Steps 4–6 wrapped in a single server grab so picom never composites
    // an intermediate state (window gone but layout/focus not yet updated, or
    // fullscreen bar still hidden while siblings remain offscreen).
    _ = xcb.xcb_grab_server(wm.conn);

    // Step 4: move off-screen.
    hideWindow(wm, win);

    // Step 5: update focus (must precede retile so border colours are correct).
    focusBestAvailable(wm);

    // Step 6: bring remaining windows back on-screen / retile.
    if (was_fullscreen) {
        // setBarState(.show_fullscreen) restores the bar and, for tiled
        // workspaces, triggers a retile.  The minimized window is not in the
        // tiling list so it will not receive a tile position.
        // The flush inside setBarState happens while picom is frozen (grab
        // is held) — harmless.
        bar.setBarState(wm, .show_fullscreen);
    } else if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }

    // Redraw the bar inside the grab so the updated workspace/title state is
    // composited atomically with the window hide and layout change.  Without
    // this, picom composites one frame showing the old bar content (e.g. the
    // minimized window's title still displayed) before the deferred redraw fires.
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
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
        // The window is currently at OFFSCREEN_X_POSITION.  Pass the saved
        // geometry directly so we can skip:
        //   (a) the xcb_get_geometry round-trip that enterFullscreen normally
        //       uses to learn the window's pre-fullscreen size, and
        //   (b) the configure_window + flush that previously "pre-positioned"
        //       the window at its saved on-screen coordinates before the
        //       fullscreen grab acquired — that flush produced an intermediate
        //       compositor frame showing the window at its small saved size.
        // With enterFullscreenWithSavedGeom the window goes from offscreen to
        // fullscreen in a single atomic grab: no intermediate frame visible.
        wm.focused_window = win;
        fullscreen.enterFullscreenWithSavedGeom(wm, win, geom);
        bar.markDirty();
        return;
    }

    // Non-fullscreen restore: wrap addWindow + retile + focus in a single grab
    // so picom never composites a frame where the window has appeared but its
    // neighbours have not yet been repositioned (or vice-versa).
    _ = xcb.xcb_grab_server(wm.conn);

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

    // .window_spawn skips the isWindowMapped round-trip in setFocus, keeping
    // the grab scope free of avoidable blocking calls.
    focus.setFocus(wm, win, .window_spawn);

    // Redraw the bar inside the grab: the restored window's title and workspace
    // indicator are correct now.  Without this, picom composites one stale-bar
    // frame (no title, old minimized count) before the deferred redraw fires.
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
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

    // Snapshot then clear the ordered list before iterating.
    var snapshot: std.ArrayListUnmanaged(u32) = .{};
    defer snapshot.deinit(s.allocator);
    snapshot.appendSlice(s.allocator, list.items) catch |err| {
        debug.warnOnErr(err, "unminimize_all: snapshot allocation failed");
        return;
    };
    list.clearRetainingCapacity();

    // If any window was fullscreen when minimized, fall back to the per-window
    // path.  Re-entering fullscreen involves its own grab + bar hide + sibling
    // offscreen — batching that with the other windows is complex and this case
    // is rare enough that N separate grabs is acceptable.
    for (snapshot.items) |win| {
        if (s.minimized_info.get(win)) |saved_fs| {
            if (saved_fs != null) {
                for (snapshot.items) |w| restoreWindow(wm, w);
                return;
            }
        }
    }

    // Common case: no fullscreen windows among the minimized set.
    // Batch all additions, retile, focus, and bar redraw into a single server
    // grab so picom composites exactly one frame where all windows have appeared
    // at their correct tiled positions.  The per-window restoreWindow loop would
    // produce N separate grab/retile/bar_redraw cycles — N-1 intermediate frames.
    _ = xcb.xcb_grab_server(wm.conn);

    for (snapshot.items) |win| {
        // Remove from the info map (was not yet removed — only the ordered list
        // was cleared above).  saved_fs is null for all entries (checked above).
        _ = s.minimized_info.fetchRemove(win);
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
        } else {
            // Floating: place at a sensible on-screen position.
            const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
            const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{ x, y });
        }
    }

    if (wm.config.tiling.enabled) tiling.retileCurrentWorkspace(wm);

    // Focus the most-recently-minimized window (last entry in the snapshot —
    // same result as N sequential restoreWindow calls each stealing focus).
    // .window_spawn skips the isWindowMapped round-trip, keeping the grab
    // scope free of avoidable blocking calls.
    if (snapshot.items.len > 0) {
        focus.setFocus(wm, snapshot.items[snapshot.items.len - 1], .window_spawn);
    }

    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
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
