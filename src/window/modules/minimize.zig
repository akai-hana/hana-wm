//! Window minimization
//! Hides and restores windows with LIFO, FIFO, or bulk restore modes, scoped to the current workspace.

const std   = @import("std");
const build = @import("build_options");

const core      = @import("core");
    const xcb   = core.xcb;
const utils     = @import("utils");
const constants = @import("constants");

const debug = @import("debug");

const window   = @import("window");
const tracking = @import("tracking");
const focus    = @import("focus");

const fullscreen  = if (build.has_fullscreen) @import("fullscreen");
const workspaces  = if (build.has_workspaces) @import("workspaces") else struct {
    pub const Workspace = struct {};
    pub fn getCurrentWorkspaceObject() ?*Workspace { return null; }
};
const WsWorkspace = workspaces.Workspace;

const tiling = if (build.has_tiling) @import("tiling") else struct {
    pub fn addWindow(_: u32) void {}
    pub fn addWindowAtFilteredIndex(_: u32, _: usize) void {}
    pub fn removeWindow(_: u32) void {}
    pub fn retileCurrentWorkspace() void {}
    pub fn getWindowFilteredIndex(_: u32) ?usize { return null; }
};

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn setBarState(_: anytype) void {}
    pub fn redrawInsideGrab() void {}
    pub fn scheduleRedraw() void {}
};

/// Per-window minimize record.
const MinimizedEntry = struct {
    saved_fs:      ?core.WindowGeometry, // non-null iff the window was fullscreen when minimized
    workspace_idx: u8,                   // single workspace only; multi-workspace tagging is handled upstream
    timestamp:     u64,                  // monotonic counter; higher = more recently minimized (drives LIFO/FIFO)
                                         //TODO: is a monotonic counter really the best way to drive lifo/fifo?
    tiling_index:  ?usize,               // workspace-filtered slot at minimize time to reinsert at original position
};

/// One slot in the fixed minimize buffer.
const MinimizedRecord = struct {
    win:   u32,
    entry: MinimizedEntry,
};

// Configurable via build_options.max_minimized_windows; 32 is the default.
// Exceeding this silently fails (with a logged error) — see minimizeWindow.
const MAX_MINIMIZED: usize = if (@hasDecl(build, "max_minimized_windows"))
    build.max_minimized_windows
else
    32;

// Zero-initialised so slots beyond g_len never contain garbage.
var g_buf:            [MAX_MINIMIZED]MinimizedRecord = std.mem.zeroes([MAX_MINIMIZED]MinimizedRecord);
var g_len:            usize = 0;
var g_next_timestamp: u64 = 0;

// Lifecycle

pub fn init() void {
    g_len            = 0;
    g_next_timestamp = 0;
}

/// No heap resources are owned, so deinit is just a state reset.
pub fn deinit() void { init(); }

/// Returns the index into g_buf[0..g_len] for the given window, or null.
fn findInBuf(win: u32) ?usize {
    for (g_buf[0..g_len], 0..) |rec, i| {
        if (rec.win == win) return i;
    }
    return null;
}

/// O(1) removal via swap-with-last. Buffer order has no semantic meaning —
/// LIFO/FIFO ordering is encoded in each entry's timestamp, not its position.
/// Returns true if the window was found and removed.
fn removeFromBuf(win: u32) bool {
    if (findInBuf(win)) |i| {
        g_len   -= 1;
        g_buf[i] = g_buf[g_len];
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
    if (!build.has_workspaces) { focus.clearFocus(); return; }
    const cur = tracking.getCurrentWorkspace() orelse { focus.clearFocus(); return; };
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
    const win    = focus.getFocused()             orelse return;
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return;

    // ── Guard: fail fast before touching any other module's state ────────────
    //
    // Both checks are cheap (a comparison against a module-local integer) and
    // have no side effects. Placing them here eliminates the need for a
    // rollback path — no other module's state has been mutated if we return.

    if (g_len >= MAX_MINIMIZED) {
        debug.err("minimize: buffer full ({d} entries), cannot minimize 0x{x}",
            .{ MAX_MINIMIZED, win });
        return;
    }

    // u64 overflow is unreachable in any real session (~1.8e19 operations),
    // but assert so a future regression is loud rather than a silent ordering bug.
    std.debug.assert(g_next_timestamp != std.math.maxInt(u64));

    // ── Side effects begin here — buffer slot is guaranteed ──────────────────

    // Tear down fullscreen state if needed, saving geometry for later restore.
    var saved_fs: ?core.WindowGeometry = null;
    if (build.has_fullscreen) fs_blk: {
        const fs_ws = fullscreen.workspaceFor(win) orelse break :fs_blk;
        saved_fs = fullscreen.getForWorkspace(fs_ws).?.saved_geometry;
        fullscreen.removeForWorkspace(fs_ws);
    }
    const tiling_index = tiling.getWindowFilteredIndex(win);

    if (core.config.tiling.enabled) tiling.removeWindow(win);

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
    utils.pushWindowOffscreen(core.conn, win);

    // Prefer MRU history; fall back to workspace insertion order.
    focus.focusBestAvailable(.tiling_operation, struct {
        fn visible(w: u32) bool { return !isMinimized(w); }
    }.visible, focusMasterOrFirst);

    if (saved_fs != null) {
        bar.setBarState(.show_fullscreen);
    } else if (core.config.tiling.enabled) {
        tiling.retileCurrentWorkspace();
    }
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}

/// Restore a window that has already been removed from g_buf.
/// Precondition: caller must remove the record before calling — asserted below.
fn restoreWindowImpl(win: u32, saved_fs: ?core.WindowGeometry, tiling_index: ?usize) void {
    std.debug.assert(!isMinimized(win));

    if (saved_fs) |geom| {
        // enterFullscreen owns its own server grab, so we must not be inside one.
        // Use scheduleRedraw (next event-loop iteration) rather than redrawInsideGrab.
        focus.setFocus(win, .window_spawn);
        if (build.has_fullscreen) fullscreen.enterFullscreen(win, geom);
        bar.scheduleRedraw();
        return;
    }

    _ = xcb.xcb_grab_server(core.conn);

    if (core.config.tiling.enabled) {
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
    utils.ungrabAndFlush(core.conn);
}

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(order: RestoreOrder) void {
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    const want_max = (order == .lifo);
    var best_idx: ?usize = null;
    // Sentinels: LIFO scans for the highest timestamp (any real ts beats 0);
    // FIFO scans for the lowest (any real ts beats maxInt).
    var best_ts: u64 = if (want_max) 0 else std.math.maxInt(u64);

    for (g_buf[0..g_len], 0..) |rec, i| {
        if (rec.entry.workspace_idx != ws_idx) continue;
        const ts = rec.entry.timestamp;
        const better = best_idx == null or
            (if (want_max) ts > best_ts else ts < best_ts);
        if (better) { best_idx = i; best_ts = ts; }
    }

    const idx = best_idx orelse return;

    // Capture fields before the swap-remove invalidates the slot.
    const win          = g_buf[idx].win;
    const saved_fs     = g_buf[idx].entry.saved_fs;
    const tiling_index = g_buf[idx].entry.tiling_index;
    g_len      -= 1;
    g_buf[idx]  = g_buf[g_len];

    restoreWindowImpl(win, saved_fs, tiling_index);
}

pub fn unminimizeAll() void {
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    // Snapshot this workspace's records before mutating the buffer.
    comptime std.debug.assert(MAX_MINIMIZED <= 256); // ensure snapshot fits on the stack
    var snapshot: [MAX_MINIMIZED]MinimizedRecord = undefined;
    var count: usize = 0;

    for (g_buf[0..g_len]) |rec| {
        if (rec.entry.workspace_idx != ws_idx) continue;
        snapshot[count] = rec;
        count += 1;
    }
    if (count == 0) return;

    // Remove all collected windows up-front. removeFromBuf uses swap-with-last;
    // working from a separate snapshot makes the reordering safe.
    for (snapshot[0..count]) |rec| _ = removeFromBuf(rec.win);

    // Primary sort: plain windows before fullscreen (each fullscreen restore needs
    // its own grab and must run after the batch). Secondary: ascending timestamp (FIFO).
    std.sort.pdq(MinimizedRecord, snapshot[0..count], {}, struct {
        fn lt(_: void, a: MinimizedRecord, b: MinimizedRecord) bool {
            const a_fs = a.entry.saved_fs != null;
            const b_fs = b.entry.saved_fs != null;
            if (a_fs != b_fs) return !a_fs; // plain before fullscreen
            return a.entry.timestamp < b.entry.timestamp;
        }
    }.lt);

    var plain_end: usize = 0;
    while (plain_end < count and snapshot[plain_end].entry.saved_fs == null) plain_end += 1;
    const plain_wins = snapshot[0..plain_end];
    const fs_wins    = snapshot[plain_end..count];

    if (plain_wins.len > 0) {
        // Focus the most recently minimized window (highest timestamp), matching
        // repeated LIFO unminimize semantics. Captured now because plain_wins is
        // re-sorted below for tiling insertion order.
        var focus_target = plain_wins[0].win;
        var focus_ts     = plain_wins[0].entry.timestamp;
        for (plain_wins[1..]) |rec| {
            if (rec.entry.timestamp > focus_ts) {
                focus_target = rec.win;
                focus_ts     = rec.entry.timestamp;
            }
        }

        _ = xcb.xcb_grab_server(core.conn);

        if (core.config.tiling.enabled) {
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
        utils.ungrabAndFlush(core.conn);
    }

    // Each fullscreen window needs its own grab (enterFullscreen owns it).
    for (fs_wins) |rec| restoreWindowImpl(rec.win, rec.entry.saved_fs, rec.entry.tiling_index);
}

/// Fills `set` with every currently minimized window ID, replacing any prior contents.
/// Called by bar.zig to build the per-frame BarSnapshot.minimized_set.
pub fn collectMinimizedIntoSet(
    set:       *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) !void {
    set.clearRetainingCapacity();
    try set.ensureTotalCapacity(allocator, @intCast(g_len));
    for (g_buf[0..g_len]) |rec|
        set.putAssumeCapacity(rec.win, {});
}

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn untrackWindow(win: u32) void {
    _ = removeFromBuf(win);
}

/// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(win: u32, new_ws: u8) void {
    if (findInBuf(win)) |i| {
        g_buf[i].entry.workspace_idx = new_ws;
    }
}
