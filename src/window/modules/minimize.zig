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
//! Thread safety: this module is NOT thread-safe.  All callers are assumed to
//! run on the single WM event-loop thread.  No internal synchronization is
//! performed; adding concurrent callers requires external locking.
//!
//! NOTE: init() is now infallible (void return).  Callers that previously did
//! `try minimize.init()` should change the call to `minimize.init()`.

// [#10] build_options moved to the top of the import block — it is referenced
// by several declarations below and must be visible before those lines.
const std           = @import("std");
const build_options = @import("build_options");
const core          = @import("core");
const xcb           = core.xcb;
const utils         = @import("utils");
const focus         = @import("focus");
const has_tiling    = build_options.has_tiling;
const tiling        = if (has_tiling) @import("tiling") else struct {
    pub fn addWindow(_: u32) void {}
    pub fn addWindowAtFilteredIndex(_: u32, _: usize) void {}
    pub fn removeWindow(_: u32) void {}
    pub fn retileCurrentWorkspace() void {}
    pub fn getWindowFilteredIndex(_: u32) ?usize { return null; }
};
const window        = @import("window");
const tracking      = @import("tracking");
const workspaces    = if (build_options.has_workspaces) @import("workspaces") else struct {};
const WsWorkspace   = if (build_options.has_workspaces) workspaces.Workspace else struct {};
fn wsGetCurrentWorkspaceObject() ?*WsWorkspace {
    return if (comptime build_options.has_workspaces)
        workspaces.getCurrentWorkspaceObject()
    else
        null;
}
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const bar        = if (build_options.has_bar) @import("bar") else struct {
    pub fn setBarState(_: anytype) void {}
    pub fn redrawInsideGrab() void {}
    pub fn scheduleRedraw() void {}
};
const constants  = @import("constants");
const debug      = @import("debug");

// ── Types ────────────────────────────────────────────────────────────────────

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

// ── Module state ─────────────────────────────────────────────────────────────
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

// [#16] Zero-initialize the buffer so slots beyond g_len never contain
// garbage values, making any accidental out-of-bounds read predictable.
var g_buf:            [MAX_MINIMIZED]MinimizedRecord = std.mem.zeroes([MAX_MINIMIZED]MinimizedRecord);
var g_len:            u8  = 0;
var g_next_timestamp: u64 = 0;

// ── Lifecycle ─────────────────────────────────────────────────────────────────

pub fn init() void {
    g_len            = 0;
    g_next_timestamp = 0;
}

// [#14] deinit now resets g_next_timestamp to mirror init(), making a
// deinit→init sequence fully idempotent.
pub fn deinit() void {
    g_len            = 0;
    g_next_timestamp = 0;
}

// ── Low-level buffer helpers ──────────────────────────────────────────────────

/// Reinterpret a signed screen coordinate as the u32 value XCB expects on its
/// wire format.  XCB takes geometry arguments as u32 but interprets them as i32
/// internally; @bitCast is the correct conversion and this wrapper names the
/// intent at every call site.
// [#18]
inline fn toXcbCoord(v: i32) u32 { return @bitCast(v); }

/// Return the index into g_buf[0..g_len] of the slot whose .win field matches,
/// or null if not found.  All buffer scans are centralised here to give a single
/// implementation that is easy to audit and covers all search paths.
// [#5]
fn findInBuf(win: u32) ?usize {
    for (g_buf[0..g_len], 0..) |rec, i| {
        if (rec.win == win) return i;
    }
    return null;
}

/// O(1) removal by swapping the target slot with the last entry.
/// Buffer order is not semantically significant — LIFO/FIFO ordering is
/// encoded in each entry's timestamp, not its position in the buffer.
/// Returns true if the window was found and removed, false if absent (no-op).
// [#5] single scan via findInBuf; [#returnbool] return value lets callers
// distinguish "was tracked" from "was not tracked" without a second lookup.
fn removeFromBuf(win: u32) bool {
    if (findInBuf(win)) |i| {
        g_len   -= 1;
        g_buf[i] = g_buf[g_len];
        return true;
    }
    return false;
}

// ── Public queries ────────────────────────────────────────────────────────────

// [#15] `inline` removed — the function contains a loop and force-inlining it
// at every call site would bloat the binary.  The compiler inlines trivial
// callers on its own.
pub fn isMinimized(win: u32) bool {
    return findInBuf(win) != null; // [#5] single centralised scan
}

/// Returns a read-only view of the current minimize buffer.
/// Valid until the next minimizeWindow / unminimize / forceUntrack call.
///
/// Prefer this over populateSet() — it lets the caller (e.g. bar.zig) build
/// whatever secondary structure it needs without introducing an allocator
/// dependency into this module.  See populateSet() for migration notes.
// [#8]
pub fn minimizedSlice() []const MinimizedRecord {
    return g_buf[0..g_len];
}

// ── Private helpers ───────────────────────────────────────────────────────────

// [#11] Both X and Y are now moved offscreen so no partial window exposure is
// possible regardless of the window's prior Y coordinate.  The same constant
// is reused for Y; add constants.OFFSCREEN_Y_POSITION if the axes ever need
// independent values.
inline fn hideWindow(win: u32) void {
    const off = toXcbCoord(constants.OFFSCREEN_X_POSITION); // [#18] named conversion
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
        &[_]u32{ off, off });
}

/// Focus the first non-minimized window on the current workspace in insertion
/// order, falling back to clearFocus() if none exists.
///
/// This is a last-resort fallback used after minimizeWindow has tried MRU
/// history via focus.focusBestAvailable() and found nothing focusable.  It
/// intentionally does not consult focus history — that is the caller's
/// responsibility.
///
/// Named to distinguish it from focus.focusBestAvailable(), which walks MRU
/// history with a caller-supplied visibility predicate.  This function uses
/// workspace insertion order, which is not MRU, and is specifically suited
/// to tiling fallback (master or first slave).
// [#6] `pub` removed — this is an internal fallback, not part of the module's
// public contract.  External callers should use focus.focusBestAvailable()
// directly.
pub fn focusMasterOrFirst() void {
    if (comptime build_options.has_workspaces) {
        if (wsGetCurrentWorkspaceObject()) |ws| {
            if (tracking.firstNonMinimized(ws.windows.items())) |win| {
                focus.setFocus(win, .tiling_operation);
                return;
            }
        }
    }
    focus.clearFocus();
}

// ── Minimize ──────────────────────────────────────────────────────────────────

/// Undo a partially-completed minimizeWindow call.
/// Called only on buffer-full failure; restores tiling and fullscreen state so
/// the window remains visible and the WM stays consistent.
///
/// tiling_index is the slot captured before the failed tiling.removeWindow so
/// the window is re-inserted at its original position rather than appended.
// [#15] `inline` removed — the function has branching conditional logic and
// is called only on the rare buffer-full error path; bloating callers with an
// inlined copy is not justified.
// [#1] tiling_index parameter added so rollback uses addWindowAtFilteredIndex
// instead of addWindow, preserving the window's original tiling position.
fn rollbackMinimize(win: u32, tiling_index: ?usize, fs_ws: ?u8, saved_fs: ?core.WindowGeometry) void {
    if (core.config.tiling.enabled) {
        if (tiling_index) |ti|
            tiling.addWindowAtFilteredIndex(win, ti)
        else
            tiling.addWindow(win);
        tiling.retileCurrentWorkspace();
    }
    if (comptime build_options.has_fullscreen) {
        if (saved_fs) |geom| {
            fullscreen.setForWorkspace(fs_ws.?, .{ .window = win, .saved_geometry = geom });
        }
    }
}

pub fn minimizeWindow() void {
    const win    = focus.getFocused()             orelse return;
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    if (isMinimized(win)) return;

    // Tear down fullscreen state if needed, saving geometry for later restore.
    var saved_fs: ?core.WindowGeometry = null;
    var fs_ws_for_rollback: ?u8 = null;
    if (comptime build_options.has_fullscreen) {
        if (fullscreen.workspaceFor(win)) |fs_ws| {
            saved_fs = fullscreen.getForWorkspace(fs_ws).?.saved_geometry;
            fs_ws_for_rollback = fs_ws;
            fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const tiling_index = tiling.getWindowFilteredIndex(win);

    if (core.config.tiling.enabled) tiling.removeWindow(win);

    if (g_len >= MAX_MINIMIZED) {
        debug.err("minimize: buffer full ({d} entries), cannot minimize 0x{x} -- rolling back",
            .{ MAX_MINIMIZED, win });
        // [#1] pass tiling_index so rollback re-inserts at the original slot.
        rollbackMinimize(win, tiling_index, fs_ws_for_rollback, saved_fs);
        return;
    }

    // [#12] Timestamp overflow guard.  g_next_timestamp is u64; wrapping to 0
    // would silently corrupt LIFO/FIFO ordering.  In a WM session this is
    // unreachable (~1.8e19 minimize operations), but an assertion makes any
    // future regression loud rather than silent.
    std.debug.assert(g_next_timestamp != std.math.maxInt(u64));

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

    // [#9] Try MRU history first so focus returns to the previously active
    // window.  focusBestAvailable() walks the MRU list and focuses the first
    // window for which the predicate returns true (i.e. not minimized).
    // Only fall back to workspace insertion order when history is exhausted.
    focus.focusBestAvailable(.tiling_operation, struct {
        fn visible(w: u32) bool { return !isMinimized(w); }
    }.visible, focusMasterOrFirst);

    if (saved_fs != null) {
        bar.setBarState(.show_fullscreen);
    } else if (core.config.tiling.enabled) {
        tiling.retileCurrentWorkspace();
    }
    bar.redrawInsideGrab();
    _ = xcb.xcb_ungrab_server(core.conn);
    _ = xcb.xcb_flush(core.conn);
}

// ── Restore helpers ───────────────────────────────────────────────────────────

/// Restore a window that has already been removed from g_buf.
///
/// Precondition: the caller MUST remove the window's record from g_buf before
/// calling this function.  This invariant is verified by assertion so any
/// future call site that forgets the removal is caught immediately.
// [#7] The former `restoreWindow` wrapper (inline fn, never called) has been
// deleted.  All call sites either do the swap-remove inline (unminimize) or
// batch-remove up-front (unminimizeAll) and then call this directly.
fn restoreWindowImpl(win: u32, saved_fs: ?core.WindowGeometry, tiling_index: ?usize) void {
    // [#3] Precondition check: the entry must have been removed before restore.
    std.debug.assert(!isMinimized(win));

    if (saved_fs) |geom| {
        // Fullscreen restore path: enterFullscreen owns its own server grab
        // internally, so there is no enclosing grab here.  redrawInsideGrab
        // must not be called outside a grab; scheduleRedraw is the correct
        // choice — it queues the redraw to the next event-loop iteration after
        // the grab has been fully released.
        focus.setFocus(win, .window_spawn);
        if (comptime build_options.has_fullscreen) fullscreen.enterFullscreen(win, geom);
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
    } else if (window.getWindowGeom(win)) |rect| {
        utils.configureWindow(core.conn, win, rect);
    } else {
        // [#13] Log the geometry miss so silent repositioning is observable
        // during debugging.  This is not fatal — floatDefaultPos() provides
        // a sensible fallback.
        debug.warn("minimize: no saved geometry for 0x{x}, placing at float default position",
            .{win});
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

// ── Unminimize ────────────────────────────────────────────────────────────────

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(order: RestoreOrder) void {
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

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
    const ws_idx = tracking.getCurrentWorkspace() orelse return;

    // Snapshot all records for this workspace before mutating the buffer.
    // [#20] MinimizedRecord is used directly — a parallel local Entry struct
    //       that duplicated its fields has been removed.
    // [#4]  The snapshot array is sized to MAX_MINIMIZED, which is also the
    //       buffer cap, so the snapshot can never overflow and no entries are
    //       silently dropped.  The former local MAX = 128 constant has been
    //       removed; it was larger than needed and lacked an overflow log.
    comptime std.debug.assert(MAX_MINIMIZED <= 256); // sanity: fits on the stack
    var snapshot: [MAX_MINIMIZED]MinimizedRecord = undefined;
    var count: usize = 0;

    for (g_buf[0..g_len]) |rec| {
        if (rec.entry.workspace_idx != ws_idx) continue;
        snapshot[count] = rec;
        count += 1;
    }
    if (count == 0) return;

    // Remove all collected windows from the buffer up-front, before any visual
    // work begins.  removeFromBuf uses swap-with-last; since we are working from
    // a separate snapshot the reordering it causes is safe.
    for (snapshot[0..count]) |rec| _ = removeFromBuf(rec.win);

    // Primary sort: plain windows before fullscreen ones (each fullscreen
    // restore needs its own server grab and must run after the batch).
    // Secondary sort: ascending timestamp (FIFO) within each group.
    std.sort.pdq(MinimizedRecord, snapshot[0..count], {}, struct {
        fn lt(_: void, a: MinimizedRecord, b: MinimizedRecord) bool {
            const a_fs = a.entry.saved_fs != null;
            const b_fs = b.entry.saved_fs != null;
            if (a_fs != b_fs) return !a_fs; // plain before fullscreen
            return a.entry.timestamp < b.entry.timestamp;
        }
    }.lt);

    // After sorting, all plain entries precede all fullscreen entries.
    var plain_end: usize = 0;
    while (plain_end < count and snapshot[plain_end].entry.saved_fs == null) plain_end += 1;
    const plain_wins = snapshot[0..plain_end];
    const fs_wins    = snapshot[plain_end..count];

    if (plain_wins.len > 0) {
        // [#19] Focus target: the window with the highest timestamp (most
        // recently minimized).  This gives unminimizeAll the same focus
        // semantic as repeated LIFO unminimize calls.  Captured here because
        // plain_wins is re-sorted below for tiling insertion order.
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
            // [#2] Re-sort plain_wins by tiling_index ascending (nulls last)
            // before inserting.  This is required for correctness: inserting a
            // window at index i shifts every slot > i by 1, so lower-index
            // windows must be inserted first to avoid displacing the target
            // positions of higher-index windows.
            //
            // Example (original list [X, A, B, Z], A at ti=1, B at ti=2):
            //   after minimizing: [X, Z]
            //   insert A at 1 → [X, A, Z]
            //   insert B at 2 → [X, A, B, Z]  ← correct
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
            const pos = utils.floatDefaultPos();
            for (plain_wins) |rec| {
                if (window.getWindowGeom(rec.win)) |rect| {
                    utils.configureWindow(core.conn, rec.win, rect);
                } else {
                    _ = xcb.xcb_configure_window(core.conn, rec.win,
                        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                        &[_]u32{ pos.x, pos.y });
                }
            }
        }

        // [#19] Focus the most recently minimized plain window (see comment above).
        focus.setFocus(focus_target, .window_spawn);

        bar.redrawInsideGrab();
        _ = xcb.xcb_ungrab_server(core.conn);
        _ = xcb.xcb_flush(core.conn);
    }

    // Each fullscreen window needs its own grab (enterFullscreen owns it).
    // Entries were already removed from g_buf above, so restoreWindowImpl is
    // called directly — no buffer lookup needed.
    for (fs_wins) |rec| restoreWindowImpl(rec.win, rec.entry.saved_fs, rec.entry.tiling_index);
}

// ── Snapshot helpers ──────────────────────────────────────────────────────────

/// Fills `set` with the window ID of every currently minimized window.
/// Called by bar.zig to build the per-frame BarSnapshot.minimized_set.
/// The caller is responsible for clearing the set before this call.
///
/// Deprecated: prefer iterating minimizedSlice() directly.  That removes the
/// only allocator-dependent (!void) function from this module and lets bar.zig
/// control its own memory strategy.  This function can be deleted once bar.zig
/// has been migrated.
// [#8]
pub fn populateSet(
    set:       *std.AutoHashMapUnmanaged(u32, void),
    allocator: std.mem.Allocator,
) !void {
    try set.ensureTotalCapacity(allocator, g_len);
    for (g_buf[0..g_len]) |rec|
        set.putAssumeCapacity(rec.win, {});
}

// ── State maintenance ─────────────────────────────────────────────────────────

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn forceUntrack(win: u32) void {
    _ = removeFromBuf(win); // return value intentionally ignored here
}

/// Called by workspaces.zig when a minimized window is moved to another workspace.
// [#5] findInBuf replaces an open-coded scan.
pub fn moveToWorkspace(win: u32, new_ws: u8) void {
    if (findInBuf(win)) |i| {
        g_buf[i].entry.workspace_idx = new_ws;
    }
}
