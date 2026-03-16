//! Window minimization: hide/restore with LIFO, FIFO, or bulk restore.
//!
//! Minimized windows remain in their workspace's window list so the bar
//! keeps rendering them, but they are moved offscreen and removed from
//! tiling so remaining windows fill the freed space.
//!
//! Three restore operations are provided, all scoped to the current workspace:
//!   unminimize(.lifo): restore the most recently minimized window (stack pop)
//!   unminimize(.fifo): restore the least recently minimized window (queue dequeue)
//!   unminimizeAll:     restore every minimized window on the current workspace
//!
//! Ordering is tracked via a monotonic per-entry timestamp — no separate
//! per-workspace ordered lists are maintained. The single `minimized_info` map is
//! the only source of truth; scanning it for the LIFO/FIFO candidate is O(n)
//! but n is always tiny in practice (typically < 10 minimized windows).
//!
//! Fullscreen interaction: minimizing a fullscreen window tears down the
//! fullscreen state but saves the pre-fullscreen geometry. Restoring such
//! a window puts it back into fullscreen exactly as it was.

const std        = @import("std");
const core = @import("core");
const xcb        = core.xcb;
const utils      = @import("utils");
const focus      = @import("focus");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const fullscreen = @import("fullscreen");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");

// Types 

/// Per-window minimize record.
const MinimizedEntry = struct {
    saved_fs:      ?core.WindowGeometry, // non-null iff the window was fullscreen when minimized
    /// The workspace this window belongs to.  A minimized window always lives
    /// on exactly one workspace (multi-workspace tagging is handled by the
    /// tagging system before minimize is called), so a simple index is clearer
    /// and cheaper than a u64 bitmask that would only ever have one bit set.
    workspace_idx: u8,
    /// Monotonic counter assigned at minimize time. Higher = more recently minimized.
    /// Used to implement LIFO (pop highest) and FIFO (pop lowest) without
    /// maintaining a separate ordered list per workspace.
    timestamp:     u64,
    /// Position of this window in the workspace-filtered tiling list at the
    /// moment it was minimized (index 0 = master).  Null when tiling was
    /// disabled or the window was not tracked.  Used by restoreWindowImpl to
    /// reinsert the window at its original layout slot instead of appending it.
    tiling_index:  ?usize,
};

const State = struct {
    minimized_info: std.AutoHashMap(u32, MinimizedEntry),
    allocator:      std.mem.Allocator,
    /// Incremented each time a window is minimized. Never reused.
    next_timestamp: u64,

    pub fn deinit(self: *State) void {
        self.minimized_info.deinit();
    }
};

// Module state 

// Module singleton — guaranteed live after init().
var g_state:       State = undefined;
var g_initialized: bool  = false;

pub inline fn getState() *State {
    std.debug.assert(g_initialized);
    return &g_state;
}

pub inline fn getStateOpt() ?*State {
    return if (g_initialized) &g_state else null;
}

// Lifecycle 

pub fn init() !void {
    var info_map = std.AutoHashMap(u32, MinimizedEntry).init(core.alloc);
    try info_map.ensureTotalCapacity(8);
    g_state = .{
        .minimized_info = info_map,
        .allocator      = core.alloc,
        .next_timestamp = 0,
    };
    g_initialized = true;
}

pub fn deinit() void {
    if (!g_initialized) return;
    g_state.deinit();
    g_initialized = false;
}

// Public queries 

pub inline fn isMinimized(win: u32) bool {
    if (!g_initialized) return false;
    return g_state.minimized_info.contains(win);
}

inline fn hideWindow(win: u32) void {
    _ = xcb.xcb_configure_window(
        core.conn, win,
        xcb.XCB_CONFIG_WINDOW_X,
        &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))},
    );
}

pub fn focusBestAvailable() void {
    if (workspaces.getCurrentWorkspaceObject()) |ws| {
        if (workspaces.firstNonMinimized(ws.windows.items())) |win| {
            focus.setFocus(win, .tiling_operation);
            return;
        }
    }
    focus.clearFocus();
}

// Minimize

/// Undo a partially-completed minimizeWindow call.
/// Called only on hash-map allocation failure; restores tiling and fullscreen
/// state so the window remains visible and the WM stays consistent.
inline fn rollbackMinimize(
    win:             u32,
    was_fullscreen:  bool,
    fs_ws:           ?u8,
    saved_fs:        ?core.WindowGeometry,
) void {
    if (core.config.tiling.enabled) {
        tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    }
    if (was_fullscreen) {
        fullscreen.setForWorkspace(fs_ws.?, .{
            .window         = win,
            .saved_geometry = saved_fs.?,
        }) catch {
            debug.err("minimize rollback: failed to re-insert fullscreen state for 0x{x}", .{win});
        };
    }
}

pub fn minimizeWindow() void {
    const win    = focus.getFocused()               orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const s      = getState();

    if (isMinimized(win)) return;

    // Tear down fullscreen state if needed, saving geometry for later restore.
    var saved_fs: ?core.WindowGeometry = null;
    var fs_ws_for_rollback: ?u8 = null;
    if (fullscreen.workspaceFor(win)) |fs_ws| {
        if (fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = info.saved_geometry;
            fs_ws_for_rollback = fs_ws;
            fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    // Capture the workspace-filtered position BEFORE removeWindow evicts the
    // window, so restoreWindowImpl can put it back at the same master/stack slot.
    const tiling_index = tiling.getWindowFilteredIndex(win);

    if (core.config.tiling.enabled) tiling.removeWindow(win);

    const ts = s.next_timestamp;
    s.minimized_info.put(win, .{
        .saved_fs      = saved_fs,
        .workspace_idx = ws_idx,
        .timestamp     = ts,
        .tiling_index  = tiling_index,
    }) catch {
        debug.err("minimize: allocation failure tracking window 0x{x} -- rolling back", .{win});
        rollbackMinimize(win, was_fullscreen, fs_ws_for_rollback, saved_fs);
        return;
    };
    s.next_timestamp = ts + 1;

    _ = xcb.xcb_grab_server(core.conn);
    hideWindow(win);
    focusBestAvailable();
    if (was_fullscreen) {
        bar.setBarState(.show_fullscreen);
    } else if (core.config.tiling.enabled) {
        tiling.retileCurrentWorkspace();
    }
    bar.redrawInsideGrab();
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

// Restore helpers 

fn restoreWindowImpl(win: u32, saved_fs: ?core.WindowGeometry, tiling_index: ?usize) void {
    if (saved_fs) |geom| {
        // Fullscreen restore path: enterFullscreen owns its own server grab
        // internally, so there is no enclosing grab here.  redrawInsideGrab
        // must not be called outside a grab; scheduleRedraw is the correct
        // choice — it queues the redraw to the next event-loop iteration after
        // the grab has been fully released.
        focus.setFocus(win, .window_spawn);
        fullscreen.enterFullscreen(win, geom);
        bar.scheduleRedraw();
        return;
    }

    _ = xcb.xcb_grab_server(core.conn);

    if (core.config.tiling.enabled) {
        // Restore at the original layout slot so a former master window
        // returns to master and a former stack window returns to its row,
        // rather than always being appended to the end of the list.
        if (tiling_index) |ti|
            tiling.addWindowAtFilteredIndex(win, ti)
        else
            tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    } else {
        const pos = utils.floatDefaultPos();
        _ = xcb.xcb_configure_window(
            core.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ pos.x, pos.y },
        );
    }

    focus.setFocus(win, .window_spawn);
    bar.redrawInsideGrab();
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

/// Remove `win` from minimized_info and restore it.
inline fn restoreWindow(win: u32) void {
    const s = getState();
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    restoreWindowImpl(win, entry.value.saved_fs, entry.value.tiling_index);
}

// Unminimize 

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(order: RestoreOrder) void {
    const s      = getState();
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    // Single pass over minimized_info: find the window on the current workspace
    // with the highest (LIFO) or lowest (FIFO) timestamp.
    var best_win: ?u32 = null;
    var best_ts:  u64  = 0;
    var it = s.minimized_info.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.workspace_idx != ws_idx) continue;
        const ts = kv.value_ptr.timestamp;
        const better = switch (order) {
            .lifo => best_win == null or ts > best_ts,
            .fifo => best_win == null or ts < best_ts,
        };
        if (better) { best_win = kv.key_ptr.*; best_ts = ts; }
    }

    const win = best_win orelse return;
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    restoreWindowImpl(win, entry.value.saved_fs, entry.value.tiling_index);
}

pub fn unminimizeAll() void {
    const s      = getState();
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    // Collect all windows minimized on the current workspace.
    const Entry = struct { win: u32, ts: u64, is_fs: bool, tiling_index: ?usize };
    const MAX = 128;
    var entries: [MAX]Entry = undefined;
    var count: usize = 0;

    var it = s.minimized_info.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.workspace_idx != ws_idx) continue;
        if (count < MAX) {
            entries[count] = .{
                .win          = kv.key_ptr.*,
                .ts           = kv.value_ptr.timestamp,
                .is_fs        = kv.value_ptr.saved_fs != null,
                .tiling_index = kv.value_ptr.tiling_index,
            };
            count += 1;
        }
    }
    if (count == 0) return;

    // Sort plain windows before fullscreen ones; each fullscreen restore needs
    // its own server grab so they must be handled separately after the batch.
    std.sort.pdq(Entry, entries[0..count], {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.is_fs != b.is_fs) return !a.is_fs; // plain before fullscreen
            return a.ts < b.ts;
        }
    }.lt);

    // After sorting, all plain entries precede all fullscreen entries.
    // Find the boundary using indexOfScalar on the is_fs field.
    const plain_end: usize = for (entries[0..count], 0..) |e, i| {
        if (e.is_fs) break i;
    } else count;
    const plain_wins = entries[0..plain_end];
    const fs_wins    = entries[plain_end..count];

    // Batch restore all plain windows in a single server grab.
    if (plain_wins.len > 0) {
        _ = xcb.xcb_grab_server(core.conn);

        if (core.config.tiling.enabled) {
            for (plain_wins) |e| {
                _ = s.minimized_info.remove(e.win);
                if (e.tiling_index) |ti|
                    tiling.addWindowAtFilteredIndex(e.win, ti)
                else
                    tiling.addWindow(e.win);
            }
            tiling.retileCurrentWorkspace();
        } else {
            const pos = utils.floatDefaultPos();
            for (plain_wins) |e| {
                _ = s.minimized_info.remove(e.win);
                _ = xcb.xcb_configure_window(core.conn, e.win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }

        focus.setFocus(plain_wins[plain_wins.len - 1].win, .window_spawn);

        bar.redrawInsideGrab();
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    }

    // Each fullscreen window needs its own grab.
    for (fs_wins) |e| restoreWindow(e.win);
}

// State maintenance 

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn forceUntrack(win: u32) void {
    const s = getState();
    _ = s.minimized_info.remove(win);
}

/// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(win: u32, new_ws: u8) void {
    const s = getState();
    const entry = s.minimized_info.getPtr(win) orelse return;
    entry.workspace_idx = new_ws;
}

