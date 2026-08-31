//! Complete minimize feature: state transitions + read helpers.
//! A self-contained plugin over the model: minimized state lives in this
//! module's OWN static store (g_recs), and the model only ever sees the
//! generic `.parked` presence pattern. The module owns the transitions
//! (minimize/restore + restore-order selection), the persistence seam
//! (serialize/deserialize), and record cleanup for torn-down windows
//! (onWindowGone). The core never names minimize.
//!
//! The deserialize hook receives the wire layer's `*model.Model` as a
//! `*anyopaque` (see plugin.WindowModule) so the seam's signature stays free
//! of model types in the core interface file (layer rule); the cast happens
//! here, where the concrete model type is known.

const std = @import("std");
const constants = @import("constants");
const utils = @import("utils");
const model = @import("model");
const build_options = @import("build_options");

pub fn init() anyerror!void {
    // Reset the static store so tests get isolation (and production re-init
    // after fatal-recovery restarts clean). The module owns all of its state.
    g_recs.clear();
    g_seq = 0;
}

pub fn deinit() void {
    g_recs.clear();
    g_seq = 0;
}

/// Ceiling on concurrently minimized windows, sourced from constants.
const MAX_MINIMIZED = constants.max_minimized;

pub const MinimizeError = error{CapacityFull};

/// One minimized window's parked record. The serialized form is `[2]u32` =
/// {tiled slot, monotonic seq} (slot is maxInt for floating-originated).
const Rec = struct { win: model.WindowId, slot: ?usize, seq: u32 };

/// Self-contained minimized store: static, allocation-free, <= 32 entries,
/// linear scans by design. No model bookkeeping backs it.
var g_recs: utils.BoundedList(Rec, MAX_MINIMIZED) = .{};

/// Monotonic minimize counter; stamps `Rec.seq` across restores too (never
/// reused) so actions can pick LIFO/FIFO restore targets without a side
/// buffer.
var g_seq: u32 = 0;

fn findRec(win: model.WindowId) ?usize {
    return g_recs.indexOfByIdField(.win, win);
}

pub fn minimize(m: *model.Model, win: model.WindowId) MinimizeError!void {
    if (isMinimized(m, win)) return; // idempotent
    // Capacity check BEFORE any mutation (T17).
    if (g_recs.len >= MAX_MINIMIZED) return error.CapacityFull;
    var slot: ?usize = null;
    if (model.findHome(m, win)) |h| {
        slot = m.ws[h].tiled_order.indexOfScalar(win);
        model.removeValue(&m.ws[h].tiled_order, win);
    }
    const e = m.store.getPtr(win) orelse return;
    e.home_ws = null; // no longer in any tiled_order
    e.presence = .parked; // mode stays unchanged (base/fullscreen)
    const appended = g_recs.append(.{ .win = win, .slot = slot, .seq = g_seq });
    std.debug.assert(appended); // cannot fail: capacity pre-checked above
    g_seq += 1;
}

pub fn restore(m: *model.Model, win: model.WindowId) void {
    const idx = findRec(win) orelse return;
    const rec = g_recs.slice()[idx];
    const e = m.store.getPtr(win) orelse return;
    // Which current anchors re-enter a home list? Derived from the CURRENT
    // anchor (left untouched by minimize): tiled-anchor windows must be
    // re-listed; floating-anchored ones restore to their saved rect directly
    // and are never appended (a phantom layout member). A covering (fullscreen)
    // window keeps its anchor, so re-listing also applies to fullscreen-tiled.
    const wants_home = switch (e.anchor) {
        .tiled => true,
        .floating => false,
    };
    if (wants_home) {
        const h: model.WSId = model.lowestBit(e.mask); // follows tag-moves made while hidden
        const list = &m.ws[h].tiled_order;
        // Refuse-before-mutate: a full home list leaves the window parked
        // rather than half-restoring it.
        if (!list.append(win)) return;
        if (rec.slot) |s| {
            const last = list.len - 1;
            if (s < last) {
                list.orderedRemove(last);
                _ = list.insert(s, win); // cannot fail: len < capacity here
            }
        }
        e.home_ws = h;
    } else {
        e.home_ws = null; // floating restores, stays home-free
    }
    e.presence = .present;
    _ = g_recs.orderedRemove(idx);
}

fn slotLess(a: ?usize, b: ?usize) bool {
    if (a == null) return false;
    if (b == null) return true;
    return a.? < b.?;
}

/// Restore-order target selection over minimized windows on `ws`:
/// `.fifo` = oldest minimize seq, `.lifo` = newest. Returns null when nothing
/// on `ws` is minimized.
pub fn restoreCandidate(m: *const model.Model, ws: model.WSId, order: model.RestoreOrder) ?model.WindowId {
    var best: ?model.WindowId = null;
    var best_seq: u32 = 0;
    for (g_recs.constSlice()) |rec| {
        const e = m.store.get(rec.win) orelse continue;
        if (e.presence != .parked) continue;
        if (e.mask & model.bit(ws) == 0) continue;
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

/// Most recently minimized PLAIN window on `ws` (fullscreen-carrying cars
/// excluded, matching the old prev != .base exclusion).
pub fn latestMinimizedBase(m: *const model.Model, ws: model.WSId) ?model.WindowId {
    var best: ?model.WindowId = null;
    var best_seq: u32 = 0;
    for (g_recs.constSlice()) |rec| {
        const e = m.store.get(rec.win) orelse continue;
        if (e.presence != .parked) continue;
        if (build_options.has_fullscreen) {
            if (@import("fullscreen").isFullscreenMode(m, rec.win)) continue;
        }
        if (e.mask & model.bit(ws) == 0) continue;
        if (best == null or rec.seq > best_seq) {
            best = rec.win;
            best_seq = rec.seq;
        }
    }
    return best;
}

pub fn restoreAllOnWs(m: *model.Model, ws: model.WSId) void {
    var wins: [MAX_MINIMIZED]model.WindowId = undefined;
    var slots: [MAX_MINIMIZED]?usize = undefined;
    var n: usize = 0;
    for (g_recs.constSlice()) |rec| {
        const e = m.store.get(rec.win) orelse continue;
        if (e.presence != .parked) continue;
        if (e.mask & model.bit(ws) == 0) continue;
        wins[n] = rec.win;
        slots[n] = rec.slot;
        n += 1;
    }
    // insertion sort by slot ascending, nulls last
    for (1..n) |a| {
        const w = wins[a];
        const s = slots[a];
        var b = a;
        while (b > 0 and slotLess(s, slots[b - 1])) : (b -= 1) {
            wins[b] = wins[b - 1];
            slots[b] = slots[b - 1];
        }
        wins[b] = w;
        slots[b] = s;
    }
    for (0..n) |i| restore(m, wins[i]);
}

/// True when `win` currently holds a minimized record in the module store.
pub fn isMinimized(m: *const model.Model, win: model.WindowId) bool {
    _ = m;
    return findRec(win) != null;
}

/// Number of concurrently minimized windows (the module's own count).
pub fn count(m: *const model.Model) u32 {
    _ = m;
    return @intCast(g_recs.len);
}

/// Saved tiled slot of a minimized window (null = floating-originated).
pub fn slotOf(m: *const model.Model, win: model.WindowId) ?usize {
    _ = m;
    const idx = findRec(win) orelse return null;
    return g_recs.slice()[idx].slot;
}

/// Monotonic sequence stamp of a minimized window.
pub fn seqOf(m: *const model.Model, win: model.WindowId) ?u32 {
    _ = m;
    const idx = findRec(win) orelse return null;
    return g_recs.slice()[idx].seq;
}

/// Next value the monotonic counter will hand out (test/bar introspection).
pub fn peekSeq(m: *const model.Model) u32 {
    _ = m;
    return g_seq;
}

/// Fills `set` with every currently minimized window ID, replacing any prior
/// contents. Called by bar.zig to build the per-frame minimized set.
pub fn collectMinimizedIntoSet(
    m: *const model.Model,
    set: *std.AutoHashMapUnmanaged(model.WindowId, void),
    allocator: std.mem.Allocator,
) !void {
    _ = m;
    set.clearRetainingCapacity();
    for (g_recs.constSlice()) |rec|
        try set.put(allocator, rec.win, {});
}

/// Persistence seam (plugin.WindowModule.serializeWindow): marshals this
/// window's parked record as an opaque 9-byte blob ([0]=0x5A 'Z' magic,
/// {slot-or-maxInt:u32, seq:u32}). The magic lets the registry deserialize
/// loop self-identify (minimize claims only parked windows). Returns null
/// when the window has no minimized record OR the model presence is not
/// parked (a covering window is fullscreen's blob). The returned slice is
/// allocator-owned; persist frees it after writing.
pub fn serializeWindow(model_ptr: *anyopaque, win: u32, alloc: std.mem.Allocator) ?[]const u8 {
    const idx = findRec(win) orelse return null;
    const m: *const model.Model = @ptrCast(@alignCast(model_ptr));
    const e = m.store.get(win) orelse return null;
    if (e.presence != .parked) return null;
    const rec = g_recs.slice()[idx];
    const held = alloc.alloc(u8, 9) catch return null;
    held[0] = 0x5A;
    const raw = std.mem.bytesAsSlice(u32, held[1..9]);
    raw[0] = @intCast(rec.slot orelse std.math.maxInt(u32));
    raw[1] = rec.seq;
    return held;
}

/// Persistence seam (plugin.WindowModule.deserializeWindow): adopts the blob
/// written by `serializeWindow` and replays the park on the live model, which
/// the wire layer passes in as `*anyopaque` (keeps the core seam signature
/// free of model types; the reverse cast happens on this side).
pub fn deserializeWindow(win: u32, bytes: []const u8, ptr: *anyopaque) bool {
    if (bytes.len != 9) return false;
    if (bytes[0] != 0x5A) return false; // not our blob; let the loop continue
    if (findRec(win) != null) return true; // already adopted; idempotent
    if (g_recs.len >= MAX_MINIMIZED) return false;
    // Slice the payload back into two native-endian u32s via an aligned copy
    // (persist buffers are byte-aligned; u32 loads need 4-byte align).
    var buf: [8]u8 align(@alignOf(u32)) = [_]u8{0} ** 8;
    @memcpy(&buf, bytes[1..9]);
    const raw = std.mem.bytesAsSlice(u32, buf[0..]);
    const slot: ?usize = if (raw[0] == std.math.maxInt(u32)) null else raw[0];
    const seq = raw[1];
    const m: *model.Model = @ptrCast(@alignCast(ptr));
    const e = m.store.getPtr(win) orelse return false;
    // Replay the minimize park: drop the tiled slot, mark parked. `mode`
    // comes from the model (already persisted), the blob restores the rec.
    if (model.findHome(m, win)) |h| model.removeValue(&m.ws[h].tiled_order, win);
    e.home_ws = null;
    e.presence = .parked;
    if (g_seq <= seq) g_seq = seq + 1; // keep the monotonic counter ahead
    _ = g_recs.append(.{ .win = win, .slot = slot, .seq = seq });
    return true;
}

/// Record cleanup on window teardown; the wire layer fires this (events /
/// unmanage) after removing the store entry.
pub fn onWindowGone(win: u32) void {
    if (findRec(win)) |i| _ = g_recs.orderedRemove(i);
}

/// Adapter for the hide seam: widens the module's `MinimizeError!void`
/// return set to the contract's uniform `anyerror!void` (the error set
/// coerces; this wrapper keeps the binding explicit).
pub fn hideWindow(m: *model.Model, win: model.WindowId) anyerror!void {
    return minimize(m, win);
}

/// collectHiddenSet adapter: widens the internal `anyerror!void` synthesis to
/// the contract's infallible `void` (the bar swallows allocation failures).
pub fn collectHiddenSet(
    m: *const model.Model,
    set: *std.AutoHashMapUnmanaged(model.WindowId, void),
    allocator: std.mem.Allocator,
) void {
    collectMinimizedIntoSet(m, set, allocator) catch {};
}

/// This module's window sub-system contribution: lifecycle + persistence
/// seam + record cleanup for torn-down windows.
pub const module: @import("plugin").WindowModule = .{
    .init = init,
    .deinit = deinit,
    .onWindowGone = onWindowGone,
    .serializeWindow = serializeWindow,
    .deserializeWindow = deserializeWindow,
    .hideWindow = hideWindow,
    .restoreWindow = restore,
    .restoreCandidateOn = restoreCandidate,
    .restoreOnWs = restoreAllOnWs,
    .latestHiddenOnWs = latestMinimizedBase,
    .isWindowHidden = isMinimized,
    .collectHiddenSet = collectHiddenSet,
};
