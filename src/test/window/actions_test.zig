//! X-gated integration tests for the actions layer (src/window/actions.zig):
//! every scenario runs against a live X server through the real
//! mapRequest/reconcile pipeline. When no server is present the tests print
//! SKIP and pass, keeping `zig build test` green headless. The model-side
//! invariants these assert are the same ones actions/reconcile maintain in
//! production; the server-side geometry checks verify the end-to-end tile.

const std = @import("std");

const core = @import("core");
const model = @import("model");
const pipeline = @import("pipeline");
const sync = @import("sync");
const actions = @import("actions");
const tiling = @import("tiling");
const fixture = @import("fixture");

test "actions: mapRequest admits, maps, and focuses a window" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const win = fx.createWindow();
    try std.testing.expect(!m.store.has(win));

    actions.mapRequest(win, 0, true);
    actions.mapRequest(win, 0, true); // double-manage guard: no-op
    fx.flush();

    try std.testing.expect(m.store.has(win));
    try std.testing.expect(m.focused != null and m.focused.? == win);
    try std.testing.expectEqual(@as(usize, 1), model.tiledCountOnWs(m, m.current));
    try std.testing.expect(fx.isViewable(win));
    try std.testing.expectEqual(win, fx.inputFocus());
    try fx.expectTiledGeometry(win);
}

test "actions: moveWindowTo transfers membership and parks off-screen" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const win = fx.createWindow();
    actions.mapRequest(win, 0, true);
    fx.flush();
    try std.testing.expect(m.focused != null and m.focused.? == win);

    actions.moveWindowTo(win, 2);
    fx.flush();

    const e = m.store.get(win) orelse return error.UnknownWindow;
    try std.testing.expectEqual(model.bit(2), e.mask);
    try std.testing.expectEqual(@as(model.WSId, 2), e.home_ws.?);
    try std.testing.expect(!model.visibleOn(m, win, m.current));
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    try fx.expectParked(win);
}

test "actions: tag/detag, pin, and all-workspaces view transitions" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();
    const ws0: u8 = @intCast(m.current);

    const w1 = fx.createWindow();
    actions.mapRequest(w1, 0, true);
    fx.flush();

    // Multi-tag: add tag 2, protecting the current tag.
    actions.tagToggle(w1, 2, true);
    const e1 = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(e1.mask & model.bit(2) != 0);
    try std.testing.expect(e1.mask & model.bit(m.current) != 0);

    // Detag the current tag: evicted from the shown workspace, focus follows
    // (no other candidate -> cleared), window parked.
    actions.tagToggle(w1, ws0, false);
    const e2 = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(e2.mask & model.bit(m.current) == 0);
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    fx.flush();
    try fx.expectParked(w1);

    // Re-add the current tag: window returns and is shown again.
    actions.tagToggle(w1, ws0, false);
    const e3 = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(e3.mask & model.bit(m.current) != 0);
    fx.flush();
    try std.testing.expect(fx.isViewable(w1));

    // Pin: single-tag window becomes everywhere-visible, and back.
    actions.pinToggle(w1);
    try std.testing.expectEqual(model.ALL_MASK, m.store.get(w1).?.mask);
    actions.pinToggle(w1);
    try std.testing.expectEqual(model.bit(m.current), m.store.get(w1).?.mask);

    // All-workspaces view flag flips round-trip.
    actions.allViewToggle();
    try std.testing.expect(m.all_view_active);
    actions.allViewToggle();
    try std.testing.expect(!m.all_view_active);
}

test "actions: minimize parks, restore unmaps-and-redraws" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const win = fx.createWindow();
    actions.mapRequest(win, 0, true);
    fx.flush();
    try std.testing.expect(m.focused != null and m.focused.? == win);

    actions.minimize(win);
    fx.flush();
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    try std.testing.expectEqual(fx.root, fx.inputFocus());
    try fx.expectParked(win);
    try std.testing.expect(fx.isViewable(win)); // parked, not unmapped

    actions.restore(win);
    fx.flush();
    try std.testing.expect(m.focused != null and m.focused.? == win);
    try std.testing.expectEqual(win, fx.inputFocus());
    try fx.expectTiledGeometry(win);
}

test "actions: toggleFloating round-trips through LastSent geometry" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const win = fx.createWindow();
    actions.mapRequest(win, 0, true);
    fx.flush();
    const before = fx.geometry(win) orelse return error.ClosedWindow;

    actions.toggleFloating(win);
    fx.flush();
    const e1 = m.store.get(win) orelse return error.UnknownWindow;
    try std.testing.expect(e1.anchor == .floating);
    try std.testing.expect(e1.home_ws == null);
    const g1 = fx.geometry(win) orelse return error.ClosedWindow;
    try std.testing.expectEqual(before.x, g1.x);
    try std.testing.expectEqual(before.width, g1.width);
    try std.testing.expectEqual(before.height, g1.height);

    actions.toggleFloating(win);
    fx.flush();
    const e2 = m.store.get(win) orelse return error.UnknownWindow;
    try std.testing.expect(e2.anchor == .tiled);
    // home_ws stays null here: in isolation the window was never removed from
    // tiled_order (findHome still resolves it), so repairStrandedHome no-ops.
    try fx.expectTiledGeometry(win); // back on the tiling grid
}

test "actions: unmanage drops the window and re-focuses" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    actions.mapRequest(w1, 0, true);
    actions.mapRequest(w2, 0, true);
    fx.flush();
    try std.testing.expect(m.focused != null and m.focused.? == w2);

    // Non-focused removal is silent for focus.
    // Silent removal, no focus involved.
    var quiet = actions.Ctx{ .withdrawn_was_focused = false };
    actions.unmanage(&quiet, w1);
    fx.flush();
    try std.testing.expect(!m.store.has(w1));
    try std.testing.expect(sync.lastRectFor(w1) == null); // ledger forgot it
    try std.testing.expect(m.store.has(w2));
    try std.testing.expect(m.focused != null and m.focused.? == w2);
    try fx.expectTiledGeometry(w2);

    // Focused removal with no remaining candidate clears to root.
    var withdrawing = actions.Ctx{ .withdrawn_was_focused = true };
    actions.unmanage(&withdrawing, w2);
    fx.flush();
    try std.testing.expect(!m.store.has(w2));
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    try std.testing.expectEqual(fx.root, fx.inputFocus());
}

test "actions: swapPrimary and moveFocused rotate the tiled order" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();
    const order = &m.ws[m.current].tiled_order;

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    const w3 = fx.createWindow();
    actions.mapRequest(w1, 0, true);
    actions.mapRequest(w2, 0, true);
    actions.mapRequest(w3, 0, true);
    fx.flush();
    try std.testing.expect(order.len == 3);
    try std.testing.expect(m.focused != null and m.focused.? == w3);

    // swap_master: head and follower exchange.
    actions.swapPrimaryAction(false);
    try std.testing.expectEqual(w2, order.items[0]);
    try std.testing.expectEqual(w1, order.items[1]);
    try std.testing.expect(m.focused != null and m.focused.? == w3);

    // swap_master focus variant: the displaced follower is focused.
    actions.swapPrimaryAction(true);
    try std.testing.expectEqual(w1, order.items[0]);
    try std.testing.expect(m.focused != null and m.focused.? == w2);

    // moveFocused steps the focused window one slot (wraps off the far edge).
    actions.moveFocused(1);
    try std.testing.expectEqual(w1, order.items[0]);
    try std.testing.expectEqual(w3, order.items[1]);
    try std.testing.expectEqual(w2, order.items[2]);
    try std.testing.expect(m.focused != null and m.focused.? == w2);
}

test "actions: layout parameters adjust within clamps" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();
    const p = &m.ws[m.current].params;

    actions.adjustPrimaryWidthAction(0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), p.primary_width, 1e-4);
    actions.adjustPrimaryWidthAction(-5.0); // clamp to floor
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), p.primary_width, 1e-4);

    actions.adjustSecondaryBalance(0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), p.secondary_balance, 1e-4);
    actions.adjustSecondaryBalance(-10.0); // clamp to floor
    try std.testing.expectApproxEqAbs(@as(f32, -6.0), p.secondary_balance, 1e-4);

    actions.adjustPrimaryCount(1);
    try std.testing.expectEqual(@as(u8, 2), p.primary_count);
    actions.adjustPrimaryCount(-5); // clamp to 1
    try std.testing.expectEqual(@as(u8, 1), p.primary_count);
}

test "actions: layout kind and variant step through the registry" {
    var fx = fixture.setUp("actions_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();
    const p = &m.ws[m.current].params;

    // cycleLayoutKind cycles the CONFIG layout list (seeded by the fixture in
    // canonical module order), not a per-test candidate list.
    const cfg_layouts = core.getState().config.tiling.layouts.items;
    try std.testing.expect(cfg_layouts.len >= 2); // fixture seeds compiled modules

    const start_kind = p.kind;
    actions.cycleLayoutKind(1);
    try std.testing.expectEqual(
        tiling.cycleKind(start_kind, 1, cfg_layouts),
        p.kind,
    );
    try std.testing.expectEqual(@as(u8, 0), p.variant_idx); // reset on cycle

    const after = p.kind;
    actions.cycleLayoutKind(-1);
    try std.testing.expectEqual(
        tiling.cycleKind(after, -1, cfg_layouts),
        p.kind,
    );

    // Step variants on a layout that actually has them: sweep forward to the
    // first registry kind with variant_count > 1 (the seed list order makes
    // this deterministic per build); if none is compiled, the stepping
    // assertions are vacuous and skipped.
    var guard: usize = 0;
    while (tiling.variantCount(p.kind) <= 1 and guard < cfg_layouts.len) : (guard += 1)
        actions.cycleLayoutKind(1);
    if (tiling.variantCount(p.kind) > 1) {
        actions.stepVariantDir(1);
        try std.testing.expectEqual(@as(u8, 1), p.variant_idx);
        actions.stepVariantDir(1);
        try std.testing.expectEqual(@as(u8, 0), p.variant_idx); // wrapped
    }
}
