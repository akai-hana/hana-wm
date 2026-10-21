//! Minimize feature: hides a window from the core by writing only its generic
//! `.parked` presence; the core never names minimize. The real minimized
//! state lives in this module's own static, allocation-free, bounded record
//! table (`g_recs`, capped at `max_minimized`), one record per window with
//! its former tiled slot and a monotonic sequence number. This module owns
//! the transitions around that state: minimize/restore, FIFO/LIFO
//! restore-target selection, restore-all-on-workspace, record cleanup, and
//! the `contract.WindowModule` persistence hooks (9-byte blob: 0x5A magic +
//! slot + seq).

const std = @import("std");
const model = @import("model");
const log = std.log.scoped(.minimize);
const bounded = @import("bounded");
const pipeline = @import("pipeline");
const focus = @import("focus");
const build_options = @import("build_options");
const registry = @import("registry");
const reconcile_tails = @import("reconcile_tails");

fn resetState() void {
    g_recs.clear();
    g_seq = 0;
}

pub fn init() anyerror!void {
    resetState();
}

pub fn deinit() void {
    resetState();
}

/// Maximum number of concurrently minimized windows. This module owns the
/// buffer it bounds; distinct from `model.max_tiled_windows`.
pub const max_minimized: usize = 32;

pub const MinimizeError = error{CapacityFull};

/// One minimized window's parked record. The on-disk blob is PackedMinimize
/// Parsed ({magic: u8, slot: u32, seq: u32}; slot is maxInt for
/// floating-originated).
const Rec = struct { win: model.WindowId, slot: ?usize, seq: u32, origin: ?model.WSId };

/// Magic byte of the on-disk blob ('Z' — see serializeWindow).
const min_magic: u8 = 0x5A;

/// The on-disk blob layout: {magic: u8, slot-OR-maxInt: u32, seq: u32}.
/// Native-endian u32 fields keep the byte layout of the earlier slice
/// format, so existing restore files stay readable.
const PackedMinimize = extern struct {
    magic: u8 align(1),
    slot: u32 align(1),
    seq: u32 align(1),
};

/// Self-contained minimized store: static, allocation-free, <= 32 entries,
/// linear scans by design. No model bookkeeping backs it.
var g_recs: bounded.BoundedList(Rec, max_minimized) = .{};

/// Monotonic minimize counter; stamps `Rec.seq` across restores too (never
/// reused) so the restore commands can pick LIFO/FIFO targets without a side
/// buffer. Saturating: after 2^32 minimizes it pins at maxInt(u32) instead of
/// wrapping, so persisted seqs keep ordering stable (a wrap would collide
/// with old blobs on restore).
var g_seq: u32 = 0;

pub fn minimize(m: *model.Model, win: model.WindowId) MinimizeError!void {
    if (isMinimized(m, win)) return; // idempotent
    // Unknown window: nothing to park and no record to keep.
    if (m.store.get(win) == null) return;
    // Capacity check BEFORE any mutation.
    if (g_recs.len >= max_minimized) return error.CapacityFull;
    var origin: ?model.WSId = null;
    const slot = parkEntry(m, win, &origin);
    const appended = g_recs.append(.{ .win = win, .slot = slot, .seq = g_seq, .origin = origin });
    std.debug.assert(appended); // cannot fail: capacity pre-checked above
    g_seq = g_seq +| 1;
}

/// Shared park: drop `win`'s tiled home-list slot and mark the entry parked.
/// Returns the former slot (or null when it held none). `origin` receives
/// the workspace whose list the slot was taken from (null for a slotless
/// park), so restore can tell whether the slot index is still meaningful.
fn parkEntry(m: *model.Model, win: model.WindowId, origin: *?model.WSId) ?usize {
    origin.* = null;
    const e = m.store.getPtr(win) orelse return null;
    var slot: ?usize = null;
    if (model.findHome(m, win)) |h| {
        slot = m.ws[h.index].tiled_order.indexOfScalar(win);
        model.removeValue(&m.ws[h.index].tiled_order, win);
        origin.* = h;
    }
    // Clear the cached home for every anchor: a parked window is in no
    // tiled_order, and keeping its home fed parked windows into a
    // destination tiled_order on move/tag.
    e.home_ws = null;
    e.presence = .parked; // mode stays unchanged (base/fullscreen)
    return slot;
}

pub fn restore(m: *model.Model, win: model.WindowId) void {
    const idx = g_recs.indexOfByIdField(.win, win) orelse return;
    const rec = g_recs.slice()[idx];
    const e = m.store.getPtr(win) orelse return;
    // Which current anchors re-enter a home list? Derived from the CURRENT
    // anchor (left untouched by minimize): tiled-anchor windows must be
    // re-listed; floating-anchored ones restore to their saved rect directly
    // and are never appended (a phantom layout member). A covering window
    // keeps its anchor, so re-listing applies to fullscreen-tiled too.
    if (e.anchor == .tiled) {
        // Restore toward the CURRENT workspace when the window is tagged to
        // it (a restore is aimed at where the user is looking); fall back to
        // the lowest tagged workspace.
        const h: model.WSId = blk: {
            if (model.taggedOn(e.*, m.current)) break :blk m.current;
            break :blk model.lowestBit(e.mask) orelse return;
        };
        const list = &m.ws[h.index].tiled_order;
        // Refuse-before-mutate: a full home list leaves the window parked
        // rather than half-restoring it.
        if (!list.append(win)) return;
        if (rec.slot) |s| {
            // Only re-seat at the recorded index when restoring to the SAME
            // workspace the slot was taken from: the index is meaningless in
            // a different destination's list and would scramble its ordering.
            // Cross-workspace restores append at the end.
            const same_origin = if (rec.origin) |o| o.eql(h) else false;
            if (same_origin) {
                const last = list.len - 1;
                if (s < last) {
                    list.orderedRemove(last);
                    _ = list.insert(s, win); // cannot fail: len < capacity here
                }
            }
        }
        e.home_ws = h;
    } else {
        e.home_ws = null; // floating restores, stays home-free
    }
    // Restore the presence pattern: a fullscreen-carrying window goes back
    // into covering (its `covering_ws` intent was preserved through the
    // minimize), so core's coverage read recognizes it as the screen owner.
    // Read the core intent off the entry rather than asking the fullscreen
    // module: a peer-module hop is a second source of truth a session
    // restore can disagree with.
    e.presence = if (e.covering_ws != null) .covering else .present;
    _ = g_recs.orderedRemove(idx);
}

fn slotLess(a: ?usize, b: ?usize) bool {
    if (a == null) return false;
    return if (b == null) true else a.? < b.?;
}

const RestoreCandidate = struct {
    win: model.WindowId,
    slot: ?usize,
    seq: u32,
};

/// Parked-on-ws predicate: the window exists, is parked (minimized), and
/// its tag mask includes `ws`.
fn parkedOnWs(m: *const model.Model, rec: Rec, ws: model.WSId) bool {
    const e = m.store.get(rec.win) orelse return false;
    if (e.presence != .parked) return false;
    return model.taggedOn(e, ws);
}

/// Restore-order target selection over minimized windows on `ws`: `.fifo` =
/// oldest minimize seq, `.lifo` = newest. Null when nothing on `ws` is
/// minimized.
fn bestSeq(
    m: *const model.Model,
    ws: model.WSId,
    order: model.RestoreOrder,
    skip_covering: bool,
) ?model.WindowId {
    var best: ?model.WindowId = null;
    var best_seq: u32 = 0;
    for (g_recs.constSlice()) |rec| {
        if (!parkedOnWs(m, rec, ws)) continue;
        if (skip_covering) {
            // Read the model's covering intent directly instead of asking a
            // PEER MODULE through the contract hook: the hook is only right
            // when the covering module is compiled in, and a hook-based scan
            // would silently pick covering windows as restore candidates in a
            // build without it. `covering_ws` is model-side truth, written on
            // capture, cleared on release, and PERSISTED — the right answer
            // even during a session restore.
            const covering = if (m.store.get(rec.win)) |e| e.covering_ws != null else false;
            if (covering) continue;
        }
        const better = switch (order) {
            .fifo => best == null or rec.seq < best_seq,
            .lifo => best == null or rec.seq > best_seq,
        };
        if (better) {
            best = rec.win;
            best_seq = rec.seq;
        }
    }
    return best;
}

pub fn restoreCandidate(
    m: *const model.Model,
    ws: model.WSId,
    order: model.RestoreOrder,
) ?model.WindowId {
    return bestSeq(m, ws, order, false);
}

/// Most recently minimized PLAIN window on `ws` (fullscreen-carrying
/// windows excluded).
pub fn latestMinimizedBase(m: *const model.Model, ws: model.WSId) ?model.WindowId {
    return bestSeq(m, ws, .lifo, true);
}

pub fn restoreAllOnWs(m: *model.Model, ws: model.WSId) void {
    var cands: [max_minimized]RestoreCandidate = undefined;
    var n: usize = 0;
    for (g_recs.constSlice()) |rec| {
        if (!parkedOnWs(m, rec, ws)) continue;
        cands[n] = .{ .win = rec.win, .slot = rec.slot, .seq = rec.seq };
        n += 1;
    }
    std.sort.heap(RestoreCandidate, cands[0..n], {}, struct {
        fn lessThan(_: void, a: RestoreCandidate, b: RestoreCandidate) bool {
            if (slotLess(a.slot, b.slot)) return true;
            if (slotLess(b.slot, a.slot)) return false;
            return a.seq < b.seq;
        }
    }.lessThan);
    for (cands[0..n]) |c| restore(m, c.win);
}

/// True when `win` currently holds a minimized record in the module store.
pub fn isMinimized(m: *const model.Model, win: model.WindowId) bool {
    _ = m;
    return g_recs.indexOfByIdField(.win, win) != null;
}

/// Number of concurrently minimized windows (the module's own count).
/// Test-only; the production bar and handoff paths read the model directly.
pub fn count() u32 {
    return @intCast(g_recs.len);
}

/// Fills `set` with every currently minimized window ID, replacing any prior
/// contents. Infallible: an allocation failure omits that window's entry (the
/// bar omits a hidden window rather than abort). Binds the collectHiddenSet
/// hook.
pub fn collectHiddenSet(
    m: *const model.Model,
    set: *std.AutoHashMapUnmanaged(model.WindowId, void),
    allocator: std.mem.Allocator,
) void {
    _ = m;
    set.clearRetainingCapacity();
    for (g_recs.constSlice()) |rec|
        set.put(allocator, rec.win, {}) catch {};
}

/// Persistence hook (serializeWindow): marshals this window's parked record
/// as an opaque 9-byte blob ([0]=0x5A magic, {slot-or-maxInt:u32, seq:u32}).
/// The magic lets the registry deserialize loop self-identify (minimize
/// claims only parked windows). Null when there is no minimized record OR
/// the model presence is not parked (a covering window is fullscreen's
/// blob). The slice is allocator-owned; handoff frees it after writing.
fn serializePreamble(m: *const model.Model, win: u32) ?Rec {
    const idx = g_recs.indexOfByIdField(.win, win) orelse return null;
    const e = m.store.get(win) orelse return null;
    if (e.presence != .parked) return null;
    return g_recs.slice()[idx];
}

pub fn serializeWindow(m: *const model.Model, win: u32, alloc: std.mem.Allocator) ?[]const u8 {
    const rec = serializePreamble(m, win) orelse return null;
    const held = alloc.alloc(u8, @sizeOf(PackedMinimize)) catch return null;
    const blob: PackedMinimize = .{
        .magic = min_magic,
        .slot = @intCast(rec.slot orelse std.math.maxInt(u32)),
        .seq = rec.seq,
    };
    @memcpy(held, std.mem.asBytes(&blob));
    return held;
}

/// Persistence hook (deserializeWindow): adopts the blob written by
/// `serializeWindow` and replays the park on the live model.
pub fn deserializeWindow(win: u32, bytes: []const u8, m: *model.Model) bool {
    if (bytes.len != 9 or bytes[0] != min_magic) return false; // not our blob; let the loop continue
    if (g_recs.indexOfByIdField(.win, win) != null) return true; // already adopted; idempotent
    if (m.store.getPtr(win) == null) return true; // window gone; claim the blob, nothing to park
    if (g_recs.len >= max_minimized) {
        // Still claim the blob (true), just without adopting the record.
        // Returning false means "not my blob": the restore loop would keep
        // asking every other module and the window would stay parked —
        // permanently invisible until the next full restart.
        log.warn("minimize: record list full; window 0x{x} not restored minimized", .{win});
        return true;
    }
    // Slice the payload back out via a byte-aligned copy (handoff buffers
    // are byte-aligned; the extern struct's align(1) u32s load unaligned
    // safely).
    const raw = std.mem.bytesToValue(PackedMinimize, bytes[0..@sizeOf(PackedMinimize)]);
    const slot: ?usize = if (raw.slot == std.math.maxInt(u32)) null else raw.slot;
    const seq = raw.seq;
    // Replay the minimize park (shared with minimize()): drop the tiled
    // slot, mark parked. `origin` recovers the workspace whose list the
    // blob's slot indexes; a park from a non-home list gets origin=null and
    // restore appends at the end.
    var origin: ?model.WSId = null;
    _ = parkEntry(m, win, &origin);
    if (g_seq <= seq) g_seq = seq +| 1; // keep the monotonic counter ahead (saturating, see g_seq)
    _ = g_recs.append(.{ .win = win, .slot = slot, .seq = seq, .origin = origin });
    return true;
}

/// Record cleanup on window teardown (wire layer fires this after removing
/// the store entry).
pub fn onWindowGone(win: u32) void {
    _ = g_recs.removeById(.win, win);
}

/// Parked-window commands, living beside the record table they fill. Each is
/// one model transition plus one reconcile entry. Atomicity: hide +
/// fallback-focus + retile land under one grab.
///
/// Focus policy reads MODEL truth (`m.focused`): hiding the focused window
/// hands focus over via focusFallback, otherwise m.focused would keep
/// pointing at the hidden window.
///
/// Hiding THE screen-covering occupant also frees the bar-hide reason; it
/// runs BEFORE the reconcile because the bar must have updated its screen
/// claim (the usable-area fact the reconcile reads) before placement is
/// re-derived.
pub fn minimizeWindow(focused: ?model.WindowId) void {
    const win = focused orelse return;
    const m = pipeline.mut();
    const was_focused = m.focused == win;
    const fs_ws_before =
        model.coveringWsOf(m, win); // Model query

    // Direct call, not hide.providerOf(.hideWindow): this module binds
    // hideWindow unconditionally (single-binder), so the registry lookup
    // only ever re-found this file's own fn.
    minimize(m, win) catch return; // Pre-refusal (CapacityFull)

    // Hiding the current workspace's covering occupant releases its screen
    // claim; retileWithFallback bumps the core fact so the bar reacts.
    reconcile_tails.retileWithFallback(m, if (fs_ws_before) |fs_ws| fs_ws.eql(m.current) else false, was_focused);
}

/// Shared hide/close withdraw tail helper for the restore family: arms the
/// deferred bar-hide when the restore opened a fresh claim.
fn armFullscreenBarHideIfNeeded(
    m: *const model.Model,
    win: model.WindowId,
    had_occupant_before: bool,
) void {
    if (build_options.has_bar and !had_occupant_before and model.isCoveringOn(m, win, m.current)) {
        registry.dispatchAll(.armPendingBarHide, .{win});
    }
}

/// Restores `win` via the `restoreWindow` hook, re-focuses it, and arms the
/// deferred bar-hide when the restore opened a fresh claim.
fn restoreTarget(m: *model.Model, win: model.WindowId) void {
    const had_occupant_before = model.coveringOccupantOn(m, m.current, .anchored_and_visible) != null;
    registry.hide.callHook(.restoreWindow, .{ m, win });
    restoreAndFocus(m, win);
    armFullscreenBarHideIfNeeded(m, win, had_occupant_before);
}

/// Restores a specific hidden window (title-bar click path).
pub fn unminimize(win: model.WindowId) void {
    const m = pipeline.mut();
    if (!registry.isMinimizedOnAnyWs(m, win)) return;
    restoreTarget(m, win);
}

/// Slot-ordered single restore (LIFO/FIFO keybind paths).
pub fn unminimizeOrdered(order: model.RestoreOrder) void {
    const m = pipeline.mut();
    const win = (if (registry.hide.providerOf(.restoreCandidateOn)) |wm|
        wm.hide.restoreCandidateOn.?(m, m.current, order)
    else
        null) orelse return;
    restoreTarget(m, win);
}

/// Slot-ordered bulk restore of the current workspace. Focus target is the
/// most recently hidden PLAIN window (screen-covering windows replay through
/// the same reconcile's covering branch).
pub fn unminimizeAll() void {
    const m = pipeline.mut();
    const wm = registry.hide.providerOf(.latestHiddenOnWs) orelse return;
    const ws = m.current;
    const target = (wm.hide.latestHiddenOnWs.?(m, ws) orelse return);
    const had_occupant_before = model.coveringOccupantOn(m, m.current, .anchored_and_visible) != null;
    registry.hide.callHook(.restoreOnWs, .{ m, ws });
    restoreAndFocus(m, target);
    if (model.coveringOccupantOn(m, m.current, .anchored_and_visible)) |occ|
        armFullscreenBarHideIfNeeded(m, occ, had_occupant_before);
}

/// Shared restore tail: re-focus the restored window (a no_input restore
/// never takes model focus, but the reconcile still runs so the restored
/// window is mapped and placed).
fn restoreAndFocus(m: *model.Model, win: model.WindowId) void {
    const prep = focus.prepareAndSetFocus(m, win, .window_spawn);
    pipeline.reconcileGrabFocus(.{ .force_restack = true }, prep, .before, null);
}

/// This module's window contribution: lifecycle + persistence hooks + record
/// cleanup for torn-down windows.
pub const module: @import("window_contract").WindowModule = .{
    .name = "minimize",
    .init = init,
    .deinit = deinit,
    .onWindowGone = onWindowGone,
    .serializeWindow = serializeWindow,
    .deserializeWindow = deserializeWindow,
    .hide = .{
        .hideWindow = minimize,
        .restoreWindow = restore,
        .restoreCandidateOn = restoreCandidate,
        .restoreOnWs = restoreAllOnWs,
        .latestHiddenOnWs = latestMinimizedBase,
        .isWindowHidden = isMinimized,
        .collectHiddenSet = collectHiddenSet,
    },
    .command = .{
        .minimizeWindow = minimizeWindow,
        .unminimize = unminimize,
        .unminimizeOrdered = unminimizeOrdered,
        .unminimizeAll = unminimizeAll,
    },
};
