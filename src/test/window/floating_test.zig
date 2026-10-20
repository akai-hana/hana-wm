//! Unit tests for the floating module's model-facing surface: the
//! floating anchor's geometry (setFloatingRect) and the
//! floating-base fullscreen/minimize interaction, asserted through
//! the model they mutate.

// build-gate: floating, fullscreen, minimize
const std = @import("std");
const testing = std.testing;

// Overflow tests (MRU/order/max budgets) deliberately trip BoundedList's
// warn-level overflow diagnostic; the vendored test runner captures
// std.log output into the diagnostics bag instead of printing, so this
// stays quiet on success.
const model = @import("model");
const helpers = @import("helpers");
const build_options = @import("build_options");
const window_state_ops = @import("window_state_ops");
const window = @import("window");
const contract = @import("tiling_contract");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const floating = if (build_options.has_floating) @import("floating") else struct {};

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;

/// Sentinel id for "a window that was never registered": every negative-path
/// assertion (unknown/unregistered lookups) uses it instead of a literal.
const unknown_win: WindowId = 999;

/// Resetting fixture: a fresh model on deterministically re-armed module
/// stores (minimize/fullscreen), so tests pass in any order regardless of
/// what records an earlier test left behind.
const makeModel = helpers.makeModel;

const regCur = helpers.regCur;
const addFloating = helpers.addFloating;

// Floating-base fullscreen round trip stays home-free.
test "floating-base fullscreen minimize/restore never joins a list" {
    var m = makeModel();

    regCur(&m, 5);
    const r: model.Rect = .{ .x = 3, .y = 4, .width = 100, .height = 80 };
    try addFloating(&m, 6, r);
    _ = fullscreen.toggleFullscreen(&m, 6);
    try minimize.minimize(&m, 6);
    try testing.expect(m.store.get(6).?.presence == .parked);
    minimize.restore(&m, 6);
    const e = m.store.get(6).?;
    try testing.expect(e.presence == .covering);
    try testing.expect(model.isCovering(&m, 6));
    try testing.expect(r.eql(e.anchor.floating));
    for (&m.ws) |*s| try testing.expect(s.tiled_order.indexOfScalar(6) == null);
}

// setFloatingRect updates floating geometry; no-ops for tiled/unknown.
test "setFloatingRect updates floating window geometry" {
    var m = makeModel();

    try fullscreen.init();
    defer fullscreen.deinit();
    const r: model.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    try addFloating(&m, 5, r);
    const new_r: model.Rect = .{ .x = 50, .y = 60, .width = 400, .height = 300 };
    floating.setFloatingRect(&m, 5, new_r);
    try testing.expect(new_r.eql(m.store.get(5).?.anchor.floating));
    // A tiled window is untouched by geometry updates.
    try window_state_ops.register(&m, 6, WSId.fromIndex(0));
    floating.setFloatingRect(&m, 6, new_r);
    try testing.expect(m.store.get(6).?.anchor == .tiled);
    // An unknown window is ignored without crashing.
    floating.setFloatingRect(&m, unknown_win, new_r);
    // A covering (fullscreen) window is untouched by geometry updates.
    _ = fullscreen.toggleFullscreen(&m, 6);
    try testing.expect(m.store.get(6).?.presence == .covering);
    floating.setFloatingRect(&m, 6, new_r);
    try testing.expect(m.store.get(6).?.anchor == .tiled);
}

// --- nearestResizeCorner: corner selection at drag-start --------------------

test "nearestResizeCorner picks the corner in the press quadrant" {
    // 200x100 window at (100, 100): center at (200, 150).
    const rect: model.Rect = .{ .x = 100, .y = 100, .width = 200, .height = 100 };
    try testing.expect(floating.nearestResizeCorner(110, 110, rect) == .top_left);
    try testing.expect(floating.nearestResizeCorner(290, 110, rect) == .top_right);
    try testing.expect(floating.nearestResizeCorner(110, 190, rect) == .bottom_left);
    try testing.expect(floating.nearestResizeCorner(290, 190, rect) == .bottom_right);
}

test "nearestResizeCorner maps interior presses, not just borders" {
    const rect: model.Rect = .{ .x = 100, .y = 100, .width = 200, .height = 100 };
    // Well inside the window — the old border-proximity check fell back to
    // bottom_right for all of these; the quadrant rule keeps them nearest.
    try testing.expect(floating.nearestResizeCorner(150, 130, rect) == .top_left);
    try testing.expect(floating.nearestResizeCorner(250, 130, rect) == .top_right);
    try testing.expect(floating.nearestResizeCorner(150, 170, rect) == .bottom_left);
    try testing.expect(floating.nearestResizeCorner(250, 170, rect) == .bottom_right);
    // Presses beyond the frame (on the border and just outside it) resolve
    // by the same quadrant rule.
    try testing.expect(floating.nearestResizeCorner(98, 98, rect) == .top_left);
    try testing.expect(floating.nearestResizeCorner(302, 202, rect) == .bottom_right);
}

// --- computeResizeRect: the pure resize-drag math (PAspect band) -----------

/// No snapping and an unbounded workarea: resize math without a live core.
const no_wa: floating.WaEdges = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 };

/// Unbounded PMin/PMax envelope carrying `hints` for the aspect fit.
fn unboundedLimits(hints: model.SizeHints) floating.HintLimits {
    return .{
        .min_w = 0,
        .min_h = 0,
        .max_w = std.math.maxInt(u16),
        .max_h = std.math.maxInt(u16),
        .hints = hints,
    };
}

/// A resize drag anchored at `rect`'s bottom-right corner, start-of-drag
/// geometry only (the live-core fields are irrelevant to the pure math).
fn resizeDrag(rect: model.Rect) floating.DragState {
    return .{
        .mode = .resize,
        .resize_corner = .bottom_right,
        .start_win_x = rect.x,
        .start_win_y = rect.y,
        .start_win_width = rect.width,
        .start_win_height = rect.height,
    };
}

const r169: model.SizeHints = .{ .min_aspect = 9.0 / 16.0, .max_aspect = 16.0 / 9.0 };

test "drag resize locks a fixed-ratio window to its band" {
    const start: model.Rect = .{ .x = 100, .y = 100, .width = 320, .height = 180 };
    const drag = resizeDrag(start);

    // Purely horizontal drag past the ratio: height keeps tracking the
    // cursor, width is derived back into the band.
    var r = floating.computeResizeRect(drag, 700, 0, no_wa, unboundedLimits(r169), false);
    try testing.expectEqual(@as(u16, 320), r.width);
    try testing.expectEqual(@as(u16, 180), r.height);
    try testing.expectEqual(@as(i16, 100), r.x); // anchor (top-left) fixed
    try testing.expectEqual(@as(i16, 100), r.y);

    // Diagonal drag that lands exactly on-ratio: both axes track the cursor.
    r = floating.computeResizeRect(drag, 640, 360, no_wa, unboundedLimits(r169), false);
    try testing.expectEqual(@as(u16, 960), r.width);
    try testing.expectEqual(@as(u16, 540), r.height);
    try testing.expectEqual(@as(i16, 100), r.x);
    try testing.expectEqual(@as(i16, 100), r.y);

    // Slightly off-ratio diagonal: the excess (height here) shrinks into
    // the band, the other axis still tracks.
    r = floating.computeResizeRect(drag, 640, 400, no_wa, unboundedLimits(r169), false);
    try testing.expectEqual(@as(u16, 960), r.width);
    try testing.expectEqual(@as(u16, 540), r.height); // round(960 * 9/16)
}

test "drag resize anchor stays fixed for a top-left grab" {
    // Grab top_left: the bottom-right corner is the anchor, pinned at
    // (420, 280) through the aspect shrink.
    const start: model.Rect = .{ .x = 100, .y = 100, .width = 320, .height = 180 };
    var drag = resizeDrag(start);
    drag.resize_corner = .top_left;

    const r = floating.computeResizeRect(drag, -1000, -100, no_wa, unboundedLimits(r169), false);
    try testing.expectEqual(@as(u16, 498), r.width); // round(280 * 16/9)
    try testing.expectEqual(@as(u16, 280), r.height);
    try testing.expectEqual(@as(i16, 420 - 498), r.x); // anchor_x - width
    try testing.expectEqual(@as(i16, 0), r.y); // anchor_y - height
}

test "drag resize break-aspect frees the band; PMax still applies" {
    const start: model.Rect = .{ .x = 100, .y = 100, .width = 320, .height = 180 };
    const drag = resizeDrag(start);

    // Shift-broken: the raw dragged shape survives (no aspect fit).
    var r = floating.computeResizeRect(drag, 700, 0, no_wa, unboundedLimits(r169), true);
    try testing.expectEqual(@as(u16, 1020), r.width);
    try testing.expectEqual(@as(u16, 180), r.height);

    // No aspect hints: identical to break-aspect (unchanged shape).
    r = floating.computeResizeRect(drag, 700, 0, no_wa, unboundedLimits(.{}), false);
    try testing.expectEqual(@as(u16, 1020), r.width);
    try testing.expectEqual(@as(u16, 180), r.height);

    // PMax still caps a broken drag.
    var limits = unboundedLimits(r169);
    limits.max_w = 500;
    limits.max_h = 500;
    r = floating.computeResizeRect(drag, 700, 360, no_wa, limits, true);
    try testing.expectEqual(@as(u16, 500), r.width);
    try testing.expectEqual(@as(u16, 500), r.height);
}

test "drag resize: aspect wins over a conflicting PMin floor" {
    const start: model.Rect = .{ .x = 100, .y = 100, .width = 320, .height = 180 };
    const drag = resizeDrag(start);
    // Envelope floor of 300 conflicts with the 16:9 derivation from width
    // 500 (height 281): the ratio wins -- letterbox freedom is the point.
    var limits = unboundedLimits(r169);
    limits.min_w = 300;
    limits.min_h = 300;
    const r = floating.computeResizeRect(drag, 180, 120, no_wa, limits, false);
    try testing.expectEqual(@as(u16, 500), r.width);
    try testing.expectEqual(@as(u16, 281), r.height); // round(500 * 9/16) < min_h
}

// P1-39: floating binds init/deinit into the window lifecycle, so the
// uniform fan-out window.init/window.deinit perform reaches it like
// minimize's and fullscreen's. dispatchAll(.deinit, .{}) is the exact call
// window.deinit makes over the compiled-in window modules.
test "window lifecycle fan-out resets a leaked floating drag" {
    try testing.expect(floating.module.init != null);
    try testing.expect(floating.module.deinit != null);

    // A drag a test never released must not survive the deinit half of a
    // deinit()+init() cycle: startDrag would stay a no-op for the rest of
    // the process.
    floating.seedLeakedDragForTest(5);
    try testing.expect(floating.isDragging());
    window.dispatchAll(.deinit, .{});
    try testing.expect(!floating.isDragging());

    // And the init half re-arms a clean slate (the leak re-seeded first, so
    // the assertion cannot pass vacuously).
    floating.seedLeakedDragForTest(5);
    try floating.module.init.?();
    try testing.expect(!floating.isDragging());
}

// --- D26: tiled edge-drag split adjustment (pure seams) -------------------
//
// The full path (press -> plan -> per-motion commit -> retile) needs the
// live pipeline; these cover the two halves the acceptance criterion asks
// for headlessly: grab classification (which presses fall through to the
// existing float-detach) and the pixel->delta mapping the commit applies.

test "grabEdge: nearest edge in band, corner ties vertical, center falls through" {
    const r: model.Rect = .{ .x = 100, .y = 50, .width = 400, .height = 300 };
    try testing.expectEqual(floating.GrabEdge.left, floating.grabEdge(100, 200, r).?);
    try testing.expectEqual(floating.GrabEdge.right, floating.grabEdge(500, 200, r).?);
    try testing.expectEqual(floating.GrabEdge.top, floating.grabEdge(300, 50, r).?);
    try testing.expectEqual(floating.GrabEdge.bottom, floating.grabEdge(300, 350, r).?);
    // the band is inclusive at 8px and stops at 9px
    try testing.expectEqual(floating.GrabEdge.left, floating.grabEdge(108, 200, r).?);
    try testing.expect(floating.grabEdge(109, 200, r) == null);
    // a corner grab resolves to the vertical edge (master boundary wins ties)
    try testing.expectEqual(floating.GrabEdge.left, floating.grabEdge(100, 50, r).?);
    // center press: the D26 detach arm
    try testing.expect(floating.grabEdge(300, 200, r) == null);
}

test "planTiledSplit: master routes, stack balance rules, fallbacks to null" {
    var m = makeModel();
    regCur(&m, 1); // master slot (params.primary_count = 1)
    regCur(&m, 2); // first stack slot
    const wa: model.Rect = .{ .x = 0, .y = 0, .width = 1280, .height = 800 };
    const master: contract.Layout = .{ .name = "master" };
    const monocle: contract.Layout = .{ .name = "monocle" };
    const mrect: model.Rect = .{ .x = 0, .y = 100, .width = 600, .height = 600 };
    const srect: model.Rect = .{ .x = 600, .y = 400, .width = 680, .height = 300 };

    // any vertical edge -> primary_width, signed by master side, wa-width
    // denominator; start snapshots the live knob value
    var s = floating.planTiledSplit(&m, 1, .left, mrect, wa, false, &master).?;
    try testing.expectEqual(floating.SplitKnob.primary, s.knob);
    try testing.expectEqual(@as(f32, 1), s.sign);
    try testing.expectEqual(@as(f32, 0.5), s.start);
    try testing.expectEqual(@as(f32, 1280), s.wa_w);
    s = floating.planTiledSplit(&m, 1, .right, mrect, wa, true, &master).?;
    try testing.expectEqual(@as(f32, -1), s.sign);
    s = floating.planTiledSplit(&m, 2, .left, srect, wa, false, &master).?;
    try testing.expectEqual(floating.SplitKnob.primary, s.knob);

    // a master-row horizontal divider has no knob behind it -> null
    try testing.expect(floating.planTiledSplit(&m, 1, .bottom, mrect, wa, false, &master) == null);

    // stack, interior divider -> balance, wa-height denominator, start 0
    s = floating.planTiledSplit(&m, 2, .top, srect, wa, false, &master).?;
    try testing.expectEqual(floating.SplitKnob.balance, s.knob);
    try testing.expectEqual(@as(f32, 0), s.start);
    try testing.expectEqual(@as(f32, 800), s.wa_h);

    // stack edges pinned to the workarea border have no divider beside them
    const outer: model.Rect = .{ .x = 600, .y = 0, .width = 680, .height = 800 };
    try testing.expect(floating.planTiledSplit(&m, 2, .top, outer, wa, false, &master) == null);
    try testing.expect(floating.planTiledSplit(&m, 2, .bottom, outer, wa, false, &master) == null);

    // anything but master (and no resolved layout at all) -> float fallback
    try testing.expect(floating.planTiledSplit(&m, 2, .left, srect, wa, false, &monocle) == null);
    try testing.expect(floating.planTiledSplit(&m, 2, .left, srect, wa, false, null) == null);
}

test "mappedSplitDelta: total displacement in knob units" {
    const p: floating.TiledSplit = .{ .knob = .primary, .sign = 1, .start = 0.5, .wa_w = 1280, .wa_h = 800 };
    try testing.expectEqual(@as(f32, 0.5), floating.mappedSplitDelta(p, 640, 0));
    try testing.expectEqual(@as(f32, -0.5), floating.mappedSplitDelta(p, -640, 0));
    var flipped = p;
    flipped.sign = -1; // master on the right: dragging right narrows it
    try testing.expectEqual(@as(f32, -0.5), floating.mappedSplitDelta(flipped, 640, 0));
    const b: floating.TiledSplit = .{ .knob = .balance, .wa_h = 800 };
    try testing.expectEqual(@as(f32, 0.5), floating.mappedSplitDelta(b, 0, 400));
    try testing.expectEqual(@as(f32, -0.5), floating.mappedSplitDelta(b, 0, -400));
}
