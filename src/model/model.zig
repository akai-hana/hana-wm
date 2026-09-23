//! Single source of truth for management state.
//! Layer rule: pure core (no X11, no feature imports). Single-threaded.
//! Feature transitions live in the window layer's optional modules; this file
//! exports only shared vocabulary types, queries, and core focus/tiling
//! intrinsics.
const std = @import("std");
const utils = @import("utils");
const bounded = @import("bounded");
const constants = @import("constants");

/// Alias of the canonical WindowId (`@import("ids").WindowId`; xcb_window_t).
pub const WindowId = @import("ids").WindowId;
/// Alias of the canonical WorkspaceId (`@import("ids").WorkspaceId`). Model
/// never imports core (xcb-free layer rule); inside the model, ws values are
/// used directly as array indices via `.index`, with the integer form only at
/// boundaries (wire formats, counters).
pub const WSId = @import("ids").WorkspaceId;
pub const Mask = u64;

/// Mask bit for workspace `ws`. Precondition: `ws.index < 64` (u64 mask);
/// workspace ids are far below that, so this is structural, not a clamp.
pub inline fn bit(ws: WSId) Mask {
    return @as(Mask, 1) << @intCast(ws.index);
}

/// Whether `mask` carries the tag bit for `ws`.
pub inline fn maskedOn(mask: Mask, ws: WSId) bool {
    return mask & bit(ws) != 0;
}

pub const ALL_MASK: Mask = ~@as(Mask, 0);

/// Single canonical size-hints record. Do NOT import layouts from here (layer rule).
pub const SizeHints = struct {
    /// PMinSize / PBaseSize floor. Policy: TILING deliberately ignores
    /// declared minimums -- the layout engine owns tiled dimensions, and
    /// honouring them would pin the rect and block mod_h/mod_l resizing
    /// (`tiling.applyHints` is the tiled-side delegate). Only the floating
    /// drag-resize path honours this as a user-facing floor.
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
    /// Core covering intent: the workspace this window's coverage anchors to.
    /// Set while the owning extension parks the window as covering the screen;
    /// kept while parked so a later park wins retargeting, then cleared. Core
    /// reads it without naming any optional subsystem.
    covering_ws: ?WSId = null,
};

const WsState = struct {
    tiled_order: OrderList = .{},
    focus_mru: MruList = .{}, // newest first (index 0), bounded at mru_capacity
    params: LayoutParams = .{},
};

/// Bounded sorted-key collection: the factory lives in core/utils/bounded.zig
/// (Store, next to BoundedList) and is re-exported here so the model's window
/// store and the sync ledger share one xcb-free container without either
/// naming core (see bounded.zig for the sorted-order and pointer contracts).
pub const Store = bounded.Store;

/// Store and MRU capacities. 128 managed windows bounds the sorted-key store
/// (stack-allocated; X ids are 32-bit, so the ceiling is arbitrary but far
/// beyond real window counts). 16 keeps the per-workspace focus MRU small
/// enough to iterate on every focus/fallback path.
pub const store_capacity = 128;
pub const mru_capacity = 16;
/// Bounded per-workspace tiled membership list (defined capacity; total
/// operations, so transitions never allocate and have no OOM rollback paths).
pub const max_tiled_per_ws = constants.max_tiled_windows;
const OrderList = utils.BoundedList(WindowId, max_tiled_per_ws);
const MruList = utils.BoundedList(WindowId, mru_capacity);
const StoreT = Store(WindowId, Entry, store_capacity);

/// Index (workspace id) of the lowest set bit in `m`. Returns null when `m`
/// is zero (`@ctz(0)` = 64 is out of the [0, constants.max_workspaces) range).
pub fn lowestBit(m: Mask) ?WSId {
    if (m == 0) return null;
    return WSId.fromIndex(@intCast(@ctz(m)));
}

pub const Model = struct {
    store: StoreT = .{},
    ws: [constants.max_workspaces]WsState = [_]WsState{.{}} ** constants.max_workspaces,
    current: WSId = WSId.fromIndex(0),
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
        if (m.ws[i].tiled_order.indexOfScalar(win) != null) return WSId.fromIndex(@intCast(i));
    }
    return null;
}

pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) error{CapacityFull}!void {
    if (m.store.has(win)) return;
    const target: WSId = hint_ws orelse m.current;
    // Defined-capacity refusal with rollback, BEFORE any observable state change.
    const ptr = m.store.put(win, .{ .mask = bit(target), .anchor = .tiled }) catch return error.CapacityFull;
    if (!m.ws[target.index].tiled_order.append(win)) {
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
    if (!m.store.remove(win)) return;
    if (findHome(m, win)) |h| removeValue(&m.ws[h.index].tiled_order, win);
    for (&m.ws) |*s| removeValue(&s.focus_mru, win);
    if (m.focused == win) m.focused = null;
}

pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    return visibleEntry(m, e, ws);
}

/// Whether entry `e` is visible on `ws`: the exact predicate behind
/// `visibleOn`, minus the store lookup, so callers that already hold the
/// entry avoid a second binary search. `pub inline` so the sync layer's
/// fast-path derives visibility with no spelling drift.
pub inline fn visibleEntry(m: *const Model, e: Entry, ws: WSId) bool {
    if (e.presence == .parked) return false;
    return m.all_view_active or taggedOn(e, ws);
}

/// Whether `e` is pinned: its mask carries the soft all-workspaces sentinel
/// (every conceivable ws bit set), making it visible everywhere and immune
/// to tag edits. Feature modules test this predicate instead of spelling out
/// `mask == ALL_MASK`, keeping the sentinel's meaning in one place.
pub inline fn isPinned(e: Entry) bool {
    return e.mask == ALL_MASK;
}

/// Whether `e` is tagged on `ws`: the tag-membership test behind the
/// visible/tiled-count predicates. `pub inline` so window/sync layers share
/// one spelling instead of re-deriving `e.mask & bit(ws)`.
pub inline fn taggedOn(e: Entry, ws: WSId) bool {
    return maskedOn(e.mask, ws);
}

/// Number of windows placed in tiled slots of `ws`: entries of `ws`'s
/// tiled_order whose tag mask includes `ws`. Viewport slot math (actions) and
/// diagnostics (input dump_state) share this single model read; recomputing
/// the count from store-wide base-tiled entries would disagree on multi-tagged
/// windows. (The window layer's countWindowsOnWorkspace is the same tag test
/// over ALL windows; this one counts tiled slots specifically.)
pub fn tiledCountOnWs(m: *const Model, ws: WSId) usize {
    var n: usize = 0;
    for (m.ws[ws.index].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (taggedOn(e, ws)) n += 1;
    }
    return n;
}

/// The covering occupant owning the screen on `ws`: a covering entry whose
/// capture anchors to `ws`, or a covering entry visible on `ws` (multi-tag) —
/// OR semantics. Pure core computation, so sync/bar resolve the screen owner
/// without enumerating optional subsystems. At most one occupant per ws by the
/// reconciler.
///
/// Contrast with the fullscreen module's occupant hook
/// (`fullscreen.fullscreenOccupantOnWs`): that is a pure store-order AND scan
/// requiring covering + anchored to `ws` + visible on it, whereas this scan
/// unions anchor-or-visibility. Neither consults a module record registry
/// anymore (the model entry is the fullscreen record).
pub fn coveringOccupantOnWs(m: *const Model, ws: WSId) ?WindowId {
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.presence != .covering) continue;
        const anchored = if (row.val.covering_ws) |cws| cws.eql(ws) else false;
        if (anchored or visibleEntry(m, row.val.*, ws)) return row.key;
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
    if (!m.store.has(win)) return;
    m.focused = win;
    const list = &m.ws[m.current.index].focus_mru;
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

/// Whether `cand` is eligible as a focus-fallback candidate on `ws`: not the
/// `excluded` window, and visible there (parked entries fail visibleOn). The
/// tier-specific extra criteria (tiled membership, base mode) stay at each
/// tier's call site.
fn qualifies(m: *const Model, cand: WindowId, ws: WSId, excluded: ?WindowId) bool {
    if (cand == excluded) return false;
    return visibleOn(m, cand, ws);
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
    const mru = &m.ws[ws.index].focus_mru;
    for (mru.constSlice()) |cand| {
        if (qualifies(m, cand, ws, excluded)) return cand;
    }
    // 2. reversed tiled_order of the workspace.
    var j = m.ws[ws.index].tiled_order.len;
    while (j > 0) {
        j -= 1;
        const cand = m.ws[ws.index].tiled_order.items[j];
        if (qualifies(m, cand, ws, excluded)) return cand;
    }
    // 3. any floating window on ws (base geometry, not in tiled_order).
    //    A covering window owns the screen, so it is not a fallback target.
    //    Linear membership check per floating entry against tiled_order;
    //    adequate for <50 windows.
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.anchor != .floating or row.val.presence == .covering) continue;
        if (!qualifies(m, row.key, ws, excluded)) continue;
        if (m.ws[ws.index].tiled_order.indexOfScalar(row.key) == null) return row.key;
    }
    return null;
}

pub fn reorderTiled(m: *Model, win: WindowId, idx_in: usize) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h.index].tiled_order;
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
    const list = &m.ws[h.index].tiled_order;
    const len = list.len;
    if (len < 2) return;
    const idx = list.indexOfScalar(win) orelse return;
    const next = utils.wrapIndex(idx, dir, len);
    reorderTiled(m, win, next);
}

/// Slot swap: exchanges the first two tiled slots of the current workspace
/// (primary head and the following slot). No-op with fewer than two tiled
/// windows. Test seam: the actions layer transitions run
/// `swapFocusedWithPrevious`; production never calls this.
pub fn swapPrimary(m: *Model) void {
    const list = &m.ws[m.current.index].tiled_order;
    if (list.len < 2) return;
    const tmp = list.items[0];
    list.items[0] = list.items[1];
    list.items[1] = tmp;
}

/// Exchanges the tiled slots of the currently focused window and the
/// previously focused window (focus MRU, newest first), regardless of their
/// positions -- the pair the swap_master actions advertise ("current and
/// previous windows"). No-op when either window has no tiled slot here
/// (floating or covering focus, a predecessor parked on another workspace,
/// minimized) or when fewer than two distinct windows are focused.
pub fn swapFocusedWithPrevious(m: *Model) void {
    const focused = m.focused orelse return;
    const ws = &m.ws[m.current.index];
    const list = &ws.tiled_order;
    const mru = ws.focus_mru.constSlice();
    if (list.len < 2 or mru.len < 2) return;
    const prev = mru[1];
    if (prev == focused) return;
    const i = list.indexOfScalar(focused) orelse return;
    const j = list.indexOfScalar(prev) orelse return;
    list.items[i] = prev;
    list.items[j] = focused;
}

/// Steps the current workspace's primary-column width fraction by `delta`,
/// clamped to the shared master-width bounds in constants.
pub fn adjustPrimaryWidth(m: *Model, delta: f32) void {
    const p = &m.ws[m.current.index].params;
    p.primary_width = std.math.clamp(p.primary_width + delta, constants.min_master_width, constants.max_master_width);
}

/// Stamp one `LayoutParams` template across every workspace (the config
/// reload/seeding path — `actions.seedParamsFromConfig` supplies the template;
/// at-zone tests use it too).
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
