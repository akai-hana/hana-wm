//! Single source of truth for management state.
//!
//! Layer rule (pure core): imports are std + utils + constants ONLY. No X11
//! access and NO feature-specific imports -- the model depends on nothing
//! feature-related and is never affected by adding/removing feature plugin
//! files.
//!
//! Threading model: the Model is single-threaded, accessed only from the
//! event-loop thread. All mutations happen sequentially, so no locks or
//! atomics are needed on Model fields.
//!
//! Architecture (plugins over the model): per-feature state transitions
//! (parking, screen coverage, floating geometry, tag sets) live in the
//! wire-side plugin modules under src/window/modules/, one file per feature.
//! Those plugins import this model one-way and draw on its types/helpers.
//! THIS file stays the pure core and exports only:
//!   - shared vocabulary types (Entry/WsState/RestoreOrder/ConfigureReq/
//!     HonorDecision/...),
//!   - the substrate + reuse helpers (register/unregister/findHome/removeValue/
//!     removeFromMruAll),
//!   - shared queries (visibleOn/tiledCountOnWs),
//!   - the core intrinsics that only touch focus and tiling params
//!     (setFocus/clearFocus/fallbackFocusCandidate and reorderTiled/swapPrimary/
//!     cycleLayout/variantCount/adjustPrimaryWidth/applyConfigReload).
//! The model contains no feature transition LOGIC.
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

/// Single canonical size-hints record (the former layouts.SizeHints copy and
/// its migration bridge are gone). Do NOT import layouts from here (layer rule).
pub const SizeHints = struct {
    max_width: u16 = 0, // PMaxSize limit
    max_height: u16 = 0,
    inc_width: u16 = 0, // PResizeInc: w = base_width + N * inc_width
    inc_height: u16 = 0,
    min_aspect: f32 = 0.0, // PAspect (dwm convention)
    max_aspect: f32 = 0.0,

    /// True when every field is zero (no constraints declared).
    pub fn isEmpty(self: SizeHints) bool {
        return self.max_width == 0 and self.max_height == 0 and
            self.inc_width == 0 and self.inc_height == 0 and
            self.min_aspect == 0.0 and self.max_aspect == 0.0;
    }
};

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

/// Open visibility pattern the model names:
///   `present`  -- visible/layoutable window,
///   `parked`   -- hidden by an extension (e.g. minimized),
///   `covering` -- owns the screen on some workspace (e.g. fullscreen); the
///                 layout layer parks everyone else while a covering window
///                 holds the screen.
/// This enumerates PATTERNS, not features: the model never names a feature,
/// so a parked or covering window keeps its `anchor` and `mask` unchanged and
/// the owning extension decides how it behaves once restored.
pub const Presence = enum { present, parked, covering };

pub const Entry = struct {
    mask: Mask,
    anchor: BaseMode,
    size_hints: SizeHints = .{},
    /// Cached workspace whose tiled_order holds this window (single-membership
    /// invariant). Updated by every transition that mutates tiled_order. Null
    /// when the window has no tiled slot (floating or parked).
    home_ws: ?WSId = null,
    presence: Presence = .present,
    /// Core covering intent: the workspace this window's screen-covering
    /// capture anchors to, present iff `presence == .covering`. This is a
    /// PATTERN intent, not a feature: a covering window owns the screen on a
    /// workspace, and the target is authoritative here so core (sync, bar,
    /// persistence) can answer "who owns the screen on ws" without naming any
    /// optional subsystem. The owning extension writes it when it claims and
    /// clears it when it releases. Null when the window is not covering.
    covering_ws: ?WSId = null,
};

pub const WsState = struct {
    tiled_order: OrderList = .{},
    focus_mru: MruList = .{}, // newest first (index 0), bounded at mru_capacity
    params: LayoutParams = .{},
};

pub const store_capacity = 128;
pub const mru_capacity = 16;
/// Bounded per-workspace tiled membership list (defined capacity; total
/// operations, so transitions never allocate and have no OOM rollback paths).
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
};

/// Removes `win` from a bounded membership list. Shared by the substrate
/// (register/unregister) and the focus slice (setFocus); anytype because
/// OrderList and MruList share the shape but not the capacity.
pub fn removeValue(list: anytype, win: WindowId) void {
    if (list.indexOfScalar(win)) |i| list.orderedRemove(i);
}

fn removeFromMruAll(m: *Model, win: WindowId) void {
    for (&m.ws) |*s| removeValue(&s.focus_mru, win);
}

/// The workspace whose tiled_order holds win (single-membership invariant).
/// Uses the cached home_ws when available; falls back to scanning when the
/// cache is null (e.g. a freshly adopted window not yet home-assigned).
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    if (m.store.get(win)) |e| {
        if (e.home_ws) |h| return h;
    }
    for (0..m.ws.len) |i| {
        if (m.ws[i].tiled_order.indexOfScalar(win) != null) return @intCast(i);
    }
    return null;
}

pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) error{CapacityFull}!void {
    if (m.store.has(win)) return;
    const target: WSId = hint_ws orelse m.current;
    // Defined-capacity refusal with rollback, BEFORE any observable state change.
    const ptr = m.store.put(win, .{
        .mask = bit(target),
        .anchor = .tiled,
    }) catch return error.CapacityFull;
    // Defensive: BoundedList.append returns a bool; the catch-style guard
    // would only be needed for a future allocator-backed list.
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
    removeFromMruAll(m, win);
    if (m.focused == win) m.focused = null;
    _ = m.store.remove(win);
}

pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    if (e.presence == .parked) return false;
    if (m.all_view_active) return true;
    return e.mask & bit(ws) != 0;
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
        if (e.mask & bit(ws) == 0) continue;
        n += 1;
    }
    return n;
}

/// The covering occupant owning the screen on `ws`, if any: a covering entry
/// whose capture anchors to `ws`, OR a covering entry visible on `ws`
/// (multi-tag). Pure core computation -- no feature import -- so core layers
/// (sync, bar) can resolve the screen owner against only the model's core
/// intent, never by enumerating optional subsystems. A covering window is
/// never `.parked` (minimize remaps it to `.parked`), so walked-ghosts are
/// excluded by construction. At most one covering occupant per ws is guaranteed
/// by the reconciler.
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
// the core; every other feature transition lives in src/window/modules/.
// ---------------------------------------------------------------------------

pub fn setFocus(m: *Model, win: WindowId) void {
    _ = m.store.getPtr(win) orelse return;
    m.focused = win;
    const list = &m.ws[m.current].focus_mru;
    removeValue(list, win);
    // Newest-first insert; when at capacity, drop the OLDEST (tail) entry so
    // the newest mru_capacity wins are retained.
    if (!list.insert(0, win)) {
        list.orderedRemove(list.len - 1);
        _ = list.insert(0, win);
    }
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
pub fn fallbackFocusCandidate(m: *const Model, ws: WSId) ?WindowId {
    // 1. focus MRU, NEWEST first: mru[0] is the MOST RECENT focus (T15),
    //    so minimizing the focused window falls back to the previously
    //    focused one. visibleOn rejects parked entries, including the
    //    just-parked window itself.
    const mru = &m.ws[ws].focus_mru;
    for (mru.constSlice()) |cand| {
        if (visibleOn(m, cand, ws)) return cand;
    }
    // 2. reversed tiled_order of the workspace.
    var j = m.ws[ws].tiled_order.len;
    while (j > 0) {
        j -= 1;
        const cand = m.ws[ws].tiled_order.items[j];
        if (visibleOn(m, cand, ws)) return cand;
    }
    // 3. any floating window on ws (base geometry, not in tiled_order).
    //    A covering window owns the screen, so it is not a fallback target.
    //    Linear membership check per floating entry against tiled_order;
    //    adequate for <50 windows.
    for (0..m.store.count()) |k| {
        const it = m.store.at(k);
        if (it.val.anchor != .floating or it.val.presence == .covering) continue;
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
/// clamped to [0.05, 0.95].
pub fn adjustPrimaryWidth(m: *Model, delta: f32) void {
    const p = &m.ws[m.current].params;
    p.primary_width = std.math.clamp(p.primary_width + delta, 0.05, 0.95);
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
