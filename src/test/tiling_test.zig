//! Layout engine tests (T19-T30).
//!
//! Golden-value tests: expected rects are hand-computed from the layout
//! modules' formulas (modules/*.zig), so any drift fails loudly. Fixture: windows registered on workspace 0 via model.register.

const std = @import("std");
const testing = std.testing;

const utils = @import("utils");
const model = @import("model");

const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};
const scroll_algo = if (build_options.has_layout_scroll) @import("scroll") else struct {};

const List = tiling.List;
const Placement = tiling.Placement;

/// Registry indices for each layout, resolved by name (instead of a closed
/// enum) so the tests stay robust to registry ordering. Computed at
/// compile time from the build-generated module registry.
const K_MASTER: u8 = @intCast(tiling.layoutByName("master") orelse 0);
const K_MONOCLE: u8 = @intCast(tiling.layoutByName("monocle") orelse 0);
const K_GRID: u8 = @intCast(tiling.layoutByName("grid") orelse 0);
const K_FIB: u8 = @intCast(tiling.layoutByName("fibonacci") orelse 0);
const K_LEAF: u8 = @intCast(tiling.layoutByName("leaf") orelse 0);
const K_SCROLL: u8 = @intCast(tiling.layoutByName("scroll") orelse 0);

// Variant indexes owned by each module (pulled from its registry Layout decl
// so tests and modules stay aligned): grid.relax_mode / monocle.gap_mode.
const tiling_mods = @import("tiling_modules").modules;
const GRID_RELAX_VARIANT: u8 = tiling_mods[K_GRID].relax_mode orelse 0;
const MONOCLE_GAP_VARIANT: u8 = tiling_mods[K_MONOCLE].gap_mode orelse 0;

/// Standard test margins/min_dim used by most cases.
const gap = 8;
const border = 2;
const min_dim = 50;

fn stdWa() utils.Rect {
    return .{ .x = 0, .y = 0, .width = 800, .height = 600 };
}

const Fixture = struct {
    m: model.Model,
    hv: tiling.HintsView,
    hint_buf: [model.store_capacity]model.SizeHints = undefined,
    wa: utils.Rect,

    fn init(self: *Fixture, wins: []const model.WindowId, wa: utils.Rect) void {
        self.* = .{
            .m = .{},
            .hv = undefined,
            .wa = wa,
        };
        for (wins) |w| model.register(&self.m, w, null) catch unreachable;
        // B5: materialize hints aligned index-for-index with the order slice.
        const s0 = &self.m.ws[0];
        for (s0.tiled_order.constSlice(), 0..) |w, i| {
            self.hint_buf[i] = if (self.m.store.get(w)) |e| e.size_hints else .{};
        }
        const n = s0.tiled_order.len;
        self.hv = .{ .order = s0.tiled_order.constSlice(), .hints = self.hint_buf[0..n] };
    }

    fn deinit(self: *Fixture) void {
        _ = self; // bounded lists need no teardown
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
    v.env.margins = .{ .gap = gap, .border = border };
    v.env.min_dim = min_dim;
    return v;
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

// T19 - master, single window fills the work area minus gaps/borders.
test "T19 master single window" {
    var fx: Fixture = undefined;
    fx.init(&.{11}, stdWa());
    defer fx.deinit();

    var out: List = .{};
    tiling.compute(K_MASTER, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 1), out.len);
    // master_inner_w = shrink(800, gap*2 + border*2 = 20) = 780
    // height: calcAvailableHeight(600,1) = 600 - (16 + 4) = 580
    try expectP(&out, 0, 11, 8, 8, 780, 580, true);
}

// T20 - master + stack, default 50/50 split.
test "T20 master two windows" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    tiling.compute(K_MASTER, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 2), out.len);
    // master_w = round(800 * 0.5) = 400; inner = shrink(400, 12 + 4) = 384
    try expectP(&out, 0, 11, 8, 8, 384, 580, true);
    // stack_x = 400; x = 400 + gap/2(4) = 404; inner = shrink(400, 4+12) = 384
    try expectP(&out, 1, 12, 404, 8, 384, 580, true);
}

// T21 - primary_on_right mirrors the columns.
test "T21 master on right" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12 }, stdWa());
    defer fx.deinit();

    var v = tuned(&fx);
    v.env.primary_on_right = true;

    var out: List = .{};
    tiling.compute(K_MASTER, v, &out);

    try testing.expectEqual(@as(usize, 2), out.len);
    // master_x = 800 - 400 = 400; x = 408
    try expectP(&out, 0, 11, 408, 8, 384, 580, true);
    // stack_x = 0; x = 4
    try expectP(&out, 1, 12, 4, 8, 384, 580, true);
}

// T22 - grid 2x2.
test "T22 grid 2x2" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    tiling.compute(K_GRID, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 4), out.len);
    // cell_w = (800 - 3*8)/2 = 388 -> win_w 384; cell_h = (600-24)/2 = 288 -> 284
    try expectP(&out, 0, 11, 8, 8, 384, 284, true);
    try expectP(&out, 1, 12, 404, 8, 384, 284, true);
    try expectP(&out, 2, 13, 8, 304, 384, 284, true);
    try expectP(&out, 3, 14, 404, 304, 384, 284, true);
}

// T23 - grid relaxed widens the partial last row (verbatim quirk:
// x spacing stays column-based, so wide partial cells overlap their row).
test "T23 grid relaxed partial row" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14, 15 }, stdWa());
    defer fx.deinit();

    var v = tuned(&fx);
    v.env.variant_idx = GRID_RELAX_VARIANT;

    var out: List = .{};
    tiling.compute(K_GRID, v, &out);

    try testing.expectEqual(@as(usize, 5), out.len);
    // cols=3 rows=2; rigid win_w = shrink((800-32)/3 = 256, 4) = 252
    try expectP(&out, 0, 11, 8, 8, 252, 284, true);
    try expectP(&out, 1, 12, 272, 8, 252, 284, true);
    try expectP(&out, 2, 13, 536, 8, 252, 284, true);
    // last row: count=2 -> partial_cell_w = (800-24)/2 = 388 -> 384
    try expectP(&out, 3, 14, 8, 304, 384, 284, true);
    try expectP(&out, 4, 15, 272, 304, 384, 284, true);

    // Rigid mode keeps the column width in the partial row.
    var outr: List = .{};
    v.env.variant_idx = 0;
    tiling.compute(K_GRID, v, &outr);
    try expectP(&outr, 3, 14, 8, 304, 252, 284, true);
    try expectP(&outr, 4, 15, 272, 304, 252, 284, true);
}

// T24 - fibonacci spiral of four, counter-clockwise from top-left.
test "T24 fibonacci spiral" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    tiling.compute(K_FIB, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 4), out.len);
    // outerArea: (8,8) 784x584; win_dim=(784-8)/2=388 etc.
    try expectP(&out, 0, 11, 8, 8, 384, 580, true); // right
    try expectP(&out, 1, 12, 404, 8, 384, 284, true); // down
    try expectP(&out, 2, 13, 602, 304, 186, 284, true); // left
    try expectP(&out, 3, 14, 404, 304, 186, 284, true); // up, final rect
}

// T25 - fibonacci overflow: the spiral prefix stays on screen, the overflow
// tail is parked with focusedElse's pick raised in the leftover region.
// Trace (200x200, gap 8, border 2): five spiral splits fit before BOTH
// cursor dims must clear min_area (the branch checks both regardless of
// split direction), so windows 41..45 are placed normally and the overflow
// branch fires at index 5, raising focused window 75 into {128,104} 12x36
// shrunk from the 16x40 remainder.
test "T25 fibonacci overflow fallback" {
    var wins: [40]model.WindowId = undefined;
    for (&wins, 0..) |*w, i| w.* = @intCast(41 + i);
    var fx: Fixture = undefined;
    fx.init(&wins, .{ .x = 0, .y = 0, .width = 200, .height = 200 });
    defer fx.deinit();
    model.setFocus(&fx.m, 75); // deep in the overflow tail

    const v = tuned(&fx);
    var out: List = .{};
    tiling.compute(K_FIB, v, &out);

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

// T26 - leaf BSP splits the longer axis first, ties favour vertical.
test "T26 leaf balanced splits" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    tiling.compute(K_LEAF, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 4), out.len);
    // Root split vertical-ish? No: w(784) >= h(584) -> horizontal halves at x=8 / x=404,
    // then each half (388 < 584) stacks vertically: heights (584-8)/2 = 288 -> 284.
    try expectP(&out, 0, 11, 8, 8, 384, 284, true);
    try expectP(&out, 1, 12, 8, 304, 384, 284, true);
    try expectP(&out, 2, 13, 404, 8, 384, 284, true);
    try expectP(&out, 3, 14, 404, 304, 384, 284, true);
}

// T27 - scroll strip: caller pre-clamps offset; off-viewport slots parked.
test "T27 scroll strip and parking" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14, 15 }, stdWa());
    defer fx.deinit();

    // Caller duties (algo_scroll header): snap right for new windows, clamp.
    const slot_w = scroll_algo.slotWidth(800);
    const max_off = scroll_algo.maxOffset(5, slot_w, 800);
    try testing.expectEqual(@as(i32, 400), slot_w);
    try testing.expectEqual(@as(i32, 1200), max_off);
    try testing.expectEqual(@as(i32, 0), scroll_algo.maxOffset(2, slot_w, 800));

    const params = &fx.m.ws[0].params;
    params.viewport_offset = max_off;
    params.viewport_prev_count = 5;

    var out: List = .{};
    tiling.compute(K_SCROLL, tuned(&fx), &out);

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

// T28 - monocle raises focusedElse's pick, parks the rest; gaps variant insets.
test "T28 monocle gaps variant" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 }, stdWa());
    defer fx.deinit();
    model.setFocus(&fx.m, 12);

    var v = tuned(&fx);
    v.env.variant_idx = MONOCLE_GAP_VARIANT;

    var out: List = .{};
    tiling.compute(K_MONOCLE, v, &out);

    try testing.expectEqual(@as(usize, 3), out.len);
    // total_margin = doubledBorder(4) + inset*2 (16) = 20
    try expectP(&out, 0, 12, 8, 8, 780, 580, true);
    // Emission order: top first, then hidden in list order.
    try expectP(&out, 1, 11, 0, 0, 0, 0, false);
    try expectP(&out, 2, 13, 0, 0, 0, 0, false);

    // Without the gaps variant the inset is zero: full size minus borders only.
    v.env.variant_idx = 0;
    var out2: List = .{};
    tiling.compute(K_MONOCLE, v, &out2);
    try expectP(&out2, 0, 12, 0, 0, 796, 596, true);
}

// T29 - size hints are applied centrally at emit time (inc snap + centring).
test "T29 hints applied at emit" {
    var fx: Fixture = undefined;
    fx.init(&.{11}, stdWa());
    defer fx.deinit();

    // Mutate the model entry, then re-materialize the View's hint snapshot
    // exactly as sync.reconcile does per retile (B5: hints are frozen INTO
    // the View; a post-snapshot store change needs a fresh View).
    fx.m.store.getPtr(11).?.size_hints = .{ .inc_width = 100, .inc_height = 100 };
    fx.hint_buf[0] = fx.m.store.getPtr(11).?.size_hints;

    var out: List = .{};
    tiling.compute(K_MASTER, tuned(&fx), &out);

    // Raw master rect is {8,8,780,580}; snapped down to 700x500 and centred
    // back into its slot: dx = (780-700)/2 = 40, dy = 40.
    try expectP(&out, 0, 11, 48, 48, 700, 500, true);
}

// T30 - purity: compute twice yields identical output and mutates nothing.
test "T30 deterministic and non-mutating" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 }, stdWa());
    defer fx.deinit();

    const params_before = fx.m.ws[0].params;
    const focus_before = fx.m.focused;
    const store_count_before = fx.m.store.count();

    const v = tuned(&fx);
    var out_a: List = .{};
    tiling.compute(K_GRID, v, &out_a);
    var out_b: List = .{};
    tiling.compute(K_GRID, v, &out_b);

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

// T31 - empty order is a supported input for every layout: each
// compute must emit nothing and must not trap. Grid previously divided by
// calcGridShape(0).rows == 0 and monocle indexed order[len - 1].
test "T31 n=0 emits nothing across all layouts" {
    var fx: Fixture = undefined;
    fx.init(&.{}, stdWa());
    defer fx.deinit();

    const kinds = [_]u8{ K_MASTER, K_MONOCLE, K_FIB, K_GRID, K_LEAF, K_SCROLL };
    for (kinds) |kind| {
        var out: List = .{};
        tiling.compute(kind, tuned(&fx), &out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }
}

// T32 - scroll orphan keep-last invariant. compute() now clamps
// viewport_offset internally, so even a stale over-max offset is safe: the
// last window stays visible without requiring caller-side clamping.
//   - a stale over-max offset is clamped, last window stays visible;
//   - the documented caller clamp (pipeline.preReconcileDuties) is still
//     correct but no longer required for correctness;
//   - the shrink case (n drops, old offset exceeds the new max) clamps to 0.
test "T32 scroll orphan keep-last invariant" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 }, stdWa());
    defer fx.deinit();

    const slot_w = scroll_algo.slotWidth(800);
    const params = &fx.m.ws[0].params;

    // (1) Stale offset (from a hypothetical n=9 strip): clamped internally,
    // so the last window is visible (not all parked).
    const stale_off = scroll_algo.maxOffset(9, slot_w, 800);
    try testing.expect(stale_off > scroll_algo.maxOffset(4, slot_w, 800));
    params.viewport_offset = stale_off;
    params.viewport_prev_count = 4;
    var out_orphan: List = .{};
    tiling.compute(K_SCROLL, tuned(&fx), &out_orphan);
    try testing.expect(out_orphan.constSlice()[3].visible);

    // (2) Clamped per duty 2: the last window is at least flush-visible at
    // max offset (its slot's right edge reaches the screen edge).
    params.viewport_offset = @min(stale_off, scroll_algo.maxOffset(4, slot_w, 800));
    var out_last: List = .{};
    tiling.compute(K_SCROLL, tuned(&fx), &out_last);
    try testing.expect(out_last.constSlice()[3].visible);

    // (3) Shrink 4 -> 2: maxOffset(2) == 0 forces offset 0; both visible.
    params.viewport_offset = @min(stale_off, scroll_algo.maxOffset(2, slot_w, 800));
    var fx2: Fixture = undefined;
    fx2.init(&.{ 11, 12 }, stdWa());
    defer fx2.deinit();
    const params2 = &fx2.m.ws[0].params;
    params2.viewport_offset = 0;
    params2.viewport_prev_count = 2;
    var out_shrunk: List = .{};
    tiling.compute(K_SCROLL, tuned(&fx2), &out_shrunk);
    try testing.expect(out_shrunk.constSlice()[0].visible);
    try testing.expect(out_shrunk.constSlice()[1].visible);
}

// T33 - emission-order pin across all layouts with a shared non-empty
// fixture (companion to T31's empty-input pin): count and win-id
// sequence are frozen so any guard/reorder drift fails loudly. Geometry is
// already pinned per-layout by T19-T28.
test "T33 emission order pin across layouts" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 }, stdWa());
    defer fx.deinit();
    model.setFocus(&fx.m, 12);

    // Every input-order layout emits exactly the tiled_order sequence.
    const in_order_kinds = [_]u8{ K_MASTER, K_FIB, K_GRID, K_LEAF, K_SCROLL };
    for (in_order_kinds) |kind| {
        var out: List = .{};
        tiling.compute(kind, tuned(&fx), &out);
        try testing.expectEqual(@as(usize, 3), out.len);
        try testing.expectEqual(@as(model.WindowId, 11), out.constSlice()[0].win);
        try testing.expectEqual(@as(model.WindowId, 12), out.constSlice()[1].win);
        try testing.expectEqual(@as(model.WindowId, 13), out.constSlice()[2].win);
    }

    // Monocle emits the focused window first, then hidden in list order.
    var out_mono: List = .{};
    tiling.compute(K_MONOCLE, tuned(&fx), &out_mono);
    try testing.expectEqual(@as(usize, 3), out_mono.len);
    try testing.expectEqual(@as(model.WindowId, 12), out_mono.constSlice()[0].win);
    try testing.expectEqual(@as(model.WindowId, 11), out_mono.constSlice()[1].win);
    try testing.expectEqual(@as(model.WindowId, 13), out_mono.constSlice()[2].win);
}

// T34 - layout cycling is registry-driven and config-order (S20): the cycle
// ring is the config layout-name list resolved by name (unresolvable names
// are skipped); stepping wraps modulo the list. Replaces the removed
// model.cycleLayout (kind is now an opaque u8, resolved at seed time).
test "T34 layout cycle is config-order and wraps" {
    const names = [_][]const u8{ "master", "monocle", "grid", "fibonacci" };
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
