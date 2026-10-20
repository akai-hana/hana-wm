//! Public state facade (MVC): WM state + operations, no I/O. Holds the
//! per-window store, per-workspace arrays, current workspace, focused id, and
//! all-view toggle, and re-exports the pure vocabulary that state is built
//! from (`core/architecture/domain.zig` — private to this facade plus its
//! sanctioned `config/model_config.zig` seeding root). This is the
//! single import surface for state: callers do `@import("model")` and get
//! vocabulary, records, `Model`, and every state operation — the domain file
//! stays an implementation detail.
//!
//! Layer rule: pure core (no X11, no feature imports). The only MODULE
//! imports are the shared bounded shelf and `domain` (std/builtin are
//! language-level edges, not module imports, so this file still cannot reach
//! the connection in `core.zig` — that is what keeps the pure side a DAG
//! root). Single-threaded.
//!
//! Feature transitions live in the window layer's optional modules and the
//! tiling engine (`window/protocol/focus.zig`, `window/state/window_state_ops.zig`,
//! `tiling/tiling.zig` via `tiling_seam`); this file exports only shared
//! vocabulary re-exports and pure queries.
const builtin = @import("builtin");
const bounded = @import("bounded");
const domain = @import("domain");
const std = @import("std");

// Re-export vocabulary — EVERY decl of domain, one line each.
pub const WindowId = domain.WindowId;
pub const WorkspaceId = domain.WorkspaceId;
pub const WSId = domain.WSId;
pub const Mask = domain.Mask;
pub const ALL_MASK = domain.ALL_MASK;
pub const Rect = domain.Rect;
pub const Dims = domain.Dims;
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
pub const centerRectIn = domain.centerRectIn;
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
    var found: ?WSId = null;
    for (0..m.ws.len) |i| {
        if (m.ws[i].tiled_order.indexOfScalar(win) == null) continue;
        // The scan fallback only answers correctly under single membership:
        // two lists holding the window means the invariant broke somewhere
        // upstream, and silently returning the first hit would hand the
        // caller a plausible-looking wrong answer. Trip loudly in Debug
        // (folded out of Release; P1-37) -- the reconcile-grab hook checks
        // this too, but this path runs on queries outside the grab as well.
        if (builtin.mode == .Debug) {
            if (found) |prev| std.debug.panic(
                "findHome: window 0x{x} listed on workspaces {d} and {d} (single-membership violated)",
                .{ win, prev.index, i },
            );
        }
        found = WSId.fromIndex(i);
    }
    return found;
}

/// First-violation form of the single-writer membership invariant (P1-31).
/// Exactly one workspace list may hold a window whose `anchor` is `.tiled`
/// and `presence` is `.present`; that list must be the one its cached
/// `home_ws` names; and every id listed on any workspace must still exist in
/// the store. Floating and parked windows are home-free by design, so they
/// are skipped. Returns the violation instead of panicking so a test can trip
/// the exact logic `debugCheckInvariants` asserts with (Zig cannot catch a
/// panic, and `std.testing.expect` would abort the run).
pub const InvariantViolation = error{
    StrandedWindow,
    DuplicateMembership,
    StaleHomeWs,
    OrphanedListEntry,
};

pub fn checkInvariants(m: *const Model) InvariantViolation!void {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.anchor != .tiled or it.val.presence != .present) continue;
        var homes: usize = 0;
        var actual_home: WSId = undefined;
        for (&m.ws, 0..) |*s, wi| {
            if (s.tiled_order.indexOfScalar(it.key) != null) {
                homes += 1;
                actual_home = WSId.fromIndex(wi);
            }
        }
        if (homes == 0) return error.StrandedWindow;
        if (homes > 1) return error.DuplicateMembership;
        // A missing home_ws on a listed window is stale too: the list IS the
        // home, so the cache simply failed to record it.
        const home = it.val.home_ws orelse return error.StaleHomeWs;
        if (home.index != actual_home.index) return error.StaleHomeWs;
    }
    for (&m.ws) |*s| {
        for (s.tiled_order.constSlice()) |w| {
            if (!m.store.has(w)) return error.OrphanedListEntry;
        }
    }
}

/// Debug-only boundary hook (P1-31): panics on the first violated
/// single-writer invariant. The mode check folds at comptime, so Release
/// builds pay nothing and the call is an inline no-op. The reconcile-grab
/// boundaries in `core/loop/pipeline.zig` invoke it inside the grab right
/// after `reconcile.run` mutates the model, so any stray membership write
/// trips loudly in a Debug session instead of silently corrupting tiling.
pub fn debugCheckInvariants(m: *const Model) void {
    if (builtin.mode != .Debug) return;
    checkInvariants(m) catch |err| std.debug.panic(
        "model single-writer invariant violated: {s} (debug hook at reconcileGrab)",
        .{@errorName(err)},
    );
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
/// occupancy question (for that see `coveringOccupantOn`).
pub fn isCoveringOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const fws = coveringWsOf(m, win) orelse return false;
    return fws.eql(ws);
}

/// Which rule decides workspace occupancy for a covering window (P2-51's
/// one parameter on the one occupant query). The two real questions the
/// codebase used to spell as two scans:
pub const OccupantRule = enum {
    /// Anchor OR visibility union: an occupant claims its anchor workspace
    /// AND every workspace its mask (or all-view) makes it visible on — a
    /// covering window whose mask was widened (tagAdd writes mask only)
    /// covers those workspaces too. The reconciler's rule; also what the
    /// border sweep's batch table fills.
    anchored_or_visible,
    /// Anchor AND visibility: only a covering window whose capture targets
    /// `ws` AND which is visible there (sync parks strays, so at most one
    /// such window per workspace). The screen-owner question: "is the
    /// screen held right now", asked by the fullscreen toggle, the bar
    /// hide/restore decision, and the workspaces move/tag guard.
    anchored_and_visible,
};

/// The covering occupant owning the screen on `ws`, under an EXPLICIT rule
/// (P2-51: one implementation, both questions — the old OR scan
/// `coveringOccupantOnWs` and the fullscreen module's AND scan
/// `visibleCoveringOnWs`). Pure core computation, so sync/bar/minimize
/// resolve the screen owner without enumerating optional subsystems or
/// routing a pure model question through a contract hook. At most one
/// occupant per workspace by reconciler; the anchor invariant itself is
/// asserted by the batch form (`coveringOccupants`, P1-37) — NOT here,
/// because this single scan also runs on intermediate states the model
/// must tolerate before sync parks a stray (a covering record whose base
/// is tagged elsewhere keeps its anchor until the park lands; the test
/// suite pins that tolerance).
pub fn coveringOccupantOn(m: *const Model, ws: WSId, rule: OccupantRule) ?WindowId {
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.presence != .covering) continue;
        switch (rule) {
            .anchored_or_visible => {
                const anchored = if (row.val.covering_ws) |cws| cws.eql(ws) else false;
                if (anchored or visibleEntry(m, row.val, ws)) return row.key;
            },
            .anchored_and_visible => {
                const cws = row.val.covering_ws orelse continue;
                if (!cws.eql(ws)) continue;
                if (!visibleEntry(m, row.val, ws)) continue;
                return row.key;
            },
        }
    }
    return null;
}

/// Fills `buf` (one slot per workspace, indexed by `WSId.index`) with that
/// workspace's covering occupant, in ONE store pass.
///
/// Batch form of `coveringOccupantOn(..., .anchored_or_visible)`, which
/// answers the same question for a single workspace: that is the right
/// shape for a one-off query and the wrong one for a sweep (the border
/// sweep asks it once per window, so a full sweep would be O(N^2) store
/// scans). This fills the whole table up front.
///
/// Per workspace the rule is the scan form's exact (anchored or visible): an
/// occupant claims its anchor slot AND every workspace its mask makes it
/// visible on — an anchored occupant whose mask was widened (tagAdd writes
/// mask only) covers those workspaces too, exactly as the scan reports them.
/// Ties resolve to the FIRST occupant in store order (the `== null` guard is
/// what preserves that; a later covering entry must not displace an earlier
/// one).
pub fn coveringOccupants(m: *const Model, buf: []?WindowId) void {
    if (builtin.mode == .Debug) assertOneAnchorPerWs(m);
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

/// Debug-only companion to `coveringOccupants` (P1-37): asserts the rule
/// `coveringOccupantOn` documents -- "at most one occupant per workspace
/// by reconciler" -- for the ANCHORED claim specifically: no two covering
/// entries may carry the same `covering_ws`. The batch fill's
/// first-in-store-order tie-break would otherwise silently mask a second
/// anchor (and a visible-tie can legally collide with an anchor, which is
/// why the check tracks anchors apart from `buf`). Runs on queries too, so
/// it covers the window between reconcile grabs. Folded out of Release.
fn assertOneAnchorPerWs(m: *const Model) void {
    if (builtin.mode != .Debug) return;
    var anchored = [_]?WindowId{null} ** max_workspaces;
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.presence != .covering) continue;
        const cws = row.val.covering_ws orelse continue;
        if (cws.index >= anchored.len) continue; // WSId.fromIndex is lenient
        if (anchored[cws.index]) |prev| std.debug.panic(
            "two anchored covering occupants on workspace {d}: 0x{x} and 0x{x} (single-anchor rule violated)",
            .{ cws.index, prev, row.key },
        );
        anchored[cws.index] = row.key;
    }
}
