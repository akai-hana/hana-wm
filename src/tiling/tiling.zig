//! Dispatch engine for the tiling sub-system.
//! Reads model types and emits placements; no XCB and no allocation.

const std = @import("std");
const model = @import("model");
const log = @import("log");

const contract = @import("contract");

const scaling = @import("scaling");
/// ICCCM section 4.1.2.3 size-hint application: increment snap, max-size
/// clamp, then aspect clamp (with a re-snap, since a client may declare both).
/// Declared minimums are intentionally NOT enforced: tiling owns window size
/// (the policy lives on `model.SizeHints.min_width`).
pub fn applyHints(rect: model.Rect, h: model.SizeHints) model.Rect {
    if (h.isEmpty()) return rect;
    var width: u16 = rect.width;
    var height: u16 = rect.height;

    width = snapDimToIncrement(width, h.inc_width);
    height = snapDimToIncrement(height, h.inc_height);

    if (h.max_width > 0) width = @min(width, h.max_width);
    if (h.max_height > 0) height = @min(height, h.max_height);

    // min_aspect = h/w lower bound, max_aspect = w/h upper bound (dwm
    // convention); cross-multiplied to avoid FP division per retile.
    //
    // BOTH OR NEITHER (13.8): one bound alone is not a weaker constraint here,
    // it is a DIFFERENT one, and applying it alone is a trap worth naming. A
    // max bound alone clamps the offending DIMENSION, so a 200x50 window under
    // `max_aspect = 4` would become 200x50 still (200/50 = 4, at the limit) but
    // a 400x50 one would have its WIDTH clamped to 200 -- the window gets
    // narrower instead of taller, so the client is told to resize its content
    // area rather than being given a shape closer to its ratio. With the pair
    // present, the SAME window is fixed through the axis the ratio says is
    // wrong (its height, here). So the gate is `min > 0 AND max > 0`, not
    // "each independently": the two halves of one rule.
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(width);
        const fh: f32 = @floatFromInt(height);
        // Clamp to u16 range before narrowing so a huge aspect ratio caps.
        if (fw > fh * h.max_aspect) {
            width = @min(clampAspectDim(fh, h.max_aspect, h.inc_width), width);
        } else if (fh > fw * h.min_aspect) {
            height = @min(clampAspectDim(fw, h.min_aspect, h.inc_height), height);
        }
    }

    // Centre the (possibly shrunk) window inside its allocated slot. A positive
    // slot must never resolve to 0: the aspect re-snap can round a dimension
    // out entirely, so floor both dims after every clamp/snap.
    if (width == 0 and rect.width > 0) width = 1;
    if (height == 0 and rect.height > 0) height = 1;
    const dx: i16 = @intCast((rect.width -| width) / 2);
    const dy: i16 = @intCast((rect.height -| height) / 2);
    return .{
        .x = rect.x + dx,
        .y = rect.y + dy,
        .width = width,
        .height = height,
    };
}

/// Clamp `other * ratio` (a cross-multiplied aspect product) into u16 range,
/// then snap down to the increment. No max cap here: callers already clamp
/// against the max dimension via `@min` (and pre-clamped width in `applyHints`).
inline fn clampAspectDim(other: f32, ratio: f32, inc: u16) u16 {
    const aspect = scaling.roundToU16(other * ratio, 0.0);
    return snapDimToIncrement(aspect, inc);
}

/// Snap `dim` down to the nearest multiple of `inc`.
inline fn snapDimToIncrement(dim: u16, inc: u16) u16 {
    if (inc == 0) return dim;
    // Floor the result so a positive slot never snaps to a 0 dimension
    // (sub-increment leftover collapses to 1 instead).
    const snapped = (dim / inc) * inc;
    return if (snapped == 0 and dim > 0) 1 else snapped;
}

// The layout interchange vocabulary lives on the tiling CONTRACT (contract.zig)
// so the always-compiled reconciler can name it even without this tiling engine;
// here we only re-export it so modules keep referring to `tiling.List` etc.
pub const Placement = contract.Placement;
pub const parked_rect = contract.parked_rect;
pub const HintsView = contract.HintsView;
pub const Env = contract.Env;
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
/// half a gap per side so neighboring windows together share one full gap.
pub inline fn seamGap(m: model.Margins) u16 {
    return m.gap / 2;
}

/// Shrinks `dim` by `margin` (gap/border), floored to `min_dim` so a layout
/// never hands a client a zero or negative size.
pub inline fn shrinkClamped(dim: u16, margin: u16, min_dim: u16) u16 {
    return if (dim > margin) dim - margin else min_dim;
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

/// Clamp a signed y coordinate to a non-negative u16.
inline fn clampYToU16(y: i32) u16 {
    return @intCast(@max(y, 0));
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
        // alone: a work area that does not start at x=0 (a side claim) was
        // silently placed back at the screen's left edge.
        .x = wa.x +| @as(i32, gap),
        .y = clampYToU16(wa.y) +| gap,
        .w = wa.width -| gap *| 2,
        .h = wa.height -| gap *| 2,
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

/// Work-area origin y clamped to >= 0, as u16.
pub inline fn waY(v: *const View) u16 {
    return clampYToU16(v.workarea.y);
}

/// Position of cell `i` along an axis of `cell`-sized cells separated by
/// `gap`. Shared by grid and master (the `i *| (cell +| gap)` stride).
pub inline fn cellStride(cell: u16, gap: u16, i: u16) u16 {
    return i *| (cell +| gap);
}

/// Append one placement. If the list is already at capacity this is a silent
/// skip (drop the new placement) rather than an overflow — ReleaseFast never
/// traps, and a full list means we're already showing the outer edges.
inline fn appendPlacement(out: *List, win: model.WindowId, rect: model.Rect, visible: bool) void {
    if (!out.append(.{ .win = win, .rect = rect, .visible = visible })) return;
}

/// Emit a visible placement with the window's size hints applied to `rect`.
pub inline fn emitView(v: *const View, out: *List, win: model.WindowId, rect: model.Rect) void {
    appendPlacement(out, win, applyHints(rect, v.hints.forWin(win)), true);
}

/// Emit a visible placement built from integer tiling coordinates, narrowing
/// x/y through model.satI16. The shared row-emission shape every module used
/// to hand-build as `model.Rect{ .x = model.satI16(...), ... }` + emitView.
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
    appendPlacement(out, win, parked_rect, false);
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
    emitView(ctx.v, ctx.out, top, insetRect(r.x, r.y, r.w, r.h, model.doubledBorder(ctx.m), ctx.min_dim));
    // The "show one, hide the rest" fan-out, inline. It was a named helper, but
    // this is its only caller and its doc claimed the monocle shape uses it --
    // monocle cannot, because it must land emitView for its top window at that
    // window's own position in v.order, while this appends unconditionally.
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
    // The kind is a u8 index and the config list is sized max_layouts, so a
    // registry that outgrows either would truncate or overrun at runtime. The
    // u8 bound is the stronger of the two (255 < max_layouts), so asserting it
    // alone still implies the other.
    std.debug.assert(tiling_mods.len <= std.math.maxInt(u8));
}

/// Resolve a config layout name to its registry index (case-insensitive match
/// on module names), or null when unregistered.
/// Returns the registry index as the `u8` kind it will actually be stored as,
/// not a `usize` the caller has to cast. The kind IS a u8, so returning usize
/// only created a truncation footgun at eight call sites.
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
    if (layoutByName(name)) |k| return @intCast(k);
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
        if (n < indices.len) {
            indices[n] = @intCast(idx);
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
    const m = contract.moduleOf(kind) orelse return;
    if (v.order.len == 0) return;
    if (m.compute) |f| {
        // The layout writes into SCRATCH and the engine emits into `out` in
        // `v.order` position (14.9). The order is a property of the SINK
        // (it consumes `out` positionally against a per-slot table built from
        // `order`), not something each layout can be trusted to reproduce:
        // master's overflow grid is column-major, so it emitted `100 101 110
        // 102..109` where the order said `100 101 102..110` -- a real screen
        // bug (each window was given another window's rect) that no golden
        // test could see, because every golden looked at windows it knew by
        // name rather than at the position. Making it an engine invariant
        // means a future layout cannot reintroduce it by choosing a tidier
        // traversal than a row-major one.
        var scratch: List = .{};
        f(v, &scratch);
        emitInOrder(v, &scratch, out);
    }
    // One placement per window, in View.order order (asserted, and now
    // GUARANTEED by emitInOrder above). The length check catches a dropped or
    // doubled window; comparing the window id at each index catches a
    // REORDERED one, which keeps the length while swapping whose rect is
    // whose. Both are std.debug.assert: no release cost.
    //
    // Note these asserts are only live in Debug/ReleaseSafe. The unit tests
    // build ReleaseFast by default (build.zig resolveOptimize), where they
    // compile out -- which is why the 14.9 invariant sweep exists as an
    // ordinary test rather than only as asserts.
    std.debug.assert(out.len == v.order.len);
    for (out.constSlice(), v.order) |p, win| std.debug.assert(p.win == win);
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
        // COUNT still matches and the caller's per-index assert names the
        // missing window, instead of a count mismatch that names nothing.
        if (!found) _ = out.append(.{ .win = win, .rect = contract.parked_rect, .visible = false });
    }
}

/// Parses a layout variant VALUE-STRING into its ordinal slot: the index of
/// the first exact-case match in `names`, or null when unmatched. Shared by
/// every layout module that exposes named variants.
pub fn variantParse(comptime variants: []const Variant) fn ([]const u8) ?u8 {
    return struct {
        fn parse(str: []const u8) ?u8 {
            // Reads the name column off the table itself rather than a
            // pre-extracted []const []const u8: the extractor's only caller was
            // this, and names[i] is defined as variants[i].name, so the
            // candidate set and its order are the same either way -- including
            // for an empty table, where both fall through to the same null.
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

/// Ordinal of the named variant in a module's OWN table, at comptime.
/// Replaces each module's hand-numbered constant (`const variant_gaps = 1`):
/// inserting or reordering a row moved the constant out from under the code
/// that compared against it, and nothing reported the shift -- the layout then
/// computed the other variant's geometry under a test that still passed.
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
/// computed from `variants` here. They were four hand-maintained parallel
/// lists per module; they happened to agree, so nothing failed, and adding a
/// variant row while forgetting `fifo_variant` would leave a layout whose
/// cycle advertised a variant that the bar rendered as the empty-indicator
/// sentinel. One table makes `indicators.len == variant_count` by construction.
pub fn layoutModule(
    comptime name: []const u8,
    comptime icon: []const u8,
    comptime f: anytype,
    comptime variants: []const Variant,
    comptime extra: contract.Layout,
) contract.Layout {
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
