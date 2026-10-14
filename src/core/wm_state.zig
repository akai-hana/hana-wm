//! Public state facade (MVC): WM state + operations, no I/O. Holds the
//! per-window store, per-workspace arrays, current workspace, focused id, and
//! all-view toggle, and re-exports the pure vocabulary that state is built
//! from (`core/architecture/domain.zig`, private to this file). This is the
//! single import surface for state: callers do `@import("wm_state")` and get
//! vocabulary, records, `Model`, and every state operation — the domain file
//! stays an implementation detail.
//!
//! Layer rule: pure core (no X11, no feature imports). The only imports are
//! `std`, the shared bounded shelf, and `domain`, so this file cannot reach
//! the connection in `core.zig` — that is what keeps the pure side a DAG
//! root. Single-threaded.
//!
//! Feature transitions live in the window layer's optional modules; this file
//! exports only shared vocabulary re-exports, queries, and core focus/tiling
//! intrinsics.
const std = @import("std");

const bounded = @import("bounded");
const domain = @import("domain");

// Re-export vocabulary — EVERY decl of domain, one line each.
pub const WindowId = domain.WindowId;
pub const WorkspaceId = domain.WorkspaceId;
pub const WSId = domain.WSId;
pub const Mask = domain.Mask;
pub const ALL_MASK = domain.ALL_MASK;
pub const Rect = domain.Rect;
pub const Margins = domain.Margins;
pub const SizeHints = domain.SizeHints;
pub const LayoutParams = domain.LayoutParams;
pub const BaseMode = domain.BaseMode;
pub const Presence = domain.Presence;
pub const RestoreOrder = domain.RestoreOrder;
pub const ConfigureReq = domain.ConfigureReq;
pub const HonorDecision = domain.HonorDecision;

pub const max_workspaces = domain.max_workspaces;
pub const max_tiled_windows = domain.max_tiled_windows;
pub const max_tiled_per_ws = domain.max_tiled_per_ws;
pub const max_primary_count = domain.max_primary_count;
pub const max_layouts = domain.max_layouts;
pub const store_capacity = domain.store_capacity;
pub const mru_capacity = domain.mru_capacity;
pub const min_master_width = domain.min_master_width;
pub const max_master_width = domain.max_master_width;

pub const isValidWorkspaceIndex = domain.isValidWorkspaceIndex;
pub const doubledBorder = domain.doubledBorder;
pub const satI16 = domain.satI16;
pub const toXcbCoord = domain.toXcbCoord;
pub const wrapIndex = domain.wrapIndex;
pub const bit = domain.bit;
pub const maskedOn = domain.maskedOn;
pub const capPrimaryCount = domain.capPrimaryCount;
pub const lowestBit = domain.lowestBit;

/// The generic bounded sorted-key Store (parameterized; the concrete instance
/// the model uses is `StoreT` below). Re-exported through the facade because
/// the reconcile ledger and tests instantiate it with other parameters —
/// `ledger.zig:69` `model.Store(model.WindowId, SentEntry, model.store_capacity)`
/// and `model_test.zig:37` `model.Store(u32, u8, 2)` must keep compiling.
pub const Store = domain.Store;

const OrderList = bounded.BoundedList(WindowId, max_tiled_per_ws);
const MruList = bounded.BoundedList(WindowId, mru_capacity);
const StoreT = Store(WindowId, Entry, store_capacity);

/// Per-window store row: the vocabulary records the model holds for every
/// managed window.
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

pub const WsState = struct {
    tiled_order: OrderList = .{},
    focus_mru: MruList = .{}, // newest first (index 0), bounded at mru_capacity
    params: LayoutParams = .{},
};

/// THE single runtime state struct. Methods live INSIDE; there is no `ws()`
/// accessor (it would collide with the `ws` field — callers use `m.ws[i]`
/// directly).
pub const Model = struct {
    store: StoreT = .{},
    ws: [max_workspaces]WsState = [_]WsState{.{}} ** max_workspaces,
    current: WSId = WSId.fromIndex(0),
    focused: ?WindowId = null,
    all_view_active: bool = false,

    pub inline fn isManaged(self: *Model, win: WindowId) bool {
        return self.store.has(win);
    }
    pub inline fn getFocused(self: *Model) ?WindowId {
        return self.focused;
    }
    pub inline fn getCurrentWorkspace(self: *Model) WSId {
        return self.current;
    }
    pub inline fn isAllViewActive(self: *Model) bool {
        return self.all_view_active;
    }
    pub inline fn entry(self: *Model, win: WindowId) ?*Entry {
        return self.store.getPtr(win);
    }
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
/// tiled_order whose tag mask includes `ws`. Viewport slot math (reconcile_tails) and
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
/// two could drift and nothing would notice. It lives here because the state
/// is on the pure layer's allowlist -- reachable from core AND the window
/// layer, whereas the obvious home (`borders`) is import-closed to core.
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
/// clamped to the shared master-width bounds above.
pub fn adjustPrimaryWidth(m: *Model, delta: f32) void {
    const p = &m.ws[m.current.index].params;
    p.primary_width = std.math.clamp(
        p.primary_width + delta,
        min_master_width,
        max_master_width,
    );
}

/// Stamp one `LayoutParams` template across every workspace (the config
/// reload/seeding path — `seed.seedParamsFromConfig` supplies the template;
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
