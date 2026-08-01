//! Window minimization
//! Hides and restores windows with LIFO, FIFO, or bulk restore modes, scoped to the current workspace.

const std = @import("std");
const build = @import("build_options");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const debug = @import("debug");
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const fullscreen = @import("fullscreen");
const workspaces = @import("workspaces");
const tiling = @import("tiling");
const bar = @import("bar");

/// Per-window minimize record.
const MinimizedEntry = struct {
    saved_fs: ?core.WindowGeometry, // non-null iff the window was fullscreen when minimized
    workspace_idx: u8, // single workspace only; multi-workspace tagging is handled upstream
    tiling_index: ?usize, // workspace-filtered slot at minimize time to reinsert at original position
};

/// One slot in the fixed minimize buffer.
const MinimizedRecord = struct {
    win: u32,
    entry: MinimizedEntry,
};

// Configurable via build_options.max_minimized_windows; 32 is the default.
// Exceeding this silently fails (with a logged error) — see minimizeWindow.
// Related to, but intentionally distinct from, constants.Limits.MAX_TILED_WINDOWS
// — this bounds concurrently-minimized windows, not the tiled-window pool.
const MAX_MINIMIZED: usize = if (@hasDecl(build, "max_minimized_windows"))
    build.max_minimized_windows
else
    32;

// Entries are always appended at the end, and removeFromBuf preserves the
// relative order of the remaining entries, so buffer position IS insertion
// order: g_minimized.items[0] is the oldest minimized window still tracked,
// g_minimized.items[g_minimized.len-1] is the most recent. LIFO/FIFO restore
// order reads directly off this — which is why removal here must use
// BoundedList.orderedRemove rather than swapRemove.
var g_minimized: utils.BoundedList(MinimizedRecord, MAX_MINIMIZED) = .{};

// Lifecycle

pub fn init() void {
    g_minimized.clear();
}

/// No heap resources are owned, so deinit is just a state reset.
pub fn deinit() void {
    init();
}

fn matchMinimizedWin(win: u32, rec: MinimizedRecord) bool {
    return rec.win == win;
}

/// Returns the index into g_minimized for the given window, or null.
fn findInBuf(win: u32) ?usize {
    return g_minimized.indexOf(win, matchMinimizedWin);
}

/// Removal that preserves the relative order of the remaining entries (see
/// g_minimized's doc comment above). Returns true if the window was found
/// and removed.
fn removeFromBuf(win: u32) bool {
    if (findInBuf(win)) |i| {
        g_minimized.orderedRemove(i);
        return true;
    }
    return false;
}

/// Returns true when `win` is currently minimized.
pub fn isMinimized(win: u32) bool {
    return findInBuf(win) != null;
}

/// Focus the first non-minimized window on the current workspace (workspace
/// insertion order, not MRU). Last-resort fallback called by minimizeWindow
/// (via focus.focusBestAvailable) and directly from window.zig.
pub fn focusMasterOrFirst() void {
    if (!core.getState().config.workspaces.enabled) {
        focus.clearFocus();
        return;
    }
    const cur = tracking.getCurrentWorkspace() orelse {
        focus.clearFocus();
        return;
    };
    const bit = tracking.workspaceBit(cur);
    for (tracking.allWindows()) |entry| {
        if (entry.mask & bit == 0) continue;
        if (!isMinimized(entry.win)) {
            focus.setFocus(entry.win, .tiling_operation);
            return;
        }
    }
    focus.clearFocus();
}

pub fn minimizeWindow() void {
    const cs = core.getState();
    if (!cs.config.minimize_enabled) return;
    const win = focus.getFocused() orelse return;
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return;

    // ── Guard: fail fast before touching any other module's state ────────────
    //
    // Both checks are cheap (a comparison against a module-local integer) and
    // have no side effects. Placing them here eliminates the need for a
    // rollback path — no other module's state has been mutated if we return.

    if (g_minimized.len >= MAX_MINIMIZED) {
        debug.err("minimize: buffer full ({d} entries), cannot minimize 0x{x}", .{ MAX_MINIMIZED, win });
        return;
    }

    // ── Side effects begin here — buffer slot is guaranteed ──────────────────

    // Tear down fullscreen state if needed, saving geometry for later restore.
    var saved_fs: ?core.WindowGeometry = null;
    fs_blk: {
        const fs_ws = fullscreen.workspaceFor(win) orelse break :fs_blk;
        saved_fs = fullscreen.getForWorkspace(fs_ws).?.saved_geometry;
        fullscreen.removeForWorkspace(fs_ws);
    }
    const tiling_index = tiling.getWindowFilteredIndex(win);

    if (cs.config.tiling.enabled) tiling.removeWindow(win);

    // Capacity was already checked above, so this always succeeds.
    _ = g_minimized.append(.{ .win = win, .entry = .{
        .saved_fs = saved_fs,
        .workspace_idx = ws_idx,
        .tiling_index = tiling_index,
    } });

    _ = xcb.xcb_grab_server(cs.conn);
    utils.pushWindowOffscreen(cs.conn, win);

    // Prefer MRU history; fall back to workspace insertion order.
    focus.focusBestAvailable(.tiling_operation, struct {
        fn visible(w: u32) bool {
            return !isMinimized(w);
        }
    }.visible, focusMasterOrFirst);

    if (saved_fs != null) {
        bar.setBarState(.show_fullscreen);
    } else if (cs.config.tiling.enabled) {
        tiling.retileCurrentWorkspace();
    }
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(cs.conn);
}

/// Restore a window that has already been removed from g_minimized.
/// Precondition: caller must remove the record before calling — asserted below.
fn restoreWindowImpl(win: u32, saved_fs: ?core.WindowGeometry, tiling_index: ?usize) void {
    std.debug.assert(!isMinimized(win));

    if (saved_fs) |geom| {
        // enterFullscreen owns its own server grab, so we must not be inside one.
        // Use scheduleRedraw (next event-loop iteration) rather than redrawInsideGrab.
        focus.setFocus(win, .window_spawn);
        fullscreen.enterFullscreen(win, geom);
        bar.scheduleRedraw();
        return;
    }

    const conn = core.getState().conn;
    _ = xcb.xcb_grab_server(conn);

    if (core.getState().config.tiling.enabled) {
        // Restore at the original layout slot so a former master returns to master,
        // rather than being appended to the end of the stack.
        if (tiling_index) |ti|
            tiling.addWindowAtFilteredIndex(win, ti)
        else
            tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    } else {
        window.restoreFloatGeom(win);
    }

    focus.setFocus(win, .window_spawn);
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(conn);
}

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(order: RestoreOrder) void {
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    // Buffer position is insertion order: LIFO wants the last matching entry,
    // FIFO wants the first.
    var best_idx: ?usize = null;
    switch (order) {
        .lifo => {
            var i = g_minimized.len;
            while (i > 0) {
                i -= 1;
                if (g_minimized.items[i].entry.workspace_idx == ws_idx) {
                    best_idx = i;
                    break;
                }
            }
        },
        .fifo => {
            for (g_minimized.constSlice(), 0..) |rec, i| {
                if (rec.entry.workspace_idx == ws_idx) {
                    best_idx = i;
                    break;
                }
            }
        },
    }

    const idx = best_idx orelse return;

    // Capture fields before removal invalidates the slot.
    const win = g_minimized.items[idx].win;
    const saved_fs = g_minimized.items[idx].entry.saved_fs;
    const tiling_index = g_minimized.items[idx].entry.tiling_index;
    _ = removeFromBuf(win);

    restoreWindowImpl(win, saved_fs, tiling_index);
}

pub fn unminimizeAll() void {
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    // Snapshot this workspace's records before mutating the buffer. Buffer
    // order is insertion order (FIFO), and this single forward pass over
    // g_minimized preserves that order in the snapshot.
    comptime std.debug.assert(MAX_MINIMIZED <= 256); // ensure snapshot fits on the stack
    var snapshot: [MAX_MINIMIZED]MinimizedRecord = undefined;
    var count: usize = 0;

    for (g_minimized.constSlice()) |rec| {
        if (rec.entry.workspace_idx != ws_idx) continue;
        snapshot[count] = rec;
        count += 1;
    }
    if (count == 0) return;

    // Remove all collected windows up-front; the snapshot is now the sole
    // record of what needs restoring.
    for (snapshot[0..count]) |rec| _ = removeFromBuf(rec.win);

    // Partition into plain vs. fullscreen (each fullscreen restore needs its
    // own grab and must run after the batch), preserving the FIFO order
    // within each group — a single forward pass keeps that stable.
    var plain_buf: [MAX_MINIMIZED]MinimizedRecord = undefined;
    var fs_buf: [MAX_MINIMIZED]MinimizedRecord = undefined;
    var plain_count: usize = 0;
    var fs_count: usize = 0;
    for (snapshot[0..count]) |rec| {
        if (rec.entry.saved_fs == null) {
            plain_buf[plain_count] = rec;
            plain_count += 1;
        } else {
            fs_buf[fs_count] = rec;
            fs_count += 1;
        }
    }
    const plain_wins = plain_buf[0..plain_count];
    const fs_wins = fs_buf[0..fs_count];

    if (plain_wins.len > 0) {
        // Focus the most recently minimized window, matching repeated LIFO
        // unminimize semantics. plain_wins is still in FIFO order here, so
        // that's simply the last entry — captured before the tiling-index
        // sort below reorders the array.
        const focus_target = plain_wins[plain_wins.len - 1].win;

        const conn = core.getState().conn;
        _ = xcb.xcb_grab_server(conn);

        if (core.getState().config.tiling.enabled) {
            // Re-sort by tiling_index ascending (nulls last) before inserting.
            // Inserting at index i shifts every slot > i by 1, so lower-index
            // windows must go first to avoid displacing higher-index targets.
            //
            // Example ([X, A, B, Z], A at ti=1, B at ti=2, minimized to [X, Z]):
            //   insert A@1 → [X, A, Z]
            //   insert B@2 → [X, A, B, Z]  ← correct
            //   (reversed order would mis-place A at index 2)
            std.sort.pdq(MinimizedRecord, plain_wins, {}, struct {
                fn lt(_: void, a: MinimizedRecord, b: MinimizedRecord) bool {
                    if (a.entry.tiling_index == null) return false; // nulls last
                    if (b.entry.tiling_index == null) return true;
                    return a.entry.tiling_index.? < b.entry.tiling_index.?;
                }
            }.lt);
            for (plain_wins) |rec| {
                if (rec.entry.tiling_index) |ti|
                    tiling.addWindowAtFilteredIndex(rec.win, ti)
                else
                    tiling.addWindow(rec.win);
            }
            tiling.retileCurrentWorkspace();
        } else {
            for (plain_wins) |rec| window.restoreFloatGeom(rec.win);
        }

        focus.setFocus(focus_target, .window_spawn);
        bar.redrawInsideGrab();
        utils.ungrabAndFlush(conn);
    }

    // Each fullscreen window needs its own grab (enterFullscreen owns it).
    for (fs_wins) |rec| restoreWindowImpl(rec.win, rec.entry.saved_fs, rec.entry.tiling_index);
}

/// Fills `set` with every currently minimized window ID, replacing any prior contents.
/// Called by bar.zig to build the per-frame BarSnapshot.minimized_set.
pub fn collectMinimizedIntoSet(
    set: *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) !void {
    set.clearRetainingCapacity();
    try set.ensureTotalCapacity(allocator, @intCast(g_minimized.len));
    for (g_minimized.constSlice()) |rec|
        set.putAssumeCapacity(rec.win, {});
}

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn untrackWindow(win: u32) void {
    _ = removeFromBuf(win);
}

/// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(win: u32, new_ws: u8) void {
    if (findInBuf(win)) |i| {
        g_minimized.items[i].entry.workspace_idx = new_ws;
    }
}