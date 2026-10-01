//! X-gated integration tests for the reconcile pipeline
//! (src/core/x11 + src/core/runtime). Runs the real engine -> Ctx -> sink
//! chain against a live X server and asserts the server state matches the
//! logged placements, plus the covering (fullscreen) winner/park branches.
//! Self-skips without a server so `zig build test` stays green headless.

// (28.6) Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: tiling

const std = @import("std");

const core = @import("core");
const model = @import("model");
const pipeline = @import("pipeline");
const actions = @import("actions");
const fixture = @import("fixture");
const xcb = core.xcb;
const ledger = @import("ledger");
const usable_area = @import("usable_area");
const fullscreen = if (@import("build_options").has_fullscreen) @import("fullscreen") else struct {};

/// Two mapped windows, the arrangement most pipeline tests seed.
fn seedTwo(fx: *fixture.Fx) struct { u32, u32 } {
    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    actions.mapRequest(w1, 0, true, null);
    actions.mapRequest(w2, 0, true, null);
    fx.flush();
    return .{ w1, w2 };
}

test "pipeline: reconcile tiles to engine placements and records LastSent" {
    var fx = try fixture.setUp("pipeline_test");
    defer fx.deinit();
    const m = pipeline.model();

    const w1, const w2 = seedTwo(fx);

    try std.testing.expectEqual(w2, m.focused.?);
    const order = m.ws[m.current.index].tiled_order.items;
    try std.testing.expectEqual(w1, order[0]);
    try std.testing.expectEqual(w2, order[1]);

    // Both windows land exactly on their engine placements.
    try fx.expectTiledGeometry(w1);
    try fx.expectTiledGeometry(w2);

    // The sent ledger matches the actual server geometry.
    const lr = ledger.lastRectFor(w1) orelse return error.NoLedgerEntry;
    const g1 = fx.geometry(w1) orelse return error.ClosedWindow;
    try std.testing.expectEqual(lr.width, g1.width);
    try std.testing.expectEqual(lr.height, g1.height);
    try std.testing.expectEqual(lr.x, @as(i32, g1.x));
    try std.testing.expectEqual(lr.y, @as(i32, g1.y));
}

test "pipeline: fullscreen winner covers the screen and parks siblings" {
    var fx = try fixture.setUp("pipeline_test");
    defer fx.deinit();
    const m = pipeline.model();
    const cs = core.getState();

    const w1, const w2 = seedTwo(fx);

    actions.fullscreenToggleWindow(w2);
    fx.flush();

    try std.testing.expectEqual(w2, (model.coveringOccupantOnWs(m, m.current) orelse return error.NoOccupant));
    const e2 = m.store.get(w2) orelse return error.UnknownWindow;
    try std.testing.expect(e2.presence == .covering);

    const g = fx.geometry(w2) orelse return error.ClosedWindow;
    try std.testing.expectEqual(@as(i32, 0), @as(i32, g.x));
    try std.testing.expectEqual(@as(i32, 0), @as(i32, g.y));
    try std.testing.expectEqual(cs.screen.width_in_pixels, g.width);
    try std.testing.expectEqual(cs.screen.height_in_pixels, g.height);
    try std.testing.expectEqual(@as(u16, 0), g.border_width); // edge-to-edge, no border
    try fx.expectParked(w1);
}

test "pipeline: fullscreen switch moves the claim; exit restores tiled" {
    var fx = try fixture.setUp("pipeline_test");
    defer fx.deinit();
    const m = pipeline.model();

    const w1, const w2 = seedTwo(fx);

    actions.fullscreenToggleWindow(w1);
    fx.flush();
    try std.testing.expectEqual(w1, (model.coveringOccupantOnWs(m, m.current) orelse return error.NoOccupant));
    // The covering winner owns the screen, so it owns keyboard focus too
    // (the toggle ran against an unfocused w1, e.g. an EWMH request).
    try std.testing.expectEqual(w1, m.focused.?);
    try std.testing.expectEqual(w1, fx.inputFocus());

    // Direct covering hand-off: claiming a second window while occupied.
    actions.fullscreenToggleWindow(w2);
    fx.flush();
    try std.testing.expectEqual(w2, (model.coveringOccupantOnWs(m, m.current) orelse return error.NoOccupant));
    try fx.expectParked(w1);
    // Focus follows the claim: the new occupant must get the screen's
    // keystrokes, not the displaced one.
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w2, fx.inputFocus());

    // Exit: both windows return to their tiled placements.
    actions.fullscreenToggleWindow(w2);
    fx.flush();
    try std.testing.expect(model.coveringOccupantOnWs(m, m.current) == null);
    try fx.expectTiledGeometry(w1);
    try fx.expectTiledGeometry(w2);
    // Exit leaves focus with the window that left fullscreen.
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w2, fx.inputFocus());
}

test "reported flow: cover w1, spawn w2 under cover, cover w2 keeps focus on w2" {
    var fx = try fixture.setUp("pipeline_test");
    defer fx.deinit();
    const m = pipeline.model();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    // Like a real client: map before MapRequest and before X input focus can
    // legally target the window (set_input_focus on an unmapped window is a
    // BadMatch, silently ignored).
    _ = xcb.xcb_map_window(fx.conn, w1);
    _ = xcb.xcb_map_window(fx.conn, w2);
    fx.flush();
    actions.mapRequest(w1, 0, true, null);
    fx.flush();
    try std.testing.expectEqual(w1, m.focused.?);
    try std.testing.expectEqual(w1, fx.inputFocus());

    // 1. Fullscreen w1 (keybind on the focused window).
    actions.fullscreenToggleWindow(w1);
    fx.flush();
    try std.testing.expectEqual(w1, m.focused.?);
    try std.testing.expectEqual(w1, fx.inputFocus());
    try std.testing.expectEqual(w1, (model.coveringOccupantOnWs(m, m.current) orelse return error.NoOccupant));

    // 2. Open w2 while w1 is still fullscreened.
    actions.mapRequest(w2, 0, true, null);
    fx.flush();
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w2, fx.inputFocus());

    // 3. Fullscreen w2 on top of the old fullscreened window.
    actions.fullscreenToggleWindow(w2);
    fx.flush();
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w2, fx.inputFocus());
    try std.testing.expectEqual(w2, (model.coveringOccupantOnWs(m, m.current) orelse return error.NoOccupant));
}

// 12.7: the deferred bar transition is resolved from MODEL TRUTH, and the
// pending entry is per-window. The two properties the single-slot,
// dimensions-only version got wrong: it dropped a second window's pending
// intent, and it re-showed the bar whenever a window's ConfigureNotify stopped
// reporting screen dimensions -- even if the model still recorded a covering
// occupant.
test "pipeline: deferred bar waits for model truth and keeps per-window entries" {
    var fx = try fixture.setUp("pipeline_test");
    defer fx.deinit();
    const cs = core.getState();
    const sw: u16 = @intCast(cs.screen.width_in_pixels);
    const sh: u16 = @intCast(cs.screen.height_in_pixels);
    const small_w: u16 = sw / 2;
    const small_h: u16 = sh / 2;

    const w1, const w2 = seedTwo(fx);

    // 1. A pending HIDE is not confirmed by a non-fullscreen report: the
    //    window must REPORT screen dimensions before the bar moves.
    //    w1 has to be COVERING for a hide to confirm at all, because the
    //    decision is MODEL TRUTH (12.7), not the reported numbers -- which is
    //    exactly what step 2 asserts. This step used to run against a plain
    //    tiled w1 and so demanded a bump the product correctly refuses; it had
    //    never run, because the fixture skips without an X display.
    actions.fullscreenToggleWindow(w1);
    fx.flush();
    fullscreen.armPendingBarHide(w1);
    const before = core.fullscreen.rev();
    fullscreen.notifyConfigureIfPending(w1, small_w, small_h);
    try std.testing.expectEqual(before, core.fullscreen.rev());
    //    The entry survived, so a later matching report still resolves it.
    fullscreen.notifyConfigureIfPending(w1, sw, sh);
    try std.testing.expectEqual(before + 1, core.fullscreen.rev());
    //    Back to NOT covering, which is the premise step 2 depends on.
    actions.fullscreenToggleWindow(w1);
    fx.flush();

    // 2. MODEL TRUTH gates the hide. Screen-sized dimensions with a model that
    //    says NOT covering must NOT move the bar: that combination is a client
    //    reporting fullscreen-shaped geometry after being told to leave, and
    //    hiding the bar there is the bug the dimensions-only version had.
    fullscreen.armPendingBarHide(w1);
    const before2 = core.fullscreen.rev();
    fullscreen.notifyConfigureIfPending(w1, sw, sh);
    try std.testing.expectEqual(before2, core.fullscreen.rev());

    // 3. PER WINDOW: arming w2 must not evict w1's pending entry.
    actions.fullscreenToggleWindow(w1);
    fx.flush();
    const before3 = core.fullscreen.rev();
    fullscreen.armPendingBarHide(w1);
    fullscreen.armPendingBarShow(w2);
    fullscreen.notifyConfigureIfPending(w2, small_w, small_h);
    //    w2's show resolved only because w1 no longer covers the screen.
    try std.testing.expectEqual(before3 + 1, core.fullscreen.rev());
    //    w1's own entry is still pending and still hidden-intent: a second
    //    report resolves it on its own account, not as w2's leftover.
    const before4 = core.fullscreen.rev();
    fullscreen.notifyConfigureIfPending(w1, small_w, small_h);
    try std.testing.expectEqual(before4, core.fullscreen.rev());
    actions.fullscreenToggleWindow(w1);
    fx.flush();
    fullscreen.notifyConfigureIfPending(w1, sw, sh);
    try std.testing.expectEqual(before4 + 1, core.fullscreen.rev());

    // 4. A pending SHOW for a window that still covers does not move the bar:
    //    non-fullscreen dimensions are the show's confirmation, and the model
    //    must also agree nothing covers. w1 has to be IN fullscreen for this
    //    to mean anything: step 3 toggled it back OUT, so the "still covers"
    //    premise the comment had always claimed was not actually true, and
    //    the gate below was therefore never exercised.
    actions.fullscreenToggleWindow(w1);
    fx.flush();
    const before5 = core.fullscreen.rev();
    fullscreen.armPendingBarShow(w1);
    fullscreen.notifyConfigureIfPending(w1, small_w, small_h);
    try std.testing.expectEqual(before5, core.fullscreen.rev()); // w1 still covers
    actions.fullscreenToggleWindow(w1);
    fx.flush();
    // The exit bumps the fact ITSELF, on purpose (actions.zig: "the deferred
    // bar-show arm waits for a non-fullscreen ConfigureNotify, which never
    // arrives when a window's restored anchor IS the screen size"). Because the
    // toggle therefore answers the question, it also RETIRES the arm it left
    // behind, so the ConfigureNotify has nothing left to decide and no second
    // bump happens. This used to read `after_toggle + 1`: the toggle published
    // the exit and the still-armed entry republished the identical bar state,
    // a redundant repaint on every fullscreen exit.
    const after_toggle = core.fullscreen.rev();
    fullscreen.notifyConfigureIfPending(w1, small_w, small_h);
    try std.testing.expectEqual(after_toggle, core.fullscreen.rev());
}

// Leaving fullscreen restores the bar, which re-claims screen space, which
// changes the usable area the windows must tile into. The claim lands while
// the grab is already held -- the fullscreen path unmaps and re-claims the bar
// inside the same grab that re-tiles the windows -- so `reconcileNow` has to
// read the claim LIVE. It used to trust the snapshot `grabScoped` took, which
// tiled into the pre-claim work area: the bar came back but the layout still
// sized as though it were not there, until a workspace switch happened to
// rebuild the ctx and correct it.
test "pipeline: a claim taken after the grab still moves the tiles" {
    var fx = try fixture.setUp("pipeline_test");
    defer fx.deinit();

    const w1, const w2 = seedTwo(fx);
    try fx.expectTiledGeometry(w1);
    try fx.expectTiledGeometry(w2);

    // Before: the tiles fill the screen, starting at the layout's own gap.
    const before = fx.geometry(w1) orelse return error.ClosedWindow;

    // The bar re-claims the top edge INSIDE the grab, which is the ordering
    // that was broken.
    const claim_px: u16 = 30;
    {
        var g = pipeline.grabScoped();
        defer g.deinit();
        usable_area.setClaim(usable_area.bar_id, .top, claim_px);
        defer usable_area.releaseClaim(usable_area.bar_id);
        g.reconcileNow();
    }
    fx.flush();

    // Every tiled window was pushed down by the claim and shrank to fit the
    // reduced area. Asserted against the BEFORE geometry as well as the claim,
    // because "fits inside the work area" alone is satisfied by geometry that
    // never moved -- which is exactly the bug.
    for ([_]u32{ w1, w2 }) |win| {
        const g = fx.geometry(win) orelse return error.ClosedWindow;
        try std.testing.expectEqual(
            @as(i32, before.y) + @as(i32, claim_px),
            @as(i32, g.y),
        );
        try std.testing.expect(g.height < before.height);
        // And the bottom edge respects the claimed work area (not the screen).
        const wa = usable_area.workArea(fx.scr);
        try std.testing.expect(
            @as(i32, g.y) + @as(i32, g.border_width) + @as(i32, g.height) <=
                @as(i32, wa.y) + @as(i32, wa.height),
        );
    }
}
