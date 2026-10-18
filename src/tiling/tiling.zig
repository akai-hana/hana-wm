//! Dispatch engine for the tiling sub-system.
//! Reads model types and emits placements; no XCB and no allocation.

const std = @import("std");
const model = @import("model");
const log = std.log.scoped(.tiling);

const contract = @import("tiling_contract");

/// ICCCM section 4.1.2.3 size-hint application: increment snap, max-size
/// clamp, then aspect clamp (with a re-snap, since a client may declare both).
/// Declared minimums are intentionally NOT enforced as floors: tiling owns
/// window size (the policy lives on `model.SizeHints.min_width`). The minimum
/// still serves as the increment snap's base when the client declared no
/// PBaseSize, which is the standard's own fallback and anchors the grid
/// without pinning the rect.
pub fn applyHints(rect: model.Rect, h: model.SizeHints) model.Rect {
    if (h.isEmpty()) return rect;
    // Snap origin per axis: PBaseSize when declared, else the declared
    // minimum (ICCCM: valid sizes are base + N*inc, base defaults to min).
    const base_w: u16 = if (h.base_width > 0) h.base_width else h.min_width;
    const base_h: u16 = if (h.base_height > 0) h.base_height else h.min_height;

    var width = snapDimToIncrement(rect.width, base_w, h.inc_width);
    var height = snapDimToIncrement(rect.height, base_h, h.inc_height);

    if (h.max_width > 0) width = @min(width, h.max_width);
    if (h.max_height > 0) height = @min(height, h.max_height);

    // min_aspect = h/w upper bound, max_aspect = w/h upper bound (dwm
    // convention); the shrink-only band fit is the ONE shared spelling on
    // model.SizeHints (.aspectFit), which also carries the both-or-neither
    // rationale. Re-snap to the increments since the shared fit rounds
    // freely.
    const fit = h.aspectFit(width, height);
    width = snapDimToIncrement(fit.width, base_w, h.inc_width);
    height = snapDimToIncrement(fit.height, base_h, h.inc_height);

    // Centre the (possibly shrunk) window inside its allocated slot. A positive
    // slot must never resolve to 0: the aspect re-snap can round a dimension
    // out entirely, so floor both dims after every clamp/snap.
    if (width == 0 and rect.width > 0) width = 1;
    if (height == 0 and rect.height > 0) height = 1;
    // dx/dy top out at (65535 - 1) / 2 = 32767 (the dims floor at 1 above),
    // so the i16 narrowing cannot overflow. The adds saturate: rect.x/y come
    // in already satI16-clamped, and a saturated origin plus a large centre
    // offset would wrap in ReleaseFast under a plain `+`.
    const dx: i16 = @intCast((rect.width -| width) / 2);
    const dy: i16 = @intCast((rect.height -| height) / 2);
    return .{
        .x = rect.x +| dx,
        .y = rect.y +| dy,
        .width = width,
        .height = height,
    };
}

/// Snap `dim` down onto the ICCCM increment grid `base + N*inc`. A `dim` at
/// or below the base passes through (tiling is shrink-only; the snap never
/// grows a window up to the grid). With a zero base the sub-increment
/// leftover collapses to 1 instead of 0, so a positive slot never snaps to
/// a zero dimension.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const snapped = base + (dim - base) / inc * inc;
    return if (snapped == 0 and dim > 0) 1 else snapped;
}

// The layout interchange vocabulary lives on the tiling CONTRACT (tiling_contract.zig)
// so the always-compiled reconciler can name it even without this tiling engine;
// here we only re-export it so modules keep referring to `tiling.List` etc.
pub const View = contract.View;
pub const List = contract.List;
/// Working context for a layout module pass: the input view and output list,
/// with the env's outer margins and min-pane dimension copied in so modules
/// that need them don't re-read `v.env`.
pub const LayoutCtx = struct {
    v: *const View,
    out: *List,
    m: model.Margins,
    min_dim: u16,

    pub inline fn init(v: *const View, out: *List) LayoutCtx {
        return .{ .v = v, .out = out, .m = v.env.margins, .min_dim = v.env.min_dim };
    }
};

/// Prefer `v.focused` when it appears in `windows`, else `fallback`.
pub fn focusedElse(
    v: *const View,
    windows: []const model.WindowId,
    fallback: model.WindowId,
) model.WindowId {
    const f = v.focused orelse return fallback;
    if (std.mem.indexOfScalar(model.WindowId, windows, f) == null) return fallback;
    return f;
}

/// Pane-inset total: the outer gap on both sides plus both border widths,
/// saturating. The single source of the "2×gap + 2×border" shrink used by
/// master, monocle, and scroll.
pub inline fn totalInset(gap_amount: u16, m: model.Margins) u16 {
    return gap_amount *| 2 +| model.doubledBorder(m);
}

/// Interior-boundary half-gap: the seam between two adjacent panes carries
/// half a gap per side (floored) so neighboring windows together share one
/// full gap — one pixel less when the gap is odd, the unavoidable cost of
/// the two integer halves. Master/scroll interior seams are spelled through
/// this; the recursive splits (leaf, fibonacci) keep the FULL gap at their
/// seam via `bisectRegion`, so the two seam styles differ by at most that
/// pixel on an odd gap.
pub inline fn seamGap(m: model.Margins) u16 {
    return m.gap / 2;
}

/// Shrinks `dim` by `margin` (gap/border), floored to `min_dim` so a layout
/// never hands a client a zero or negative size.
pub inline fn shrinkClamped(dim: u16, margin: u16, min_dim: u16) u16 {
    return if (dim > margin) dim - margin else min_dim;
}

/// `shrinkClamped` capped at the space left after the margin, then floored
/// at 1: the min_dim floor alone can flare a window past its own cell/strip
/// in a congested layout (overlapping neighbours), and the emission needs at
/// least one pixel -- so a cell that cannot hold its margins collapses to
/// 1px instead. Callers that must NOT collapse this way gate the emission
/// on `insetFits` first. The single spelling of the `@max(dim -| margin, 1)`
/// idiom (note there is no min_dim here: under the cap it had no effect --
/// the `dim <= margin` branch always collapsed to 1 regardless).
pub inline fn shrinkCapped(dim: u16, margin: u16) u16 {
    return @max(dim -| margin, 1);
}

/// Full-rect inset by `margin` (shrinkClamped width/height at fixed origin).
pub inline fn insetRect(x: i32, y: i32, w: u16, h: u16, margin: u16, min_dim: u16) model.Rect {
    return .{
        .x = model.satI16(x),
        .y = model.satI16(y),
        .width = shrinkClamped(w, margin, min_dim),
        .height = shrinkClamped(h, margin, min_dim),
    };
}

/// Can a region of `w x h` host an inset-by-`margin` placement at a positive
/// size? Exactly the condition under which `insetRect`'s min_dim floor stays
/// inside the region: `shrinkClamped` only takes the floor branch when
/// `dim <= margin`, and a floor-sized rect at the region origin is then free
/// to flare past the workarea edge (a 0x0 workarea would show a min_dim
/// rectangle off-screen). Every `insetRect` emission site parks the window
/// instead of emitting when this is false -- the one spelling of the
/// degenerate-region guard.
pub inline fn insetFits(w: u16, h: u16, margin: u16) bool {
    return w > margin and h > margin;
}

/// A two-dimensional screen region in tiling coordinates (x/y are i32, w/h
/// u16). The shared shape for outerArea and the layout modules' recursion.
pub const Region = struct {
    x: i32,
    y: i32,
    w: u16,
    h: u16,
};

/// Work-area rect inset by the outer gap; x/y are i32, w/h u16
/// (threaded through some layouts' recursion).
pub inline fn outerArea(wa: model.Rect, gap: u16) Region {
    return .{
        // Both edges take the work area's own origin plus the gap, not the gap
        // alone: without the origin, a work area that does not start at x=0 (a
        // side claim) would be silently placed back at the screen's left edge.
        // The origins take the shared non-negative floors (waX for x, waY for
        // y); the sizes take the matching shrink (waWidth / waHeight) so a
        // floored origin cannot push the far edge past the workarea.
        .x = waX(wa) +| @as(i32, gap),
        .y = waY(wa) +| @as(i32, gap),
        .w = waWidth(wa) -| gap *| 2,
        .h = waHeight(wa) -| gap *| 2,
    };
}

/// Split `dim` into two halves separated by `gap` at the seam. Division and
/// subtraction are saturating (so a `gap` larger than `dim` yields two zero
/// halves rather than underflowing); callers guard `gap <= dim` (leaf via its
/// min-dim check) so the pair really does fit the parent region. Shared by
/// leaf (BSP) and fibonacci (spiral).
pub inline fn bisectRegion(dim: u16, gap: u16) struct { first: u16, second: u16 } {
    const first = (dim -| gap) / 2;
    const second = dim -| (first +| gap);
    return .{ .first = first, .second = second };
}

/// Work-area origin y clamped to >= 0, as i32 — the y twin of `waX` (same
/// shape: Rect in, non-negative i32 out). Layout modules take every y origin
/// through it, so a negative-origin workarea (latent; one sign flip of a
/// future claim bug must not produce negative-y placements) can never place
/// a window off the screen's top edge. The result is also always in u16
/// range (wa.y is i16), so u16-layout callers can narrow it unchecked.
pub inline fn waY(wa: model.Rect) i32 {
    return @max(0, wa.y);
}

/// Work-area origin x clamped to >= 0, as i32 — the one home for the x
/// floor. outerArea's inset and every layout module's origin offset take it,
/// so a negative-origin workarea (latent; one sign flip of a future claim
/// bug must not produce negative-x placements) can never place a window off
/// the screen's left edge. The y floor is `waY`.
pub inline fn waX(wa: model.Rect) i32 {
    return @max(0, wa.x);
}

/// Workarea width after the x-origin floor (`waX`): a negative wa.x is
/// floored to 0 for placement, so the width shrinks by the same amount or
/// every right edge overshoots the workarea by |wa.x|. Horizontal twin of
/// `waHeight`.
pub inline fn waWidth(wa: model.Rect) u16 {
    return wa.width -| @as(u16, @intCast(@max(0, -@as(i32, wa.x))));
}

/// Workarea height after the y-origin floor (`waY`): the
/// vertical twin of `waWidth`. Layouts that size panes from the workarea
/// dimensions MUST take them through this (or outerArea) -- sizing from the
/// raw height while placing at the floored origin flares the bottom edge
/// past the workarea by |wa.y|.
pub inline fn waHeight(wa: model.Rect) u16 {
    return wa.height -| @as(u16, @intCast(@max(0, -@as(i32, wa.y))));
}

/// Position of cell `i` along an axis of `cell`-sized cells separated by
/// `gap`. Shared by grid and master (the `i *| (cell +| gap)` stride).
pub inline fn cellStride(cell: u16, gap: u16, i: u16) u16 {
    return i *| (cell +| gap);
}

/// Append one placement. An already-full list drops the new placement
/// (BoundedList latches one overflow warning per list type, so the drop is
/// reported once, not silent); the engine's emission is one append per
/// window in `v.order`, which a store-capacity list always has room for, so
/// the drop is a backstop against a future capacity contract change rather
/// than a control-flow path.
inline fn appendPlacement(out: *List, win: model.WindowId, rect: model.Rect, visible: bool) void {
    _ = out.append(.{ .win = win, .rect = rect, .visible = visible });
}

/// Emit a visible placement with the window's size hints applied to `rect`.
pub inline fn emitView(v: *const View, out: *List, win: model.WindowId, rect: model.Rect) void {
    appendPlacement(out, win, applyHints(rect, v.hintsFor(win)), true);
}

/// Emit a visible placement built from integer tiling coordinates, narrowing
/// x/y through model.satI16. The shared row-emission shape used by the layout
/// modules.
pub inline fn emitRect(v: *const View, out: *List, win: model.WindowId, x: i32, y: i32, w: u16, h: u16) void {
    emitView(v, out, win, .{
        .x = model.satI16(x),
        .y = model.satI16(y),
        .width = w,
        .height = h,
    });
}

/// Emit a parked placement (the parked position sync applies via Sink.park).
pub inline fn emitHidden(out: *List, win: model.WindowId) void {
    appendPlacement(out, win, contract.parked_rect, false);
}

/// Region too small to subdivide (overflow share): place the focused window —
/// falling back to the list head — on-screen inset by the doubled border, park
/// every other window in `windows`. Shared by fibonacci and leaf, whose
/// "region can't fit two children" fallbacks both reduce to this shape.
pub inline fn emitOverflowShare(ctx: LayoutCtx, windows: []const model.WindowId, r: Region) void {
    // windows[0] is evaluated eagerly as focusedElse's fallback, so an empty
    // slice would trap before the "region can't fit two children" case this
    // exists to handle could even be reached.
    if (windows.len == 0) return;
    const top = focusedElse(ctx.v, windows, windows[0]);
    const margin = model.doubledBorder(ctx.m);
    if (insetFits(r.w, r.h, margin)) {
        emitView(ctx.v, ctx.out, top, insetRect(r.x, r.y, r.w, r.h, margin, ctx.min_dim));
    } else {
        // Region cannot hold even one pixel after the border: the min_dim
        // floor would flare off the workarea, and a parked placement is the
        // honest rendering of a place that cannot be shown.
        emitHidden(ctx.out, top);
    }
    // The "show one, hide the rest" fan-out. It appends unconditionally, which
    // the monocle shape cannot use: monocle must land emitView for its top
    // window at that window's own position in v.order.
    for (windows) |w| {
        if (w != top) emitHidden(ctx.out, w);
    }
}

/// Dispatch registry (build-generated, alphabetical stems). The active layout
/// is a `u8` index into this table; the engine never owns a closed enum.
/// Imported via contract's guarded re-export (the single `has_tiling`
/// conditional-import definition).
const tiling_mods = contract.tiling_mods;

comptime {
    // The kind is a u8 index and the config list is capped at
    // model.max_layouts, so a registry past either bound would truncate the
    // kind or overrun the config list at runtime. Both are asserted, not
    // just the u8 one: the u8 bound only implies the config cap while
    // max_layouts stays >= 256, and a bare assert would report as a panic
    // with no registry context.
    if (tiling_mods.len > std.math.maxInt(u8))
        @compileError("tiling registry exceeds the u8 kind index (max 255 layouts)");
    if (tiling_mods.len > model.max_layouts)
        @compileError("tiling registry exceeds model.max_layouts");
}

/// Resolve a config layout name to its registry index (case-insensitive match
/// on module names), or null when unregistered.
/// Returns the registry index as the `u8` kind it will actually be stored as,
/// not a `usize` the caller has to cast. The kind IS a u8, so returning usize
/// would hand every caller a truncation footgun.
pub fn layoutByName(name: []const u8) ?u8 {
    for (tiling_mods, 0..) |m, i| if (std.ascii.eqlIgnoreCase(name, m.name)) return @intCast(i);
    return null;
}

/// Resolve a config layout name to a registry index, collapsing to `fallback`
/// when the name does not resolve. Loud, never silent: an unresolvable/removed
/// layout name is a config bug, and every seeding/reload site resolves config
/// names through this one function. The fallback is the caller's choice: the
/// neutral default (index 0) or a caller-chosen seed kind.
pub fn layoutKindFallingBack(name: []const u8, fallback: u8) u8 {
    if (layoutByName(name)) |k| return k;
    // The fallback is the caller's choice (the neutral default or a
    // caller-chosen seed kind); an out-of-range one would warn about "" and
    // hand every degraded workspace a kind that resolves to nothing, so it
    // is a caller bug, pinned here. The empty-registry (no-tiling) build is
    // exempt: there is no kind that resolves there.
    std.debug.assert(contract.tiling_mods.len == 0 or contract.moduleOf(fallback) != null);
    log.warn(
        "Config: layout name '{s}' did not resolve to a registered layout; " ++
            "using layout '{s}'",
        .{ name, moduleName(fallback) },
    );
    return fallback;
}

/// The registry module name for `kind` ("" when out of range).
pub fn moduleName(kind: u8) []const u8 {
    if (contract.moduleOf(kind)) |m| return m.name;
    return "";
}

/// Variant count for `kind` (cycle_variant actions/mod bar). Registry-driven.
pub fn variantCount(kind: u8) u8 {
    if (contract.moduleOf(kind)) |m| return m.variant_count;
    return 1;
}

/// Step a layout within the config layout-name list (config order is the
/// cycle order). Each name resolves to a registry index (unresolvable names
/// are skipped); `cur`'s position steps by `dir` and wraps modulo the list.
/// When `cur` is not in the list (safety net — defaults/overrides always come
/// from config names) it lands on the first/last edge by direction.
pub fn cycleKind(cur: u8, dir: i32, names: []const []const u8) u8 {
    // Names list is the config layout-name list (fits model.max_layouts);
    // a larger registry-resolved set would spill here. The `n < indices.len`
    // clamp below is unreachable under that config cap — kept as a hard bound
    // so a larger future source can't overflow the stack array.
    var indices: [model.max_layouts]u8 = undefined;
    var n: usize = 0;
    for (names) |nm| if (layoutByName(nm)) |idx| {
        // A repeated name (the config parse de-duplicates, but a duplicate
        // from any other source) would otherwise make the value-equality
        // search below bounce between the two rows and never reach the rest
        // of the ring — skip it so every DISTINCT layout stays reachable.
        var seen = false;
        for (indices[0..n]) |prev| {
            if (prev == idx) seen = true;
        }
        if (seen) continue;
        if (n < indices.len) {
            indices[n] = idx;
            n += 1;
        }
    };
    if (n == 0) return cur;
    for (indices[0..n], 0..) |idx, i| if (idx == cur) {
        return indices[model.wrapIndex(i, dir, n)];
    };
    return indices[if (dir >= 0) 0 else n - 1];
}

/// Compute `kind`'s layout into `out` (cleared first). Each layout module
/// binds its `compute` hook to the module's placement function and must
/// append exactly one placement per window in `v.order` (off-viewport/hidden
/// windows are parked via emitHidden).
///
/// Contract: `v.order` is non-empty and canonical. The engine always invokes
/// compute with the FULL ordered window set of the workspace (`n > 0` guard
/// in reconcile); a layout module may rely on seeing the whole set at once
/// and must not assume a sliced subset — module counters/boosts that mirror
/// per-window state (e.g. pending-count) depend on this. The empty-check in
/// the engine below is a div-by-zero guard first (grid's paneCell divides by
/// `count`), reconciles the contract for direct/test callers, and is not a
/// slicing seam.
pub fn compute(kind: u8, v: *const View, out: *List) void {
    out.clear();
    if (v.order.len == 0) return;
    // An unregistered kind (a restored `kind` whose registry entry is gone,
    // or a corrupted index) cannot dispatch. Emitting nothing would break
    // the one-placement-per-window contract the sink consumes positionally
    // against a per-slot table already built from `order` — so fall back to
    // the neutral layout instead. The empty registry (no-tiling build) has
    // no kind to fall back to and stays empty; reconcile gates the call on a
    // resolved kind there.
    const m = contract.moduleOf(kind) orelse blk: {
        if (contract.tiling_mods.len == 0) return;
        std.debug.assert(contract.moduleOf(contract.default_kind) != null);
        break :blk contract.moduleOf(contract.default_kind) orelse return;
    };
    // layoutModule assigns `compute` unconditionally, so null can only come
    // from a misbuilt registry entry — panic loudly instead of silently
    // parking the whole workspace.
    const f = m.compute.?;
    {
        // The layout writes into SCRATCH and the engine emits into `out` in
        // `v.order` position. The order is a property of the SINK
        // (it consumes `out` positionally against a per-slot table built from
        // `order`), not something each layout can be trusted to reproduce: a
        // column-major traversal that emitted `100 101 110 102..109` where the
        // order said `100 101 102..110` hands each window another window's
        // rect -- a real screen bug that no golden test can see, because every
        // golden looks at windows it knows by name rather than at the position.
        // Making it an engine invariant means a future layout cannot
        // reintroduce it by choosing a tidier traversal than a row-major one.
        var scratch: List = .{};
        f(v, &scratch);
        // The module-side half of the contract: one placement per window.
        // emitInOrder REPAIRS a reordering but cannot invent a window a
        // module dropped or split one it emitted twice, so those violations
        // are caught HERE (debug builds; the raw-hook coverage check in the
        // invariant sweep carries the same property into ReleaseFast test
        // runs) instead of surfacing as a silently parked window.
        std.debug.assert(scratchCoversOrder(v, &scratch));
        emitInOrder(v, &scratch, out);
    }
    // One placement per window, in View.order order — emitInOrder's
    // guarantee, pinned here as the cheap invariant on the engine's own
    // reordering pass (a failure below is a bug in emitInOrder, not in a
    // layout module). Length first, then ids: a length-equal but reordered
    // `out` is the same wrong-screen outcome the repair exists to prevent.
    // std.debug.assert: no release cost.
    std.debug.assert(out.len == v.order.len);
    for (out.constSlice(), v.order) |p, win| std.debug.assert(p.win == win);
}

/// Whether `scratch` holds exactly one placement per window of `v.order`
/// (count and set; order is emitInOrder's business to repair). O(n^2), but
/// only ever called under a debug assert.
fn scratchCoversOrder(v: *const View, scratch: *const List) bool {
    const ps = scratch.constSlice();
    if (ps.len != v.order.len) return false;
    for (v.order) |win| {
        var seen: usize = 0;
        for (ps) |p| {
            if (p.win == win) seen += 1;
        }
        if (seen != 1) return false;
    }
    return true;
}

/// Re-emit `scratch` into `out` in `v.order` position.
///
/// Fast path: the layout already emitted in order (five of the six do), so
/// this is one comparison pass plus a copy and no searching. Otherwise each
/// order position takes the placement whose window it names, and `taken` keeps
/// a duplicate from satisfying two positions -- without it, a layout that
/// emitted window 5 twice and dropped window 4 would silently hand window 5's
/// single rect to both positions, which is the same wrong-screen outcome the
/// reordering exists to prevent, wearing a passing length check.
fn emitInOrder(v: *const View, scratch: *const List, out: *List) void {
    const order = v.order;
    const ps = scratch.constSlice();
    if (ps.len == order.len) {
        var already = true;
        for (ps, order) |p, win| {
            if (p.win != win) {
                already = false;
                break;
            }
        }
        if (already) {
            for (ps) |p| _ = out.append(p);
            return;
        }
    }

    var taken: [model.store_capacity]bool = @splat(false);
    for (order) |win| {
        var found = false;
        for (ps, 0..) |p, k| {
            if (taken[k] or p.win != win) continue;
            taken[k] = true;
            _ = out.append(p);
            found = true;
            break;
        }
        // No match for this position: emit a placeholder so the placement
        // COUNT still matches and the sink's positional indexing never runs
        // off the end of `out`. A window can only be missing here when a
        // module violated the one-placement-per-window contract (dropped or
        // doubled it) — caught by the scratch coverage assert in debug
        // builds; the placeholder is what keeps the release build's screen
        // merely degraded (one parked window) instead of misindexed.
        if (!found) _ = out.append(.{ .win = win, .rect = contract.parked_rect, .visible = false });
    }
}

/// Parses a layout variant VALUE-STRING into its ordinal slot: the index of
/// the first exact-case match in `names`, or null when unmatched. Shared by
/// every layout module that exposes named variants.
fn variantParse(comptime variants: []const Variant) fn ([]const u8) ?u8 {
    return struct {
        fn parse(str: []const u8) ?u8 {
            // Reads the name column off the table itself: names[i] is defined
            // as variants[i].name, so no separate names array has to be kept in
            // sync with the variant rows; an empty table falls through to null.
            for (variants, 0..) |v, i| {
                if (std.mem.eql(u8, str, v.name)) return @intCast(i);
            }
            return null;
        }
    }.parse;
}

/// One row of a layout module's variant table: the config value-string, the
/// bar indicator glyph drawn for it, and whether it is the fifo-spawn variant.
pub const Variant = struct {
    /// Value-string parsed out of the config file.
    name: []const u8,
    /// Bar indicator for this variant (the layouts segment draws it).
    indicator: []const u8,
    /// True for the one variant that toggles fifo spawn order.
    fifo: bool = false,
};

/// The indicator column of a variant table, as `Layout.indicators`.
fn variantIndicators(comptime variants: []const Variant) []const []const u8 {
    const arr: [variants.len][]const u8 = blk: {
        var a: [variants.len][]const u8 = undefined;
        for (variants, 0..) |v, i| a[i] = v.indicator;
        break :blk a;
    };
    return &arr;
}

/// The ordinal of the `fifo` variant, or null when the table marks none.
fn variantFifo(comptime variants: []const Variant) ?u8 {
    // No len == 0 guard: iterating an empty slice falls through to the same
    // return null below it.
    for (variants, 0..) |v, i| {
        if (v.fifo) return @intCast(i);
    }
    return null;
}

/// Ordinal of the named variant in a module's OWN table, at comptime. A
/// hand-numbered constant drifts when a row is inserted or reordered and
/// nothing reports the shift -- the layout then computes the other variant's
/// geometry under a test that still passes; a name lookup cannot drift, and a
/// missing name is a compile error.
pub fn variantIndex(comptime variants: []const Variant, comptime vname: []const u8) u8 {
    for (variants, 0..) |v, i| {
        if (comptime std.mem.eql(u8, v.name, vname)) return @intCast(i);
    }
    @compileError("no variant named '" ++ vname ++ "' in this module's variant table");
}

/// Assemble a layout module's registry entry: `name`/`icon` are the display
/// stems, `f` the compute hook, `variants` the ONE table the variant metadata
/// is derived from, and `extra` the remaining `contract.Layout` fields
/// (property hints). Build-generated registry.
///
/// The variant-derived contract fields (`variant_count`, `variant_parse`,
/// `indicators`, `fifo_variant`) are NOT settable through `extra` and are
/// computed from `variants` here. As four hand-maintained parallel lists per
/// module they would agree only by accident: adding a variant row while
/// forgetting `fifo_variant` leaves a layout whose cycle advertises a variant
/// that the bar renders as the empty-indicator sentinel. One table makes
/// `indicators.len == variant_count` by construction.
pub fn layoutModule(
    comptime name: []const u8,
    comptime icon: []const u8,
    comptime f: anytype,
    comptime variants: []const Variant,
    comptime extra: contract.Layout,
) contract.Layout {
    comptime {
        // One table, checked: a duplicated value-string would shadow its twin
        // in variantParse/variantIndex (first match wins), and a second fifo
        // row would be unreachable through fifo_variant — both silent
        // mis-parses of a hand-edited table. The count itself must fit the
        // u8 `variant_count`/`variant_idx` fields.
        if (variants.len > std.math.maxInt(u8))
            @compileError("layout '" ++ name ++ "' has more than 255 variants");
        for (variants, 0..) |a, i| {
            for (variants[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.name, b.name))
                    @compileError("layout '" ++ name ++ "' has duplicate variant name '" ++ a.name ++ "'");
                if (a.fifo and b.fifo)
                    @compileError("layout '" ++ name ++ "' marks more than one fifo variant");
            }
        }
    }
    var m = extra;
    m.name = name;
    m.icon = icon;
    m.compute = f;
    m.variant_count = @intCast(variants.len);
    m.fifo_variant = variantFifo(variants);
    m.variant_parse = if (variants.len == 0) null else variantParse(variants);
    m.indicators = if (variants.len == 0) null else variantIndicators(variants);
    // The four derived fields are assigned AFTER `extra` is copied in, so a
    // stale value in an `extra` literal is overwritten rather than honored --
    // the table is the single source, which is the whole point.
    return m;
}

// Tiling-order transitions: the tiling engine owns layout-order mutations on
// the model. Core/window call sites reach these through the build-generated
// `tiling_seam` (which provides has_tiling-gated stubs), never by naming this
// module.

/// Moves `win` within `list` from `from` to `to`. Shared by reorderTiled and
/// stepTiled (who already resolved both indices) to keep the single mutation
/// in one place.
fn moveTiled(list: anytype, win: model.WindowId, from: usize, to: usize) void {
    list.orderedRemove(from);
    _ = list.insert(to, win); // cannot fail: removal freed a slot
}

/// Moves `win` to index `idx_in` within its home workspace's tiled order
/// (clamped to the last slot). Unknown windows are no-ops.
pub fn reorderTiled(m: *model.Model, win: model.WindowId, idx_in: usize) void {
    const h = model.findHome(m, win) orelse return;
    const list = &m.ws[h.index].tiled_order;
    const from = list.indexOfScalar(win) orelse return;
    moveTiled(list, win, from, @min(idx_in, list.len - 1));
}

/// Moves `win` one slot in `dir` within its home workspace's tiled order,
/// wrapping around either edge (dwm-style stack rotate, mirroring the focus
/// cycle's modulo wrap). Unknown windows and lone tiled windows are no-ops.
pub fn stepTiled(m: *model.Model, win: model.WindowId, dir: i32) void {
    const h = model.findHome(m, win) orelse return;
    const list = &m.ws[h.index].tiled_order;
    const len = list.len;
    if (len < 2) return;
    const from = list.indexOfScalar(win) orelse return;
    moveTiled(list, win, from, model.wrapIndex(from, dir, len));
}

/// Slot swap: exchanges the first two tiled slots of the current workspace
/// (primary head and the following slot). No-op with fewer than two tiled
/// windows. Test seam: the actions layer transitions run
/// `swapFocusedWithPrevious`; production never calls this.
pub fn swapPrimary(m: *model.Model) void {
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
pub fn swapFocusedWithPrevious(m: *model.Model) void {
    const focused = m.focused orelse return;
    const ws = &m.ws[m.current.index];
    const list = &ws.tiled_order;
    const mru = ws.focus_mru.constSlice();
    if (list.len < 2 or mru.len < 2) return;
    // MRU[0] is maintained as the focused window (focus.setFocus front-
    // inserts). If the two ever diverge, mru[1] is NOT "the previously
    // focused window" and swapping with it would move an unrelated slot.
    if (mru[0] != focused) return;
    const prev = mru[1];
    if (prev == focused) return;
    const i = list.indexOfScalar(focused) orelse return;
    const j = list.indexOfScalar(prev) orelse return;
    list.items[i] = prev;
    list.items[j] = focused;
}

/// Steps the current workspace's primary-column width fraction by `delta`,
/// clamped to the shared master-width bounds.
pub fn adjustPrimaryWidth(m: *model.Model, delta: f32) void {
    const p = &m.ws[m.current.index].params;
    p.primary_width = std.math.clamp(
        p.primary_width + delta,
        model.min_master_width,
        model.max_master_width,
    );
}
