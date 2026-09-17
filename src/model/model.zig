//! Single source of truth for management state.
//! Layer rule: pure core (no X11, no feature imports). Single-threaded.
//! Feature transitions live in the window layer's optional modules; this file
//! exports only shared vocabulary types, queries, and core focus/tiling
//! intrinsics.
const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");

pub const WindowId = u32;
/// Local alias so model never imports core. Core's canonical WorkspaceId is
/// converted via `.index` at the entry-point boundary; inside the model, ws
/// values are raw integers used directly as array indices.
pub const WSId = u16;
pub const Mask = u64;

pub inline fn bit(ws: WSId) Mask {
    return @as(Mask, 1) << @intCast(ws);
}

/// Alias for the workspace count ceiling; the canonical value lives in
/// constants so config plumbing shares one source.
const MAX_WS = constants.max_workspaces;

pub const ALL_MASK: Mask = ~@as(Mask, 0);

/// Single canonical size-hints record. Do NOT import layouts from here (layer rule).
pub const SizeHints = struct {
    /// PMinSize / PBaseSize floor. Tiling deliberately ignores this (the layout
    /// engine owns tiled dimensions), but the floating drag-resize path honours
    /// it as a user-facing floor.
    min_width: u16 = 0,
    min_height: u16 = 0,
    max_width: u16 = 0, // PMaxSize limit
    max_height: u16 = 0,
    inc_width: u16 = 0, // PResizeInc: w = base_width + N * inc_width
    inc_height: u16 = 0,
    min_aspect: f32 = 0.0, // PAspect (dwm convention)
    max_aspect: f32 = 0.0,

    /// True when every field is zero (no constraints declared).
    pub fn isEmpty(self: SizeHints) bool {
        return self.min_width == 0 and self.min_height == 0 and
            self.max_width == 0 and self.max_height == 0 and
            self.inc_width == 0 and self.inc_height == 0 and
            self.min_aspect == 0.0 and self.max_aspect == 0.0;
    }
};

/// Hard ceiling on the number of distinct layouts the cycle ring can hold.
/// The canonical value lives here because it bounds the u8 `kind` registry
/// index (LayoutParams.kind) and the u8 `layout_idx` in workspace layout
/// overrides alike; config side imports it and enforces the cap at parse time
/// (a 256th entry would trap on the config-side `@intCast` in ReleaseFast,
/// so names past the cap warn-and-skip).
pub const max_layouts = 256;

pub const LayoutParams = struct {
    /// Index into the build-generated `tiling_modules` registry (dispatch
    /// order == deterministic scan order). Resolved from config at seed time;
    /// out-of-range values are disambiguated by the registry layer (default
    /// layout fallback). The model stays registry-free: it is a bare index here.
    kind: u8 = 0,
    variant_idx: u8 = 0,
    primary_width: f32 = 0.5,
    primary_count: u8 = 1,
    secondary_balance: f32 = 0,
    /// Viewport state: model-owned so the layout engine stays pure. The
    /// snap-right-on-new-window and clamp duties belong to callers (actions/sync).
    viewport_offset: i32 = 0,
    viewport_prev_count: u32 = 0,
};

pub const BaseMode = union(enum) {
    /// Home workspace membership is DERIVED (exactly one ws.tiled_order list
    /// holds a tiled window; findHome). Visibility on other tagged workspaces
    /// is a sync-time mask filter (engine stays mask-agnostic).
    tiled,
    floating: utils.Rect,
};

/// Open visibility pattern: `present` (visible/layoutable), `parked` (hidden
/// by an extension), `covering` (owns the screen on a workspace). Enumerates
/// PATTERNS, not features; a parked/covering window keeps its `anchor`/`mask`.
pub const Presence = enum { present, parked, covering };

pub const Entry = struct {
    mask: Mask,
    anchor: BaseMode,
    size_hints: SizeHints = .{},
    /// Cached workspace whose tiled_order holds this window (single-membership
    /// invariant); null when the window has no tiled slot.
    home_ws: ?WSId = null,
    presence: Presence = .present,
    /// Core covering intent: the workspace this window's coverage anchors to,
    /// present iff `presence == .covering`. The owning extension writes and
    /// clears it; core reads it without naming any optional subsystem.
    covering_ws: ?WSId = null,
};

pub const WsState = struct {
    tiled_order: OrderList = .{},
    focus_mru: MruList = .{}, // newest first (index 0), bounded at mru_capacity
    params: LayoutParams = .{},
};

/// Bounded, stack-allocated key-value collection with sorted-key binary search.
///
/// Parameterised by key type, value type, and a hard capacity ceiling
/// (stack-allocated arrays, no heap allocation). Keys are kept in sorted
/// order at all times: lookups (get, getPtr, has) use O(log n) binary search;
/// put and remove use binary search for the position and then shift arrays to
/// maintain sorted order.
///
/// Threading model: single-threaded, no locking needed; all access occurs
/// on the event-loop thread.
///
/// When the capacity is reached, put returns error.StoreFull; there is no
/// eviction or overflow, the ceiling is absolute.
pub fn Store(comptime K: type, comptime V: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Error = error{StoreFull};

        keys: [capacity]K = undefined,
        vals: [capacity]V = undefined,
        len: usize = 0,

        fn exactAt(self: *const Self, k: K) ?usize {
            var lo: usize = 0;
            var hi: usize = self.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.keys[mid] == k) return mid;
                if (self.keys[mid] < k) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return null;
        }

        fn lowerBound(self: *const Self, k: K) usize {
            var lo: usize = 0;
            var hi: usize = self.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                if (self.keys[mid] < k) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            return lo;
        }

        pub fn getPtr(self: *Self, k: K) ?*V {
            if (self.exactAt(k)) |i| return &self.vals[i];
            return null;
        }

        // Pointer-relocation contract: the Store is a contiguous array, so a
        // *V returned by getPtr/put remains valid across get/put/remove of
        // OTHER keys (those shift slots but never reallocate). It is
        // invalidated ONLY by put(k) on a different entry, remove(k), or
        // clear() -- each of which may move the slot that k occupies -- or by
        // a reload into self.keys/self.vals wholesale. Callers must not cache
        // a *V across such an operation on its own key.

        pub fn get(self: *const Self, k: K) ?V {
            if (self.exactAt(k)) |i| return self.vals[i];
            return null;
        }

        pub fn has(self: *const Self, k: K) bool {
            return self.exactAt(k) != null;
        }

        pub fn put(self: *Self, k: K, v: V) Error!*V {
            if (self.exactAt(k)) |i| {
                self.vals[i] = v;
                return &self.vals[i];
            }
            if (self.len == capacity) return Error.StoreFull;
            const pos = self.lowerBound(k);
            std.mem.copyBackwards(K, self.keys[pos + 1 .. self.len + 1], self.keys[pos..self.len]);
            std.mem.copyBackwards(V, self.vals[pos + 1 .. self.len + 1], self.vals[pos..self.len]);
            self.keys[pos] = k;
            self.vals[pos] = v;
            self.len += 1;
            return &self.vals[pos];
        }

        /// Sorted-shift-remove: elements after `i` shift left to fill the gap.
        /// O(n); iteration order stays sorted-by-key.
        pub fn remove(self: *Self, k: K) bool {
            if (self.exactAt(k)) |i| {
                const last = self.len - 1;
                std.mem.copyForwards(K, self.keys[i..last], self.keys[i + 1 .. self.len]);
                std.mem.copyForwards(V, self.vals[i..last], self.vals[i + 1 .. self.len]);
                self.len = last;
                return true;
            }
            return false;
        }

        pub const Item = struct { key: K, val: *const V };

        /// seq must be < count(). Iterates in sorted-key order.
        /// seq beyond count() clamps to the last stored row (real check, not a
        /// debug-only assert), so an off-by-one index can't OOB the backing
        /// arrays in ReleaseFast. Empty map → row 0 of the fixed-capacity
        /// storage (always addressable, capacity >= 1).
        pub fn at(self: *const Self, seq: usize) Item {
            const idx = @min(seq, self.len -| 1);
            return .{ .key = self.keys[idx], .val = &self.vals[idx] };
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }
    };
}

pub const store_capacity = 128;
pub const mru_capacity = 16;
/// Bounded per-workspace tiled membership list (defined capacity; total
/// operations, so transitions never allocate and have no OOM rollback paths).
pub const max_tiled_per_ws = constants.Limits.max_tiled_windows;
pub const OrderList = utils.BoundedList(WindowId, max_tiled_per_ws);
pub const MruList = utils.BoundedList(WindowId, mru_capacity);
pub const StoreT = Store(WindowId, Entry, store_capacity);

/// Index (workspace id) of the lowest set bit in `m`. Returns null when `m`
/// is zero (`@ctz(0)` = 64 is out of the [0, MAX_WS) index range).
pub fn lowestBit(m: Mask) ?WSId {
    if (m == 0) return null;
    return @intCast(@ctz(m));
}

pub const Model = struct {
    store: StoreT = .{},
    ws: [MAX_WS]WsState = [_]WsState{.{}} ** MAX_WS,
    current: WSId = 0,
    focused: ?WindowId = null,
    all_view_active: bool = false,
};

/// Removes `win` from a bounded membership list. Shared by the substrate
/// (register/unregister) and the focus slice (setFocus); anytype because
/// OrderList and MruList share the shape but not the capacity.
pub fn removeValue(list: anytype, win: WindowId) void {
    if (list.indexOfScalar(win)) |i| list.orderedRemove(i);
}

/// The workspace whose tiled_order holds win (single-membership invariant).
/// Uses the cached home_ws when available; falls back to scanning when the
/// cache is null (e.g. a freshly adopted window not yet home-assigned).
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    if (m.store.get(win)) |e| if (e.home_ws) |h| return h;
    for (0..m.ws.len) |i| {
        if (m.ws[i].tiled_order.indexOfScalar(win) != null) return @intCast(i);
    }
    return null;
}

pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) error{CapacityFull}!void {
    if (m.store.has(win)) return;
    const target: WSId = hint_ws orelse m.current;
    // Defined-capacity refusal with rollback, BEFORE any observable state change.
    const ptr = m.store.put(win, .{ .mask = bit(target), .anchor = .tiled }) catch return error.CapacityFull;
    if (!m.ws[target].tiled_order.append(win)) {
        _ = m.store.remove(win);
        return error.CapacityFull;
    }
    // home_ws cache: set AFTER tiled_order append succeeds so the cache
    // is only valid when the window actually has a tiled slot.
    ptr.home_ws = target;
    // Fifo spawn placement lives in actions.mapRequest; this primitive is a
    // dumb membership insert.
}

pub fn unregister(m: *Model, win: WindowId) void {
    if (m.store.getPtr(win) == null) return;
    if (findHome(m, win)) |h| removeValue(&m.ws[h].tiled_order, win);
    for (&m.ws) |*s| removeValue(&s.focus_mru, win);
    if (m.focused == win) m.focused = null;
    _ = m.store.remove(win);
}

pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    if (e.presence == .parked) return false;
    if (m.all_view_active) return true;
    return e.mask & bit(ws) != 0;
}

/// Whether `e` is pinned: its mask carries the soft all-workspaces sentinel
/// (every conceivable ws bit set), making it visible everywhere and immune
/// to tag edits. Feature modules test this predicate instead of spelling out
/// `mask == ALL_MASK`, keeping the sentinel's meaning in one place.
pub inline fn isPinned(e: Entry) bool {
    return e.mask == ALL_MASK;
}

/// Number of windows placed in tiled slots of `ws`: entries of `ws`'s
/// tiled_order whose tag mask includes `ws`. Viewport slot math (actions) and
/// diagnostics (input dump_state) share this single model read; recomputing
/// the count from store-wide base-tiled entries would disagree on multi-tagged
/// windows.
pub fn tiledCountOnWs(m: *const Model, ws: WSId) usize {
    var n: usize = 0;
    for (m.ws[ws].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (e.mask & bit(ws) != 0) n += 1;
    }
    return n;
}

/// The covering occupant owning the screen on `ws`: a covering entry whose
/// capture anchors to `ws`, or a covering entry visible on `ws` (multi-tag).
/// Pure core computation, so sync/bar resolve the screen owner without
/// enumerating optional subsystems. At most one occupant per ws by the
/// reconciler.
pub fn coveringOccupantOnWs(m: *const Model, ws: WSId) ?WindowId {
    for (0..m.store.count()) |k| {
        const it = m.store.at(k);
        if (it.val.presence != .covering) continue;
        if (it.val.covering_ws == ws or visibleOn(m, it.key, ws)) return it.key;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Shared vocabulary types (folded in from the former feature module files).
// Pure vocabulary consumed by both the wire-side feature plugins and wire
// callers; they live in core so nothing needs to import a feature file just
// to reference them.
// ---------------------------------------------------------------------------

/// Restore-order target selection over minimized windows on a workspace:
/// `.fifo` = oldest minimize seq, `.lifo` = newest.
pub const RestoreOrder = enum { lifo, fifo };

/// Optional increment of a floating window's geometry honored on
/// configure-request; unset fields leave the current value unchanged.
pub const ConfigureReq = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
};

/// Outcome of honoring a configure request against a floating window record.
pub const HonorDecision = enum { geometry_applied, border_only, ignored };

// ---------------------------------------------------------------------------
// Core intrinsics: focus (MRU + fallback) and tiling-param transitions. These
// are pure model operations and are the ONLY transition logic that lives in
// the core; every other feature transition lives in the window layer's
// optional modules.
// ---------------------------------------------------------------------------

pub fn setFocus(m: *Model, win: WindowId) void {
    _ = m.store.getPtr(win) orelse return;
    m.focused = win;
    const list = &m.ws[m.current].focus_mru;
    removeValue(list, win);
    // Newest-first insert; insert only fails at capacity, so drop the OLDEST
    // (tail) entry first, keeping the newest mru_capacity wins retained.
    if (list.len == mru_capacity) list.orderedRemove(list.len - 1);
    _ = list.insert(0, win);
}

/// Model-side focus drop (minimize/close with no eligible successor).
pub fn clearFocus(m: *Model) void {
    m.focused = null;
}

/// Minimize-fallback target policy. The window layer's focusFallback
/// delegates here, and tests exercise the same logic without linking the
/// protocol layers. Tier order on workspace `ws`:
///   1. focus MRU, newest first,
///   2. reversed tiled_order,
///   3. any visible floating-base window not in tiled_order.
/// First visibleOn(ws) candidate wins; null when nothing qualifies.
/// `excluded` is a candidate the caller already rejected (e.g. a no_input
/// window that can never hold X focus) — it is skipped across all tiers so
/// the caller can re-scan for the next focusable window.
pub fn fallbackFocusCandidate(m: *const Model, ws: WSId, excluded: ?WindowId) ?WindowId {
    // 1. focus MRU, NEWEST first: mru[0] is the MOST RECENT focus,
    //    so minimizing the focused window falls back to the previously
    //    focused one. visibleOn rejects parked entries, including the
    //    just-parked window itself.
    const mru = &m.ws[ws].focus_mru;
    for (mru.constSlice()) |cand| {
        if (cand == excluded) continue;
        if (visibleOn(m, cand, ws)) return cand;
    }
    // 2. reversed tiled_order of the workspace.
    var j = m.ws[ws].tiled_order.len;
    while (j > 0) {
        j -= 1;
        const cand = m.ws[ws].tiled_order.items[j];
        if (cand == excluded) continue;
        if (visibleOn(m, cand, ws)) return cand;
    }
    // 3. any floating window on ws (base geometry, not in tiled_order).
    //    A covering window owns the screen, so it is not a fallback target.
    //    Linear membership check per floating entry against tiled_order;
    //    adequate for <50 windows.
    for (0..m.store.count()) |k| {
        const it = m.store.at(k);
        if (it.val.anchor != .floating or it.val.presence == .covering) continue;
        if (it.key == excluded) continue;
        if (!visibleOn(m, it.key, ws)) continue;
        if (m.ws[ws].tiled_order.indexOfScalar(it.key) == null) return it.key;
    }
    return null;
}

pub fn reorderTiled(m: *Model, win: WindowId, idx_in: usize) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h].tiled_order;
    const from = list.indexOfScalar(win) orelse return;
    const idx = @min(idx_in, list.len - 1);
    list.orderedRemove(from);
    _ = list.insert(idx, win); // cannot fail: removal freed a slot
}

/// Moves `win` one slot in `dir` within its home workspace's tiled order,
/// wrapping around either edge (dwm-style stack rotate, mirroring the focus
/// cycle's modulo wrap). Unknown windows and lone tiled windows are no-ops.
pub fn stepTiled(m: *Model, win: WindowId, dir: i32) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h].tiled_order;
    const len = list.len;
    if (len < 2) return;
    const idx = list.indexOfScalar(win) orelse return;
    const next = utils.wrapIndex(idx, dir, len);
    reorderTiled(m, win, next);
}

/// Slot swap: exchanges the first two tiled slots of the current workspace
/// (primary head and the following slot). No-op with fewer than two tiled
/// windows.
pub fn swapPrimary(m: *Model) void {
    const list = &m.ws[m.current].tiled_order;
    if (list.len < 2) return;
    const tmp = list.items[0];
    list.items[0] = list.items[1];
    list.items[1] = tmp;
}

/// Steps the current workspace's primary-column width fraction by `delta`,
/// clamped to the shared master-width bounds in constants.
pub fn adjustPrimaryWidth(m: *Model, delta: f32) void {
    const p = &m.ws[m.current].params;
    p.primary_width = std.math.clamp(p.primary_width + delta, constants.min_master_width, constants.max_master_width);
}

pub fn applyConfigReload(m: *Model, tpl: LayoutParams) void {
    for (&m.ws) |*s| {
        // Viewport state is RUNTIME state, not config: preserving it prevents
        // a spurious snap-right (n > prev_count fires when the counter resets)
        // on an unrelated reload while the viewport layout is active.
        const keep_offset = s.params.viewport_offset;
        const keep_prev_count = s.params.viewport_prev_count;
        s.params = tpl;
        s.params.viewport_offset = keep_offset;
        s.params.viewport_prev_count = keep_prev_count;
    }
}
