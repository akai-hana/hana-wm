//! The bar render core headless (REFACTOR-PLAN P1-20): the four entry points
//! of `render.zig` and `input_events.zig` with a synthetic `*State` over an
//! image-surface DrawContext -- no X connection anywhere. The bootstrap mirrors
//! production shape at half cost: `core.init` once with a dummy connection and
//! a page-allocator config box (core owns it for the process, so testing's
//! leak checker never sees it), a fresh image-surface `DrawContext` + `State`
//! per test, and the pipeline model re-armed the way `query_test` does it.
//!
//! What each area pins, and why it is assertable without pixels:
//!   - `solveRowPlan`: slot order, the forward cursor partitioning `[0,
//!     width)`, the right cluster hugging `width - right_total`, and the
//!     center budget feeding `centerRowBudget` (incl. the title-minimum floor).
//!   - `paintRowPlan`: click bounds are layout facts -- reset + recorded exactly
//!     once per clickable slot at solved positions, non-repaintable slots and
//!     non-clickable segments excluded from paint/bounds as specified, and the
//!     self-ticker scope agreeing with the clock's slot.
//!   - `scanLiveFrame`: model -> frame fills, no wire.
//!   - click dispatch: synthetic ButtonPress -> registry onClick (the clock's
//!     display mode is the observable; scroll mapping incl. the no-onScroll
//!     fall-through), and the title trampoline's pre-target guards.
//!
// Declared here, next to the imports that make it necessary,
// rather than in a build.zig table that had to be kept in agreement
// with them by hand.
// build-gate: bar, workspaces, seg_clock, seg_title, seg_systatus

const std = @import("std");
const testing = std.testing;

const core = @import("core");
const model = @import("model");
const pipeline = @import("pipeline");
const helpers = @import("helpers");
const recon = @import("reconcile");
const query = @import("query");
const window_state_ops = @import("window_state_ops");
const composed = @import("composed");
const state = @import("state");
const render = @import("render");
const drawing = @import("drawing");
const segmod = @import("segment");
const center_row = @import("center_row");
const bar_config = @import("bar_config");
const input_events = @import("input_events");
const masks = @import("masks");
const clock = @import("clock");
const title_geom = @import("geom");
const xcb = core.xcb;

const bar_w: u16 = 480;
const bar_h: u16 = 24;

/// The process-wide config box `core.init` takes ownership of. Page allocator
/// deliberately: it lives for the whole process (core never releases it in a
/// test), so keeping it out of testing's leak accounting is honest, not a
/// workaround -- the layout rows reconfigured per test are freed against the
/// same allocator.
var g_cfg: composed.Config = .{};
var g_core_ready = false;
var g_screen: core.xcb.xcb_screen_t = std.mem.zeroes(core.xcb.xcb_screen_t);

fn ensureCore() void {
    if (g_core_ready) return;
    g_screen.width_in_pixels = 1920;
    g_screen.height_in_pixels = 1080;
    g_screen.root_depth = 24;
    g_cfg.workspaces.count = 9;
    // Never dereferenced: every path these tests reach guards the XCB half on
    // its zero handle or is model/config-only (the pipeline's own `g_sink`
    // carries the same deliberate undefined until a live init).
    const conn: core.Connection = undefined;
    core.init(conn, &g_screen, 0, std.heap.page_allocator, &g_cfg, 96.0);
    g_core_ready = true;
}

const LayoutRow = struct {
    position: bar_config.BarSegmentAnchor,
    names: []const []const u8,
};

/// Replaces the live bar layout in place: core owns the config box for the
/// process, and `State` reads layout through `core.getState()` on every frame,
/// so per-test layouts are a swap of the one list rather than a new box.
fn setLayout(rows: []const LayoutRow) !void {
    const alloc = std.heap.page_allocator;
    bar_config.freeBarLayouts(&g_cfg.bar.layout, alloc, true);
    for (rows) |row| {
        var lay = bar_config.BarLayout{ .position = row.position, .segments = .empty };
        errdefer lay.deinit(alloc);
        for (row.names) |n| {
            // Owned copies: BarLayout.deinit frees its names, and a literal
            // would hand page_allocator a non-heap slice.
            const owned = try alloc.dupe(u8, n);
            errdefer alloc.free(owned);
            try lay.segments.append(alloc, owned);
        }
        try g_cfg.bar.layout.append(alloc, lay);
    }
}

const Fixture = struct {
    s: *state.State,
    dc: *drawing.DrawContext,

    fn setup() !Fixture {
        ensureCore();
        try setLayout(&.{
            .{ .position = .left, .names = &.{ "workspaces", "layout" } },
            .{ .position = .center, .names = &.{"title"} },
            .{ .position = .right, .names = &.{ "clock", "cpu" } },
        });

        const alloc = testing.allocator;
        const dc = try drawing.DrawContext.initImage(alloc, bar_w, bar_h, 96.0);
        errdefer dc.deinit();
        const s = try state.State.init(alloc, undefined, 0, 0, bar_w, bar_h, dc, g_cfg.bar);
        errdefer {
            s.title_data.minimized.deinit(alloc);
            alloc.destroy(s);
        }
        // Pin the merged-clock budget. State.init derives it from a Pango
        // probe; a font-less host would otherwise hand the clock a
        // zero-width slot that no press could ever hit-test into.
        s.clock.width = 80;
        state.gBar.state = s;

        // The model half, bootstrapped the query_test way: the phase latch,
        // then the global instance overwritten through the same mutation gate.
        core.markModelReady();
        pipeline.mut().* = helpers.makeModel();
        recon.init();

        return .{ .s = s, .dc = dc };
    }

    fn teardown(self: Fixture) void {
        state.gBar.state = null;
        // State.deinit also destroys the X window; these tests never made
        // one, so the teardown mirrors State.init's own errdefer mirror.
        const alloc = self.s.render.allocator;
        self.s.title_data.minimized.deinit(alloc);
        alloc.destroy(self.s);
        self.dc.deinit();
    }
};

/// The per-frame context the production `frameCtx` builds privately: scan the
/// model into the State, then fill the title/focus slots from in-process caches.
fn frameCtxOf(fx: Fixture) segmod.DrawCtx {
    render.scanLiveFrame(fx.s);
    var ctx: segmod.DrawCtx = .{
        .dc = fx.s.render.dc,
        .config = state.renderBar(),
        .height = bar_h,
        .conn = fx.s.win.conn,
        .allocator = fx.s.render.allocator,
        .frame = .{},
    };
    render.fillDrawCtx(fx.s, &ctx);
    return ctx;
}

/// Full bar frame, exactly as a dirty wake runs it: scan + solve + paint +
/// queueBlit over the image surface.
fn renderFull(fx: Fixture) void {
    render.markDirty(fx.s);
    render.performDraw();
}

test "solveRowPlan partitions the row: forward cursor from 0, right cluster at width - right_total" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;

    var ctx = frameCtxOf(fx);
    var plan: render.RowPlan = .{};
    render.solveRowPlan(s, &ctx, &plan);

    try testing.expect(!plan.overflowed);
    try testing.expectEqual(@as(usize, 5), plan.len);
    try testing.expectEqual(segmod.segId("workspaces").?, plan.slots[0].id.?);
    try testing.expectEqual(segmod.segId("layout").?, plan.slots[1].id.?);
    try testing.expectEqual(segmod.segId("title").?, plan.slots[2].id.?);
    // The right cluster is pushed backwards, so paint order within it is
    // config REVERSED: the trailing segment sits at the row's edge first.
    try testing.expectEqual(segmod.segId("cpu").?, plan.slots[3].id.?);
    try testing.expectEqual(segmod.segId("clock").?, plan.slots[4].id.?);
    try testing.expect(plan.slots[3].is_right);
    try testing.expect(plan.slots[4].is_right);

    const spacing = state.renderBar().scaledSpacing(bar_h);

    // Forward half: left/center slots claim [0, cursor) contiguously -- gap
    // after every non-center slot, none after the center title -- and the
    // claim never crosses into the right cluster's reservation. This is the
    // partition: every pixel below `width - right_total` belongs to exactly
    // one left/center slot or one gap, none overlaps, none is skipped.
    var cursor: u32 = 0;
    var i: usize = 0;
    while (i < plan.len and !plan.slots[i].is_right) : (i += 1) {
        const sl = plan.slots[i];
        cursor += sl.w;
        if (!sl.omit_gap) cursor += spacing;
        try testing.expect(cursor <= @as(u32, bar_w - plan.right_total));
    }
    try testing.expectEqual(@as(usize, 3), i);
    try testing.expect(plan.slots[2].omit_gap);
    try testing.expect(!plan.slots[0].omit_gap);

    // Right cluster: inside the row, pairwise disjoint, and its left edge is
    // exactly the total the left/center budgets subtracted above -- the two
    // halves tile [0, width) between them with the gap arithmetic intact.
    var min_x: u16 = bar_w;
    var j = i;
    while (j < plan.len) : (j += 1) {
        const sl = plan.slots[j];
        try testing.expect(sl.is_right);
        try testing.expect(@as(u32, sl.x) + sl.w <= bar_w);
        min_x = @min(min_x, sl.x);
        var k = i;
        while (k < j) : (k += 1) {
            const other = plan.slots[k];
            try testing.expect(sl.x + sl.w <= other.x or other.x + other.w <= sl.x);
        }
    }
    try testing.expectEqual(@as(u16, bar_w - plan.right_total), min_x);
    try testing.expect(cursor <= @as(u32, min_x));

    // Center budget wiring: solve's avail (right cluster AND the preceding
    // left claim subtracted) is what `centerRowBudget` sees, and the title's
    // share is the result. The floor rule itself is pinned in center_row_test;
    // this pins that solve feeds it the same claim arithmetic paint advances by.
    var lay = bar_config.BarLayout{ .position = .center, .segments = .empty };
    defer lay.deinit(testing.allocator);
    try lay.segments.append(testing.allocator, try testing.allocator.dupe(u8, "title"));
    const left_claim: u32 = plan.slots[0].w + plan.slots[1].w + 2 * @as(u32, spacing);
    const avail: u16 = @intCast(@as(u32, bar_w) - @as(u32, plan.right_total) - left_claim);
    const budget = center_row.centerRowBudget(lay, avail, spacing, &ctx.frame, s.clock.width);
    try testing.expectEqual(@as(u16, 1), budget.center_count);
    try testing.expectEqual(
        center_row.centerShare(budget.remaining, budget.center_count, 0),
        plan.slots[2].w,
    );
}

test "solveRowPlan: the center budget floors at the title minimum, and clamps at the row" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    try setLayout(&.{.{ .position = .center, .names = &.{"title"} }});
    var ctx = frameCtxOf(fx);

    // Any row with room for the minimum reserves at least the minimum: the
    // floor is what stops a spacing-shrunk avail from starving the title slot.
    var w: u16 = 100;
    while (w <= 140) : (w += 1) {
        fx.s.render.width = w;
        var plan: render.RowPlan = .{};
        render.solveRowPlan(fx.s, &ctx, &plan);
        try testing.expectEqual(@as(usize, 1), plan.len);
        try testing.expect(plan.slots[0].w >= segmod.title_min_width);
    }

    // A row narrower than the minimum clamps at the row itself: the floor
    // reserves MORE than fits when it can, never more than the width that
    // exists.
    fx.s.render.width = 60;
    var plan: render.RowPlan = .{};
    render.solveRowPlan(fx.s, &ctx, &plan);
    try testing.expectEqual(@as(usize, 1), plan.len);
    try testing.expectEqual(@as(u16, 60), plan.slots[0].w);
}

test "paintRowPlan records each clickable bound exactly once at the solved position" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;
    var ctx = frameCtxOf(fx);

    // A fresh State starts EVERY segment dirty (the first-draw-is-full rule);
    // clear the bits BEFORE solving so the plan caches every slot
    // non-repaintable and this pass is a settled bar where nothing repaints.
    // Bounds are layout facts and are still recorded, at the reservation
    // cursor (no draw can move it), with no span for a blit.
    for (0..segmod.all().len) |i| render.clearSegmentDirty(s, i);

    var plan: render.RowPlan = .{};
    render.solveRowPlan(s, &ctx, &plan);

    // Stale pre-pollution: paint resets the table rather than appending, so a
    // stale full-length table cannot survive into the recorded set.
    s.clicks.len = state.max_click_bounds;
    s.clicks.bounds[0] = .{ .id = 0, .x = 999, .w = 7 };
    s.dirty.span_x = 0;
    s.dirty.span_w = 0;

    render.paintRowPlan(s, &ctx, &plan, false);
    try testing.expectEqual(@as(u16, 0), s.dirty.span_w);
    try testing.expectEqual(@as(usize, 4), s.clicks.len);

    const spacing = state.renderBar().scaledSpacing(bar_h);
    var cursor: u16 = 0;
    for (plan.slots[0..plan.len]) |sl| {
        const x = if (sl.is_right) sl.x else cursor;
        if (!sl.is_right) {
            cursor += sl.w;
            if (!sl.omit_gap) cursor += spacing;
        }
        const id = sl.id orelse continue;
        if (!segmod.segmentAt(id).clickable) {
            try testing.expect(render.recordedBound(s, id) == null);
            continue;
        }
        const b = render.recordedBound(s, id).?;
        try testing.expectEqual(x, b.x);
        try testing.expectEqual(sl.w, b.w);
    }
    // cpu (non-clickable) was skipped; every other id landed, and with
    // len == 4 over 4 present ids no segment was recorded twice.
    try testing.expect(render.recordedBound(s, segmod.segId("cpu").?) == null);
    try testing.expect(render.recordedBound(s, segmod.segId("workspaces").?) != null);
    try testing.expect(render.recordedBound(s, segmod.segId("layout").?) != null);
    try testing.expect(render.recordedBound(s, segmod.segId("title").?) != null);
    try testing.expect(render.recordedBound(s, segmod.segId("clock").?) != null);

    // A second pass over the same plan: the reset makes the table idempotent.
    render.paintRowPlan(s, &ctx, &plan, false);
    try testing.expectEqual(@as(usize, 4), s.clicks.len);

    // Full frame (performDraw's own fresh solve, every slot dirty): bounds
    // stay exactly-once, the whole row is the blit span, and the right
    // cluster's positions are pinned -- they derive only from the clock
    // budget and the (zero-width) cpu probe, so the two solves agree. Left/
    // center positions may ride the painted cursor here, the documented over/
    // under-paint behavior, so only their presence is pinned.
    renderFull(fx);
    try testing.expectEqual(@as(usize, 4), s.clicks.len);
    try testing.expectEqual(@as(u16, 0), s.dirty.span_x);
    try testing.expectEqual(bar_w, s.dirty.span_w);
    for (plan.slots[3..5]) |sl| {
        if (!segmod.segmentAt(sl.id.?).clickable) continue;
        const b = render.recordedBound(s, sl.id.?).?;
        try testing.expectEqual(sl.x, b.x);
        try testing.expectEqual(sl.w, b.w);
    }
    try testing.expect(render.recordedBound(s, segmod.segId("cpu").?) == null);

    // The clock's self-ticker scope records the same solved slot paint used.
    const clock_id = segmod.segId("clock").?;
    const ti = segmod.roleIndexOf(clock_id, segmod.self_ticking_ids).?;
    try testing.expect(s.clock.segs[ti].valid);
    try testing.expectEqual(plan.slots[4].x, s.clock.segs[ti].x);
    try testing.expectEqual(plan.slots[4].w, s.clock.segs[ti].width);
}

test "scanLiveFrame fills the frame from the model alone" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;
    const m = pipeline.mut();
    helpers.regCur(m, 101);
    try window_state_ops.register(m, 201, model.WSId.fromIndex(1));

    render.scanLiveFrame(s);

    try testing.expectEqual(@as(usize, 1), s.frame.entries_len);
    try testing.expectEqual(@as(u32, 101), s.frame.entries[0].window);
    try testing.expectEqual(@as(u8, m.current.index), s.frame.frame.current_workspace);
    try testing.expectEqual(
        @as(u32, @intCast(query.getWorkspaceCount())),
        s.frame.frame.workspace_count,
    );
    for (0..s.frame.frame.workspace_count) |i| {
        try testing.expectEqual(i == 0 or i == 1, s.frame.ws_has_windows[i]);
    }
}

test "performDraw end-to-end: dirty consumed, bounds recorded, frame cached" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;

    renderFull(fx);

    try testing.expect(!s.dirty.flag);
    try testing.expect(s.frame.ctx_valid);
    // Full redraw clears the whole row up front, so the blit span is the row.
    try testing.expectEqual(@as(u16, 0), s.dirty.span_x);
    try testing.expectEqual(bar_w, s.dirty.span_w);
    try testing.expectEqual(@as(usize, 4), s.clicks.len);
    const tb = render.recordedBound(s, state.title_id.?).?;
    try testing.expect(tb.w > 0);
    try testing.expect(render.recordedBound(s, segmod.segId("clock").?) != null);
}

test "P2-59 width-stable fast path: one dirty segment blits only its slot; fact bump scopes to declared segments" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;

    // Establish a laid-out baseline so every segment has a recorded bound and
    // a valid last_ctx (the scoped path reuses it).
    renderFull(fx);
    try testing.expect(!s.dirty.flag);
    try testing.expect(s.frame.ctx_valid);

    // --- Width-stable single-segment request (the foldModuleRedraw fast
    // path's dirty shape): exactly ONE segment dirty + the whole-bar flag, but
    // NOT every slot. paintRowPlan then runs is_full_redraw = false and blits
    // only that segment's slot, not the whole row. ---
    for (0..segmod.all().len) |i| render.clearSegmentDirty(s, i);
    const clock_id = segmod.segId("clock").?;
    s.dirty.segments[clock_id] = true;
    s.dirty.flag = true;
    // Not a full redraw: the fast path must NOT have memset every slot.
    try testing.expect(!render.isFullDirty(s));

    render.performDraw();
    // The blit span covers the clock's slot (plus its trailing gap) but is
    // nowhere near the whole row -- the fast path blitted one region.
    const cb = render.recordedBound(s, clock_id).?;
    try testing.expect(s.dirty.span_x <= cb.x);
    try testing.expect(s.dirty.span_x + s.dirty.span_w >= cb.x + cb.w);
    try testing.expect(s.dirty.span_w < bar_w);
    // The draw consumed the flag and the painted segment's dirty bit.
    try testing.expect(!s.dirty.flag);
    try testing.expect(!s.dirty.segments[clock_id]);

    // --- Width-change / escalation half: a fact bump (markDirtySource) still
    // repaints the DECLARED segments (title declares focus+frame). ---
    render.markDirtySource(s, .focus);
    try testing.expect(s.dirty.flag);
    const title_id = state.title_id.?;
    try testing.expect(s.dirty.segments[title_id]);
    // A segment that declares no focus source stays clean.
    try testing.expect(!s.dirty.segments[clock_id]);

    render.performDraw();
    // Title's slot is inside the blit span; the span covers the declared set.
    const tb = render.recordedBound(s, title_id).?;
    try testing.expect(s.dirty.span_x <= tb.x);
    try testing.expect(s.dirty.span_x + s.dirty.span_w >= tb.x + tb.w);
    try testing.expect(!s.dirty.flag);
}

test "P2-62 draw-failure log is rate-limited per segment id: first logs, repeats bounded" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;

    const broken_id: usize = 3;
    const other_id: usize = 4;
    const t0: i64 = 1_000;

    // First failure for a segment logs at once (its stamp starts at 0).
    try testing.expect(s.drawFailLogDue(broken_id, t0));
    // A permanent failure repeats every frame: the next frame inside the
    // interval is suppressed -- the bounded rate the acceptance names.
    try testing.expect(!s.drawFailLogDue(broken_id, t0 + 500));
    try testing.expect(!s.drawFailLogDue(broken_id, t0 + state.draw_fail_log_interval_ms - 1));
    // Once the interval elapses, the line is admitted again.
    try testing.expect(s.drawFailLogDue(broken_id, t0 + state.draw_fail_log_interval_ms));

    // Slots are independent: another segment's failure is unaffected.
    try testing.expect(s.drawFailLogDue(other_id, t0 + 500));
    try testing.expect(!s.drawFailLogDue(other_id, t0 + 600));

    // The null-id path (no resolvable segment) has its own shared slot.
    try testing.expect(s.drawFailLogDue(null, t0));
    try testing.expect(!s.drawFailLogDue(null, t0 + 500));
    try testing.expect(s.drawFailLogDue(null, t0 + state.draw_fail_log_interval_ms));
}

test "P2-63 layout generation stamps scopes and bounds; a stale stamp is detectable" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;

    // A first full layout: solveRowPlan bumped the generation, and the paint
    // recorded every scope/bound stamped with it.
    renderFull(fx);
    try testing.expect(s.layout_gen > 0);

    // The clock's self-ticker scope carries the current generation.
    const clock_id = segmod.segId("clock").?;
    var clock_idx: usize = undefined;
    var found = false;
    for (segmod.self_ticking_ids, 0..) |cid, i| {
        if (cid == clock_id) {
            clock_idx = i;
            found = true;
        }
    }
    try testing.expect(found);
    try testing.expect(s.clock.segs[clock_idx].valid);
    try testing.expectEqual(s.layout_gen, s.clock.segs[clock_idx].gen);

    // A clickable segment's recorded bound carries it too.
    const title_id = state.title_id.?;
    try testing.expectEqual(s.layout_gen, render.recordedBound(s, title_id).?.gen);

    // A second layout bumps the generation and re-stamps from scratch.
    const prev = s.layout_gen;
    renderFull(fx);
    try testing.expect(s.layout_gen > prev);
    try testing.expectEqual(s.layout_gen, s.clock.segs[clock_idx].gen);
    try testing.expectEqual(s.layout_gen, render.recordedBound(s, title_id).?.gen);

    // Deliberately stale scope: bump the generation WITHOUT a re-record --
    // the shape a "re-laid out but forgot to re-record" logic bug leaves.
    // The stamps no longer match, which is exactly the condition the Debug
    // asserts in drawClockOnly / redrawSegmentScoped trip on.
    s.layout_gen +%= 1;
    try testing.expect(s.clock.segs[clock_idx].gen != s.layout_gen);
    try testing.expect(render.recordedBound(s, title_id).?.gen != s.layout_gen);
}

test "handleButtonPress dispatches left/right presses to the segment's onClick" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;
    renderFull(fx);

    const id = segmod.segId("clock").?;
    const b = render.recordedBound(s, id).?;
    try testing.expect(b.w > 0);

    var ev: xcb.xcb_button_press_event_t = std.mem.zeroes(xcb.xcb_button_press_event_t);
    ev.event_x = @intCast(b.x);

    // Left: the press anchors the drag and the clock cycles forward.
    const before = clock.displayMode();
    ev.detail = masks.mouse_button_left;
    input_events.handleButtonPress(&ev);
    try testing.expectEqual(id, s.drag_segment.?);
    try testing.expectEqual(clock.cycledMode(before, true), clock.displayMode());

    var rel: xcb.xcb_button_release_event_t = std.mem.zeroes(xcb.xcb_button_release_event_t);
    input_events.handleButtonRelease(&rel);
    try testing.expect(s.drag_segment == null);

    // Right: cycles backward, and arms no drag anchor.
    const now = clock.displayMode();
    ev.detail = masks.mouse_button_right;
    input_events.handleButtonPress(&ev);
    try testing.expect(s.drag_segment == null);
    try testing.expectEqual(clock.cycledMode(now, false), clock.displayMode());
}

test "scroll presses: 4 maps to +1, 5 to -1, and a segment without onScroll is untouched" {
    // The mapping itself, pure: no `onScroll` binder is needed to pin it.
    try testing.expectEqual(@as(?i8, 1), input_events.scrollDir(masks.mouse_button_scroll_up));
    try testing.expectEqual(@as(?i8, -1), input_events.scrollDir(masks.mouse_button_scroll_down));
    try testing.expectEqual(@as(?i8, null), input_events.scrollDir(masks.mouse_button_left));
    try testing.expectEqual(@as(?i8, null), input_events.scrollDir(masks.mouse_button_right));
    try testing.expectEqual(@as(?i8, null), input_events.scrollDir(6));

    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;
    renderFull(fx);

    // Wheel over the clock (no onScroll hook): the press dispatches nowhere --
    // no mode change, no drag anchor, no scroll target left behind.
    const id = segmod.segId("clock").?;
    const b = render.recordedBound(s, id).?;
    const before = clock.displayMode();

    var ev: xcb.xcb_button_press_event_t = std.mem.zeroes(xcb.xcb_button_press_event_t);
    ev.event_x = @intCast(b.x);
    ev.detail = masks.mouse_button_scroll_up;
    input_events.handleButtonPress(&ev);
    try testing.expectEqual(before, clock.displayMode());
    try testing.expect(s.drag_segment == null);
    try testing.expect(s.scroll_segment == null);

    ev.detail = masks.mouse_button_scroll_down;
    input_events.handleButtonPress(&ev);
    try testing.expectEqual(before, clock.displayMode());
    try testing.expect(s.scroll_segment == null);
}

test "title-click trampoline guards: empty frame and missing bound never reach hitTest" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;
    const m = pipeline.mut();
    const title_id = state.title_id.?;

    // No scan yet: entries_len is 0, the guard fires first.
    input_events.dispatchClick(s, title_id, 0, true, false);
    try testing.expect(m.focused == null);

    // Entries present, but no layout pass has recorded a title bound.
    helpers.regCur(m, 101);
    render.scanLiveFrame(s);
    try testing.expectEqual(@as(usize, 1), s.frame.entries_len);
    try testing.expectEqual(@as(usize, 0), s.clicks.len);
    input_events.dispatchClick(s, title_id, 0, true, false);
    try testing.expect(m.focused == null);
}

test "title-click trampoline: a snapshot cached before the window existed misses" {
    var fx = try Fixture.setup();
    defer fx.teardown();
    const s = fx.s;
    const m = pipeline.mut();
    const title_id = state.title_id.?;

    // Draw with an empty model: bound recorded, last_ctx snapshot cached
    // with zero entries. A window arriving after that draw fills entries_len
    // (the guard passes) but not the cached snapshot the hit-test reads --
    // the documented post-draw click path, and a miss, not a wrong window.
    renderFull(fx);
    try testing.expect(render.recordedBound(s, title_id) != null);
    helpers.regCur(m, 101);
    render.scanLiveFrame(s);
    try testing.expectEqual(@as(usize, 1), s.frame.entries_len);

    input_events.dispatchClick(s, title_id, 0, true, false);
    try testing.expect(m.focused == null);
}

test "titleClickAction: minimized restores even when focused; else minimize; else focus" {
    const minimized = title_geom.ClickTarget{ .window = 7, .minimized = true };
    const focused = title_geom.ClickTarget{ .window = 7, .minimized = false };
    const other = title_geom.ClickTarget{ .window = 8, .minimized = false };

    // The priority contract: minimized beats focused -- restoring must not be
    // shadowed into a minimize just because the window also held focus.
    try testing.expectEqual(
        input_events.TitleAction.unminimize,
        input_events.titleClickAction(minimized, 7),
    );
    try testing.expectEqual(
        input_events.TitleAction.minimize,
        input_events.titleClickAction(focused, 7),
    );
    try testing.expectEqual(
        input_events.TitleAction.focus,
        input_events.titleClickAction(other, 7),
    );
    try testing.expectEqual(
        input_events.TitleAction.focus,
        input_events.titleClickAction(other, null),
    );
}
