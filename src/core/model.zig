//! Public state facade (MVC): WM state + operations, no I/O. Holds the
//! per-window store, per-workspace arrays, current workspace, focused id, and
//! all-view toggle, and re-exports the pure vocabulary that state is built
//! from (`core/architecture/domain.zig`, private to this file). This is the
//! single import surface for state: callers do `@import("model")` and get
//! vocabulary, records, `Model`, and every state operation — the domain file
//! stays an implementation detail.
//!
//! Layer rule: pure core (no X11, no feature imports). The only imports are
//! the shared bounded shelf and `domain`, so this file cannot reach
//! the connection in `core.zig` — that is what keeps the pure side a DAG
//! root. Single-threaded.
//!
//! Feature transitions live in the window layer's optional modules and the
//! tiling engine (`window/protocol/focus.zig`, `window/state/window_state_ops.zig`,
//! `tiling/tiling.zig` via `tiling_seam`); this file exports only shared
//! vocabulary re-exports and pure queries.
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
/// (`window_state_ops.unregister`) and `detachTiledToFloating`; anytype because
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
/// full sweep would be O(N^2) store scans). This fills the whole table up front.
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
