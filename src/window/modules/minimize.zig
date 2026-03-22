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
//! per-workspace ordered lists are maintained.  Scanning the fixed buffer for
//! the LIFO/FIFO candidate is O(n), but n is always tiny in practice (typically
//! < 10 minimized windows), the entire buffer fits in cache, and there is no
//! hashing cost, no heap pointer chase, and no allocator dependency.
//!
//! Fullscreen interaction: minimizing a fullscreen window tears down the
//! fullscreen state but saves the pre-fullscreen geometry. Restoring such
//! a window puts it back into fullscreen exactly as it was.
//!
//! NOTE: init() is now infallible (void return).  Callers that previously did
//! `try minimize.init()` should change the call to `minimize.init()`.

const std        = @import("std");
const core       = @import("core");
const xcb        = core.xcb;
const utils      = @import("utils");
const focus      = @import("focus");
const has_tiling = @import("build_options").has_tiling;
const tiling = if (has_tiling) @import("tiling") else struct {
    pub fn addWindow(_: u32) void {}
    pub fn addWindowAtFilteredIndex(_: u32, _: usize) void {}
    pub fn removeWindow(_: u32) void {}
    pub fn retileCurrentWorkspace() void {}
    pub fn getWindowFilteredIndex(_: u32) ?usize { return null; }
};
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

/// One slot in the fixed minimize buffer.
const MinimizedRecord = struct {
    win:   u32,
    entry: MinimizedEntry,
};

// Module state
//
// A fixed buffer replaces the former AutoHashMap(u32, MinimizedEntry).
// Rationale: the realistic population is 0-10 minimized windows at any time.
// For that range a HashMap costs more than it saves: hash computation on every
// probe, a heap allocation up-front, a pointer chase to the backing store on
// every access, and a failure path in init() that required callers to propagate
// !void.  A flat array of MinimizedRecords is smaller, stays entirely in cache,
// and has zero allocator involvement.  MAX_MINIMIZED = 32 is deliberately more
// than any real session needs; hitting the cap produces a clear error message
// and a rollback rather than silent corruption.

const MAX_MINIMIZED: usize = 32;

var g_buf:            [MAX_MINIMIZED]MinimizedRecord = undefined;
var g_len:            u8  = 0;
var g_next_timestamp: u64 = 0;

// Lifecycle

pub fn init() void {
    g_len            = 0;
    g_next_timestamp = 0;
}

pub fn deinit() void {
    g_len = 0;
}

// Internal buffer helpers

/// O(1) removal by swapping the target entry with the last.
/// Buffer order is not semantically significant — LIFO/FIFO ordering is
/// encoded in each entry's timestamp, not its position in the buffer.
fn removeFromBuf(win: u32) void {
    for (g_buf[0..g_len], 0..) |rec, i| {
        if (rec.win == win) {
            g_len   -= 1;
            g_buf[i] = g_buf[g_len];
            return;
        }
    }
}

// Public queries

pub inline fn isMinimized(win: u32) bool {
    for (g_buf[0..g_len]) |rec| if (rec.win == win) return true;
    return false;
}

inline fn hideWindow(win: u32) void {
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
}

/// Focus the first non-minimized window on the current workspace in insertion
/// order, falling back to clearFocus() if none exists.
///
/// This is a last-resort fallback used when the MRU history has been exhausted
/// (e.g. after unmanaging a window with no prior focus history) or during
/// minimize when no prior focused window is recorded.  It intentionally does
/// not consult focus history — that is the caller's responsibility.
///
/// Named to distinguish it from focus.focusBestAvailable(), which walks MRU
/// history with a caller-supplied visibility predicate.  This function uses
/// workspace insertion order, which is not MRU, and is specifically suited
/// to tiling fallback (master or first slave).
pub fn focusMasterOrFirst() void {
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
/// Called only on buffer-full failure; restores tiling and fullscreen
/// state so the window remains visible and the WM stays consistent.
inline fn rollbackMinimize(win: u32, fs_ws: ?u8, saved_fs: ?core.WindowGeometry) void {
    if (core.config.tiling.enabled) {
        tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    }
    if (saved_fs) |geom| {
        fullscreen.setForWorkspace(fs_ws.?, .{ .window = win, .saved_geometry = geom });
    }
}

pub fn minimizeWindow() void {
    const win    = focus.getFocused()               orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return;

    // Tear down fullscreen state if needed, saving geometry for later restore.
    var saved_fs: ?core.WindowGeometry = null;
    var fs_ws_for_rollback: ?u8 = null;
    if (fullscreen.workspaceFor(win)) |fs_ws| {
        saved_fs = fullscreen.getForWorkspace(fs_ws).?.saved_geometry;
        fs_ws_for_rollback = fs_ws;
        fullscreen.removeForWorkspace(fs_ws);
    }
    const tiling_index = tiling.getWindowFilteredIndex(win);

    if (core.config.tiling.enabled) tiling.removeWindow(win);

    if (g_len >= MAX_MINIMIZED) {
        debug.err("minimize: buffer full ({d} entries), cannot minimize 0x{x} -- rolling back",
            .{ MAX_MINIMIZED, win });
        rollbackMinimize(win, fs_ws_for_rollback, saved_fs);
        return;
    }

    const ts = g_next_timestamp;
    g_buf[g_len] = .{ .win = win, .entry = .{
        .saved_fs      = saved_fs,
        .workspace_idx = ws_idx,
        .timestamp     = ts,
        .tiling_index  = tiling_index,
    }};
    g_len           += 1;
    g_next_timestamp = ts + 1;

    _ = xcb.xcb_grab_server(core.conn);
    hideWindow(win);
    focusMasterOrFirst();
    if (saved_fs != null) {
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
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ pos.x, pos.y });
    }

    focus.setFocus(win, .window_spawn);
    bar.redrawInsideGrab();
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

/// Remove `win` from the buffer and restore it.
inline fn restoreWindow(win: u32) void {
    for (g_buf[0..g_len], 0..) |rec, i| {
        if (rec.win == win) {
            // Capture the fields before the swap-remove invalidates this slot.
            const saved_fs     = rec.entry.saved_fs;
            const tiling_index = rec.entry.tiling_index;
            g_len   -= 1;
            g_buf[i] = g_buf[g_len];
            restoreWindowImpl(win, saved_fs, tiling_index);
            return;
        }
    }
}

// Unminimize

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(order: RestoreOrder) void {
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    // Resolve the comparison direction once — `order` is a loop-invariant
    // constant and the branch would otherwise be re-evaluated on every entry.
    const want_max = (order == .lifo);
    var best_idx: ?usize = null;
    var best_ts:  u64    = 0;

    for (g_buf[0..g_len], 0..) |rec, i| {
        if (rec.entry.workspace_idx != ws_idx) continue;
        const ts = rec.entry.timestamp;
        const better = best_idx == null or
            (if (want_max) ts > best_ts else ts < best_ts);
        if (better) { best_idx = i; best_ts = ts; }
    }

    const idx = best_idx orelse return;

    // Capture before the swap-remove.
    const win          = g_buf[idx].win;
    const saved_fs     = g_buf[idx].entry.saved_fs;
    const tiling_index = g_buf[idx].entry.tiling_index;
    g_len      -= 1;
    g_buf[idx]  = g_buf[g_len];

    restoreWindowImpl(win, saved_fs, tiling_index);
}

pub fn unminimizeAll() void {
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;

    // Collect all windows minimized on the current workspace.
    // saved_fs is included so fullscreen windows can be restored directly
    // via restoreWindowImpl without a second buffer lookup (all entries will
    // have already been removed by the time the fullscreen loop runs).
    const Entry = struct {
        win:          u32,
        ts:           u64,
        is_fs:        bool,
        tiling_index: ?usize,
        saved_fs:     ?core.WindowGeometry,
    };
    const MAX = 128;
    var entries: [MAX]Entry = undefined;
    var count:   usize      = 0;

    for (g_buf[0..g_len]) |rec| {
        if (rec.entry.workspace_idx != ws_idx) continue;
        if (count < MAX) {
            entries[count] = .{
                .win          = rec.win,
                .ts           = rec.entry.timestamp,
                .is_fs        = rec.entry.saved_fs != null,
                .tiling_index = rec.entry.tiling_index,
                .saved_fs     = rec.entry.saved_fs,
            };
            count += 1;
        }
    }
    if (count == 0) return;

    // Remove all collected windows from the buffer up-front, before any
    // visual work begins.  removeFromBuf uses swap-with-last; since we are
    // working from a separate snapshot (entries[]), not iterating g_buf
    // directly, the reordering it causes is safe.
    for (entries[0..count]) |e| removeFromBuf(e.win);

    // Sort plain windows before fullscreen ones; each fullscreen restore needs
    // its own server grab so they must be handled separately after the batch.
    std.sort.pdq(Entry, entries[0..count], {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.is_fs != b.is_fs) return !a.is_fs; // plain before fullscreen
            return a.ts < b.ts;
        }
    }.lt);

    // After sorting, all plain entries precede all fullscreen entries.
    var plain_end: usize = 0;
    while (plain_end < count and !entries[plain_end].is_fs) plain_end += 1;
    const plain_wins = entries[0..plain_end];
    const fs_wins    = entries[plain_end..count];

    // Batch restore all plain windows in a single server grab.
    if (plain_wins.len > 0) {
        _ = xcb.xcb_grab_server(core.conn);

        if (core.config.tiling.enabled) {
            for (plain_wins) |e| {
                if (e.tiling_index) |ti|
                    tiling.addWindowAtFilteredIndex(e.win, ti)
                else
                    tiling.addWindow(e.win);
            }
            tiling.retileCurrentWorkspace();
        } else {
            const pos = utils.floatDefaultPos();
            for (plain_wins) |e| {
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

    // Each fullscreen window needs its own grab (enterFullscreen owns it).
    // Entries were already removed from g_buf above, so restoreWindowImpl is
    // called directly — no buffer lookup needed.
    for (fs_wins) |e| restoreWindowImpl(e.win, e.saved_fs, e.tiling_index);
}

// Snapshot helpers

/// Fills `set` with the window ID of every currently minimized window.
/// Called by bar.zig to build the per-frame BarSnapshot.minimized_set.
/// The caller is responsible for clearing the set before this call.
pub fn populateSet(
    set:       *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) !void {
    try set.ensureTotalCapacity(allocator, g_len);
    for (g_buf[0..g_len]) |rec|
        set.putAssumeCapacity(rec.win, {});
}

// State maintenance

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn forceUntrack(win: u32) void {
    removeFromBuf(win);
}

/// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(win: u32, new_ws: u8) void {
    for (g_buf[0..g_len]) |*rec| {
        if (rec.win == win) {
            rec.entry.workspace_idx = new_ws;
            return;
        }
    }
}
