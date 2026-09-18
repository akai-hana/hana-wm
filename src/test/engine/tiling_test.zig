//! Layout engine tests.
//!
//! Golden-value tests: expected rects are hand-computed from the layout
//! modules' formulas (modules/*.zig), so any drift fails loudly. Fixture: windows registered on workspace 0 via model.register.

const std = @import("std");
const testing = std.testing;

const utils = @import("utils");
const model = @import("model");
const helpers = @import("helpers");

const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};
// Scroll-only tests runtime-skip below, but the stub must still expose the
// two members their bodies reference so a scroll-less tree compiles.
const scroll_algo = if (build_options.has_layout_scroll) @import("scroll") else struct {
    fn slotWidth(_: i32) i32 {
        return 0;
    }
    fn maxOffset(_: i32, _: i32, _: i32) i32 {
        return 0;
    }
};

const List = tiling.List;
const Placement = tiling.Placement;

/// Registry indices for each layout, resolved by name (instead of a closed
/// enum) so the tests stay robust to registry ordering. Computed at
/// compile time from the build-generated module registry.
/// Panic message shared by the name→index constants below: a missing layout
/// here is a registry bug, not a test condition, so a silent 0 would corrupt
/// every golden rect (layout 0 is master).
const kLayoutMissing = "tiling test: registry missing layout";
const K_MASTER: u8 = @intCast(tiling.layoutByName("master") orelse @panic(kLayoutMissing));
const K_MONOCLE: u8 = @intCast(tiling.layoutByName("monocle") orelse @panic(kLayoutMissing));
const K_GRID: u8 = @intCast(tiling.layoutByName("grid") orelse @panic(kLayoutMissing));
const K_FIB: u8 = @intCast(tiling.layoutByName("fibonacci") orelse @panic(kLayoutMissing));
const K_LEAF: u8 = @intCast(tiling.layoutByName("leaf") orelse @panic(kLayoutMissing));
const K_SCROLL: u8 = @intCast(tiling.layoutByName("scroll") orelse @panic(kLayoutMissing));

// Variant indexes owned by each module: grid's "relaxed" is variant 1 of
// {"rigid","relaxed"}; monocle's "gaps" is variant 1 of {"gapless","gaps"}.
const GRID_RELAX_VARIANT: u8 = 1;
const MONOCLE_GAP_VARIANT: u8 = 1;

const Fixture = struct {
    m: model.Model,
    hv: tiling.HintsView,
    hint_buf: [model.store_capacity]model.SizeHints = undefined,
    wa: utils.Rect,

    fn init(self: *Fixture, wins: []const model.WindowId) void {
        self.initAt(wins, helpers.std_wa);
    }

    /// init with an explicit work area, for the non-standard-geometry cases.
    fn initAt(self: *Fixture, wins: []const model.WindowId, wa: utils.Rect) void {
        self.* = .{
            .m = .{},
            .hv = undefined,
            .wa = wa,
        };
        for (wins) |w| model.register(&self.m, w, null) catch unreachable;
        // Materialize hints aligned index-for-index with the order slice.
        const s0 = &self.m.ws[0];
        for (s0.tiled_order.constSlice(), 0..) |w, i| {
            self.hint_buf[i] = if (self.m.store.get(w)) |e| e.size_hints else .{};
        }
        const n = s0.tiled_order.len;
        self.hv = .{ .order = s0.tiled_order.constSlice(), .hints = self.hint_buf[0..n] };
    }

    fn view(self: *Fixture) tiling.View {
        const s = &self.m.ws[0];
        return .{
            .order = s.tiled_order.constSlice(),
            .params = &s.params,
            .workarea = self.wa,
            .hints = &self.hv,
            .focused = self.m.focused,
        };
    }
};

/// View with the standard margin/min_dim tuning.
fn tuned(fx: *Fixture) tiling.View {
    var v = fx.view();
    v.env = helpers.std_env;
    return v;
}

/// One compute pass into a fresh list (a BoundedList, so returning by value
/// is allocation-free).
fn computeOf(kind: u8, v: tiling.View) List {
    var list: List = .{};
    tiling.compute(kind, v, &list);
    return list;
}

fn expectP(out: *const List, i: usize, win: model.WindowId, x: i32, y: i32, w: u16, h: u16, visible: bool) !void {
    const p = out.constSlice()[i];
    try testing.expectEqual(win, p.win);
    try testing.expectEqual(visible, p.visible);
    try testing.expectEqual(x, @as(i32, p.rect.x));
    try testing.expectEqual(y, @as(i32, p.rect.y));
    try testing.expectEqual(w, p.rect.width);
    try testing.expectEqual(h, p.rect.height);
}

// master, single window fills the work area minus gaps/borders.
test "master single window" {
    var fx: Fixture = undefined;
    fx.init(&.{11});

    const out = computeOf(K_MASTER, tuned(&fx));

    try testing.expectEqual(@as(usize, 1), out.len);
    // master_inner_w = shrink(800, gap*2 + border*2 = 20) = 780
    // height: calcAvailableHeight(600,1) = 600 - (16 + 4) = 580
    try expectP(&out, 0, 11, 8, 8, 780, 580, true);
}

// master + stack, default 50/50 split.
test "master two windows" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12 });

    const out = computeOf(K_MASTER, tuned(&fx));

    try testing.expectEqual(@as(usize, 2), out.len);
    // master_w = round(800 * 0.5) = 400; inner = shrink(400, 12 + 4) = 384
    try expectP(&out, 0, 11, 8, 8, 384, 580, true);
    // stack_x = 400; x = 400 + gap/2(4) = 404; inner = shrink(400, 4+12) = 384
    try expectP(&out, 1, 12, 404, 8, 384, 580, true);
}

// primary_on_right mirrors the columns.
test "master on right" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12 });

    var v = tuned(&fx);
    v.env.primary_on_right = true;

    const out = computeOf(K_MASTER, v);

    try testing.expectEqual(@as(usize, 2), out.len);
    // master_x = 800 - 400 = 400; x = 408
    try expectP(&out, 0, 11, 408, 8, 384, 580, true);
    // Mirrored stack: x = gap + gap/2 = 12 (exact mirror of the two-window stack at
    // [404,388] -> 800-404-384 = 12); a 0 pane origin would leave only a
    // half-gap at the left screen edge.
    try expectP(&out, 1, 12, 12, 8, 384, 580, true);
}

// grid 2x2.
test "grid 2x2" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 });

    const out = computeOf(K_GRID, tuned(&fx));

    try testing.expectEqual(@as(usize, 4), out.len);
    // cell_w = (800 - 3*8)/2 = 388 -> win_w 384; cell_h = (600-24)/2 = 288 -> 284
    try expectP(&out, 0, 11, 8, 8, 384, 284, true);
    try expectP(&out, 1, 12, 404, 8, 384, 284, true);
    try expectP(&out, 2, 13, 8, 304, 384, 284, true);
    try expectP(&out, 3, 14, 404, 304, 384, 284, true);
}

// grid relaxed widens the partial last row: cells share the full
// screen width AND the partial row is column-spaced by that wider cell, so
// the wide relaxed cells do not overlap (previously the partial row kept the
// narrow column stride, making neighbouring wide cells overlap each other).
test "grid relaxed partial row" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14, 15 });

    var v = tuned(&fx);
    v.env.variant_idx = GRID_RELAX_VARIANT;

    const out = computeOf(K_GRID, v);

    try testing.expectEqual(@as(usize, 5), out.len);
    // cols=3 rows=2; rigid win_w = shrink((800-32)/3 = 256, 4) = 252
    try expectP(&out, 0, 11, 8, 8, 252, 284, true);
    try expectP(&out, 1, 12, 272, 8, 252, 284, true);
    try expectP(&out, 2, 13, 536, 8, 252, 284, true);
    // last row: count=2 -> partial_cell_w = (800-24)/2 = 388 -> 384, spaced
    // by the partial cell stride (388+8): x = 8 and 404 (no overlap).
    try expectP(&out, 3, 14, 8, 304, 384, 284, true);
    try expectP(&out, 4, 15, 404, 304, 384, 284, true);

    // Rigid mode keeps the column width in the partial row.
    v.env.variant_idx = 0;
    const outr = computeOf(K_GRID, v);
    try expectP(&outr, 3, 14, 8, 304, 252, 284, true);
    try expectP(&outr, 4, 15, 272, 304, 252, 284, true);
}

// fibonacci spiral of four, counter-clockwise from top-left.
test "fibonacci spiral" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 });

    const out = computeOf(K_FIB, tuned(&fx));

    try testing.expectEqual(@as(usize, 4), out.len);
    // outerArea: (8,8) 784x584; win_dim=(784-8)/2=388 etc.
    try expectP(&out, 0, 11, 8, 8, 384, 580, true); // right
    try expectP(&out, 1, 12, 404, 8, 384, 284, true); // down
    try expectP(&out, 2, 13, 602, 304, 186, 284, true); // left
    try expectP(&out, 3, 14, 404, 304, 186, 284, true); // up, final rect
}

// fibonacci overflow: the spiral prefix stays on screen, the overflow
// tail is parked with focusedElse's pick raised in the leftover region.
// Trace (200x200, gap 8, border 2): five spiral splits fit before BOTH
// cursor dims must clear min_area (the branch checks both regardless of
// split direction), so windows 41..45 are placed normally and the overflow
// branch fires at index 5, raising focused window 75 into {128,104} 12x36
// shrunk from the 16x40 remainder.
test "fibonacci overflow fallback" {
    var wins: [40]model.WindowId = undefined;
    for (&wins, 0..) |*w, i| w.* = @intCast(41 + i);
    var fx: Fixture = undefined;
    fx.initAt(&wins, .{ .x = 0, .y = 0, .width = 200, .height = 200 });

    model.setFocus(&fx.m, 75); // deep in the overflow tail

    const v = tuned(&fx);
    const out = computeOf(K_FIB, v);

    try testing.expectEqual(@as(usize, 40), out.len);
    var visible_count: usize = 0;
    var raised_found = false;
    for (out.constSlice()) |p| {
        if (p.visible) {
            visible_count += 1;
            if (p.win == 75) raised_found = true;
        } else {
            try testing.expectEqual(tiling.parked_rect.x, p.rect.x);
            try testing.expectEqual(tiling.parked_rect.width, p.rect.width);
        }
    }
    try testing.expectEqual(@as(usize, 6), visible_count);
    try testing.expect(raised_found);
    // The raised window sits in the leftover region, hint-free here.
    try expectP(&out, 5, 75, 128, 104, 12, 36, true);
}

// leaf BSP splits the longer axis first, ties favour vertical.
test "leaf balanced splits" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 });

    const out = computeOf(K_LEAF, tuned(&fx));

    try testing.expectEqual(@as(usize, 4), out.len);
    // Root split vertical-ish? No: w(784) >= h(584) -> horizontal halves at x=8 / x=404,
    // then each half (388 < 584) stacks vertically: heights (584-8)/2 = 288 -> 284.
    try expectP(&out, 0, 11, 8, 8, 384, 284, true);
    try expectP(&out, 1, 12, 8, 304, 384, 284, true);
    try expectP(&out, 2, 13, 404, 8, 384, 284, true);
    try expectP(&out, 3, 14, 404, 304, 384, 284, true);
}

// scroll strip: caller pre-clamps offset; off-viewport slots parked.
test "scroll strip and parking" {
    if (!build_options.has_layout_scroll) return error.SkipZigTest;
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14, 15 });

    // Caller duties (algo_scroll header): snap right for new windows, clamp.
    const slot_w = scroll_algo.slotWidth(800);
    const max_off = scroll_algo.maxOffset(5, slot_w, 800);
    try testing.expectEqual(@as(i32, 400), slot_w);
    try testing.expectEqual(@as(i32, 1200), max_off);
    try testing.expectEqual(@as(i32, 0), scroll_algo.maxOffset(2, slot_w, 800));

    const params = &fx.m.ws[0].params;
    params.viewport_offset = max_off;
    params.viewport_prev_count = 5;

    const out = computeOf(K_SCROLL, tuned(&fx));

    try testing.expectEqual(@as(usize, 5), out.len);
    // cols 0..2 fully left of the viewport -> parked.
    try expectP(&out, 0, 11, 0, 0, 0, 0, false);
    try expectP(&out, 1, 12, 0, 0, 0, 0, false);
    try expectP(&out, 2, 13, 0, 0, 0, 0, false);
    // col 3 straddles the left edge: full-gap inset; col 4 interior/right edge.
    // avail = 400 - insets - border*2 = 384; content_h = shrink(600, 20) = 580.
    try expectP(&out, 3, 14, 8, 8, 384, 580, true);
    try expectP(&out, 4, 15, 404, 8, 384, 580, true);
}

// monocle raises focusedElse's pick, parks the rest; gaps variant insets.
test "monocle gaps variant" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 });

    model.setFocus(&fx.m, 12);

    var v = tuned(&fx);
    v.env.variant_idx = MONOCLE_GAP_VARIANT;

    const out = computeOf(K_MONOCLE, v);

    try testing.expectEqual(@as(usize, 3), out.len);
    // total_margin = doubledBorder(4) + inset*2 (16) = 20
    try expectP(&out, 0, 12, 8, 8, 780, 580, true);
    // Emission order: top first, then hidden in list order.
    try expectP(&out, 1, 11, 0, 0, 0, 0, false);
    try expectP(&out, 2, 13, 0, 0, 0, 0, false);

    // Without the gaps variant the inset is zero: full size minus borders only.
    v.env.variant_idx = 0;
    const out2 = computeOf(K_MONOCLE, v);
    try expectP(&out2, 0, 12, 0, 0, 796, 596, true);
}

// size hints are applied centrally at emit time (inc snap + centring).
test "hints applied at emit" {
    var fx: Fixture = undefined;
    fx.init(&.{11});

    // Mutate the model entry, then re-materialize the View's hint snapshot
    // exactly as sync.reconcile does per retile (hints are frozen INTO
    // the View; a post-snapshot store change needs a fresh View).
    fx.m.store.getPtr(11).?.size_hints = .{ .inc_width = 100, .inc_height = 100 };
    fx.hint_buf[0] = fx.m.store.getPtr(11).?.size_hints;

    const out = computeOf(K_MASTER, tuned(&fx));

    // Raw master rect is {8,8,780,580}; snapped down to 700x500 and centred
    // back into its slot: dx = (780-700)/2 = 40, dy = 40.
    try expectP(&out, 0, 11, 48, 48, 700, 500, true);
}

// Tiling deliberately ignores PMinSize/PBaseSize: the layout engine owns all
// tiled dimensions, so honouring a client minimum would pin the rect and block
// mod_h/mod_l. The same hints ARE honoured by the floating drag-resize floor
// (floating.sizeHintLimits); this guards against min enforcement leaking into
// the shared hint path.
test "applyHints ignores declared minimums" {
    const rect: utils.Rect = .{ .x = 8, .y = 8, .width = 780, .height = 580 };
    try testing.expectEqual(rect, tiling.applyHints(rect, .{ .min_width = 1000, .min_height = 1000 }));
}

// Horizontal geometry enforcement on the master-slave axis: a slave
// that declares a small max_width (e.g. a dialog) shrinks the stack column to
// its natural width and the master absorbs the freed horizontal space, so the
// dialog no longer leaves a dead gap beside it. Mirrors tileColumn's vertical
// max_height capping, on the width axis.
test "master swallows freed space from a narrow dialog slave" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12 });

    // Window 12 (the stack slave) declares a small max_width. Re-materialize
    // the hint snapshot into the buffer, exactly as sync does per retile.
    fx.m.store.getPtr(12).?.size_hints = .{ .max_width = 200 };
    fx.hint_buf[1] = fx.m.store.getPtr(12).?.size_hints;

    const out = computeOf(K_MASTER, tuned(&fx));

    try testing.expectEqual(@as(usize, 2), out.len);
    // Raw stack pane = 800 - (0.5*800 = 400) = 400; natural width for the
    // 200-wide dialog = 200 + (gap/2 4 + gap 8 + 2*border 4 = 16) = 216,
    // which is < 400, so the stack shrinks to 216 and master grows to 584.
    // master: x=8, inner=shrink(584, 12+4=16)=568, h=580.
    try expectP(&out, 0, 11, 8, 8, 568, 580, true);
    // stack_x = master_w = 584; x=584+4=588, inner=shrink(216,16)=200.
    try expectP(&out, 1, 12, 588, 8, 200, 580, true);
}

// purity: compute twice yields identical output and mutates nothing.
test "deterministic and non-mutating" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 });

    const params_before = fx.m.ws[0].params;
    const focus_before = fx.m.focused;
    const store_count_before = fx.m.store.count();

    const v = tuned(&fx);
    const out_a = computeOf(K_GRID, v);
    const out_b = computeOf(K_GRID, v);

    try testing.expectEqual(out_a.len, out_b.len);
    for (out_a.constSlice(), out_b.constSlice()) |a, b| {
        try testing.expect(a.win == b.win);
        try testing.expect(a.rect.eql(b.rect));
        try testing.expect(a.visible == b.visible);
    }
    try testing.expectEqual(params_before, fx.m.ws[0].params);
    try testing.expectEqual(focus_before, fx.m.focused);
    try testing.expectEqual(store_count_before, fx.m.store.count());
}

// empty order is a supported input for every layout: each
// compute must emit nothing and must not trap. Grid previously divided by
// calcGridShape(0).rows == 0 and monocle indexed order[len - 1].
test "n=0 emits nothing across all layouts" {
    var fx: Fixture = undefined;
    fx.init(&.{});

    // Scroll is a removeable addon: absent it, its registry entries collapse
    // to the same index as another layout, so prune it from the sweep.
    const kinds = if (comptime build_options.has_layout_scroll)
        [_]u8{ K_MASTER, K_MONOCLE, K_FIB, K_GRID, K_LEAF, K_SCROLL }
    else
        [_]u8{ K_MASTER, K_MONOCLE, K_FIB, K_GRID, K_LEAF };
    for (kinds) |kind| {
        const out = computeOf(kind, tuned(&fx));
        try testing.expectEqual(@as(usize, 0), out.len);
    }
}

// scroll orphan keep-last invariant. compute() now clamps
// viewport_offset internally, so even a stale over-max offset is safe: the
// last window stays visible without requiring caller-side clamping.
//   - a stale over-max offset is clamped, last window stays visible;
//   - the documented caller clamp (pipeline.preReconcileDuties) is still
//     correct but no longer required for correctness;
//   - the shrink case (n drops, old offset exceeds the new max) clamps to 0.
test "scroll orphan keep-last invariant" {
    if (!build_options.has_layout_scroll) return error.SkipZigTest;
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 });

    const slot_w = scroll_algo.slotWidth(800);
    const params = &fx.m.ws[0].params;

    // (1) Stale offset (from a hypothetical n=9 strip): clamped internally,
    // so the last window is visible (not all parked).
    const stale_off = scroll_algo.maxOffset(9, slot_w, 800);
    try testing.expect(stale_off > scroll_algo.maxOffset(4, slot_w, 800));
    params.viewport_offset = stale_off;
    params.viewport_prev_count = 4;
    const out_orphan = computeOf(K_SCROLL, tuned(&fx));
    try testing.expect(out_orphan.constSlice()[3].visible);

    // (2) Clamped per duty 2: the last window is at least flush-visible at
    // max offset (its slot's right edge reaches the screen edge).
    params.viewport_offset = @min(stale_off, scroll_algo.maxOffset(4, slot_w, 800));
    const out_last = computeOf(K_SCROLL, tuned(&fx));
    try testing.expect(out_last.constSlice()[3].visible);

    // (3) Shrink 4 -> 2: maxOffset(2) == 0 forces offset 0; both visible.
    params.viewport_offset = @min(stale_off, scroll_algo.maxOffset(2, slot_w, 800));
    var fx2: Fixture = undefined;
    fx2.init(&.{ 11, 12 });

    const params2 = &fx2.m.ws[0].params;
    params2.viewport_offset = 0;
    params2.viewport_prev_count = 2;
    const out_shrunk = computeOf(K_SCROLL, tuned(&fx2));
    try testing.expect(out_shrunk.constSlice()[0].visible);
    try testing.expect(out_shrunk.constSlice()[1].visible);
}

// emission-order pin across all layouts with a shared non-empty
// fixture (companion to the empty-input pin test): count and win-id
// sequence are frozen so any guard/reorder drift fails loudly. Geometry is
// already pinned per-layout above.
test "emission order pin across layouts" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 });

    model.setFocus(&fx.m, 12);

    // Every input-order layout emits exactly the tiled_order sequence.
    // Scroll is a removeable addon, so prune it when absent (its registry
    // entry then collapses to another layout's index and would re-test it).
    const in_order_kinds = if (comptime build_options.has_layout_scroll)
        [_]u8{ K_MASTER, K_FIB, K_GRID, K_LEAF, K_SCROLL }
    else
        [_]u8{ K_MASTER, K_FIB, K_GRID, K_LEAF };
    for (in_order_kinds) |kind| {
        const out = computeOf(kind, tuned(&fx));
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqual(@as(model.WindowId, 11), out.constSlice()[0].win);
        try testing.expectEqual(@as(model.WindowId, 12), out.constSlice()[1].win);
        try testing.expectEqual(@as(model.WindowId, 13), out.constSlice()[2].win);
    }

    // Monocle emits the focused window first, then hidden in list order.
    const out_mono = computeOf(K_MONOCLE, tuned(&fx));
    try testing.expectEqual(@as(usize, 3), out_mono.len);
    try testing.expectEqual(@as(model.WindowId, 12), out_mono.constSlice()[0].win);
    try testing.expectEqual(@as(model.WindowId, 11), out_mono.constSlice()[1].win);
    try testing.expectEqual(@as(model.WindowId, 13), out_mono.constSlice()[2].win);
}

// layout cycling is registry-driven and config-order: the cycle
// ring is the config layout-name list resolved by name (unresolvable names
// are skipped); stepping wraps modulo the list. Replaces the removed
// model.cycleLayout (kind is now an opaque u8, resolved at seed time).
test "layout cycle is config-order and wraps" {
    const names = helpers.std_layout_names;
    var ring: [8]u8 = undefined;
    var n: usize = 0;
    for (names) |nm| {
        if (tiling.layoutByName(nm)) |idx| {
            ring[n] = @intCast(idx);
            n += 1;
        }
    }
    const start = ring[0];
    // One full cycle forward returns to the starting layout.
    var k = start;
    for (0..n) |_| k = tiling.cycleKind(k, 1, &names);
    try testing.expectEqual(start, k);
    // A single backward step leaves the start (wraps to the last)...
    try testing.expect(tiling.cycleKind(start, -1, &names) != start);
    // ...and one forward step recovers it.
    try testing.expectEqual(start, tiling.cycleKind(tiling.cycleKind(start, -1, &names), 1, &names));
    // Forward steps traverse each resolved list entry in order.
    k = start;
    for (0..n) |i| {
        k = tiling.cycleKind(k, 1, &names);
        try testing.expectEqual(ring[if (i + 1 == n) 0 else i + 1], k);
    }
}
