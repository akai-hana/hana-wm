//! Domain model (MVC): WM state + operations, no I/O. Holds per-window store,
//! per-workspace arrays, current workspace, focused id, and all-view toggle.
//! Vocabulary (Entry, WsState, LayoutParams, BaseMode, Presence, Mask, Rect,
//! Margins) is shared language across layers; distinct from src/window/ directory.
//!
//! Geometry lives here rather than in a `geom` module because it is not a
//! utility: `Rect`/`Margins` are value objects the state holds (`BaseMode.
//! floating`, `Placement`), and the two coordinate helpers exist only to serve
//! them -- `satI16` clamps into `Rect`'s own i16 range, `toXcbCoord` adapts a
//! `Rect` field to the wire. `satI16` is also used by the pure `tiling/` layer,
//! which is why these cannot live on the x11 side. The one adapter that IS
//! genuinely xcb-typed, `rectFromXcb`, stays in `x11/requests.zig`.
//!
//! Layer rule: pure core (no X11, no feature imports). The only imports are
//! `std` and other xcb-free vocabulary, so this file cannot reach the
//! connection in `core.zig` -- that is what makes it a DAG root.
//! Single-threaded.
//!
//! Feature transitions live in the window layer's optional modules; this file
//! exports only shared vocabulary types, queries, and core focus/tiling
//! intrinsics.
const std = @import("std");
const constants = @import("constants");

const bounded = @import("bounded");
/// Alias of the canonical WindowId (`@import("ids").WindowId`; see ids.zig).
pub const WindowId = @import("ids").WindowId;
/// Alias of the canonical WorkspaceId (`@import("ids").WorkspaceId`). Model
/// never imports core (xcb-free layer rule); within the model, `ws` values
/// are read as array indices via `.index`. See the ids.zig header for the
/// single-definition rationale.
pub const WSId = @import("ids").WorkspaceId;

/// Position and dimensions of a managed window, relative to the root window
/// (the total display area).
pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16 = 0,

    pub inline fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and self.width == other.width and
            self.height == other.height and self.border_width == other.border_width;
    }

    /// Geometry only, ignoring `border_width`.
    ///
    /// `eql` and `eqlGeom` exist because a `Rect` carries BOTH geometry and a
    /// border width, but the two are sent by different requests and tracked by
    /// different sent-state (a geometry configure vs the ledger's `bw` field).
    /// Comparing a whole `Rect` to decide "did the geometry move" therefore
    /// reads a field the comparison does not own, so a border-width-only
    /// change reads as a move and buys a spurious configure plus raise. Use
    /// `eql` only when the border width is part of the comparison.
    pub inline fn eqlGeom(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and self.width == other.width and
            self.height == other.height;
    }
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap: u16 = 0,
    border: u16 = 0,
};

/// Twice the border width (left+right / top+bottom inset).
pub inline fn doubledBorder(m: Margins) u16 {
    return 2 *| m.border;
}

/// Saturating i16 coordinate clamp: narrows an i32 coordinate into the i16
/// `Rect` range, clamping instead of wrapping so a single pathological value
/// can't cross the whole screen in ReleaseFast.
pub inline fn satI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// Reinterprets a signed X11 coordinate (i16 on the wire) as the u32 value
/// XCB's configure_window value array expects.
pub inline fn toXcbCoord(v: i16) u32 {
    return @bitCast(@as(i32, v));
}

/// Modulo-wraps `idx` by signed `dir` into [0, n); 0 for an empty range.
/// The one modulo-wrap in the tree, powering the round-robin focus and
/// layout-direction cycles, so those callers name the operation instead of
/// reaching into a shared grab bag for it.
pub inline fn wrapIndex(idx: usize, dir: i32, n: usize) usize {
    if (n == 0) return 0;
    return @intCast(@mod(@as(i64, @intCast(idx)) + dir, @as(i64, @intCast(n))));
}

pub const Mask = u64;

/// Mask bit for workspace `ws`.
///
/// Two preconditions, both tied to `constants.max_workspaces` rather than
/// restating its number: the index must name a real workspace, and it must
/// fit the u64 mask. A shift by >= bitSizeOf would silently produce a wrong
/// mask in safe modes, so raising max_workspaces past 64 is a loud build
/// failure rather than a corrupt membership mask.
pub inline fn bit(ws: WSId) Mask {
    std.debug.assert(ws.isValid());
    std.debug.assert(ws.index < @bitSizeOf(Mask));
    return @as(Mask, 1) << @intCast(ws.index);
}

/// Whether `mask` carries the tag bit for `ws`.
pub inline fn maskedOn(mask: Mask, ws: WSId) bool {
    return mask & bit(ws) != 0;
}

pub const ALL_MASK: Mask = ~@as(Mask, 0);

/// Single canonical size-hints record AND the only store: admission threads
/// the parsed WM_NORMAL_HINTS to mapRequest as a parameter (there is no
/// staging copy anywhere -- wincache used to hold a pre-registration bridge,
/// deleted as double bookkeeping). Do NOT import layouts from here (layer rule).
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
    /// Home workspace membership is DERIVED (exactly one `ws`.tiled_order list
    /// holds a tiled window; findHome). Visibility on other tagged workspaces
    /// is a sync-time mask filter (engine stays mask-agnostic).
    tiled,
    floating: Rect,
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
    /// invariant); null when the window has no tiled slot. See findHome.
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

/// Bounded sorted-key collection re-exported from the pure shelf; the model's
/// window store and the reconcile ledger share it without either naming core.
pub const Store = bounded.Store;

/// Store and MRU capacities: 128 bounds the sorted-key store (stack-allocated);
/// 16 keeps the per-workspace focus MRU small. Per-workspace tiled membership
/// is bounds from constants. Transitions never allocate (defined capacities).
pub const store_capacity = 128;
pub const mru_capacity = 16;
pub const max_tiled_per_ws = constants.max_tiled_windows;
const OrderList = bounded.BoundedList(WindowId, max_tiled_per_ws);
const MruList = bounded.BoundedList(WindowId, mru_capacity);
const StoreT = Store(WindowId, Entry, store_capacity);

/// Index (workspace id) of the lowest set bit in `m`, or null for the zero
/// mask (`@ctz(0)` = 64, out of the u64 bit range — see `bit`).
pub fn lowestBit(m: Mask) ?WSId {
    if (m == 0) return null;
    return WSId.fromIndex(@ctz(m));
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
/// Thin delegate to BoundedList.removeValue, kept as a free function because
/// the typed-list spelling reads better at the call sites than a method on a
/// generic the caller would have to name.
pub fn removeValue(list: anytype, win: WindowId) void {
    _ = list.removeValue(win);
}

/// The workspace whose tiled_order holds win (single-membership invariant).
/// Uses the cached home_ws when available; falls back to scanning when the
/// cache is null (e.g. a freshly adopted window not yet home-assigned).
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    if (m.store.get(win)) |e| if (e.home_ws) |h| return h;
    for (0..m.ws.len) |i| {
        if (m.ws[i].tiled_order.indexOfScalar(win) != null) return WSId.fromIndex(i);
    }
    return null;
}

/// Shared tiled->floating detach (toggle_floating / drag-detach): seeds the
/// floating anchor from `rect` and drops the home-list membership. `rect` is
/// the window's last-sent (on-screen) geometry, fetched from the X11 ledger
/// by the caller -- model stays ledger-free. One spelling, reached by both
/// the action layer and the floating module directly.
pub fn detachTiledToFloating(m: *Model, e: *Entry, win: WindowId, rect: Rect) void {
    if (e.home_ws) |home| removeValue(&m.ws[home.index].tiled_order, win);
    e.anchor = .{ .floating = rect };
    e.home_ws = null; // no longer in tiled_order
}

pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) error{CapacityFull}!void {
    if (m.store.has(win)) return;
    const target: WSId = hint_ws orelse m.current;
    // Bounds-checked: `ws` is a FIXED [max_workspaces] array, so an out-of-range
    // target (reachable from a lenient `WorkspaceId.fromIndex` on a config
    // path) would index out of the model. Fail at the boundary that created
    // the id, not silently on the array read below.
    std.debug.assert(target.isValid());
    // Defined-capacity refusal with rollback, BEFORE any observable state change.
    const ptr = m.store.put(win, .{ .mask = bit(target), .anchor = .tiled }) catch |e| return e;
    if (!m.ws[target.index].tiled_order.append(win)) {
        _ = m.store.remove(win);
        return error.CapacityFull;
    }
    // home_ws cache set only after a tiled slot exists (see findHome).
    ptr.home_ws = target;
}

pub fn unregister(m: *Model, win: WindowId) void {
    if (!m.store.remove(win)) return;
    // Scrub EVERY workspace's lists, not just the cached home_ws. A stale id
    // left in some other workspace's tiled_order would make a later layout
    // pass move or draw a window the store no longer has, and there is no
    // way to detect that from the entry once it is gone. Whole-model scan, provably
    // idempotent, and it removes the home_ws-then-unregister ordering dance.
    for (&m.ws) |*s| {
        removeValue(&s.tiled_order, win);
        removeValue(&s.focus_mru, win);
    }
    if (m.focused == win) m.focused = null;
}

pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    return visibleEntry(m, &e, ws);
}

/// Whether entry `e` is visible on `ws`: the exact predicate behind
/// `visibleOn`, minus the store lookup, so callers that already hold the
/// entry avoid a second binary search. `pub inline` so the sync layer's
/// fast-path derives visibility with no spelling drift.
pub inline fn visibleEntry(m: *const Model, e: *const Entry, ws: WSId) bool {
    if (e.presence == .parked) return false;
    return m.all_view_active or taggedOn(e.*, ws);
}

/// Whether `e` is pinned: its mask carries the soft all-workspaces sentinel
/// (every conceivable workspace bit set), making it visible everywhere and
/// immune to tag edits. Feature modules test this predicate instead of
/// `mask == ALL_MASK`, keeping the sentinel's meaning in one place.
pub inline fn isPinned(e: Entry) bool {
    return e.mask == ALL_MASK;
}

/// Whether `e` is tagged on `ws`: the tag-membership test behind the
/// visible/tiled-count predicates, re-exported via `maskedOn` for facades that
/// hold only a raw mask (query/window re-derive `maskedOn(e.mask, ws)`).
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

/// The workspace `win`'s covering capture anchors to, or null when it
/// holds no covering intent.
///
/// GHOST: reports the workspace even while the entry's presence is parked
/// (minimized-from-covering leaves `covering_ws` set), so callers
/// classifying a drop can read the true target before teardown.
pub fn coveringWsOf(m: *const Model, win: WindowId) ?WSId {
    const e = m.store.get(win) orelse return null;
    return e.covering_ws;
}

/// Whether `win` holds covering intent at all. One definition of the question,
/// so the "is it covering" test cannot differ between callers.
pub inline fn isCovering(m: *const Model, win: WindowId) bool {
    return coveringWsOf(m, win) != null;
}

/// Whether `win`'s covering capture targets `ws`. Does NOT consult visibility:
/// this is pre-toggle classification and was-covering capture, not an
/// occupancy question (for that see `coveringOccupantOnWs`).
pub fn isCoveringOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const fws = coveringWsOf(m, win) orelse return false;
    return fws.eql(ws);
}

/// The covering occupant owning the screen on `ws`: anchor-or-visibility OR
/// union. Pure core computation, so sync/bar resolve the screen owner without
/// enumerating optional subsystems. At most one occupant per workspace by
/// reconciler. (fullscreen's occupant hook is a stricter AND scan: covering +
/// anchored + visible — see fullscreen.visibleCoveringOnWs.)
pub fn coveringOccupantOnWs(m: *const Model, ws: WSId) ?WindowId {
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.presence != .covering) continue;
        const anchored = if (row.val.covering_ws) |cws| cws.eql(ws) else false;
        if (anchored or visibleEntry(m, row.val, ws)) return row.key;
    }
    return null;
}

/// Fills `buf` (one slot per workspace, indexed by `WSId.index`) with that
/// workspace's covering occupant, in ONE store pass.
///
/// Batch form of `coveringOccupantOnWs`, which answers the same question
/// for a single workspace: that is the right shape for a one-off query and
/// the wrong one for a sweep (the border sweep asks it once per window, so a
/// full sweep was O(N^2) store scans). This fills the whole table up front.
///
/// Per workspace the rule is the scan form's exact (anchored or visible): an
/// occupant claims its anchor slot AND every workspace its mask makes it
/// visible on — an anchored occupant whose mask was widened (tagAdd writes
/// mask only) covers those workspaces too, exactly as the scan reports them.
/// Ties resolve to the FIRST occupant in store order (the `== null` guard is
/// what preserves that; a later covering entry must not displace an earlier
/// one).
pub fn coveringOccupants(m: *const Model, buf: []?WindowId) void {
    for (buf) |*slot| slot.* = null;
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.presence != .covering) continue;
        if (row.val.covering_ws) |cws| {
            if (cws.index < buf.len and buf[cws.index] == null) buf[cws.index] = row.key;
        }
        // Anchored or not, the occupant also owns every workspace it is
        // visible on (mask / all-view); already-filled slots keep the
        // earlier store-order winner.
        for (buf, 0..) |*slot, i| {
            if (slot.* != null) continue;
            if (visibleEntry(m, row.val, WSId.fromIndex(i))) slot.* = row.key;
        }
    }
}

// Shared vocabulary types (folded in from the former feature module files).
// Pure vocabulary consumed by both the wire-side feature plugins and wire
// callers; they live in core so nothing needs to import a feature file just
// to reference them.

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

// Core intrinsics: focus (setFocus/clearFocus, MRU upkeep, fallback candidate)
// and tiling-order transitions (reorder/step/swap, primary width). Pure model
// operations; feature transitions live in the window layer's optional modules.

pub fn setFocus(m: *Model, win: WindowId) void {
    if (!m.store.has(win)) return;
    m.focused = win;
    const list = &m.ws[m.current.index].focus_mru;
    // Re-focusing an already-tracked window moves it to the front WITHOUT
    // spending an eviction, so the newest `mru_capacity` DISTINCT windows are
    // the ones retained. Then front-insert, evicting the oldest (tail) at
    // capacity -- one call, so the order (evict, then insert) cannot be
    // transposed at the call site.
    const already = list.removeValue(win);
    if (!already) _ = list.pushFrontEvictingTail(win) else _ = list.insert(0, win);
}

/// The ONE focused/unfocused border-pixel pick.
///
/// This lived as `borders.borderColorOf(focused, ...)` in the window layer
/// while the core pipeline carried its own copy of the same ternary, so the
/// two could drift and nothing would notice. It lives here because `model` is
/// on the pure layer's allowlist -- reachable from core AND the window layer,
/// whereas the obvious home (`borders`) is import-closed to core.
///
/// `m` supplies the focus source so the caller does not have to pass a
/// possibly-different answer (borders used `focus.getFocused()`, the pipeline
/// read `m.focused`; those agree in production but nothing enforced it).
pub inline fn focusedBorderColor(m: *const Model, win: WindowId, focused_px: u32, unfocused_px: u32) u32 {
    return if (m.focused == win) focused_px else unfocused_px;
}

/// Applies a layout module's pre-reconcile delta to `ws`'s params, IN PLACE,
/// through the model.
///
/// The hook is value-in/value-out (`old -> new`), and the pipeline used to
/// write the result straight back through a raw `*LayoutParams` it took from
/// the model. That pointer was an un-gated mutation channel into the model:
/// anything holding it could rewrite a field the model owns (or reach another
/// workspace) with no check. Routing the write through here means the model
/// decides whether `ws` is addressable, and the pipeline holds no pointer
/// into model state at all.
pub fn applyParamsDelta(m: *Model, ws: WSId, delta: LayoutParams) void {
    std.debug.assert(ws.isValid());
    m.ws[ws.index].params = delta;
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

/// The visible windows of `ws` in ON-SCREEN order, for focus cycling: writes
/// them into `buf` and returns the count (0 when `buf` is empty). Ordered by
/// layout, not by window id, because the cycle must follow the arrangement:
/// `ws`'s tiled_order first (the same slice the layout engine tiles, so master
/// slots lead and the stack follows), then the visible windows with no tiled
/// slot here -- floating ones and multi-tagged windows homed on another
/// workspace -- in store order. Anchoring to tiled_order is what makes a
/// cycle step track a move or a master swap: those rewrite that list in place
/// (stepTiled / swapFocusedWithPrevious), so the cycle reorders with the
/// screen instead of staying on the order windows happened to be created in.
///
/// A covering occupant collapses the pool to that one window: it owns the
/// screen, so nothing behind it is reachable. Membership is exactly
/// `visibleEntry` (parked never cycles; the tag test is relaxed while
/// all_view_active drives visibility), so the pool can never disagree with the
/// focus-visible model. `seen` is per-call stack scratch marking the store
/// slots already admitted, so the two passes can't double-admit a window.
pub fn collectCyclePool(m: *const Model, ws: WSId, buf: []WindowId) usize {
    if (coveringOccupantOnWs(m, ws)) |occ| {
        if (buf.len == 0) return 0;
        buf[0] = occ;
        return 1;
    }
    var seen: [store_capacity]bool = [_]bool{false} ** store_capacity;
    var n: usize = 0;
    // Pass 1: the shown workspace's tiled order == screen order. indexOf
    // locates the store row, at() reads it -- one search per window, matching
    // the reconciler's order build.
    for (m.ws[ws.index].tiled_order.constSlice()) |w| {
        if (n == buf.len) break;
        const slot = m.store.indexOf(w) orelse continue;
        const e = m.store.at(slot).val;
        if (!visibleEntry(m, e, ws)) continue;
        seen[slot] = true;
        buf[n] = w;
        n += 1;
    }
    // Pass 2: the untiled tail, after the tiled run. Store order, so floating
    // windows keep a stable order among themselves.
    for (0..m.store.count()) |slot| {
        if (n == buf.len) break;
        if (seen[slot]) continue;
        const row = m.store.at(slot);
        if (!visibleEntry(m, row.val, ws)) continue;
        buf[n] = row.key;
        n += 1;
    }
    return n;
}

/// Minimize-fallback target policy. The window layer's focusFallback
/// delegates here, and tests exercise the same logic without linking the
/// protocol layers. Tier order on workspace `ws`: focus MRU (newest first),
/// reversed tiled_order, then any visible floating-base window not in
/// tiled_order. First `visibleOn(ws)` candidate wins; null when nothing
/// qualifies. `excluded` is a candidate the caller already rejected (e.g. a
/// no_input window that can never hold X focus) — it is skipped across all
/// tiers so the caller can re-scan for the next focusable window.
pub fn fallbackFocusCandidate(m: *const Model, ws: WSId, excluded: ?WindowId) ?WindowId {
    // 1. focus MRU, newest first (mru[0] is the MOST RECENT focus, so
    //    minimizing the focused window falls back to the previously focused
    //    one). visibleOn rejects parked entries, including the just-parked
    //    window itself.
    const mru = &m.ws[ws.index].focus_mru;
    for (mru.constSlice()) |cand| {
        if (qualifies(m, cand, ws, excluded)) return cand;
    }
    // 2. reversed tiled_order.
    var j = m.ws[ws.index].tiled_order.len;
    while (j > 0) {
        j -= 1;
        const cand = m.ws[ws.index].tiled_order.items[j];
        if (qualifies(m, cand, ws, excluded)) return cand;
    }
    // 3. any floating window on the workspace (base geometry, not in
    //    tiled_order). A covering window owns the screen, so it is not a
    //    fallback target.
    //    Linear membership check per floating entry against tiled_order;
    //    adequate for <50 windows.
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.anchor != .floating or row.val.presence == .covering) continue;
        if (row.key == excluded or !visibleEntry(m, row.val, ws)) continue;
        if (m.ws[ws.index].tiled_order.indexOfScalar(row.key) == null) return row.key;
    }
    return null;
}

/// Moves `win` within `list` from `from` to `to`. Shared by reorderTiled and
/// stepTiled (who already resolved both indices) to keep the single mutation
/// in one place.
fn moveTiled(list: *OrderList, win: WindowId, from: usize, to: usize) void {
    list.orderedRemove(from);
    _ = list.insert(to, win); // cannot fail: removal freed a slot
}

pub fn reorderTiled(m: *Model, win: WindowId, idx_in: usize) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h.index].tiled_order;
    const from = list.indexOfScalar(win) orelse return;
    moveTiled(list, win, from, @min(idx_in, list.len - 1));
}

/// Moves `win` one slot in `dir` within its home workspace's tiled order,
/// wrapping around either edge (dwm-style stack rotate, mirroring the focus
/// cycle's modulo wrap). Unknown windows and lone tiled windows are no-ops.
pub fn stepTiled(m: *Model, win: WindowId, dir: i32) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h.index].tiled_order;
    const len = list.len;
    if (len < 2) return;
    const from = list.indexOfScalar(win) orelse return;
    moveTiled(list, win, from, wrapIndex(from, dir, len));
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
    p.primary_width = std.math.clamp(
        p.primary_width + delta,
        constants.min_master_width,
        constants.max_master_width,
    );
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
