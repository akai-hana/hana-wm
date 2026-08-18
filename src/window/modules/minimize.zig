//! Window minimization
//! Hides and restores windows with LIFO, FIFO, or bulk restore modes, scoped to the current workspace.

const std = @import("std");
const build = @import("build_options");

const core = @import("core");
const utils = @import("utils");
const debug = @import("debug");
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const fullscreen = @import("fullscreen");
const bar = if (build.has_bar) @import("bar") else null;
const tiling = if (build.has_tiling) @import("tiling") else null;

/// Per-window minimize record.
const MinimizedEntry = struct {
    saved_fs: ?core.WindowGeometry, // non-null iff the window was fullscreen when minimized
    workspace_idx: u8, // single workspace only; multi-workspace tagging is handled upstream
    tiling_index: ?usize, // workspace-filtered slot at minimize time to reinsert at original position
};

/// One slot in the fixed minimize buffer.
const MinimizedRecord = struct {
    id: u32,
    entry: MinimizedEntry,
};

// Configurable via build_options.max_minimized_windows (default 32).
// Exceeding it silently fails with a logged error; see minimizeWindow.
// Intentionally distinct from constants.Limits.MAX_TILED_WINDOWS: this bounds
// concurrently-minimized windows, not the tiled-window pool.
const MAX_MINIMIZED: usize = if (@hasDecl(build, "max_minimized_windows"))
    build.max_minimized_windows
else
    32;

// Entries are always appended at the end and removeFromBuf preserves relative
// order, so buffer position IS insertion order: items[0] is the oldest
// minimized window, items[len-1] the most recent. LIFO/FIFO restore read
// directly off this; which is why removal uses orderedRemove, not swapRemove.
var g_minimized: utils.BoundedList(MinimizedRecord, MAX_MINIMIZED) = .{};

// Lifecycle

pub fn init() void {
    g_minimized.clear();
}

/// No heap resources are owned, so deinit is just a state reset.
pub fn deinit() void {
    init();
}

/// Returns the index into g_minimized for the given window, or null.
fn findInBuf(win: u32) ?usize {
    return g_minimized.indexOfById(win);
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

pub fn minimizeWindow() void {
    const cs = core.getState();
    if (!cs.config.minimize_enabled) return;
    const win = focus.getFocused() orelse return;
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return;

    // Guard: check capacity before mutating any state so there is no rollback path.

    if (g_minimized.len >= MAX_MINIMIZED) {
        debug.err("minimize: buffer full ({d} entries), cannot minimize 0x{x}", .{ MAX_MINIMIZED, win });
        return;
    }

    // -- Side effects begin here; buffer slot is guaranteed -------------------

    // Tear down fullscreen state if needed, saving geometry for later restore.
    var saved_fs: ?core.WindowGeometry = null;
    fs_blk: {
        const fs_ws = fullscreen.workspaceFor(win) orelse break :fs_blk;
        saved_fs = fullscreen.getForWorkspace(fs_ws).?.saved_geometry;
        fullscreen.removeForWorkspace(fs_ws);
    }
    const tiling_index = if (build.has_tiling) tiling.getWindowFilteredIndex(win) else null;

    if (cs.config.tiling.enabled) if (build.has_tiling) tiling.removeWindow(win);

    // Capacity was already checked above, so this always succeeds.
    _ = g_minimized.append(.{ .id = win, .entry = .{
        .saved_fs = saved_fs,
        .workspace_idx = ws_idx,
        .tiling_index = tiling_index,
    } });

    // Resolve the fallback focus target and its input model BEFORE the grab:
    // focusBestAvailable would otherwise run setFocus's blocking WM_PROTOCOLS
    // reply wait inside it (see focus.setFocusWithModel).
    //
    // Two-tier resolution, both scoped to the current workspace so this can
    // never hand focus to a window living on a workspace the user isn't even
    // looking at:
    //  1. The most recently focused-then-defocused window on this workspace,
    //     per tracking's per-workspace focus MRU; this is "whichever window
    //     you were looking at before the one you just minimized", not merely
    //     *a* visible window.
    //  2. Fallback when the MRU has nothing eligible (e.g. right after a
    //     workspace switch, before any focus transition has been recorded
    //     for it yet): the first visible window on this workspace in
    //     tracking order.
    const restore_target = tracking.popFocusMru(ws_idx, tracking.isOnCurrentWorkspaceAndVisible) orelse
        focus.findBestAvailable(tracking.isOnCurrentWorkspaceAndVisible);
    const restore_ctx = focus.FocusContext.resolve(restore_target);

    utils.grabServer(cs.conn);
    utils.pushWindowOffscreen(cs.conn, win);

    // When restore_target is null, nothing eligible remains on this
    // workspace (every window here is minimized), so the only correct
    // outcome is clearing focus; inlined here rather than going through
    // focus.focusBestAvailable() to keep the grab body free of reply waits.
    restore_ctx.apply(.tiling_operation);

    if (saved_fs != null) {
        if (build.has_bar) bar.setBarState(.show_fullscreen);
    } else if (cs.config.tiling.enabled) {
        if (build.has_tiling) tiling.retileCurrentWorkspace();
    }
    if (build.has_bar) bar.commitInsideGrab();
}

/// Restore a window that has already been removed from g_minimized.
/// Precondition: caller must remove the record before calling; asserted below.
fn restoreWindowImpl(win: u32, saved_fs: ?core.WindowGeometry, tiling_index: ?usize) void {
    std.debug.assert(!isMinimized(win));

    if (saved_fs) |geom| {
        // Fullscreen does not remove a window from the tiling pool (see
        // fullscreen.zig's enterFullscreenCommit); it just stops the layout
        // from repositioning it. So if `win` was tiled when minimizeWindow()
        // tore down its fullscreen state, tiling_index is non-null and it
        // must be reinserted at its original slot now, BEFORE re-entering
        // fullscreen. Without this, isWindowTiled(win) stays false forever:
        // when this window later exits fullscreen, exitFullscreenCommit sees
        // an untiled window, so it configures it to the saved geometry
        // directly and never hands it back to the tiling engine; it keeps
        // its dimensions but is permanently stuck outside the tiled layout.
        if (tiling_index) |ti| if (build.has_tiling) tiling.addWindowAtFilteredIndex(win, ti);

        // enterFullscreen owns its own server grab, so we must not be inside one.
        // Use scheduleRedraw (next event-loop iteration) rather than redrawInsideGrab.
        focus.setFocus(win, .window_spawn);
        fullscreen.enterFullscreen(win, geom);
        if (build.has_bar) bar.scheduleRedraw();
        return;
    }

    const conn = core.getState().conn;
    // Resolve the input model BEFORE the grab: setFocus's blocking WM_PROTOCOLS
    // reply wait inside the grab would implicitly flush the queued retile
    // configure_window batch to the compositor mid-grab (see
    // focus.setFocusWithModel).
    const focus_ctx = focus.FocusContext.resolve(win);
    utils.grabServer(conn);

    if (core.getState().config.tiling.enabled) {
        if (tiling_index) |ti| {
            // Restore at the original layout slot so a former master returns to
            // master rather than being appended to the stack end.
            if (build.has_tiling) tiling.addWindowAtFilteredIndex(win, ti);
            // Move focus BEFORE the retile: layouts that pick their visible window
            // from focus.getFocused() at retile time (monocle) would otherwise
            // retile against the still-focused old window with no follow-up retile
            // once focus lands on `win`.
            focus.setFocusWithModel(win, .window_spawn, focus_ctx.model.?);
            if (build.has_tiling) tiling.retileCurrentWorkspace();
        } else {
            // Window was floating when minimized (not in the tiling pool);
            // restore its floating geometry instead of adding it to tiling.
            window.restoreFloatGeom(win);
            focus.setFocusWithModel(win, .window_spawn, focus_ctx.model.?);
        }
    } else {
        window.restoreFloatGeom(win);
        focus.setFocusWithModel(win, .window_spawn, focus_ctx.model.?);
    }

        if (build.has_bar) bar.commitInsideGrab();
}

pub const RestoreOrder = enum { lifo, fifo };

/// Remove the minimized record at `idx` and restore the window.
/// Precondition: `idx` is a valid index into g_minimized.
fn unminimizeAtIndex(idx: usize) void {
    const rec = g_minimized.items[idx];
    const win = rec.id;
    const saved_fs = rec.entry.saved_fs;
    const tiling_index = rec.entry.tiling_index;
    _ = removeFromBuf(win);
    restoreWindowImpl(win, saved_fs, tiling_index);
}

pub fn unminimize(order: RestoreOrder) void {
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    // Buffer position is insertion order. One forward scan serves both modes:
    // FIFO breaks on the first matching entry, LIFO keeps scanning so the last
    // (most recent) matching entry wins.
    var best_idx: ?usize = null;
    for (g_minimized.constSlice(), 0..) |rec, i| {
        if (rec.entry.workspace_idx != ws_idx) continue;
        best_idx = i;
        if (order == .fifo) break;
    }

    const idx = best_idx orelse return;
    unminimizeAtIndex(idx);
}

/// Restores a specific minimized window, regardless of where it falls in the
/// LIFO/FIFO order `unminimize` uses. Used by the title bar segment's click
/// handling: clicking a minimized window's segment should bring back that
/// particular window, not "whichever `unminimize` would have picked".
/// No-op if `win` is not currently minimized.
pub fn unminimizeSpecific(win: u32) void {
    const idx = findInBuf(win) orelse return;
    unminimizeAtIndex(idx);
}

const Partitioned = struct {
    plain: [MAX_MINIMIZED]MinimizedRecord = undefined,
    fs: [MAX_MINIMIZED]MinimizedRecord = undefined,
    plain_len: usize = 0,
    fs_len: usize = 0,

    fn plainSlice(self: *Partitioned) []MinimizedRecord {
        return self.plain[0..self.plain_len];
    }

    fn fsSlice(self: *const Partitioned) []const MinimizedRecord {
        return self.fs[0..self.fs_len];
    }
};

fn partitionByFullscreen(snapshot: []const MinimizedRecord) Partitioned {
    var result: Partitioned = .{};
    for (snapshot) |rec| {
        if (rec.entry.saved_fs == null) {
            result.plain[result.plain_len] = rec;
            result.plain_len += 1;
        } else {
            result.fs[result.fs_len] = rec;
            result.fs_len += 1;
        }
    }
    return result;
}

/// Restore a batch of plain (non-fullscreen) minimized windows back into the
/// tiling layout, sorted by original tiling index so lower-index slots are
/// inserted first. Caller must already hold the server grab and have resolved
/// the focus input model.
fn restorePlainWindowsTiling(plain_wins: []MinimizedRecord, focus_target: u32, focus_model: window.InputModel) void {
    // Re-sort by tiling_index ascending (nulls last) before inserting.
    // Inserting at index i shifts every slot > i by 1, so lower-index
    // windows must go first to avoid displacing higher-index targets.
    //
    // Example ([X, A, B, Z], A at ti=1, B at ti=2, minimized to [X, Z]):
    //   insert A@1 -> [X, A, Z]
    //   insert B@2 -> [X, A, B, Z]  <- correct
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
            if (build.has_tiling) tiling.addWindowAtFilteredIndex(rec.id, ti)
        else
            window.restoreFloatGeom(rec.id);
    }
    // Focus must move to focus_target BEFORE the retile; see the
    // matching comment in restoreWindowImpl.
    focus.setFocusWithModel(focus_target, .window_spawn, focus_model);
    if (build.has_tiling) tiling.retileCurrentWorkspace();
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
    for (snapshot[0..count]) |rec| _ = removeFromBuf(rec.id);

    var partitioned = partitionByFullscreen(snapshot[0..count]);
    const plain_wins = partitioned.plainSlice();
    const fs_wins = partitioned.fsSlice();

    if (plain_wins.len > 0) {
        // Focus the most recently minimized window (LIFO semantics):
        // plain_wins is still in FIFO order here, so that's the last entry;
        // captured before the tiling-index sort below reorders the array.
        const focus_target = plain_wins[plain_wins.len - 1].id;

        const conn = core.getState().conn;
        // Resolve the input model BEFORE the grab; see restoreWindowImpl.
        const focus_ctx = focus.FocusContext.resolve(focus_target);
        utils.grabServer(conn);

        if (core.getState().config.tiling.enabled) {
            restorePlainWindowsTiling(plain_wins, focus_target, focus_ctx.model.?);
        } else {
            for (plain_wins) |rec| window.restoreFloatGeom(rec.id);
            focus.setFocusWithModel(focus_target, .window_spawn, focus_ctx.model.?);
        }

    if (build.has_bar) bar.commitInsideGrab();
    }

    // Each fullscreen window needs its own grab (enterFullscreen owns it).
    for (fs_wins) |rec| restoreWindowImpl(rec.id, rec.entry.saved_fs, rec.entry.tiling_index);
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
        set.putAssumeCapacity(rec.id, {});
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
