//! Dispatch engine for the tiling sub-system.
//! Reads model types and emits placements; no XCB and no allocation.

const std = @import("std");
const model = @import("model");
const log = std.log.scoped(.tiling);

const contract = @import("tiling_contract");

/// ICCCM 4.1.2.3 size-hint application: increment snap, max-size clamp, then aspect
/// clamp (with a re-snap, since a client may declare both). Declared minimums are
/// intentionally NOT enforced as floors: tiling owns window size (policy on
/// `model.SizeHints.min_width`); the minimum only serves as the increment-snap base
/// when no PBaseSize was declared — the standard's own fallback, which anchors the
/// grid without pinning the rect.
pub fn applyHints(rect: model.Rect, h: model.SizeHints) model.Rect {
    if (h.isEmpty()) return rect;
    // Snap origin per axis: PBaseSize when declared, else the minimum (ICCCM: valid
    // sizes are base + N*inc, base defaults to min).
    const base_w: u16 = if (h.base_width > 0) h.base_width else h.min_width;
    const base_h: u16 = if (h.base_height > 0) h.base_height else h.min_height;

    var width = snapDimToIncrement(rect.width, base_w, h.inc_width);
    var height = snapDimToIncrement(rect.height, base_h, h.inc_height);

    if (h.max_width > 0) width = @min(width, h.max_width);
    if (h.max_height > 0) height = @min(height, h.max_height);

    // min_aspect = h/w upper bound, max_aspect = w/h upper bound (dwm convention); the
    // shrink-only band fit is the ONE shared spelling on model.SizeHints (.aspectFit).
    // Re-snap to the increments since the fit rounds freely.
    const fit = h.aspectFit(width, height);
    width = snapDimToIncrement(fit.width, base_w, h.inc_width);
    height = snapDimToIncrement(fit.height, base_h, h.inc_height);

    // Centre in the slot. A positive slot must never resolve to 0: the aspect re-snap
    // can round a dimension out entirely, so floor both dims after every clamp/snap.
    if (width == 0 and rect.width > 0) width = 1;
    if (height == 0 and rect.height > 0) height = 1;
    // dx/dy top out at (65535-1)/2 = 32767 (dims floor at 1 above), so the i16
    // narrowing cannot overflow. The adds saturate: rect.x/y arrive satI16-clamped,
    // and a saturated origin plus a large centre offset would wrap in ReleaseFast.
    const dx: i16 = @intCast((rect.width -| width) / 2);
    const dy: i16 = @intCast((rect.height -| height) / 2);
    return .{
        .x = rect.x +| dx,
        .y = rect.y +| dy,
        .width = width,
        .height = height,
    };
}

/// Snap `dim` down onto the ICCCM increment grid `base + N*inc`. A `dim` at or below
/// the base passes through (tiling is shrink-only). With a zero base the
/// sub-increment leftover collapses to 1, so a positive slot never snaps to zero.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const snapped = base + (dim - base) / inc * inc;
    return if (snapped == 0 and dim > 0) 1 else snapped;
}

// The interchange vocabulary lives on the tiling CONTRACT so the always-compiled
// reconciler can name it without this engine; re-exported here so modules keep
// referring to `tiling.List` etc.
pub const View = contract.View;
pub const List = contract.List;
/// Working context for a layout module pass: input view + output list, with the env's
/// outer margins and min-pane dimension copied in so modules don't re-read `v.env`.
pub const LayoutCtx = struct {
    v: *const View,
    out: *List,
    m: model.Margins,
    min_dim: u16,

    pub inline fn init(v: *const View, out: *List) LayoutCtx {
        return .{ .v = v, .out = out, .m = v.env.margins, .min_dim = v.env.min_dim };
    }
};

pub fn focusedElse(
    v: *const View,
    windows: []const model.WindowId,
    fallback: model.WindowId,
) model.WindowId {
    const f = v.focused orelse return fallback;
    if (std.mem.indexOfScalar(model.WindowId, windows, f) == null) return fallback;
    return f;
}

/// Pane-inset total: outer gap on both sides plus both border widths, saturating.
/// The single source of the "2×gap + 2×border" shrink.
pub inline fn totalInset(gap_amount: u16, m: model.Margins) u16 {
    return gap_amount *| 2 +| model.doubledBorder(m);
}

/// Interior-boundary half-gap: an adjacent-pane seam carries half a gap per side
/// (floored) so neighbors share one full gap — a pixel less when the gap is odd.
/// Master/scroll use this; the recursive splits (leaf, fibonacci) keep the FULL gap
/// via `bisectRegion`, so the two styles differ by at most that pixel.
pub inline fn seamGap(m: model.Margins) u16 {
    return m.gap / 2;
}

/// Shrinks `dim` by `margin` (gap/border), floored to `min_dim` so a layout
/// never hands a client a zero or negative size.
pub inline fn shrinkClamped(dim: u16, margin: u16, min_dim: u16) u16 {
    return if (dim > margin) dim - margin else min_dim;
}

/// `shrinkClamped` capped at the space left after the margin, floored at 1. The
/// min_dim floor alone can flare a window past its own cell in a congested layout, and
/// an emission needs at least one pixel -- so a cell that cannot hold its margins
/// collapses to 1px instead; callers that must NOT collapse that way gate on
/// `insetFits` first. The one spelling of `@max(dim -| margin, 1)`.
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

/// Can a region of `w x h` host an inset-by-`margin` placement at a positive size?
/// Exactly the condition under which `insetRect`'s min_dim floor stays inside the
/// region: `shrinkClamped` only takes the floor branch when `dim <= margin`, and a
/// floor-sized rect at the region origin is then free to flare past the workarea edge.
/// Every `insetRect` site parks instead of emitting when false -- the one
/// degenerate-region guard.
pub inline fn insetFits(w: u16, h: u16, margin: u16) bool {
    return w > margin and h > margin;
}

/// A two-dimensional screen region in tiling coordinates (x/y i32, w/h u16);
/// the shared shape for outerArea and the layout modules' recursion.
pub const Region = struct {
    x: i32,
    y: i32,
    w: u16,
    h: u16,
};

/// Work-area rect inset by the outer gap; x/y i32, w/h u16 (threaded through
/// some layouts' recursion).
pub inline fn outerArea(wa: model.Rect, gap: u16) Region {
    return .{
        // Both edges take the work area's own origin plus the gap, not the gap alone:
        // without the origin, a work area not starting at x=0 (a side claim) would be
        // silently placed back at the screen's left edge. Origins take the non-negative
        // floors (waX/waY); sizes the matching shrink (waWidth/waHeight) so a floored
        // origin cannot push the far edge past the workarea.
        .x = waX(wa) +| @as(i32, gap),
        .y = waY(wa) +| @as(i32, gap),
        .w = waWidth(wa) -| gap *| 2,
        .h = waHeight(wa) -| gap *| 2,
    };
}

/// Split `dim` into two halves separated by `gap` at the seam. Division and
/// subtraction are saturating (a `gap` larger than `dim` yields two zero halves
/// rather than underflowing); callers guard `gap <= dim` so the pair really fits
/// the parent. Shared by leaf and fibonacci.
pub inline fn bisectRegion(dim: u16, gap: u16) struct { first: u16, second: u16 } {
    const first = (dim -| gap) / 2;
    const second = dim -| (first +| gap);
    return .{ .first = first, .second = second };
}

/// Work-area origin y clamped to >= 0, as i32 — the y twin of `waX`. Layout modules
/// take every y origin through it, so a negative-origin workarea (latent; one sign
/// flip of a future claim bug must not produce negative-y placements) can never place
/// a window off the top edge. Always u16-range (wa.y is i16).
pub inline fn waY(wa: model.Rect) i32 {
    return @max(0, wa.y);
}

/// Work-area origin x clamped to >= 0, as i32 — the one home for the x floor.
/// outerArea's inset and every layout module's origin offset take it, so a
/// negative-origin workarea can never place a window off the left edge (same latent
/// hazard as `waY`).
pub inline fn waX(wa: model.Rect) i32 {
    return @max(0, wa.x);
}

/// Workarea width after the x-origin floor (`waX`): a negative wa.x is floored to 0
/// for placement, so the width shrinks by the same amount or every right edge
/// overshoots by |wa.x|. Twin of `waHeight`.
pub inline fn waWidth(wa: model.Rect) u16 {
    return wa.width -| @as(u16, @intCast(@max(0, -@as(i32, wa.x))));
}

/// Workarea height after the y-origin floor (`waY`); twin of `waWidth`. Layouts that
/// size panes from workarea dimensions MUST take them through this (or outerArea) --
/// sizing from the raw height while placing at the floored origin flares the bottom
/// edge past the workarea by |wa.y|.
pub inline fn waHeight(wa: model.Rect) u16 {
    return wa.height -| @as(u16, @intCast(@max(0, -@as(i32, wa.y))));
}

/// Position of cell `i` along an axis of `cell`-sized cells separated by `gap`.
/// Shared by grid and master (the `i *| (cell +| gap)` stride).
pub inline fn cellStride(cell: u16, gap: u16, i: u16) u16 {
    return i *| (cell +| gap);
}

/// Append one placement. An already-full list drops the new one (BoundedList latches
/// one overflow warning per list type, so the drop is reported once, not silent); the
/// engine emits one append per window in `v.order`, which a store-capacity list always
/// has room for -- the drop is a backstop against a future capacity contract change,
/// not a control-flow path.
inline fn appendPlacement(out: *List, win: model.WindowId, rect: model.Rect, visible: bool) void {
    _ = out.append(.{ .win = win, .rect = rect, .visible = visible });
}

/// Emit a visible placement with the window's size hints applied to `rect`.
pub inline fn emitView(v: *const View, out: *List, win: model.WindowId, rect: model.Rect) void {
    appendPlacement(out, win, applyHints(rect, v.hintsFor(win)), true);
}

/// Emit a visible placement from integer tiling coordinates, narrowing x/y
/// through model.satI16. The shared emission shape for layout modules.
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

/// Region too small to subdivide (overflow share): place the focused window — falling
/// back to the list head — on-screen inset by the doubled border, park every other
/// window. Shared by fibonacci and leaf, whose "can't fit two children" fallbacks
/// reduce to this shape.
pub inline fn emitOverflowShare(ctx: LayoutCtx, windows: []const model.WindowId, r: Region) void {
    // windows[0] is evaluated eagerly as focusedElse's fallback, so an empty slice
    // would trap before this case is even reachable.
    if (windows.len == 0) return;
    const top = focusedElse(ctx.v, windows, windows[0]);
    const margin = model.doubledBorder(ctx.m);
    if (insetFits(r.w, r.h, margin)) {
        emitView(ctx.v, ctx.out, top, insetRect(r.x, r.y, r.w, r.h, margin, ctx.min_dim));
    } else {
        // Region cannot hold even one pixel after the border: the min_dim floor would
        // flare off the workarea, and parking is the honest rendering.
        emitHidden(ctx.out, top);
    }
    // The "show one, hide the rest" fan-out. It appends unconditionally, which the
    // monocle shape cannot use: monocle must land emitView for its top window at that
    // window's own position in v.order.
    for (windows) |w| {
        if (w != top) emitHidden(ctx.out, w);
    }
}

/// Dispatch registry (build-generated, alphabetical stems). The active layout is a
/// `u8` index into this table; the engine never owns a closed enum. Imported via
/// contract's guarded re-export (the one `has_tiling` import).
const tiling_mods = contract.tiling_mods;

comptime {
    // The kind is a u8 index and the config list is capped at model.max_layouts, so a
    // registry past either bound would truncate the kind or overrun the config list at
    // runtime. Both are asserted: the u8 bound only implies the config cap while
    // max_layouts stays >= 256.
    if (tiling_mods.len > std.math.maxInt(u8))
        @compileError("tiling registry exceeds the u8 kind index (max 255 layouts)");
    if (tiling_mods.len > model.max_layouts)
        @compileError("tiling registry exceeds model.max_layouts");
}

/// Resolve a config layout name to its registry index (case-insensitive on module
/// names), or null when unregistered. Returns the index as the `u8` kind it will
/// actually be stored as: the kind IS a u8, so returning `usize` would hand every
/// caller a truncation footgun.
pub fn layoutByName(name: []const u8) ?u8 {
    for (tiling_mods, 0..) |m, i| if (std.ascii.eqlIgnoreCase(name, m.name)) return @intCast(i);
    return null;
}

/// Resolve a config layout name to a registry index, collapsing to `fallback` when
/// the name does not resolve. Loud, never silent: an unresolvable layout name is a
/// config bug, and every seeding/reload site resolves config names through this one
/// function.
pub fn layoutKindFallingBack(name: []const u8, fallback: u8) u8 {
    if (layoutByName(name)) |k| return k;
    // The fallback is the caller's choice (index 0 or a seed kind); an out-of-range
    // one would warn about "" and hand every degraded workspace a kind resolving to
    // nothing, so it is a caller bug, pinned here. The empty-registry (no-tiling)
    // build is exempt.
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

/// Step a layout within the config layout-name list (config order is the cycle
/// order). Each name resolves to a registry index (unresolvable names are skipped);
/// `cur`'s position steps by `dir` and wraps modulo the list. When `cur` is not in
/// the list (a safety net) it lands on the first/last edge by direction.
pub fn cycleKind(cur: u8, dir: i32, names: []const []const u8) u8 {
    // The names list fits model.max_layouts, so the `n < indices.len` clamp below is
    // unreachable under that cap — kept as a hard bound so a larger future source
    // can't overflow the stack array.
    var indices: [model.max_layouts]u8 = undefined;
    var n: usize = 0;
    for (names) |nm| if (layoutByName(nm)) |idx| {
        // A repeated name would make the value-equality search below bounce between the
        // two rows and never reach the rest of the ring — skip it so every DISTINCT
        // layout stays reachable.
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

/// Compute `kind`'s layout into `out` (cleared first). Each layout module must append
/// exactly one placement per window in `v.order` (off-viewport/hidden windows parked
/// via emitHidden).
///
/// Contract: `v.order` is non-empty and canonical. The engine always invokes compute
/// with the FULL ordered window set (`n > 0` guard in reconcile); a module may rely on
/// seeing the whole set at once and must not assume a sliced subset — counters/boosts
/// mirroring per-window state depend on this. The empty check below is a
/// div-by-zero guard first (grid's paneCell divides by `count`), reconciles the
/// contract for direct/test callers, and is NOT a slicing seam.
pub fn compute(kind: u8, v: *const View, out: *List) void {
    out.clear();
    if (v.order.len == 0) return;
    // An unregistered kind (restored `kind` whose entry is gone, or a corrupted index)
    // cannot dispatch. Emitting nothing would break the one-placement-per-window
    // contract the sink consumes positionally — fall back to the neutral layout. The
    // empty registry (no-tiling) has no kind and stays empty; reconcile gates the call
    // on a resolved kind.
    const m = contract.moduleOf(kind) orelse blk: {
        if (contract.tiling_mods.len == 0) return;
        std.debug.assert(contract.moduleOf(contract.default_kind) != null);
        break :blk contract.moduleOf(contract.default_kind) orelse return;
    };
    // layoutModule assigns `compute` unconditionally, so null can only be a misbuilt
    // registry entry — panic loudly instead of silently parking the whole workspace.
    const f = m.compute.?;
    {
        // The layout writes into SCRATCH; the engine emits into `out` in `v.order`
        // position. Order is a property of the SINK (it consumes `out` positionally
        // against a per-slot table from `order`), not something each layout can be
        // trusted to reproduce: a traversal emitting `100 101 110 102..109` where the
        // order said `100 101 102..110` hands each window another's rect -- a real
        // screen bug no golden test can see (goldens identify windows by name).
        var scratch: List = .{};
        f(v, &scratch);
        // The module-side half of the contract: one placement per window. emitInOrder
        // REPAIRS a reordering but cannot invent a dropped window or split a doubled
        // one, so those are caught HERE (debug; the raw-hook coverage check carries the
        // same property into ReleaseFast tests).
        std.debug.assert(scratchCoversOrder(v, &scratch));
        emitInOrder(v, &scratch, out);
    }
    // One placement per window, in View.order order — emitInOrder's guarantee, pinned
    // as a cheap invariant on the engine's own reordering pass (a failure is a bug in
    // emitInOrder, not a layout module). Length first, then ids: a reordered `out` is
    // the same wrong-screen outcome the repair exists to prevent.
    std.debug.assert(out.len == v.order.len);
    for (out.constSlice(), v.order) |p, win| std.debug.assert(p.win == win);
}

/// Whether `scratch` holds exactly one placement per window of `v.order` (count and
/// set; order is emitInOrder's business). O(n^2), but only ever called under a debug
/// assert.
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
/// Fast path: the layout already emitted in order (all registry layouts do — the only
/// out-of-order shape still possible is emitOverflowShare's fan-out), so this is one
/// comparison pass plus a copy. Otherwise each order position takes the placement
/// naming its window, and `taken` stops a duplicate satisfying two positions —
/// without it, a layout that emitted window 5 twice and dropped 4 would hand window
/// 5's single rect to both positions: the same wrong-screen outcome wearing a
/// passing length check.
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
        // No match: emit a placeholder so the placement COUNT still matches and the
        // sink's positional indexing never runs off the end of `out`. A window is only
        // missing when a module violated the one-placement-per-window contract —
        // caught by the scratch coverage assert in debug; the placeholder keeps a
        // release build degraded (one parked window) instead of misindexed.
        if (!found) _ = out.append(.{ .win = win, .rect = contract.parked_rect, .visible = false });
    }
}

/// Parses a layout variant VALUE-STRING into its ordinal slot: the index of the first
/// exact-case match, or null when unmatched. Shared by every layout module exposing
/// named variants.
fn variantParse(comptime variants: []const Variant) fn ([]const u8) ?u8 {
    return struct {
        fn parse(str: []const u8) ?u8 {
            // Reads the name column off the table itself: names[i] is variants[i].name,
            // so no separate array must stay in sync.
            for (variants, 0..) |v, i| {
                if (std.mem.eql(u8, str, v.name)) return @intCast(i);
            }
            return null;
        }
    }.parse;
}

/// One row of a layout module's variant table: the config value-string, the bar
/// indicator glyph drawn for it, and whether it is the fifo-spawn variant.
pub const Variant = struct {
    name: []const u8,
    indicator: []const u8,
    /// True for the one variant that toggles fifo spawn order.
    fifo: bool = false,
};

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
    // No len == 0 guard: an empty slice falls through to the same null.
    for (variants, 0..) |v, i| {
        if (v.fifo) return @intCast(i);
    }
    return null;
}

/// Ordinal of the named variant in a module's OWN table, at comptime. A hand-numbered
/// constant drifts when a row is inserted or reordered and nothing reports it -- the
/// layout then computes the other variant's geometry under a test that still passes;
/// a name lookup cannot drift, and a missing name is a compile error.
pub fn variantIndex(comptime variants: []const Variant, comptime vname: []const u8) u8 {
    for (variants, 0..) |v, i| {
        if (comptime std.mem.eql(u8, v.name, vname)) return @intCast(i);
    }
    @compileError("no variant named '" ++ vname ++ "' in this module's variant table");
}

/// Assemble a layout module's registry entry: `name`/`icon` are the display stems, `f`
/// the compute hook, `variants` the ONE table variant metadata is derived from,
/// `extra` the remaining `contract.Layout` fields.
///
/// The variant-derived fields (`variant_count`, `variant_parse`, `indicators`,
/// `fifo_variant`) are NOT settable through `extra`; they are computed from `variants`
/// here. As four parallel lists they would agree only by accident: adding a variant
/// row while forgetting `fifo_variant` leaves a layout whose cycle advertises a
/// variant the bar renders as the empty-indicator sentinel. One table makes
/// `indicators.len == variant_count` by construction.
pub fn layoutModule(
    comptime name: []const u8,
    comptime icon: []const u8,
    comptime f: anytype,
    comptime variants: []const Variant,
    comptime extra: contract.Layout,
) contract.Layout {
    comptime {
        // One table, checked: a duplicate value-string would shadow its twin in
        // variantParse/variantIndex (first match wins) and a second fifo row would be
        // unreachable through fifo_variant — both silent mis-parses. The count must fit
        // the u8 `variant_count`/`variant_idx` fields.
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
    // The four derived fields are assigned AFTER `extra` is copied in, so a stale value
    // in an `extra` literal is overwritten rather than honored -- the table is the
    // single source, which is the whole point.
    return m;
}

// Tiling-order transitions: the tiling engine owns layout-order mutations on the
// model. Core/window call sites reach these through the build-generated
// `tiling_seam` (has_tiling-gated stubs), never by naming this module.

fn moveTiled(list: anytype, win: model.WindowId, from: usize, to: usize) void {
    list.orderedRemove(from);
    _ = list.insert(to, win); // cannot fail: removal freed a slot
}

/// Moves `win` to index `idx_in` within its home workspace's tiled order, clamped to
/// the last slot; unknown windows are no-ops.
pub fn reorderTiled(m: *model.Model, win: model.WindowId, idx_in: usize) void {
    const h = model.findHome(m, win) orelse return;
    const list = &m.ws[h.index].tiled_order;
    const from = list.indexOfScalar(win) orelse return;
    moveTiled(list, win, from, @min(idx_in, list.len - 1));
}

/// Moves `win` one slot in `dir` within its home workspace's tiled order, wrapping at
/// either edge (dwm-style stack rotate, mirroring the focus cycle's modulo wrap);
/// unknown and lone tiled windows are no-ops.
pub fn stepTiled(m: *model.Model, win: model.WindowId, dir: i32) void {
    const h = model.findHome(m, win) orelse return;
    const list = &m.ws[h.index].tiled_order;
    const len = list.len;
    if (len < 2) return;
    const from = list.indexOfScalar(win) orelse return;
    moveTiled(list, win, from, model.wrapIndex(from, dir, len));
}

/// Slot swap: exchanges the first two tiled slots of the current workspace. No-op with
/// fewer than two tiled windows. Test seam: the actions layer runs
/// `swapFocusedWithPrevious`; production never calls this.
pub fn swapPrimary(m: *model.Model) void {
    const list = &m.ws[m.current.index].tiled_order;
    if (list.len < 2) return;
    const tmp = list.items[0];
    list.items[0] = list.items[1];
    list.items[1] = tmp;
}

/// Exchanges the tiled slots of the focused window and the previously focused one
/// (focus MRU, newest first), regardless of position -- the pair the swap_master
/// actions advertise. No-op when either has no tiled slot here (floating, other
/// workspace, minimized) or fewer than two are focused.
pub fn swapFocusedWithPrevious(m: *model.Model) void {
    const focused = m.focused orelse return;
    const ws = &m.ws[m.current.index];
    const list = &ws.tiled_order;
    const mru = ws.focus_mru.constSlice();
    if (list.len < 2 or mru.len < 2) return;
    // MRU[0] is maintained as the focused window (focus.setFocus front-inserts). If
    // they ever diverge, mru[1] is NOT "previously focused" and swapping with it would
    // move an unrelated slot.
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
