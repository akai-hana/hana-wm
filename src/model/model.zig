//! Single source of truth for management state.
//!
//! Layer rule: imports are std + utils + constants ONLY. No X11 access.
//!
//! Threading model: the Model is single-threaded — it is accessed only from
//! the event-loop thread.  All mutations happen sequentially, so no locks or
//! atomics are needed on Model fields.
//!
//! Strangler pattern: some legacy bookkeeping (e.g. fullscreen records, tiled
//! order lists) is still updated alongside Model mutations for backward
//! compatibility with subsystems that have not yet migrated to pure Model
//! queries.  These dual-writes will be removed as the migration completes.
const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");

pub const WindowId = u32;
// TYPE NOTE: WorkspaceId (core.zig) is the canonical type for workspace
// identifiers. Model code uses raw integers for internal array indexing.
// The conversion happens at the entry-point boundary.
/// Local alias so model never imports core. Convert core.WorkspaceId via
/// `.index` at entry points.
pub const WSId = u16;
pub const Mask = u64;

pub inline fn bit(ws: WSId) Mask {
    return @as(Mask, 1) << @intCast(ws);
}

/// REUSE the exact identifier that exists in constants.zig for the max
/// workspace count (`max_workspaces`); if named differently there, alias it
/// here under MAX_WS without renaming the original.
const MAX_WS = constants.max_workspaces;
/// REUSE the exact identifier for the minimize capacity constant used by
/// legacy minimize.zig (`max_minimized`).
const MAX_MINIMIZED = constants.max_minimized;

pub const ALL_MASK: Mask = ~@as(Mask, 0);

/// STRANGLER COPY: duplicate of layouts.SizeHints. Field-for-field identical;
/// pipeline converts between the two during migration. Do NOT import
/// layouts from here (layer rule).
pub const SizeHints = struct {
    max_width: u16 = 0, // PMaxSize
    max_height: u16 = 0,
    inc_width: u16 = 0, // PResizeInc: w = base_width + N * inc_width
    inc_height: u16 = 0,
    min_aspect: f32 = 0.0, // PAspect (dwm convention)
    max_aspect: f32 = 0.0,
};

pub const LayoutKind = enum { master, monocle, grid, fibonacci, leaf, scroll };

pub const LayoutParams = struct {
    kind: LayoutKind = .master,
    variant_idx: u8 = 0,
    master_width: f32 = 0.5,
    master_count: u8 = 1,
    stack_balance: f32 = 0,
    /// Scroll viewport state: model-owned so the layout engine stays pure.
    /// The snap-right-on-new-window and clamp duties belong to callers
    /// (actions/sync).
    scroll_offset: i32 = 0,
    scroll_prev_count: u32 = 0,
};

pub const BaseMode = union(enum) {
    /// Home workspace membership is DERIVED (exactly one ws.tiled_order list
    /// holds a tiled window; findHome). Visibility on other tagged workspaces
    /// is a sync-time mask filter (engine stays mask-agnostic).
    tiled,
    floating: utils.Rect,
};

/// Minimized stores the ENTIRE previous mode plus its tiled slot, which
/// preserves restore-exactly-into-fullscreen behavior.
pub const FullscreenPayload = struct { ws: WSId, base: BaseMode };

/// Previous-mode payload of minimized. Flattened one level: a by-value
/// recursive `prev: Mode` cannot compile, and the recursion depth is
/// provably <= 1 because minimize() only accepts base/fullscreen states.
pub const PrevMode = union(enum) {
    base: BaseMode,
    fullscreen: FullscreenPayload,
};

pub const MinimizedPayload = struct { prev: PrevMode, slot: ?usize, seq: u32 = 0 };

pub const Mode = union(enum) {
    base: BaseMode,
    fullscreen: FullscreenPayload,
    minimized: MinimizedPayload,
};

pub const Entry = struct {
    mask: Mask,
    mode: Mode,
    size_hints: SizeHints = .{},
    /// Cached workspace whose tiled_order holds this window (single-membership
    /// invariant). Updated by every transition that mutates tiled_order:
    /// register, unregister, minimize, restore, moveWindowToWs, toggleFloating.
    /// Null when the window has no tiled slot (floating or minimized-from-floating).
    home_ws: ?WSId = null,
};

pub const WsState = struct {
    tiled_order: OrderList = .{},
    focus_mru: MruList = .{}, // newest first (index 0), bounded at mru_capacity
    params: LayoutParams = .{},
};

pub const store_capacity = 128;
pub const mru_capacity = 16;
/// Bounded per-workspace tiled membership list (defined capacity,
/// total operations — transitions never allocate, so no OOM rollback paths).
pub const max_tiled_per_ws = constants.Limits.max_tiled_windows;
pub const OrderList = utils.BoundedList(WindowId, max_tiled_per_ws);
pub const MruList = utils.BoundedList(WindowId, mru_capacity);
pub const StoreT = @import("store").Store(WindowId, Entry, store_capacity);

pub fn lowestBit(m: Mask) WSId {
    return @intCast(@ctz(m));
}

pub const Model = struct {
    store: StoreT = .{},
    ws: [MAX_WS]WsState = [_]WsState{.{}} ** MAX_WS,
    current: WSId = 0,
    focused: ?WindowId = null,
    all_view_active: bool = false,
    /// Monotonic minimize counter; stamps MinimizedPayload.seq so actions can
    /// pick LIFO/FIFO restore targets without a side buffer.
    next_seq: u32 = 0,
    /// Incremental counter for minimized windows — avoids O(n) scan.
    count_minimized: u32 = 0,
};

fn removeValue(list: anytype, win: WindowId) void {
    // anytype: shared by OrderList and MruList (different capacities).
    if (list.indexOfScalar(win)) |i| list.orderedRemove(i);
}

/// The workspace whose tiled_order holds win (single-membership invariant).
/// Uses the cached home_ws when available; falls back to scan for
/// backwards-compat with code that hasn't migrated yet.
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    if (m.store.get(win)) |e| {
        if (e.home_ws) |h| return h;
    }
    for (&m.ws, 0..) |*s, i| {
        if (s.tiled_order.indexOfScalar(win) != null) return @intCast(i);
    }
    return null;
}

fn removeFromMruAll(m: *Model, win: WindowId) void {
    for (&m.ws) |*s| removeValue(&s.focus_mru, win);
}

pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) error{CapacityFull}!void {
    if (m.store.has(win)) return;
    const target: WSId = hint_ws orelse m.current;
    // Defined-capacity refusal with rollback, BEFORE any
    // observable state change.
    const ptr = m.store.put(win, .{
        .mask = bit(target),
        .mode = .{ .base = .tiled },
    }) catch return error.CapacityFull;
    // Defensive: BoundedList.append returns bool, catch path is for future allocator-backed lists
    if (!m.ws[target].tiled_order.append(win)) {
        _ = m.store.remove(win);
        return error.CapacityFull;
    }
    // home_ws cache: set AFTER tiled_order append succeeds so the cache
    // is only valid when the window actually has a tiled slot.
    ptr.home_ws = target;
    // NOTE: master-fifo spawn placement lives in actions.mapRequest — this
    // primitive is a dumb membership insert.
}

pub fn unregister(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    const was_minimized = e.mode == .minimized;
    if (findHome(m, win)) |h| removeValue(&m.ws[h].tiled_order, win);
    removeFromMruAll(m, win);
    if (m.focused == win) m.focused = null;
    _ = m.store.remove(win);
    if (was_minimized) m.count_minimized -= 1;
}

pub const MinimizeError = error{CapacityFull};

pub fn minimize(m: *Model, win: WindowId) MinimizeError!void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mode == .minimized) return;
    // Capacity check BEFORE any mutation (T17).
    if (m.count_minimized >= MAX_MINIMIZED) return error.CapacityFull;
    var slot: ?usize = null;
    if (findHome(m, win)) |h| {
        slot = m.ws[h].tiled_order.indexOfScalar(win);
        removeValue(&m.ws[h].tiled_order, win);
    }
    const prev: PrevMode = switch (e.mode) {
        .base => |b| .{ .base = b },
        .fullscreen => |f| .{ .fullscreen = f },
        .minimized => return, // guarded above; unreachable in practice
    };
    e.mode = .{ .minimized = .{ .prev = prev, .slot = slot, .seq = m.next_seq } };
    e.home_ws = null; // no longer in any tiled_order
    m.next_seq += 1;
    m.count_minimized += 1;
}

pub fn restore(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mode != .minimized) return;
    const mm = e.mode.minimized;
    // Which previous states re-enter a home list?
    //   - base-tiled prev: must be re-listed.
    //   - floating-prev: restores to its saved rect directly; appending it
    //     would create a phantom layout member.
    //   - fullscreen-prev whose inner base is tiled: slot was removed on
    //     minimize so it must be re-added here too. Skipping stranded the
    //     window: after exit-fullscreen it was base-tiled but home-less.
    const wants_home = switch (mm.prev) {
        .base => |b| b == .tiled,
        .fullscreen => |f| f.base == .tiled,
    };
    if (wants_home) {
        const h: WSId = lowestBit(e.mask); // follows tag-moves made while hidden
        const list = &m.ws[h].tiled_order;
        // Refuse-before-mutate: a full home list leaves the window
        // minimized rather than half-restoring it.
        if (!list.append(win)) return;
        if (mm.slot) |s| {
            const last = list.len - 1;
            if (s < last) {
                list.orderedRemove(last);
                _ = list.insert(s, win); // cannot fail: len < capacity here
            }
        }
        e.home_ws = h;
    }
    e.mode = switch (mm.prev) {
        .base => |b| .{ .base = b },
        .fullscreen => |f| .{ .fullscreen = f },
    };
    m.count_minimized -= 1;
}

fn slotLess(a: ?usize, b: ?usize) bool {
    if (a == null) return false;
    if (b == null) return true;
    return a.? < b.?;
}

fn minimizedOnWs(m: *const Model, ws: WSId, pos: *usize) ?StoreT.Item {
    while (pos.* < m.store.count()) {
        const it = m.store.at(pos.*);
        pos.* += 1;
        if (it.val.mode != .minimized) continue;
        if (it.val.mask & bit(ws) == 0) continue;
        return it;
    }
    return null;
}

/// Restore-order target selection over minimized windows on `ws`:
/// `.fifo` = oldest minimize seq, `.lifo` = newest. Returns null when nothing
/// on `ws` is minimized.
pub fn restoreCandidate(m: *const Model, ws: WSId, order: RestoreOrder) ?WindowId {
    var best: ?WindowId = null;
    var best_seq: u32 = 0;
    var pos: usize = 0;
    while (minimizedOnWs(m, ws, &pos)) |it| {
        const seq = it.val.mode.minimized.seq;
        const better = switch (order) {
            .fifo => best == null or seq < best_seq,
            .lifo => best == null or seq > best_seq,
        };
        if (better) {
            best = it.key;
            best_seq = seq;
        }
    }
    return best;
}

pub const RestoreOrder = enum { lifo, fifo };

/// Most recently minimized PLAIN window on `ws` (fullscreen-prev excluded).
pub fn latestMinimizedBase(m: *const Model, ws: WSId) ?WindowId {
    var best: ?WindowId = null;
    var best_seq: u32 = 0;
    var pos: usize = 0;
    while (minimizedOnWs(m, ws, &pos)) |it| {
        if (it.val.mode.minimized.prev != .base) continue;
        if (best == null or it.val.mode.minimized.seq > best_seq) {
            best = it.key;
            best_seq = it.val.mode.minimized.seq;
        }
    }
    return best;
}

pub fn restoreAllOnWs(m: *Model, ws: WSId) void {
    var wins: [MAX_MINIMIZED]WindowId = undefined;
    var slots: [MAX_MINIMIZED]?usize = undefined;
    var n: usize = 0;
    var pos: usize = 0;
    while (minimizedOnWs(m, ws, &pos)) |it| {
        wins[n] = it.key;
        slots[n] = it.val.mode.minimized.slot;
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

pub fn toggleFullscreen(m: *Model, win: WindowId) bool {
    const e = m.store.getPtr(win) orelse return false;
    switch (e.mode) {
        .base => |b| {
            e.mode = .{ .fullscreen = .{ .ws = m.current, .base = b } };
            return true;
        },
        .fullscreen => |f| {
            e.mode = .{ .base = f.base };
            return true;
        },
        .minimized => return false,
    }
}

pub fn switchTo(m: *Model, ws: WSId) void {
    m.current = ws;
}

fn fullscreenOccupied(m: *const Model, exclude: WindowId, ws: WSId) bool {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.key == exclude) continue;
        if (it.val.mode == .fullscreen and it.val.mode.fullscreen.ws == ws) return true;
    }
    return false;
}

pub fn moveWindowToWs(m: *Model, win: WindowId, ws: WSId) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mask == ALL_MASK) return; // pinned stays everywhere-visible
    if (e.mode == .minimized) {
        e.mask = bit(ws); // record follows the move
        return;
    }
    // Fullscreen record follows the move (legacy transferFullscreenRecord);
    // destination occupied ⇒ drop this one rather than clobber the resident.
    if (e.mode == .fullscreen and e.mode.fullscreen.ws != ws) {
        if (fullscreenOccupied(m, win, ws)) {
            e.mode = .{ .base = e.mode.fullscreen.base };
        } else {
            e.mode.fullscreen.ws = ws;
        }
    }
    e.mask = bit(ws);
    const h: ?WSId = e.home_ws;
    if (h) |old_h| {
        if (old_h != ws) {
            // Refuse-before-mutate: a full destination list cancels the
            // move instead of stranding the window home-less.
            if (m.ws[ws].tiled_order.len >= max_tiled_per_ws) {
                e.mask = bit(old_h);
                return;
            }
            removeValue(&m.ws[old_h].tiled_order, win);
            _ = m.ws[ws].tiled_order.append(win);
            e.home_ws = ws;
        }
    }
}

/// Remove tag `ws`; the last remaining tag is protected (returns false).
/// Fullscreen-on-removed-ws transfers to the lowest remaining bit, or drops
/// when that destination is occupied (legacy transferFullscreenRecord).
pub fn tagRemove(m: *Model, win: WindowId, ws: WSId) bool {
    const e = m.store.getPtr(win) orelse return false;
    if (@popCount(e.mask) <= 1) return false;
    e.mask &= ~bit(ws);
    if (e.mode == .fullscreen and e.mode.fullscreen.ws == ws) {
        const dest = lowestBit(e.mask);
        if (fullscreenOccupied(m, win, dest)) {
            e.mode = .{ .base = e.mode.fullscreen.base };
        } else {
            e.mode.fullscreen.ws = dest;
        }
    }
    return true;
}

pub fn tagAdd(m: *Model, win: WindowId, ws: WSId, protect_current: bool) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask |= bit(ws);
    if (protect_current) e.mask |= bit(m.current);
}

pub fn pinToggle(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask = if (e.mask == ALL_MASK) bit(m.current) else ALL_MASK;
}

pub fn allViewToggle(m: *Model) bool {
    m.all_view_active = !m.all_view_active;
    return m.all_view_active;
}

pub fn reorderTiled(m: *Model, win: WindowId, idx_in: usize) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h].tiled_order;
    const from = list.indexOfScalar(win) orelse return;
    const idx = @min(idx_in, list.len - 1);
    list.orderedRemove(from);
    _ = list.insert(idx, win); // cannot fail: removal freed a slot
}

pub fn swapMaster(m: *Model) void {
    const list = &m.ws[m.current].tiled_order;
    if (list.len < 2) return;
    const tmp = list.items[0];
    list.items[0] = list.items[1];
    list.items[1] = tmp;
}

pub fn cycleLayout(m: *Model, dir: i32) void {
    const p = &m.ws[m.current].params;
    const n: i32 = @typeInfo(LayoutKind).@"enum".fields.len;
    const cur: i32 = @intCast(@intFromEnum(p.kind));
    // @mod's result carries the divisor's sign; with n > 0 it is already in
    // [0, n), so no negative correction is needed (the old `if (next < 0)`
    // was unreachable).
    const next = @mod(cur + dir, n);
    // Cast to LayoutKind's tag type (inferred via std.meta.Tag), so the
    // width follows automatically if the enum ever grows past 8 variants
    // (no hardcoded u3 that would silently truncate).
    p.kind = @enumFromInt(@as(std.meta.Tag(LayoutKind), @intCast(next)));
    p.variant_idx = 0;
}

/// Variant count per layout kind (caller-side variant resolution): master
/// lifo/fifo, monocle gapless/gaps, grid rigid/relaxed; the rest have
/// exactly one.
pub fn variantCount(kind: LayoutKind) u8 {
    return switch (kind) {
        .master, .monocle, .grid => 2,
        else => 1,
    };
}

pub fn adjustMasterWidth(m: *Model, delta: f32) void {
    const p = &m.ws[m.current].params;
    p.master_width = std.math.clamp(p.master_width + delta, 0.05, 0.95);
}

pub fn setFloatingRect(m: *Model, win: WindowId, r: utils.Rect) void {
    const e = m.store.getPtr(win) orelse return;
    switch (e.mode) {
        .base => |*bm| switch (bm.*) {
            .floating => |*fr| fr.* = r,
            .tiled => {},
        },
        else => {},
    }
}

pub const ConfigureReq = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
};

pub const HonorDecision = enum { geometry_applied, border_only, ignored };

pub fn honorConfigureRequest(m: *Model, win: WindowId, req: ConfigureReq) HonorDecision {
    const e = m.store.getPtr(win) orelse return .ignored;
    switch (e.mode) {
        .base => |*bm| switch (bm.*) {
            .floating => |*r| {
                if (req.x) |v| r.x = v;
                if (req.y) |v| r.y = v;
                if (req.width) |v| r.width = v;
                if (req.height) |v| r.height = v;
                // NOTE: a requested border_width is not stored here (the
                // floating rect has no bw field); the entry point sends and
                // caches it alongside the geometry it applies.
                return .geometry_applied;
            },
            .tiled => {
                // Geometry denied. BW honored; recording is SYNC's job.
                if (req.border_width != null) return .border_only;
                return .ignored;
            },
        },
        .fullscreen => return .ignored,
        .minimized => return .ignored,
    }
}

pub fn applyConfigReload(m: *Model, tpl: LayoutParams) void {
    for (&m.ws) |*s| {
        // Scroll viewport state is RUNTIME state, not config: preserving it
        // prevents a spurious snap-right (n > prev_count fires when the
        // counter resets) on an unrelated reload while scroll is active.
        const keep_offset = s.params.scroll_offset;
        const keep_prev_count = s.params.scroll_prev_count;
        s.params = tpl;
        s.params.scroll_offset = keep_offset;
        s.params.scroll_prev_count = keep_prev_count;
    }
}

pub fn setFocus(m: *Model, win: WindowId) void {
    _ = m.store.getPtr(win) orelse return;
    m.focused = win;
    const list = &m.ws[m.current].focus_mru;
    removeValue(list, win);
    // Newest-first insert; when at capacity, drop the OLDEST (tail) entry so
    // the newest mru_capacity wins are retained (legacy shrink semantics).
    if (!list.insert(0, win)) {
        list.orderedRemove(list.len - 1);
        _ = list.insert(0, win);
    }
}

/// Model-side focus drop (minimize/close with no eligible successor).
pub fn clearFocus(m: *Model) void {
    m.focused = null;
}

pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    if (e.mode == .minimized) return false;
    if (m.all_view_active) return true;
    return e.mask & bit(ws) != 0;
}

/// Fullscreen workspace record of `win`, null unless its current mode is
/// fullscreen. Callers about to DROP the store entry (unmanage paths) must
/// read this BEFORE removal — afterwards it is always null.
pub fn fullscreenWsOf(m: *const Model, win: WindowId) ?WSId {
    const e = m.store.get(win) orelse return null;
    return switch (e.mode) {
        .fullscreen => |f| f.ws,
        else => null,
    };
}

/// MODEL-mode fullscreen query (single source of truth; replaces the legacy
/// fullscreen-record lookup for EWMH and client-message paths): true when
/// `win`'s current mode is fullscreen, regardless of which workspace its
/// record targets.
pub fn isFullscreenMode(m: *const Model, win: WindowId) bool {
    const e = m.store.get(win) orelse return false;
    return e.mode == .fullscreen;
}

/// Whether `win` is fullscreen AND its record targets workspace `ws`.
/// Unlike fullscreenOccupantOnWs this does NOT consult visibility — callers
/// use it for pre-toggle classification and was-fullscreen captures.
pub fn isFullscreenOnWs(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    return e.mode == .fullscreen and e.mode.fullscreen.ws == ws;
}

/// The window occupying the visible fullscreen slot on `ws`, if any. Model
/// guarantees at most one visible fullscreen per ws (sync parks the rest).
/// Replaces the deleted legacy fullscreen.zig record store for bar
/// visibility decisions and enter/exit classification.
pub fn fullscreenOccupantOnWs(m: *const Model, ws: WSId) ?WindowId {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.mode != .fullscreen) continue;
        if (it.val.mode.fullscreen.ws != ws) continue;
        if (!visibleOn(m, it.key, ws)) continue;
        return it.key;
    }
    return null;
}

/// Minimize-fallback target policy. The window layer's focusFallback
/// delegates here, and tests exercise the same logic without linking the
/// protocol layers. Tier order on workspace `ws`:
///   1. focus MRU, newest first,
///   2. reversed tiled_order,
///   3. any visible floating-base window not in tiled_order.
/// First visibleOn(ws) candidate wins; null when nothing qualifies.
pub fn fallbackFocusCandidate(m: *const Model, ws: WSId) ?WindowId {
    // 1. focus MRU, NEWEST first: mru[0] is the MOST RECENT focus (T15),
    //    so minimizing the focused window falls back to the previously
    //    focused one. visibleOn rejects minimized entries, including the
    //    just-minimized window itself.
    const mru = &m.ws[ws].focus_mru;
    for (mru.items[0..mru.len]) |cand| {
        if (visibleOn(m, cand, ws)) return cand;
    }
    // 2. reversed tiled_order of the workspace.
    const order = &m.ws[ws].tiled_order;
    var j = order.items.len;
    while (j > 0) {
        j -= 1;
        const cand = order.items[j];
        if (visibleOn(m, cand, ws)) return cand;
    }
    // 3. any floating window on ws (base mode, not in tiled_order).
    // Linear membership check per floating entry against tiled_order;
    // adequate for <50 windows.
    for (0..m.store.count()) |k| {
        const it = m.store.at(k);
        if (it.val.mode != .base) continue;
        if (!visibleOn(m, it.key, ws)) continue;
        if (order.indexOfScalar(it.key) == null) return it.key;
    }
    return null;
}
