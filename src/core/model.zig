//! Public state facade (MVC): WM state + operations, no I/O. Holds the
//! per-window store, per-workspace arrays, current workspace, focused id, and
//! all-view toggle, and re-exports the pure vocabulary state is built from
//! (`core/architecture/domain.zig` — private to this facade plus its sanctioned
//! `config/model_config.zig` seeding root). Single import surface for state:
//! callers do `@import("model")` and get vocabulary, records, `Model`, and
//! every state operation.
//!
//! Layer rule: pure core (no X11, no feature imports). The only MODULE imports
//! are the shared bounded shelf and `domain` (std/builtin are language-level
//! edges, so this file still cannot reach the connection in `core.zig`).
//! Single-threaded.
//!
//! Feature transitions live in the window layer's optional modules and the
//! tiling engine; this file exports vocabulary re-exports and pure queries.
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

/// The generic bounded sorted-key Store (the model's concrete instance is
/// `StoreT` below). Re-exported because the reconcile ledger and tests
/// instantiate it with other parameters (`ledger.zig:69`, `model_test.zig:37`).
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
    /// invariant); null when there is no tiled slot. See findHome.
    home_ws: ?WSId = null,
    presence: Presence = .present,
    /// Core covering intent: the workspace this window's coverage anchors to.
    /// Set while the owning extension parks the window as covering the screen;
    /// kept while parked so a later park wins retargeting, then cleared.
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
pub fn removeValue(list: anytype, win: WindowId) void {
    _ = list.removeValue(win);
}

/// The workspace whose tiled_order holds win (single-membership invariant).
/// Uses the cached home_ws when available; falls back to scanning when null
/// (e.g. a freshly adopted window not yet home-assigned).
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    if (m.store.get(win)) |e| if (e.home_ws) |h| return h;
    var found: ?WSId = null;
    for (0..m.ws.len) |i| {
        if (m.ws[i].tiled_order.indexOfScalar(win) == null) continue;
        // The scan fallback only answers correctly under single membership:
        // two lists holding the window means the invariant broke upstream, and
        // returning the first hit would hand a plausible-looking wrong answer.
        // Trip loudly in Debug (folded out of Release).
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
/// Exactly one workspace list may hold a window whose `anchor` is `.tiled` and
/// `presence` is `.present`; that list must be the one its cached `home_ws`
/// names; and every id listed on any workspace must still exist in the store.
/// Floating and parked windows are home-free by design. Returns the violation
/// instead of panicking so a test can trip the exact logic
/// `debugCheckInvariants` asserts with.
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
        // home, so the cache failed to record it.
        const home = it.val.home_ws orelse return error.StaleHomeWs;
        if (home.index != actual_home.index) return error.StaleHomeWs;
    }
    for (&m.ws) |*s| {
        for (s.tiled_order.constSlice()) |w| {
            if (!m.store.has(w)) return error.OrphanedListEntry;
        }
    }
}

/// Debug-only boundary hook (P1-31): panics on the first violated single-writer
/// invariant. The mode check folds at comptime, so Release builds pay nothing.
/// Invoked inside the reconcile grab right after `reconcile.run` mutates the
/// model, so any stray membership write trips loudly in a Debug session.
pub fn debugCheckInvariants(m: *const Model) void {
    if (builtin.mode != .Debug) return;
    checkInvariants(m) catch |err| std.debug.panic(
        "model single-writer invariant violated: {s} (debug hook at reconcileGrab)",
        .{@errorName(err)},
    );
}

/// Shared tiled->floating detach (toggle_floating / drag-detach): seeds the
/// floating anchor from `rect` and drops the home-list membership. `rect` is
/// the window's last-sent (on-screen) geometry; model stays ledger-free.
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
/// `visibleOn`, minus the store lookup. `pub inline` so the sync layer's
/// fast-path derives visibility with no spelling drift.
pub inline fn visibleEntry(m: *const Model, e: *const Entry, ws: WSId) bool {
    if (e.presence == .parked) return false;
    return m.all_view_active or taggedOn(e.*, ws);
}

/// Whether `e` is pinned: its mask carries the soft all-workspaces sentinel
/// (every workspace bit set), making it visible everywhere and immune to tag
/// edits. Feature modules test this instead of `mask == ALL_MASK`.
pub inline fn isPinned(e: Entry) bool {
    return e.mask == ALL_MASK;
}

/// Whether `e` is tagged on `ws`: the tag-membership test behind the
/// visible/tiled-count predicates, re-exported via `maskedOn` for facades
/// holding only a raw mask.
pub inline fn taggedOn(e: Entry, ws: WSId) bool {
    return maskedOn(e.mask, ws);
}

/// Number of windows placed in tiled slots of `ws`: entries of `ws`'s
/// tiled_order whose tag mask includes `ws`. Viewport slot math and
/// diagnostics share this read.
pub fn tiledCountOnWs(m: *const Model, ws: WSId) usize {
    var n: usize = 0;
    for (m.ws[ws.index].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (taggedOn(e, ws)) n += 1;
    }
    return n;
}

/// The workspace `win`'s covering capture anchors to, or null when it holds
/// no covering intent.
///
/// GHOST: reports the workspace even while the entry's presence is parked
/// (minimized-from-covering leaves `covering_ws` set), so callers can read
/// the true target before teardown.
pub fn coveringWsOf(m: *const Model, win: WindowId) ?WSId {
    const e = m.store.get(win) orelse return null;
    return e.covering_ws;
}

/// Whether `win` holds covering intent at all. One definition, so the "is it
/// covering" test cannot differ between callers.
pub inline fn isCovering(m: *const Model, win: WindowId) bool {
    return coveringWsOf(m, win) != null;
}

/// Whether `win`'s covering capture targets `ws`. Does NOT consult visibility:
/// this is pre-toggle classification and was-covering capture, not an
/// occupancy question (for that, `coveringOccupantOn`).
pub fn isCoveringOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const fws = coveringWsOf(m, win) orelse return false;
    return fws.eql(ws);
}

/// Which rule decides workspace occupancy for a covering window (P2-51's one
/// parameter on the one occupant query). The two real questions the codebase
/// used to spell as two scans:
pub const OccupantRule = enum {
    /// Anchor OR visibility union: an occupant claims its anchor workspace AND
    /// every workspace its mask (or all-view) makes it visible on — a covering
    /// window whose mask was widened covers those too. The reconciler's rule;
    /// also what the border sweep's table fills.
    anchored_or_visible,
    /// Anchor AND visibility: only a covering window whose capture targets `ws`
    /// AND which is visible there (sync parks strays, so at most one per
    /// workspace). The screen-owner question: "is the screen held right now".
    anchored_and_visible,
};

/// The covering occupant owning the screen on `ws`, under an EXPLICIT rule
/// (P2-51: one implementation, both questions). Pure core computation, so
/// sync/bar/minimize resolve the screen owner without enumerating optional
/// subsystems. At most one occupant per workspace by reconciler; the anchor
/// invariant is asserted by the batch form (`coveringOccupants`) — NOT here,
/// because this single scan also runs on intermediate states.
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
/// Batch form of `coveringOccupantOn(..., .anchored_or_visible)`: right for a
/// one-off query, wrong for a sweep (the border sweep asks once per window, so
/// a full sweep would be O(N^2) store scans).
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

/// Debug-only companion to `coveringOccupants` (P1-37): asserts "at most one
/// occupant per workspace by reconciler" for the ANCHORED claim specifically:
/// no two covering entries may carry the same `covering_ws`. The batch fill's
/// tie-break would otherwise silently mask a second anchor.
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
