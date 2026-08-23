//! Layout engine tests (T19–T30, REARCHITECTURE_PLAN.md §7.4 step 5).
//!
//! Golden-value tests: expected rects are hand-computed from the legacy
//! algorithms' formulas (modules/*.zig), so any drift from BC parity fails
//! loudly. Fixture: windows registered on workspace 0 via model.register.

const std = @import("std");
const testing = std.testing;

const utils = @import("utils");
const model = @import("model");

const engine = @import("engine");
const scroll_algo = @import("scroll");

const List = engine.List;
const Placement = engine.Placement;

/// Standard test margins/min_dim used by most cases.
const gap = 8;
const border = 2;
const min_dim = 50;

fn stdWa() utils.Rect {
    return .{ .x = 0, .y = 0, .width = 800, .height = 600 };
}

const Fixture = struct {
    m: model.Model,
    hv: engine.HintsView,
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

    fn view(self: *Fixture) engine.View {
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
fn tuned(fx: *Fixture) engine.View {
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

// T19 — master, single window fills the work area minus gaps/borders.
test "T19 master single window" {
    var fx: Fixture = undefined;
    fx.init(&.{11}, stdWa());
    defer fx.deinit();

    var out: List = .{};
    engine.compute(.master, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 1), out.len);
    // master_inner_w = shrink(800, gap*2 + border*2 = 20) = 780
    // height: calcAvailableHeight(600,1) = 600 - (16 + 4) = 580
    try expectP(&out, 0, 11, 8, 8, 780, 580, true);
}

// T20 — master + stack, default 50/50 split.
test "T20 master two windows" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    engine.compute(.master, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 2), out.len);
    // master_w = round(800 * 0.5) = 400; inner = shrink(400, 12 + 4) = 384
    try expectP(&out, 0, 11, 8, 8, 384, 580, true);
    // stack_x = 400; x = 400 + gap/2(4) = 404; inner = shrink(400, 4+12) = 384
    try expectP(&out, 1, 12, 404, 8, 384, 580, true);
}

// T21 — master_on_right mirrors the columns.
test "T21 master on right" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12 }, stdWa());
    defer fx.deinit();

    var v = tuned(&fx);
    v.env.master_on_right = true;

    var out: List = .{};
    engine.compute(.master, v, &out);

    try testing.expectEqual(@as(usize, 2), out.len);
    // master_x = 800 - 400 = 400; x = 408
    try expectP(&out, 0, 11, 408, 8, 384, 580, true);
    // stack_x = 0; x = 4
    try expectP(&out, 1, 12, 4, 8, 384, 580, true);
}

// T22 — grid 2x2.
test "T22 grid 2x2" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    engine.compute(.grid, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 4), out.len);
    // cell_w = (800 - 3*8)/2 = 388 -> win_w 384; cell_h = (600-24)/2 = 288 -> 284
    try expectP(&out, 0, 11, 8, 8, 384, 284, true);
    try expectP(&out, 1, 12, 404, 8, 384, 284, true);
    try expectP(&out, 2, 13, 8, 304, 384, 284, true);
    try expectP(&out, 3, 14, 404, 304, 384, 284, true);
}

// T23 — grid relaxed widens the partial last row (verbatim legacy quirk:
// x spacing stays column-based, so wide partial cells overlap their row).
test "T23 grid relaxed partial row" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14, 15 }, stdWa());
    defer fx.deinit();

    var v = tuned(&fx);
    v.env.grid_relaxed = true;

    var out: List = .{};
    engine.compute(.grid, v, &out);

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
    v.env.grid_relaxed = false;
    engine.compute(.grid, v, &outr);
    try expectP(&outr, 3, 14, 8, 304, 252, 284, true);
    try expectP(&outr, 4, 15, 272, 304, 252, 284, true);
}

// T24 — fibonacci spiral of four, counter-clockwise from top-left.
test "T24 fibonacci spiral" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    engine.compute(.fibonacci, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 4), out.len);
    // outerArea: (8,8) 784x584; win_dim=(784-8)/2=388 etc.
    try expectP(&out, 0, 11, 8, 8, 384, 580, true); // right
    try expectP(&out, 1, 12, 404, 8, 384, 284, true); // down
    try expectP(&out, 2, 13, 602, 304, 186, 284, true); // left
    try expectP(&out, 3, 14, 404, 304, 186, 284, true); // up, final rect
}

// T25 — fibonacci overflow: the spiral prefix stays on screen, the overflow
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
    engine.compute(.fibonacci, v, &out);

    try testing.expectEqual(@as(usize, 40), out.len);
    var visible_count: usize = 0;
    var raised_found = false;
    for (out.constSlice()) |p| {
        if (p.visible) {
            visible_count += 1;
            if (p.win == 75) raised_found = true;
        } else {
            try testing.expectEqual(engine.parked_rect.x, p.rect.x);
            try testing.expectEqual(engine.parked_rect.width, p.rect.width);
        }
    }
    try testing.expectEqual(@as(usize, 6), visible_count);
    try testing.expect(raised_found);
    // The raised window sits in the leftover region, hint-free here.
    try expectP(&out, 5, 75, 128, 104, 12, 36, true);
}

// T26 — leaf BSP splits the longer axis first, ties favour vertical.
test "T26 leaf balanced splits" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13, 14 }, stdWa());
    defer fx.deinit();

    var out: List = .{};
    engine.compute(.leaf, tuned(&fx), &out);

    try testing.expectEqual(@as(usize, 4), out.len);
    // Root split vertical-ish? No: w(784) >= h(584) -> horizontal halves at x=8 / x=404,
    // then each half (388 < 584) stacks vertically: heights (584-8)/2 = 288 -> 284.
    try expectP(&out, 0, 11, 8, 8, 384, 284, true);
    try expectP(&out, 1, 12, 8, 304, 384, 284, true);
    try expectP(&out, 2, 13, 404, 8, 384, 284, true);
    try expectP(&out, 3, 14, 404, 304, 384, 284, true);
}

// T27 — scroll strip: caller pre-clamps offset; off-viewport slots parked.
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
    params.scroll_offset = max_off;
    params.scroll_prev_count = 5;

    var out: List = .{};
    engine.compute(.scroll, tuned(&fx), &out);

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

// T28 — monocle raises focusedElse's pick, parks the rest; gaps variant insets.
test "T28 monocle gaps variant" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 }, stdWa());
    defer fx.deinit();
    model.setFocus(&fx.m, 12);

    var v = tuned(&fx);
    v.env.monocle_gaps = true;

    var out: List = .{};
    engine.compute(.monocle, v, &out);

    try testing.expectEqual(@as(usize, 3), out.len);
    // total_margin = doubledBorder(4) + inset*2 (16) = 20
    try expectP(&out, 0, 12, 8, 8, 780, 580, true);
    // Emission order: top first, then hidden in list order.
    try expectP(&out, 1, 11, 0, 0, 0, 0, false);
    try expectP(&out, 2, 13, 0, 0, 0, 0, false);

    // Without the gaps variant the inset is zero: full size minus borders only.
    v.env.monocle_gaps = false;
    var out2: List = .{};
    engine.compute(.monocle, v, &out2);
    try expectP(&out2, 0, 12, 0, 0, 796, 596, true);
}

// T29 — size hints are applied centrally at emit time (inc snap + centring).
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
    engine.compute(.master, tuned(&fx), &out);

    // Raw master rect is {8,8,780,580}; snapped down to 700x500 and centred
    // back into its slot: dx = (780-700)/2 = 40, dy = 40.
    try expectP(&out, 0, 11, 48, 48, 700, 500, true);
}

// T30 — purity: compute twice yields identical output and mutates nothing.
test "T30 deterministic and non-mutating" {
    var fx: Fixture = undefined;
    fx.init(&.{ 11, 12, 13 }, stdWa());
    defer fx.deinit();

    const params_before = fx.m.ws[0].params;
    const focus_before = fx.m.focused;
    const store_count_before = fx.m.store.count();

    const v = tuned(&fx);
    var out_a: List = .{};
    engine.compute(.grid, v, &out_a);
    var out_b: List = .{};
    engine.compute(.grid, v, &out_b);

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
