//! Layout engine tests.
//!
//! Golden-value tests: expected rects are hand-computed from the layout
//! modules' formulas (modules/*.zig), so any drift fails loudly. Fixture:
//! windows registered on workspace 0 via model.register.

// Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: tiling

const std = @import("std");
const testing = std.testing;

const model = @import("model");
const helpers = @import("helpers");
const focus = @import("focus");
const window_state_ops = @import("window_state_ops");

const build_options = @import("build_options");
const tiling = @import("tiling");
const contract = @import("tiling_contract");
const config = @import("config");
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
const Placement = contract.Placement;

/// Registry indices for each layout, resolved by name (instead of a closed
/// enum) so the tests stay robust to registry ordering. Computed at
/// compile time from the build-generated module registry.
/// Panic message shared by the name→index constants below: a missing layout
/// here is a registry bug, not a test condition, so a silent 0 would corrupt
/// every golden rect (layout 0 is master).
const kLayoutMissing = "tiling test: registry missing layout";
const K_MASTER: u8 = tiling.layoutByName("master") orelse @panic(kLayoutMissing);
const K_MONOCLE: u8 = tiling.layoutByName("monocle") orelse @panic(kLayoutMissing);
const K_GRID: u8 = tiling.layoutByName("grid") orelse @panic(kLayoutMissing);
const K_FIB: u8 = tiling.layoutByName("fibonacci") orelse @panic(kLayoutMissing);
const K_LEAF: u8 = tiling.layoutByName("leaf") orelse @panic(kLayoutMissing);
const K_SCROLL: u8 = tiling.layoutByName("scroll") orelse @panic(kLayoutMissing);

/// The ordinal of `vname` in layout `kind`'s own variant table, read back
/// through that module's `variant_parse`. A hardcoded ordinal with the table
/// spelled out in a comment rots: a row inserted above "relaxed" moves the
/// real one and leaves the test exercising the RIGID path while asserting
/// RELAXED golden rects. Asking the module is the only version that cannot.
fn variantOrdinal(kind: u8, vname: []const u8) u8 {
    const parse = contract.tiling_mods[kind].variant_parse orelse
        @panic("tiling test: layout has no variant table");
    return parse(vname) orelse @panic("tiling test: unknown variant name");
}

const GRID_RELAX_VARIANT: u8 = variantOrdinal(K_GRID, "relaxed");
const MONOCLE_GAP_VARIANT: u8 = variantOrdinal(K_MONOCLE, "gaps");

pub const Fixture = struct {
    m: model.Model,
    hv: contract.HintsView,
    hint_buf: [model.store_capacity]model.SizeHints = undefined,
    wa: model.Rect,

    pub fn init(self: *Fixture, wins: []const model.WindowId) !void {
        try self.initAt(wins, helpers.std_wa);
    }

    /// init with an explicit work area, for the non-standard-geometry cases.
    pub fn initAt(self: *Fixture, wins: []const model.WindowId, wa: model.Rect) !void {
        self.* = .{
            .m = .{},
            .hv = undefined,
            .wa = wa,
        };
        for (wins) |w| try window_state_ops.register(&self.m, w, null);
        // Materialize hints aligned index-for-index with the order slice.
        const s0 = &self.m.ws[0];
        for (s0.tiled_order.constSlice(), 0..) |w, i| {
            self.hint_buf[i] = if (self.m.store.get(w)) |e| e.size_hints else .{};
        }
        const n = s0.tiled_order.len;
        self.hv = self.hint_buf[0..n];
    }

    pub fn view(self: *Fixture) tiling.View {
        const s = &self.m.ws[0];
        return .{
            .order = s.tiled_order.constSlice(),
            .params = &s.params,
            .workarea = self.wa,
            .hints = self.hv,
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

/// One compute into a fresh list (a BoundedList, so returning by value
/// is allocation-free).
pub fn computeOf(kind: u8, v: tiling.View) List {
    var list: List = .{};
    tiling.compute(kind, &v, &list);
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
    try fx.init(&.{11});

    const out = computeOf(K_MASTER, tuned(&fx));

    try testing.expectEqual(@as(usize, 1), out.len);
    // master_inner_w = shrink(800, gap*2 + border*2 = 20) = 780
    // height: calcAvailableHeight(600,1) = 600 - (16 + 4) = 580
    try expectP(&out, 0, 11, 8, 8, 780, 580, true);
}

// master + stack, default 50/50 split.
test "master two windows" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12 });

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
    try fx.init(&.{ 11, 12 });

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
    try fx.init(&.{ 11, 12, 13, 14 });

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
// the wide relaxed cells do not overlap (the rigid row's narrow column stride
// would make neighbouring wide cells overlap each other).
test "grid relaxed partial row" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13, 14, 15 });

    fx.m.ws[0].params.variant_idx = GRID_RELAX_VARIANT;
    const v = tuned(&fx);

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
    fx.m.ws[0].params.variant_idx = 0;
    const outr = computeOf(K_GRID, v);
    try expectP(&outr, 3, 14, 8, 304, 252, 284, true);
    try expectP(&outr, 4, 15, 272, 304, 252, 284, true);
}

// fibonacci spiral of four, clockwise from top-left (screen coords are y-down).
test "fibonacci spiral" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13, 14 });

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
    try fx.initAt(&wins, .{ .x = 0, .y = 0, .width = 200, .height = 200 });

    focus.setFocus(&fx.m, 75); // deep in the overflow tail

    const v = tuned(&fx);
    const out = computeOf(K_FIB, v);

    try testing.expectEqual(@as(usize, 40), out.len);
    var visible_count: usize = 0;
    var raised: ?Placement = null;
    for (out.constSlice()) |p| {
        if (p.visible) {
            visible_count += 1;
            if (p.win == 75) raised = p;
        } else {
            try testing.expectEqual(contract.parked_rect.x, p.rect.x);
            try testing.expectEqual(contract.parked_rect.width, p.rect.width);
        }
    }
    try testing.expectEqual(@as(usize, 6), visible_count);
    // The raised window sits in the leftover region, hint-free here.
    //
    // Addressed BY WINDOW, not by index: the slot that holds the raised
    // window is a function of the traversal, not of the layout. The rect is
    // the golden value; the slot it lands in is the engine's business.
    const r = raised orelse return error.RaisedWindowMissing;
    try testing.expectEqual(@as(i32, 128), @as(i32, r.rect.x));
    try testing.expectEqual(@as(i32, 104), @as(i32, r.rect.y));
    try testing.expectEqual(@as(u16, 12), r.rect.width);
    try testing.expectEqual(@as(u16, 36), r.rect.height);
}

// leaf BSP splits the longer axis first, ties favour vertical.
test "leaf balanced splits" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13, 14 });

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
    try fx.init(&.{ 11, 12, 13, 14, 15 });

    // Caller duties: snap right for new windows, cap the offset at the strip.
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
    try fx.init(&.{ 11, 12, 13 });

    focus.setFocus(&fx.m, 12);

    fx.m.ws[0].params.variant_idx = MONOCLE_GAP_VARIANT;
    const v = tuned(&fx);

    const out = computeOf(K_MONOCLE, v);

    try testing.expectEqual(@as(usize, 3), out.len);
    // Emission order is View.order for every layout, monocle included: the
    // focused window's POSITION in the list does not change where it is
    // emitted. Visibility is the separate axis -- 12 is focused, so it holds
    // the rect and its siblings are parked.
    // total_margin = model.doubledBorder(4) + inset*2 (16) = 20
    try expectP(&out, 0, 11, 0, 0, 0, 0, false);
    try expectP(&out, 1, 12, 8, 8, 780, 580, true);
    try expectP(&out, 2, 13, 0, 0, 0, 0, false);

    // Without the gaps variant the inset is zero: full size minus borders only.
    // Same View.order emission, so the focused window is still at index 1.
    fx.m.ws[0].params.variant_idx = 0;
    const out2 = computeOf(K_MONOCLE, v);
    try expectP(&out2, 0, 11, 0, 0, 0, 0, false);
    try expectP(&out2, 1, 12, 0, 0, 796, 596, true);
    try expectP(&out2, 2, 13, 0, 0, 0, 0, false);
}

// size hints are applied centrally at emit time (inc snap + centring).
test "hints applied at emit" {
    var fx: Fixture = undefined;
    try fx.init(&.{11});

    // Mutate the model entry, then re-materialize the View's hint snapshot
    // exactly as reconcile.run does per retile (hints are frozen INTO
    // the View; a post-snapshot store change needs a fresh View).
    fx.m.store.getPtr(11).?.size_hints = .{ .inc_width = 100, .inc_height = 100 };
    fx.hint_buf[0] = fx.m.store.getPtr(11).?.size_hints;

    const out = computeOf(K_MASTER, tuned(&fx));

    // Raw master rect is {8,8,780,580}; snapped down to 700x500 and centred
    // back into its slot: dx = (780-700)/2 = 40, dy = 40. Zero base (no
    // PBaseSize/PMinSize): the snap anchors at 0, raw multiples of inc.
    try expectP(&out, 0, 11, 48, 48, 700, 500, true);
}

// ICCCM 4.1.2.3: valid sizes are base + N*inc, so the increment snap anchors
// at PBaseSize, NOT at 0. A terminal declaring base 10x10 with 20x20 cells
// must land on the client's grid; snapping from 0 would leave a partial cell
// at the slot's edge (the very thing the snap exists to prevent).
test "applyHints snaps increments from the declared base" {
    const rect: model.Rect = .{ .x = 8, .y = 8, .width = 781, .height = 583 };
    const h: model.SizeHints = .{
        .base_width = 10,
        .base_height = 10,
        .inc_width = 20,
        .inc_height = 20,
    };
    // w: 10 + (781-10)/20*20 = 770; h: 10 + (583-10)/20*20 = 570.
    // Centred: dx = (781-770)/2 = 5, dy = (583-570)/2 = 6.
    try testing.expectEqual(
        model.Rect{ .x = 13, .y = 14, .width = 770, .height = 570 },
        tiling.applyHints(rect, h),
    );
}

// When PBaseSize is absent the snap falls back to the declared minimum
// (the standard's own fallback). The minimum anchors the GRID; it is not
// enforced as a floor -- a slot below it still passes through shrink-only.
test "applyHints falls back to the declared minimum as snap base" {
    const rect: model.Rect = .{ .x = 0, .y = 0, .width = 781, .height = 583 };
    const h: model.SizeHints = .{
        .min_width = 10,
        .min_height = 10,
        .inc_width = 20,
        .inc_height = 20,
    };
    try testing.expectEqual(
        model.Rect{ .x = 5, .y = 6, .width = 770, .height = 570 },
        tiling.applyHints(rect, h),
    );
    // A slot at or below the base snaps to nothing and passes through:
    // shrink-only, never a grow-up to the grid.
    const small: model.Rect = .{ .x = 0, .y = 0, .width = 8, .height = 8 };
    try testing.expectEqual(small, tiling.applyHints(small, h));
}

// Tiling deliberately does not ENFORCE PMinSize/PBaseSize as floors: the
// layout engine owns all tiled dimensions, so a declared minimum would pin
// the rect and block mod_h/mod_l. (The minimum still serves as the ICCCM
// increment-snap base when PBaseSize is absent -- see the test above --
// which anchors the grid without pinning the result.) The same hints ARE
// honoured by the floating drag-resize floor (floating.sizeHintLimits);
// this guards against min enforcement leaking into the shared hint path.
test "applyHints ignores declared minimums" {
    const rect: model.Rect = .{ .x = 8, .y = 8, .width = 780, .height = 580 };
    try testing.expectEqual(rect, tiling.applyHints(rect, .{ .min_width = 1000, .min_height = 1000 }));
}

// Horizontal geometry enforcement on the master-slave axis: a slave
// that declares a small max_width (e.g. a dialog) shrinks the stack column to
// its natural width and the master absorbs the freed horizontal space, so the
// dialog does not leave a dead gap beside it. Mirrors tileColumn's vertical
// max_height capping, on the width axis.
test "master swallows freed space from a narrow dialog slave" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12 });

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

// Water-fill goldens (fillHeights): a window whose max_height sits at or
// below its fair share is PINNED to that height and its surplus redistributes
// across the rest. Three windows, no stack (primary_count = n), so the whole
// work area is one master column: avail = 600 - (gap 8 + 3*12) = 556.
// Pin pass (zero boost, fair = rem/3): 80 <= 185 pins, then 120 <= (476/2 =
// 238) pins; the uncapped middle takes the leftover 356. Heights sum to
// avail, so pad_top is 0.
test "master column water-fill pins max_height and redistributes the slack" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13 });
    fx.m.ws[0].params.primary_count = 3;

    fx.m.store.getPtr(11).?.size_hints = .{ .max_height = 80 };
    fx.hint_buf[0] = fx.m.store.getPtr(11).?.size_hints;
    fx.m.store.getPtr(13).?.size_hints = .{ .max_height = 120 };
    fx.hint_buf[2] = fx.m.store.getPtr(13).?.size_hints;

    const out = computeOf(K_MASTER, tuned(&fx));

    // master full width: inner = shrink(800, 2*gap 16 + 2*border 4) = 780.
    // Heights 80 / 356 / 120 at row pitch 12 from y = 8.
    try expectP(&out, 0, 11, 8, 8, 780, 80, true);
    try expectP(&out, 1, 12, 8, 100, 780, 356, true);
    try expectP(&out, 2, 13, 8, 468, 780, 120, true);
}

// StackBoost goldens: secondary_balance boosts the FIRST stack slot (positive)
// or the LAST (negative) via cumulative rounded boundaries. Stack column
// avail = 556, rem_weight = 2 + boost = 3. balance=-1: boundaries
// round(568/3)=189 then 568 -> heights 189/379 (the bottom slot gets the
// larger share); balance=+1 mirrors them to 379/189. (avail here is the
// column's 568 = 600 - gap 8 - 2*12.)
test "stack column balance boosts the top or bottom slot" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13 });

    // Master column: count 1, avail 580 -> full-height pane.
    // Stack: x = master_w 400 + seam 4, inner = shrink(400, 16) = 384.
    fx.m.ws[0].params.secondary_balance = -1.0;
    var out = computeOf(K_MASTER, tuned(&fx));
    try expectP(&out, 0, 11, 8, 8, 384, 580, true);
    try expectP(&out, 1, 12, 404, 8, 384, 189, true);
    try expectP(&out, 2, 13, 404, 209, 384, 379, true);

    fx.m.ws[0].params.secondary_balance = 1.0;
    out = computeOf(K_MASTER, tuned(&fx));
    try expectP(&out, 0, 11, 8, 8, 384, 580, true);
    try expectP(&out, 1, 12, 404, 8, 384, 379, true);
    try expectP(&out, 2, 13, 404, 399, 384, 189, true);
}

// The primary_width split off 0.5: master pane = round(800 * width), stack
// takes the rest, each inset by the seam/edge margins. 3 windows, primary
// count 1 -> one master window + a two-high stack column (even split of the
// stack's 556: 278/278? -- no: the stack's avail is 600-(8+2*12) = 568, and
// the zero-boost even split is 284/284).
test "primary_width splits the master pane at 0.25 and 0.75" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13 });

    fx.m.ws[0].params.primary_width = 0.25;
    var out = computeOf(K_MASTER, tuned(&fx));
    // master_w = 200, inner = shrink(200, 16) = 184; stack pane 600,
    // inner = 584 at x = 200 + 4.
    try expectP(&out, 0, 11, 8, 8, 184, 580, true);
    try expectP(&out, 1, 12, 204, 8, 584, 284, true);
    try expectP(&out, 2, 13, 204, 304, 584, 284, true);

    fx.m.ws[0].params.primary_width = 0.75;
    out = computeOf(K_MASTER, tuned(&fx));
    // master_w = 600, inner = 584; stack pane 200, inner = 184 at x = 604.
    try expectP(&out, 0, 11, 8, 8, 584, 580, true);
    try expectP(&out, 1, 12, 604, 8, 184, 284, true);
    try expectP(&out, 2, 13, 604, 304, 184, 284, true);
}

// purity: compute twice yields identical output and mutates nothing.
test "deterministic and non-mutating" {
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13 });

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
// compute must emit nothing and must not trap. Otherwise grid divides by
// calcGridShape(0).rows == 0 and monocle indexes order[len - 1].
test "n=0 emits nothing across all layouts" {
    var fx: Fixture = undefined;
    try fx.init(&.{});

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

// scroll orphan keep-last invariant. compute() clamps
// viewport_offset internally, so even a stale over-max offset is safe: the
// last window stays visible without requiring caller-side clamping.
//   - a stale over-max offset is clamped, last window stays visible;
//   - the documented caller clamp (pipeline.preReconcileDuties) is still
//     correct but not required for correctness;
//   - the shrink case (n drops, old offset exceeds the new max) clamps to 0.
test "scroll orphan keep-last invariant" {
    if (!build_options.has_layout_scroll) return error.SkipZigTest;
    var fx: Fixture = undefined;
    try fx.init(&.{ 11, 12, 13, 14 });

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
    try fx2.init(&.{ 11, 12 });

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
    try fx.init(&.{ 11, 12, 13 });

    focus.setFocus(&fx.m, 12);

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

    // Monocle obeys the same positional contract as the other five: emission
    // follows View.order, so the focused window (12) is emitted in its own
    // slot rather than hoisted to the front.
    const out_mono = computeOf(K_MONOCLE, tuned(&fx));
    try testing.expectEqual(@as(usize, 3), out_mono.len);
    try testing.expectEqual(@as(model.WindowId, 11), out_mono.constSlice()[0].win);
    try testing.expectEqual(@as(model.WindowId, 12), out_mono.constSlice()[1].win);
    try testing.expectEqual(@as(model.WindowId, 13), out_mono.constSlice()[2].win);
}

// layout cycling is registry-driven and config-order: the cycle
// ring is the config layout-name list resolved by name (unresolvable names
// are skipped); stepping wraps modulo the list. Kind is an opaque u8,
// resolved at seed time.
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

// A repeated ring entry cannot trap the cycle: value-equality search would
// otherwise bounce between the two rows of the duplicated kind and never
// reach the layouts past it. cycleKind de-duplicates the resolved indices.
test "layout cycle skips duplicate ring entries" {
    const names = [_][]const u8{ "master", "monocle", "master", "grid" };
    var k = K_MASTER;
    k = tiling.cycleKind(k, 1, &names);
    try testing.expectEqual(K_MONOCLE, k);
    // The duplicate "master" row is skipped: the next step lands on grid.
    k = tiling.cycleKind(k, 1, &names);
    try testing.expectEqual(K_GRID, k);
    // ...and one more wraps back to the (single) master entry.
    k = tiling.cycleKind(k, 1, &names);
    try testing.expectEqual(K_MASTER, k);
    // Backward from master skips the duplicate too and lands on grid.
    k = tiling.cycleKind(K_MASTER, -1, &names);
    try testing.expectEqual(K_GRID, k);
}

/// The shared placement-invariant checker. Every layout's own tests pin
/// GOLDEN rects, which is exactly the blind spot: a golden test passes when a
/// layout emits the right numbers for the right window and nothing at all says
/// anything about the properties that must hold for EVERY input. These five
/// are the ones a golden cannot see:
///
///   1. count     -- one placement per ordered window (tiling.compute asserts
///                   this too, but a skipped window there is a ReleaseFast no-op);
///   2. win set   -- the same windows, each exactly once, in order;
///   3. in bounds -- no rect escapes the work area (a negative or overflowing
///                   rect is a real screen bug the server will not report);
///   4. area      -- a VISIBLE placement has positive area (zero-area is not
///                   "small", it is unmappable);
///   5. overlap   -- two VISIBLE placements do not overlap: the layouts' one
///                   shared failure mode, and the one a per-layout golden is
///                   least likely to catch because each golden only looks at
///                   its own windows.
pub fn assertInvariants(out: *const List, v: tiling.View, wa: model.Rect) !void {
    const order = v.order;
    try testing.expectEqual(order.len, out.len);
    const ps = out.constSlice();
    for (ps, order) |p, win| try testing.expectEqual(win, p.win);
    for (ps, 0..) |p, i| {
        const r = p.rect;
        if (!p.visible) continue;
        try testing.expect(r.width > 0);
        try testing.expect(r.height > 0);
        const x0 = @as(i32, r.x);
        const y0 = @as(i32, r.y);
        const x1 = x0 + @as(i32, r.width);
        const y1 = y0 + @as(i32, r.height);
        try testing.expect(x0 >= @as(i32, wa.x));
        try testing.expect(y0 >= @as(i32, wa.y));
        try testing.expect(x1 <= @as(i32, wa.x) + @as(i32, wa.width));
        try testing.expect(y1 <= @as(i32, wa.y) + @as(i32, wa.height));
        for (ps[0..i]) |q| {
            if (!q.visible) continue;
            const qx0 = @as(i32, q.rect.x);
            const qy0 = @as(i32, q.rect.y);
            const qx1 = qx0 + @as(i32, q.rect.width);
            const qy1 = qy0 + @as(i32, q.rect.height);
            const disjoint = x1 <= qx0 or qx1 <= x0 or y1 <= qy0 or qy1 <= y0;
            try testing.expect(disjoint);
        }
    }
}

/// The raw-hook coverage check: run a module's own `compute` DIRECTLY
/// (bypassing the engine's emitInOrder repair) and require exactly one
/// placement per window. A dropped or duplicated window is repaired into a
/// parked placement by the engine, so the repaired output cannot see it --
/// and `tiling.compute`'s matching debug assert is compiled out of
/// ReleaseFast test builds. This carries the module-side contract check into
/// every optimize mode the sweep may run under.
fn assertRawCoverage(lm: contract.Layout, v: tiling.View) !void {
    // The engine guards the empty order BEFORE any module sees it (grid's
    // paneCell divides by count, monocle indexes the tail), so the raw-hook
    // contract starts at n = 1.
    if (v.order.len == 0) return;
    const f = lm.compute orelse return;
    var raw: List = .{};
    f(&v, &raw);
    const ps = raw.constSlice();
    try testing.expectEqual(v.order.len, ps.len);
    for (v.order) |win| {
        var seen: usize = 0;
        for (ps) |p| {
            if (p.win == win) seen += 1;
        }
        try testing.expectEqual(@as(usize, 1), seen);
    }
}

// The sweep: every registered layout x every variant x n over 0..12 (all)
// and 14..64 (stride 2, up to `model.max_tiled_per_ws`), across five work
// areas (incl. the degenerate 0x0 and a smaller-than-margins one) and five
// environments (the standard gap-heavy one, a border-dominated one that
// exercises the fibonacci fence at 2*border >= gap, a collapsed min_dim
// floor, an odd gap for the half-gap rounding paths, and the standard one
// mirrored by Env.primary_on_right).
test "Every layout satisfies the placement invariants at every size" {
    if (!build_options.has_tiling) return error.SkipZigTest;
    // The workarea injections for the invariant sweep, extended beyond the
    // origin case: a side-claimed origin (`x=40, y=50`) catches the missing
    // wa.x placements; the 120x120 hostile one keeps the clamps turning on;
    // the fully degenerate 0x0 and the 16x16 (smaller than 2*(gap+border) =
    // 20px of margins, so the inner area is negative) pin that a layout
    // degrades to hidden placements instead of emitting out-of-bounds or
    // zero-area rects.
    const areas = [_]model.Rect{
        helpers.std_wa,
        .{ .x = 0, .y = 0, .width = 120, .height = 120 },
        .{ .x = 40, .y = 50, .width = 800, .height = 600 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .{ .x = 7, .y = 9, .width = 16, .height = 16 },
        // Negative origin: the waX/waY floors keep placements non-negative,
        // and waWidth/waHeight must shrink to match or the far edge
        // overshoots (found by the P1-24 fuzzer, monocle at wa.y=-2).
        .{ .x = -5, .y = -5, .width = 800, .height = 600 },
    };
    // The environments the layout modules have to survive: the standard
    // gap-heavy one; a border-dominated one (5px border > 2px gap) that
    // exercises the fibonacci fence at 2*border >= gap; a collapsed min_dim
    // floor (every cell may take any size, so clamps stop protecting and the
    // rounding has to stand alone); an ODD gap (layouts that halve the gap --
    // grid/leaf gutters -- round, and an odd gap is the only way the two
    // sides of a gutter can disagree); and the standard one mirrored by
    // primary_on_right.
    const envs = [_]contract.Env{
        helpers.std_env,
        .{ .margins = .{ .gap = 2, .border = 5 }, .min_dim = 50 },
        .{ .margins = .{ .gap = 8, .border = 2 }, .min_dim = 1 },
        .{ .margins = .{ .gap = 1, .border = 2 }, .min_dim = 50 },
        .{ .margins = helpers.std_env.margins, .min_dim = helpers.std_env.min_dim, .primary_on_right = true },
    };
    // n: every size 0..12, then stride 2 up to max_tiled_per_ws (64) --
    // the full range costs one extra loop level and still finishes fast,
    // while small-n (0..3) keeps the degenerate-count paths dense.
    const n_list = n: {
        var l: [39]usize = undefined;
        var idx: usize = 0;
        var i: usize = 0;
        while (i <= 12) : (i += 1) {
            l[idx] = i;
            idx += 1;
        }
        i = 14;
        while (i <= 64) : (i += 2) {
            l[idx] = i;
            idx += 1;
        }
        break :n l;
    };
    var kinds: usize = 0;
    for (contract.tiling_mods, 0..) |lm, kind| {
        if (lm.compute == null) continue;
        kinds += 1;
        const vcount: usize = if (lm.variant_count == 0) 1 else lm.variant_count;
        for (0..vcount) |vi| {
            for (n_list) |n| {
                var wins: [64]model.WindowId = undefined;
                for (wins[0..n], 0..) |*w, i| w.* = @intCast(100 + i);
                var fx: Fixture = undefined;
                for (areas) |wa| {
                    for (envs) |env| {
                        fx.initAt(wins[0..n], wa) catch |err| return err;
                        // The variant lives in the model (View.params is a const
                        // handle to it), so seed it before building the View.
                        fx.m.ws[0].params.variant_idx = @intCast(vi);
                        // A primary_count that can exceed the master pane's fit
                        // at the sweep sizes, so the master-column cap actually
                        // fires.
                        fx.m.ws[0].params.primary_count = 12;
                        var v = fx.view();
                        v.env = env;
                        // The module's OWN output, pre-repair: the invariant
                        // pass below runs on the engine-repaired plan, which
                        // cannot show a dropped or duplicated window.
                        try assertRawCoverage(lm, v);
                        const out = computeOf(@intCast(kind), v);
                        assertInvariants(&out, v, wa) catch |err| {
                            // Dump both sequences: an order mismatch is only
                            // actionable next to the two lists that disagree.
                            std.debug.print("FAIL {s} variant={d} n={d} wa=({d},{d}) {d}x{d} env=(gap={d},border={d},min={d},right={any}): {s}\n", .{
                                lm.name, vi, n, wa.x, wa.y, wa.width, wa.height, env.margins.gap, env.margins.border, env.min_dim, env.primary_on_right, @errorName(err),
                            });
                            std.debug.print("  order   :", .{});
                            for (v.order) |w| std.debug.print(" {d}", .{w});
                            std.debug.print("\n  emitted :", .{});
                            for (out.constSlice()) |p| std.debug.print(" {d}", .{p.win});
                            std.debug.print("\n  rects   :", .{});
                            for (out.constSlice()) |p|
                                std.debug.print(" ({d},{d} {d}x{d}{s})", .{
                                    p.rect.x,                         p.rect.y, p.rect.width, p.rect.height,
                                    if (p.visible) "" else " hidden",
                                });
                            std.debug.print("\n", .{});
                            return err;
                        };
                    }
                }
            }
        }
    }
    try testing.expect(kinds >= 6); // the six layouts the tree ships
}

// P1-22: the tuning axes that split/weight the panes rather than the frame --
// Env.primary_on_right and params.{primary_width, secondary_balance} -- swept
// as their own cross product over a reduced n/area set. The main sweep pins
// them at their defaults, which is exactly where a bug in the 0.05/0.95 split
// or a balance-pinned water fill would hide: every axis combination gets the
// same five properties, and the degenerate 0x0 workarea stays in the set so
// the axes cannot turn a hidden placement into an out-of-bounds one.
test "Placement invariants hold across the primary/secondary param axes" {
    if (!build_options.has_tiling) return error.SkipZigTest;
    const areas = [_]model.Rect{
        helpers.std_wa,
        .{ .x = 0, .y = 0, .width = 120, .height = 120 },
        .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    };
    // Sizes chosen around the split arithmetic: empty, single (no split at
    // all), the 2-window threshold, mid-stack, past the master-column cap
    // fit, and the full max_tiled_per_ws.
    const ns = [_]usize{ 0, 1, 2, 3, 6, 12, 64 };
    const widths = [_]f32{ 0.05, 0.5, 0.95 };
    const balances = [_]f32{ -1.0, 0.0, 1.0 };
    const rights = [_]bool{ false, true };
    var kinds: usize = 0;
    for (contract.tiling_mods, 0..) |lm, kind| {
        if (lm.compute == null) continue;
        kinds += 1;
        for (rights) |right| {
            for (balances) |bal| {
                for (widths) |pw| {
                    for (ns) |n| {
                        var wins: [64]model.WindowId = undefined;
                        for (wins[0..n], 0..) |*w, i| w.* = @intCast(100 + i);
                        var fx: Fixture = undefined;
                        for (areas) |wa| {
                            fx.initAt(wins[0..n], wa) catch |err| return err;
                            fx.m.ws[0].params.primary_count = 12;
                            fx.m.ws[0].params.primary_width = pw;
                            fx.m.ws[0].params.secondary_balance = bal;
                            var v = fx.view();
                            v.env = .{
                                .margins = helpers.std_env.margins,
                                .min_dim = helpers.std_env.min_dim,
                                .primary_on_right = right,
                            };
                            const out = computeOf(@intCast(kind), v);
                            assertInvariants(&out, v, wa) catch |err| {
                                std.debug.print("FAIL-AXES {s} n={d} wa=({d},{d}) {d}x{d} width={d} balance={d} right={any}: {s}\n", .{
                                    lm.name, n, wa.x, wa.y, wa.width, wa.height, pw, bal, right, @errorName(err),
                                });
                                std.debug.print("  order   :", .{});
                                for (v.order) |w| std.debug.print(" {d}", .{w});
                                std.debug.print("\n  emitted :", .{});
                                for (out.constSlice()) |p| std.debug.print(" {d}", .{p.win});
                                std.debug.print("\n  rects   :", .{});
                                for (out.constSlice()) |p|
                                    std.debug.print(" ({d},{d} {d}x{d}{s})", .{
                                        p.rect.x,                         p.rect.y, p.rect.width, p.rect.height,
                                        if (p.visible) "" else " hidden",
                                    });
                                std.debug.print("\n", .{});
                                return err;
                            };
                        }
                    }
                }
            }
        }
    }
    try testing.expect(kinds >= 6); // the six layouts the tree ships
}

// The config-side layout-name grammar and the layout registry are kept in sync
// here, in the test, because neither side may import the other: config sits
// below tiling in the layer order. Both directions matter and each fails
// silently. A spelling the registry no longer has is dropped from the
// parse, so a user's config entry stops working with no diagnostic. A registry
// layout the grammar omits is unselectable, and the seed-time resolver just
// logs a warning naming a fallback the user never asked for.
test "config layout names and the layout registry agree" {
    var checked: usize = 0;
    for (config.layout_name_grammar.keys()) |spelling| {
        // The master-stack spellings fold to the canonical "master" at the
        // storage site, so compare the folded form.
        const canon = config.canonicalLayoutName(spelling);
        if (tiling.layoutByName(canon) == null) {
            std.debug.print("config accepts layout '{s}' but the registry has no '{s}'\n", .{ spelling, canon });
            return error.ConfigAcceptsUnknownLayout;
        }
        checked += 1;
    }
    for (contract.tiling_mods) |m| {
        if (!config.isLayoutName(m.name)) {
            std.debug.print("layout '{s}' is registered but the config grammar cannot spell it\n", .{m.name});
            return error.LayoutUnspellableInConfig;
        }
    }
    // Guard against the loops above going vacuous if the grammar were emptied.
    try testing.expect(checked >= 6);
}
