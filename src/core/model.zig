//! State + vocabulary (MVC): WM state and its pure operations, no I/O. Holds
//! the identifier types, state-held value objects (`Rect`/`Margins`), mask/tag
//! and layout-parameter records, feature enums, constants and helpers, plus
//! the per-window store, per-workspace arrays, current workspace, focused id,
//! and all-view toggle. Callers do `@import("model")` and get everything:
//! vocabulary, records, `Model`, and every state query.
//!
//! Layer rule: pure core (no X11, no feature imports). The only MODULE import
//! is the shared bounded shelf (std/builtin are language-level edges, so this
//! file cannot reach the connection in `core.zig`). Geometry lives here because
//! `Rect`/`Margins` are state-held value objects and `satI16` also serves the
//! pure `tiling/` layer. Single-threaded.
//!
//! Feature transitions live in the window layer's optional modules and the
//! tiling engine; this file holds vocabulary and pure queries.
const builtin = @import("builtin");
const bounded = @import("bounded");
const std = @import("std");

/// Canonical window identifier type (xcb_window_t / uint32_t). `core.WindowId` and
/// `model.WindowId` alias it, so ids cross the core/state boundary without
/// conversion.
pub const WindowId = u32;

/// Canonical workspace identifier; `core.WorkspaceId` and `model.WSId` are both names for
/// this struct, so ids cross the core/state boundary without conversion. `.index` keeps
/// `ws` values usable directly as array indices. Range is a SEPARATE question from
/// representation: `fromIndex` is lenient (config/recovery), `fromIndexChecked` asserts
/// (internal), `isValid` is the question every fixed-size consumer asks.
pub const WorkspaceId = struct {
    index: u8,

    /// Lenient constructor (the parser/restore entry point): narrows to u8 and deliberately
    /// does NOT range-check -- an out-of-range config value is recoverable there (the
    /// caller clamps or warns) while a panic would turn a config typo into a failed
    /// startup. Use `fromIndexChecked` for internal values that must be valid.
    pub fn fromIndex(i: anytype) WorkspaceId {
        return .{ .index = @intCast(i) };
    }

    /// Constructive constructor: asserts a real workspace, so an internal 65th
    /// workspace fails at the boundary that created it rather than as a silent
    /// wrong-mask or out-of-bounds read further on.
    pub fn fromIndexChecked(i: anytype) WorkspaceId {
        const ws: WorkspaceId = .{ .index = @intCast(i) };
        std.debug.assert(isValidWorkspaceIndex(ws.index));
        return ws;
    }

    /// True when this id names a workspace the model can hold. Past-ceiling values can
    /// still exist (lenient `fromIndex` admits them), so every fixed-size-array consumer
    /// must ask.
    pub fn isValid(self: WorkspaceId) bool {
        return isValidWorkspaceIndex(self.index);
    }

    pub fn eql(self: WorkspaceId, other: WorkspaceId) bool {
        return self.index == other.index;
    }
};

/// State-layer alias of the canonical WorkspaceId.
pub const WSId = WorkspaceId;

/// The ONE validity notion for a workspace index: the mask shift, the state's
/// fixed-size `ws` array and the config lookup tables all ask here, so a raise of
/// `max_workspaces` cannot leave one answering a different question.
pub fn isValidWorkspaceIndex(i: anytype) bool {
    return @as(usize, @intCast(i)) < max_workspaces;
}

/// Hard ceiling on workspaces the WM can meaningfully support -- not an arbitrary round
/// number: tiling.zig packs one bit per workspace into a u64 (`workspace_geom_valid_bits`)
/// and workspaces.zig's override tables are fixed-size arrays sized to match, so those
/// widen first. config.zig validates parsed workspace numbers against it.
pub const max_workspaces: usize = 64;

/// Maximum tiled windows per workspace (tiled_order capacity). Buffers sized from this
/// are usize/u16-indexed, so raising it only costs memory. `View.hintsFor` is an O(n)
/// scan over exactly this bound -- past ~64, swap it for an index-aligned lookup FIRST.
pub const max_tiled_windows: usize = 64;

/// Lower bound on the primary-column width ratio; config validation and the
/// runtime adjustment both clamp here.
pub const min_master_width: f32 = 0.05;

/// Primary-column width caps at 95% so the secondary column always keeps some screen.
/// Single-sourced: config validation, the runtime pixel->ratio conversion and the
/// primary-width adjustment all clamp here.
pub const max_master_width: f32 = 0.95;

/// Position and dimensions of a managed window, relative to the root window.
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

    /// Geometry only, ignoring `border_width`. The two comparators exist because geometry
    /// and border width ride different requests and sent-state, so comparing a whole `Rect`
    /// to decide "did the geometry move" makes a border-only change buy a spurious
    /// configure plus raise. Use `eql` for the full comparison.
    pub inline fn eqlGeom(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and self.width == other.width and
            self.height == other.height;
    }
};

/// Width/height without a position: the resize-while-parked request shape. A parked window
/// must be resized OFFSCREEN so its client re-renders before a workspace switch shows it,
/// i.e. WIDTH|HEIGHT without X/Y. `sink.Configure.size` is the wire shape.
pub const Dims = struct {
    width: u16,
    height: u16,
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap: u16 = 0,
    border: u16 = 0,
};

/// Twice the border width (the left+right / top+bottom inset).
pub inline fn doubledBorder(m: Margins) u16 {
    return 2 *| m.border;
}

/// Saturating i16 coordinate clamp: narrows an i32 into the i16 `Rect` range, clamping
/// instead of wrapping so one pathological value can't cross the whole screen in
/// ReleaseFast.
pub inline fn satI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// Centers a `w`x`h` box over `parent`, clamped inside `bounds` (the work area): the
/// dialog-over-parent placement ICCCM's WM_TRANSIENT_FOR asks for. The clamp wins over
/// centering; a box larger than `bounds` pins to the bounds origin.
pub fn centerRectIn(parent: Rect, w: u16, h: u16, bounds: Rect) Rect {
    const bx: i32 = bounds.x;
    const by: i32 = bounds.y;
    const cx: i32 = @as(i32, parent.x) + @divTrunc(@as(i32, parent.width) - @as(i32, w), 2);
    const cy: i32 = @as(i32, parent.y) + @divTrunc(@as(i32, parent.height) - @as(i32, h), 2);
    const max_x: i32 = bx + @as(i32, bounds.width) - @as(i32, w);
    const max_y: i32 = by + @as(i32, bounds.height) - @as(i32, h);
    const x: i32 = if (max_x <= bx) bx else std.math.clamp(cx, bx, max_x);
    const y: i32 = if (max_y <= by) by else std.math.clamp(cy, by, max_y);
    return .{ .x = satI16(x), .y = satI16(y), .width = w, .height = h, .border_width = 0 };
}

/// Reinterprets a signed X11 coordinate (i16 on the wire) as the u32 value
/// XCB's configure_window value array expects.
pub inline fn toXcbCoord(v: i16) u32 {
    return @bitCast(@as(i32, v));
}

/// Modulo-wraps `idx` by signed `dir` into [0, n); 0 for an empty range. The one
/// modulo-wrap in the tree (round-robin focus and layout cycles), so those callers name
/// it rather than reaching into a grab bag.
pub inline fn wrapIndex(idx: usize, dir: i32, n: usize) usize {
    if (n == 0) return 0;
    return @intCast(@mod(@as(i64, @intCast(idx)) + dir, @as(i64, @intCast(n))));
}

pub const Mask = u64;

/// Mask bit for workspace `ws`. Two preconditions, both tied to `max_workspaces` rather
/// than restating its number: the index must name a real workspace and must fit the u64
/// mask. A shift by >= bitSizeOf would silently yield a wrong mask, so raising
/// max_workspaces past 64 is a loud build failure instead of a corrupt membership mask.
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

/// Single canonical size-hints record AND the only store: admission threads the parsed
/// WM_NORMAL_HINTS to mapRequest as a parameter (no staging copy anywhere). Do NOT
/// import layouts from here (layer rule).
pub const SizeHints = struct {
    /// PMinSize / PBaseSize floor. TILING deliberately does not ENFORCE declared minimums
    /// -- the layout engine owns tiled dimensions; honouring them would pin the rect and
    /// block mod_h/mod_l resizing (`tiling.applyHints` is the tiled-side delegate). It only
    /// serves as the ICCCM increment-snap fallback base when PBaseSize is absent. Only the
    /// floating drag-resize honours it as a user-facing floor.
    min_width: u16 = 0,
    min_height: u16 = 0,
    max_width: u16 = 0, // PMaxSize limit
    max_height: u16 = 0,
    inc_width: u16 = 0, // PResizeInc: w = base_width + N * inc_width
    inc_height: u16 = 0,
    /// PBaseSize: snap origin for PResizeInc (ICCCM sizes are base + N*inc); 0 when
    /// undeclared, so the snap falls back to `min_width` (the standard's own fallback).
    /// NOT a floor: tiling stays shrink-only.
    base_width: u16 = 0,
    base_height: u16 = 0,
    min_aspect: f32 = 0.0, // PAspect (dwm convention)
    max_aspect: f32 = 0.0,

    /// True when every field is zero (no constraints declared).
    pub fn isEmpty(self: SizeHints) bool {
        return self.min_width == 0 and self.min_height == 0 and
            self.max_width == 0 and self.max_height == 0 and
            self.inc_width == 0 and self.inc_height == 0 and
            self.base_width == 0 and self.base_height == 0 and
            self.min_aspect == 0.0 and self.max_aspect == 0.0;
    }

    /// Shrink-only PAspect fit: reduces whichever dimension of `w` x `h` is excess so the
    /// result lands inside the declared aspect band, cross-multiplied
    /// (`1/min_aspect <= w/h <= max_aspect`). Never grows; in-band sizes pass through.
    ///
    /// BOTH OR NEITHER: the two bounds are the halves of ONE rule -- a max bound alone
    /// clamps the offending DIMENSION, so a 400x50 window under `max_aspect = 4` gets
    /// NARROWER instead of taller. One bound alone returns the size unchanged. Callers
    /// clamp into the PMin/PMax envelope first. A dimension rounding out floors to 1.
    pub fn aspectFit(self: SizeHints, w: u16, h: u16) struct { width: u16, height: u16 } {
        if (self.min_aspect <= 0.0 or self.max_aspect <= 0.0)
            return .{ .width = w, .height = h };
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        var out_w = w;
        var out_h = h;
        // Cross-multiplied to avoid a per-resize FP division pair. Clamp the product into
        // the u16 range before narrowing so a huge declared ratio caps instead of
        // trapping in ReleaseFast.
        if (fw > fh * self.max_aspect) {
            out_w = @min(roundAspectDim(fh * self.max_aspect), w);
        } else if (fh > fw * self.min_aspect) {
            out_h = @min(roundAspectDim(fw * self.min_aspect), h);
        }
        if (out_w == 0 and w > 0) out_w = 1;
        if (out_h == 0 and h > 0) out_h = 1;
        return .{ .width = out_w, .height = out_h };
    }
};

/// Round a non-negative aspect product to the nearest integer, saturating at
/// the u16 wire limit.
inline fn roundAspectDim(product: f32) u16 {
    if (!(product > 0.0)) return 0; // zero or NaN (defensive; ratios are > 0)
    const clamped = std.math.clamp(@round(product), 0.0, @as(f32, std.math.maxInt(u16)));
    return @intFromFloat(clamped);
}

/// Hard ceiling on distinct layouts in the cycle ring. Lives here because it bounds BOTH
/// the u8 `kind` registry index and the u8 `layout_idx` workspace override; config
/// enforces the cap at parse time (a 256th entry would trap the config-side `@intCast`).
pub const max_layouts = 256;

pub const LayoutParams = struct {
    /// Index into the build-generated `tiling_modules` registry (dispatch order ==
    /// deterministic scan order), resolved from config at seed time; the registry layer
    /// disambiguates out-of-range values. The model stays registry-free.
    kind: u8 = 0,
    variant_idx: u8 = 0,
    primary_width: f32 = 0.5,
    primary_count: u8 = 1,
    secondary_balance: f32 = 0,
    /// Viewport state: model-owned so the layout engine stays pure. The
    /// snap-right-on-new-window and clamp duties belong to callers (reconcile_tails/sync).
    viewport_offset: i32 = 0,
    viewport_prev_count: u32 = 0,
};

pub const BaseMode = union(enum) {
    /// Home workspace membership is DERIVED (exactly one `ws`.tiled_order list holds a
    /// tiled window; findHome). Visibility on other tagged workspaces is a sync-time mask
    /// filter (engine stays mask-agnostic).
    tiled,
    floating: Rect,
};

/// Open visibility pattern: `present` (visible/layoutable), `parked` (hidden by an
/// extension), `covering` (owns the screen on a workspace). Enumerates PATTERNS, not
/// features; parked/covering windows keep their `anchor`/`mask`.
pub const Presence = enum { present, parked, covering };

// Shared vocabulary types: consumed by wire-side feature plugins and wire
// callers alike, so they live in core and neither imports a feature file.

/// Restore-order over minimized windows: `.fifo` = oldest minimize seq,
/// `.lifo` = newest.
pub const RestoreOrder = enum { lifo, fifo };

/// Optional increment of a floating window's geometry honored on
/// configure-request; null fields leave the current value unchanged.
pub const ConfigureReq = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
};

/// Outcome of honoring a configure request against a floating window record.
pub const HonorDecision = enum { geometry_applied, border_only, ignored };

/// Bounded sorted-key collection re-exported from the pure shelf; the model's
/// window store and the reconcile ledger share it without naming `core`/wire.
pub const Store = bounded.Store;

/// Store and MRU capacities: 128 bounds the sorted-key store (stack-allocated), 16 keeps
/// the per-workspace focus MRU small; defined capacities mean state transitions never
/// allocate. tiling_contract's hintsFor scan is O(n) in max_tiled_windows, not this
/// store cap.
pub const store_capacity = 128;

/// Primary-column capacity: capped at a quarter of the managed-window ceiling so one
/// workspace can't statically claim the store. Config lets master_count reach its u8
/// ceiling, so config-driven stamps go through `capPrimaryCount`.
pub const max_primary_count = store_capacity / 4;

/// Clamps a configured primary count into [1, max_primary_count] -- the model's
/// primary-count invariant, and the one clamp config-driven seed stamps call. The
/// interactive `adjustPrimaryCount` clamps the same bounds inline instead: its delta runs
/// in i32 so a decrement below 1 cannot wrap a u8.
pub fn capPrimaryCount(count: u8) u8 {
    return std.math.clamp(count, 1, @as(u8, @intCast(max_primary_count)));
}
pub const mru_capacity = 16;
pub const max_tiled_per_ws = max_tiled_windows;

/// Index (workspace id) of the lowest set bit in `m`, or null for the zero
/// mask (`@ctz(0)` = 64, out of u64 range -- see `bit`).
pub fn lowestBit(m: Mask) ?WSId {
    if (m == 0) return null;
    return WSId.fromIndex(@ctz(m));
}

const OrderList = bounded.BoundedList(WindowId, max_tiled_per_ws);
const MruList = bounded.BoundedList(WindowId, mru_capacity);
const StoreT = Store(WindowId, Entry, store_capacity);

/// Per-window store row: the vocabulary records the model holds for every
/// managed window.
pub const Entry = struct {
    mask: Mask,
    anchor: BaseMode,
    size_hints: SizeHints = .{},
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

/// The workspace whose tiled_order holds win (single-membership invariant), or
/// null when no list holds it (floating, parked, or unmanaged). The lists ARE
/// the answer: there is deliberately no cached copy to drift from them. The
/// scan is at most max_workspaces x max_tiled_per_ws integer compares, run
/// only on user actions.
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    var found: ?WSId = null;
    for (0..m.ws.len) |i| {
        if (m.ws[i].tiled_order.indexOfScalar(win) == null) continue;
        // The scan only answers correctly under single membership: two lists
        // holding the window means the invariant broke upstream, and returning
        // one of them would hand a plausible-looking wrong answer. Trip loudly
        // in Debug (folded out of Release).
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
/// `presence` is `.present`, and every id listed on any workspace must still
/// exist in the store.
/// Floating and parked windows are home-free by design. Returns the violation
/// instead of panicking so a test can trip the exact logic
/// `debugCheckInvariants` asserts with.
pub const InvariantViolation = error{
    StrandedWindow,
    DuplicateMembership,
    OrphanedListEntry,
};

pub fn checkInvariants(m: *const Model) InvariantViolation!void {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.anchor != .tiled or it.val.presence != .present) continue;
        var homes: usize = 0;
        for (&m.ws) |*s| {
            if (s.tiled_order.indexOfScalar(it.key) != null) homes += 1;
        }
        if (homes == 0) return error.StrandedWindow;
        if (homes > 1) return error.DuplicateMembership;
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
    if (findHome(m, win)) |home| removeValue(&m.ws[home.index].tiled_order, win);
    e.anchor = .{ .floating = rect };
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
