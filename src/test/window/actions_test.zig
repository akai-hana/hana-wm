//! X-gated integration tests for the command layer: every scenario runs
//! against a live X server through the real admission/reconcile pipeline.
//! When no server is present the tests print SKIP and pass, keeping
//! `zig build test` green headless. The model-side invariants these assert
//! are the same ones the commands maintain in production; the server-side
//! geometry checks verify the end-to-end tile.
//!
//! The commands live with the module that owns the state they write, so the
//! test reaches each one there (or through `window` for the always-present
//! transitions). Each module named below is a `build-gate` feature: the gate
//! line declares exactly what these imports make necessary.

// Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that must be kept in agreement with them by hand.
// build-gate: tiling, floating, minimize, workspaces

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const model = @import("model");
const pipeline = @import("pipeline");
const window = @import("window");
const workspaces = @import("workspaces");
const minimize = @import("minimize");
const floating = @import("floating");
const tiling = @import("tiling");
const fixture = @import("fixture");
const reconcile = @import("reconcile");
const title_cache = @import("title_cache");
const events = @import("events");
const registry = @import("registry");
const atoms = @import("atoms");
test "actions: mapRequest admits, maps, and focuses a window" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    try std.testing.expect(!m.store.has(win));

    window.mapRequest(win, 0, true, null, null);
    window.mapRequest(win, 0, true, null, null); // double-manage guard: no-op
    fx.flush();

    try std.testing.expect(m.store.has(win));
    try std.testing.expectEqual(win, m.focused.?);
    try std.testing.expectEqual(@as(usize, 1), model.tiledCountOnWs(m, m.current));
    try std.testing.expect(fx.isViewable(win));
    try std.testing.expectEqual(win, fx.inputFocus());
    try fx.expectTiledGeometry(win);
}

test "actions: mapRequest admits a float-rule window floating at its rect" {
    var fx = try fixture.setUp("actions_float");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    const rect = model.Rect{ .x = 40, .y = 30, .width = 320, .height = 240 };
    window.mapRequest(win, 0, true, rect, null);
    fx.flush();

    const e = m.store.get(win) orelse return error.ExpectedManaged;
    try std.testing.expect(e.anchor == .floating);
    try std.testing.expectEqual(rect.x, e.anchor.floating.x);
    try std.testing.expectEqual(rect.y, e.anchor.floating.y);
    try std.testing.expectEqual(rect.width, e.anchor.floating.width);
    try std.testing.expectEqual(rect.height, e.anchor.floating.height);
    try std.testing.expectEqual(@as(?model.WSId, null), e.home_ws);
    try std.testing.expectEqual(@as(usize, 0), model.tiledCountOnWs(m, m.current));

    const g = fx.geometry(win) orelse return error.ClosedWindow;
    try std.testing.expectEqual(rect.width, g.width);
    try std.testing.expectEqual(rect.height, g.height);
    try std.testing.expectEqual(rect.x, @as(i16, @intCast(g.x)));
    try std.testing.expectEqual(rect.y, @as(i16, @intCast(g.y)));
    try std.testing.expect(fx.isViewable(win));
}

test "actions: moveWindowTo transfers membership and parks off-screen" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();
    try std.testing.expectEqual(win, m.focused.?);

    workspaces.moveToWorkspace(win, 2);
    fx.flush();

    const e = m.store.get(win) orelse return error.UnknownWindow;
    try std.testing.expectEqual(model.bit(model.WSId.fromIndex(2)), e.mask);
    try std.testing.expectEqual(model.WSId.fromIndex(2), e.home_ws.?);
    try std.testing.expect(!model.visibleOn(m, win, m.current));
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    try fx.expectParked(win);
}

test "actions: tag/detag, pin, and all-workspaces view transitions" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();
    const ws0: u8 = @intCast(m.current.index);

    const w1 = fx.createWindow();
    window.mapRequest(w1, 0, true, null, null);
    fx.flush();

    // Multi-tag: add tag 2, protecting the current tag.
    workspaces.toggleTag(w1, 2, true);
    const e1 = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(model.taggedOn(e1, model.WSId.fromIndex(2)));
    try std.testing.expect(model.taggedOn(e1, m.current));

    // Detag the current tag: evicted from the shown workspace, focus follows
    // (no other candidate -> cleared), window parked.
    workspaces.toggleTag(w1, ws0, false);
    const e2 = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(!model.taggedOn(e2, m.current));
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    fx.flush();
    try fx.expectParked(w1);

    // Re-add the current tag: window returns and is shown again.
    workspaces.toggleTag(w1, ws0, false);
    const e3 = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(model.taggedOn(e3, m.current));
    fx.flush();
    try std.testing.expect(fx.isViewable(w1));

    // Pin: single-tag window becomes everywhere-visible, and back.
    workspaces.pinWindow(w1);
    try std.testing.expectEqual(model.ALL_MASK, m.store.get(w1).?.mask);
    workspaces.pinWindow(w1);
    try std.testing.expectEqual(model.bit(m.current), m.store.get(w1).?.mask);

    // All-workspaces view flag flips round-trip.
    workspaces.allWorkspaces();
    try std.testing.expect(m.all_view_active);
    workspaces.allWorkspaces();
    try std.testing.expect(!m.all_view_active);
}

test "actions: switching to the CURRENT workspace while in all-view exits it" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();
    const ws0: u8 = @intCast(m.current.index);

    const w1 = fx.createWindow();
    window.mapRequest(w1, 0, true, null, null);
    fx.flush();

    // w2 lives on a neighbor workspace, hidden from the current one.
    const w2 = fx.createWindow();
    window.mapRequest(w2, 0, true, null, null);
    workspaces.moveToWorkspace(w2, 2);
    fx.flush();
    try std.testing.expect(model.visibleOn(m, w2, m.current) == false);

    // Enter all-view: every workspace's windows become visible.
    workspaces.allWorkspaces();
    fx.flush();
    try std.testing.expect(m.all_view_active);
    try std.testing.expect(model.visibleOn(m, w2, m.current));

    // Switching to the current workspace (a no-op when the view is already
    // this workspace) must still exit the all-view flag and park the foreign
    // window, returning focus to workspace-1's own window.
    workspaces.switchWorkspace(ws0);
    fx.flush();
    try std.testing.expect(!m.all_view_active);
    try std.testing.expectEqual(ws0, m.current.index);
    try std.testing.expect(!model.visibleOn(m, w2, m.current));
    try std.testing.expectEqual(w1, m.focused.?);
    try fx.expectParked(w2);
}

test "actions: minimize parks, restore unmaps-and-redraws" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();
    try std.testing.expectEqual(win, m.focused.?);

    minimize.minimizeWindow(win);
    fx.flush();
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    try std.testing.expectEqual(fx.root, fx.inputFocus());
    try fx.expectParked(win);
    try std.testing.expect(fx.isViewable(win)); // parked, not unmapped

    minimize.unminimize(win);
    fx.flush();
    try std.testing.expectEqual(win, m.focused.?);
    try std.testing.expectEqual(win, fx.inputFocus());
    try fx.expectTiledGeometry(win);
}

test "actions: toggleFloating round-trips through LastSent geometry" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();
    const before = fx.geometry(win) orelse return error.ClosedWindow;

    floating.toggleFloating(win);
    fx.flush();
    const e1 = m.store.get(win) orelse return error.UnknownWindow;
    try std.testing.expect(e1.anchor == .floating);
    try std.testing.expect(e1.home_ws == null);
    const g1 = fx.geometry(win) orelse return error.ClosedWindow;
    try std.testing.expectEqual(before.x, g1.x);
    try std.testing.expectEqual(before.width, g1.width);
    try std.testing.expectEqual(before.height, g1.height);

    floating.toggleFloating(win);
    fx.flush();
    const e2 = m.store.get(win) orelse return error.UnknownWindow;
    try std.testing.expect(e2.anchor == .tiled);
    // The detach removed the tiled_order membership for real; re-entry
    // re-adds it (repairStrandedHome), so the window is a tiled member again.
    try std.testing.expect(e2.home_ws != null);
    try std.testing.expectEqual(@as(usize, 1), model.tiledCountOnWs(m, m.current));
    try fx.expectTiledGeometry(win); // back on the tiling grid
}

test "actions: dragging a tiled window out detaches AND reflows the pile (no gap)" {
    var fx = try fixture.setUp("actions_drag");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    const w3 = fx.createWindow();
    window.mapRequest(w1, 0, true, null, null);
    window.mapRequest(w2, 0, true, null, null);
    window.mapRequest(w3, 0, true, null, null);
    fx.flush();

    // Baseline: three tiled windows (the fixture's default layout kind).
    try fx.expectTiledGeometry(w1);
    try fx.expectTiledGeometry(w2);
    try fx.expectTiledGeometry(w3);
    const g2 = fx.geometry(w2) orelse return error.ClosedWindow;
    const g3 = fx.geometry(w3) orelse return error.ClosedWindow;

    // Real drag: press (Super+left) on w2, first motion detaches it to
    // floating (pending-float), ticks move it, release ends the drag.
    const px: i16 = @intCast(@as(i32, g2.x) + @as(i32, g2.width) - 4);
    const py: i16 = @intCast(@as(i32, g2.y) + 4);
    window.dispatchAll(.startDrag, .{ w2, 1, px, py });
    window.dispatchAll(.updateDrag, .{ px + 8, py + 8, false }); // first motion: detach + retile
    window.dispatchAll(.updateDrag, .{ px + 60, py + 60, false }); // subsequent tick
    window.dispatchAll(.stopDrag, .{});
    fx.flush();

    // w2 is floating and out of the pile.
    const e2 = m.store.get(w2) orelse return error.UnknownWindow;
    try std.testing.expect(e2.anchor == .floating);
    try std.testing.expectEqual(@as(?model.WSId, null), e2.home_ws);
    try std.testing.expectEqual(@as(usize, 2), model.tiledCountOnWs(m, m.current));

    // NO GAP: w3 reflowed off the pile into the freed slot (server truth =
    // current engine placement) and grew to cover it.
    try fx.expectTiledGeometry(w3);
    const g3_after = fx.geometry(w3) orelse return error.ClosedWindow;
    try std.testing.expect(g3_after.height > g3.height);
    // w1 stays put.
    try fx.expectTiledGeometry(w1);
    // w2 moved with the drag (floating, off the tile)
    const g2_after = fx.geometry(w2) orelse return error.ClosedWindow;
    try std.testing.expect(g2_after.x != g2.x or g2_after.y != g2.y);
}

test "actions: unmanage drops the window and re-focuses" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    window.mapRequest(w1, 0, true, null, null);
    window.mapRequest(w2, 0, true, null, null);
    fx.flush();
    try std.testing.expectEqual(w2, m.focused.?);

    // Non-focused removal is silent for focus.
    // Silent removal, no focus involved.
    window.unmanage(w1);
    fx.flush();
    try std.testing.expect(!m.store.has(w1));
    try std.testing.expect(reconcile.lastRectFor(w1) == null); // ledger forgot it
    try std.testing.expect(m.store.has(w2));
    try std.testing.expectEqual(w2, m.focused.?);
    try fx.expectTiledGeometry(w2);

    // Focused removal with no remaining candidate clears to root.
    window.unmanage(w2);
    fx.flush();
    try std.testing.expect(!m.store.has(w2));
    try std.testing.expect(@as(?model.WindowId, null) == m.focused);
    try std.testing.expectEqual(fx.root, fx.inputFocus());
}

test "actions: swapPrimaryAction and moveFocused rotate the tiled order" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();
    const order = &m.ws[m.current.index].tiled_order;

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    const w3 = fx.createWindow();
    window.mapRequest(w1, 0, true, null, null);
    window.mapRequest(w2, 0, true, null, null);
    window.mapRequest(w3, 0, true, null, null);
    fx.flush();
    try std.testing.expect(order.len == 3);
    try std.testing.expectEqual(w3, m.focused.?);

    // swap_master: the focused window (w3) and the previously focused one (w2)
    // exchange tiled slots, wherever they sit; focus stays on w3.
    window.swapPrimaryAction(false);
    try std.testing.expectEqual(w1, order.items[0]);
    try std.testing.expectEqual(w3, order.items[1]);
    try std.testing.expectEqual(w2, order.items[2]);
    try std.testing.expectEqual(w3, m.focused.?);

    // swap_master focus variant: the pair swaps once more (toggling back) and
    // focus moves to the previously focused displaced window.
    window.swapPrimaryAction(true);
    try std.testing.expectEqual(w1, order.items[0]);
    try std.testing.expectEqual(w2, order.items[1]);
    try std.testing.expectEqual(w3, order.items[2]);
    try std.testing.expectEqual(w2, m.focused.?);

    // moveFocused steps the focused window one slot (wraps off the far edge).
    window.moveFocused(1);
    try std.testing.expectEqual(w1, order.items[0]);
    try std.testing.expectEqual(w3, order.items[1]);
    try std.testing.expectEqual(w2, order.items[2]);
    try std.testing.expectEqual(w2, m.focused.?);
}

test "actions: layout parameters adjust within clamps" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();
    const p = &m.ws[m.current.index].params;

    window.adjustPrimaryWidthAction(0.2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), p.primary_width, 1e-4);
    window.adjustPrimaryWidthAction(-5.0); // clamp to floor
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), p.primary_width, 1e-4);

    window.adjustSecondaryBalance(0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), p.secondary_balance, 1e-4);
    window.adjustSecondaryBalance(-10.0); // clamp to floor
    try std.testing.expectApproxEqAbs(@as(f32, -6.0), p.secondary_balance, 1e-4);

    window.adjustPrimaryCount(1);
    try std.testing.expectEqual(@as(u8, 2), p.primary_count);
    window.adjustPrimaryCount(-5); // clamp to 1
    try std.testing.expectEqual(@as(u8, 1), p.primary_count);
}

test "actions: layout kind and variant step through the registry" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();
    const p = &m.ws[m.current.index].params;

    // cycleLayoutKind cycles the CONFIG layout list (seeded by the fixture in
    // canonical module order), not a per-test candidate list.
    const cfg_layouts = core.getState().config.tiling.layouts.items;
    try std.testing.expect(cfg_layouts.len >= 2); // fixture seeds compiled modules

    const start_kind = p.kind;
    window.cycleLayoutKind(1);
    try std.testing.expectEqual(
        tiling.cycleKind(start_kind, 1, cfg_layouts),
        p.kind,
    );
    try std.testing.expectEqual(@as(u8, 0), p.variant_idx); // reset on cycle

    const after = p.kind;
    window.cycleLayoutKind(-1);
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
        window.cycleLayoutKind(1);
    if (tiling.variantCount(p.kind) > 1) {
        window.stepVariantDir(1);
        try std.testing.expectEqual(@as(u8, 1), p.variant_idx);
        window.stepVariantDir(1);
        try std.testing.expectEqual(@as(u8, 0), p.variant_idx); // wrapped
    }
}

// The fact-bump invariant, pinned at the entry that owns it.
//
// Eight actions reconcile through `pipeline.reconcileGrab(.{})`. The bump
// lives inside that entry, not in the callers, and the `retile` paths are
// covered by the geometry assertions above, which all route through it.
//
// X-gated like the rest of this file: `reconcileGrab` takes a real server
// grab, so this skips headless.
test "actions: the default reconcile entry bumps the window fact" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();

    // A tiling op that reconciles through the plain alias: toggleFloating
    // ends in pipeline.reconcileGrab with no focus handoff.
    const before = core.window.rev();
    floating.toggleFloating(win);
    fx.flush();
    try std.testing.expect(core.window.rev() != before);
}

// The layout fact is how the bar learns that what the layout/variants
// segments render changed. Those two render the ACTIVE workspace's
// per-workspace kind/variant, which the window fact the switch always bumps
// does not carry: without a conditional layout bump the variants indicator
// went stale on a switch until an unrelated segment's redraw request
// repainted the row. X-gated like the rest of this file (switchWorkspace
// reconciles under a real server grab).
test "actions: a workspace switch bumps the layout fact only when the variant differs" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.mut();
    const home: u8 = @intCast(m.current.index);
    const other: u8 = if (home == 0) 1 else 0;

    // Park both workspaces on a layout that HAS variants (the fixture seeds
    // kind 0, which may be a variant-less registry entry where there is no
    // indicator to compare), at the same variant.
    const cfg_layouts = core.getState().config.tiling.layouts.items;
    var kind: u8 = m.ws[home].params.kind;
    var guard: usize = 0;
    while (tiling.variantCount(kind) <= 1 and guard < cfg_layouts.len) : (guard += 1)
        kind = tiling.cycleKind(kind, 1, cfg_layouts);
    if (tiling.variantCount(kind) <= 1) return; // no multi-variant layout compiled
    m.ws[home].params.kind = kind;
    m.ws[other].params.kind = kind;
    m.ws[home].params.variant_idx = 0;
    m.ws[other].params.variant_idx = 0;

    // Identical kind+variant on both sides: nothing the segments render
    // changes, so no layout revision is owed.
    const flat = core.layout.rev();
    workspaces.switchWorkspace(other);
    fx.flush();
    try std.testing.expectEqual(other, m.current.index);
    try std.testing.expectEqual(flat, core.layout.rev());

    // A variant only a cycle_variants ON the far workspace could have left
    // behind: switching across it is what must carry the difference to the
    // bar, in both directions.
    m.ws[other].params.variant_idx = 1;
    const stepped = core.layout.rev();

    workspaces.switchWorkspace(home);
    fx.flush();
    try std.testing.expectEqual(stepped + 1, core.layout.rev());

    workspaces.switchWorkspace(other);
    fx.flush();
    try std.testing.expectEqual(stepped + 2, core.layout.rev());
}

// P1-10 / ICCCM 4.1.5: a DENIED ConfigureRequest must still be answered with
// a synthetic ConfigureNotify carrying the geometry the window actually has,
// so a self-resizing client learns the WM overruled it instead of wedging
// mid-resize against its own idea of its size. The denial branch this pins is
// the one every tiled window takes -- and, in a floating-less build with no
// honorConfigureRequest provider, the ONLY managed branch there is (see the
// floating scenario note in check-modularity.sh).
test "actions: a denied ConfigureRequest gets a synthetic ConfigureNotify" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();
    const sent = fx.sentGeometry(win) orelse return error.NoLedgerEntry;

    // A self-resizing tiled client asking for a size the layout owns.
    var ev: xcb.xcb_configure_request_event_t = std.mem.zeroes(xcb.xcb_configure_request_event_t);
    ev.response_type = xcb.XCB_CONFIGURE_REQUEST;
    ev.window = win;
    ev.value_mask = xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
    ev.width = sent.width + 100;
    ev.height = sent.height + 100;
    window.handleConfigureRequest(&ev);
    fx.flush();

    // Round trip so the synthetic event is sitting in our own queue (the
    // connection selected StructureNotify on the window at admission).
    _ = fx.inputFocus();
    var echoed: ?xcb.xcb_configure_notify_event_t = null;
    while (xcb.xcb_poll_for_event(fx.conn)) |raw| {
        defer std.c.free(raw);
        if (raw.*.response_type & 0x7F != xcb.XCB_CONFIGURE_NOTIFY) continue;
        const n: *const xcb.xcb_configure_notify_event_t = @ptrCast(@alignCast(raw));
        if (n.window == win) echoed = n.*;
    }
    const n = echoed orelse return error.NoSyntheticConfigureNotify;

    // The echo is the DENIED truth (layout geometry), not the request.
    try std.testing.expectEqual(sent.width, n.width);
    try std.testing.expectEqual(sent.height, n.height);
    try std.testing.expectEqual(sent.x, n.x);
    try std.testing.expectEqual(sent.y, n.y);
    // And the request really was denied: the window kept its layout size.
    try fx.expectTiledGeometry(win);
}

// P1-11: a dialog (WM_TRANSIENT_FOR) must map floating and centered over its
// parent -- the placement toolkits expect when they set the ICCCM hint
// before mapping a dialog. Drives the PRODUCTION event entry
// (handleMapRequest), which fires and drains the transient cookie; the
// centering arithmetic itself is pinned headlessly by model_test's
// centerRectIn test.
test "actions: a WM_TRANSIENT_FOR dialog maps floating, centered over its parent" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();

    const parent = fx.createWindow();
    window.mapRequest(parent, 0, true, null, null);
    fx.flush();
    const parent_rect = fx.sentGeometry(parent) orelse return error.NoLedgerEntry;

    // The dialog's own pre-map size, like a toolkit sizing its toplevel
    // before mapping.
    const dialog = fx.createWindow();
    const size = [_]u32{ 400, 300 };
    _ = xcb.xcb_configure_window(fx.conn, dialog, xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT, &size);
    // WM_TRANSIENT_FOR = parent, set before the MapRequest.
    _ = xcb.xcb_change_property(
        fx.conn,
        xcb.XCB_PROP_MODE_REPLACE,
        dialog,
        xcb.XCB_ATOM_WM_TRANSIENT_FOR,
        xcb.XCB_ATOM_WINDOW,
        32,
        1,
        &[_]u32{parent},
    );
    fx.flush();

    var ev: xcb.xcb_map_request_event_t = std.mem.zeroes(xcb.xcb_map_request_event_t);
    ev.response_type = xcb.XCB_MAP_REQUEST;
    ev.window = dialog;
    window.handleMapRequest(&ev);
    fx.flush();

    // Floating anchor, and the centered-over-parent rect on the wire.
    const e = m.store.get(dialog) orelse return error.UnknownDialog;
    try std.testing.expect(e.anchor == .floating);
    const want = model.centerRectIn(parent_rect, 400, 300, fx.workArea());
    try std.testing.expect(want.eqlGeom(fx.sentGeometry(dialog) orelse return error.NoLedgerEntry));
}

// P1-12: a rename-looping client's PropertyNotify storm must coalesce into
// ONE title fetch per event batch: each notify only MARKS the window, the
// cache is untouched until the batch-end flush, and the flush converges on
// the property's FINAL value (not an intermediate one).
test "actions: title PropertyNotify storms coalesce into one batch refresh" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();

    // Rename-loop: several writes + notifies before any batch end.
    const titles = [_][]const u8{ "one", "two", "three" };
    for (titles) |t| {
        _ = xcb.xcb_change_property(
            fx.conn,
            xcb.XCB_PROP_MODE_REPLACE,
            win,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(t.len),
            t.ptr,
        );
        fx.flush();
        var ev: xcb.xcb_property_notify_event_t = std.mem.zeroes(xcb.xcb_property_notify_event_t);
        ev.response_type = xcb.XCB_PROPERTY_NOTIFY;
        ev.window = win;
        ev.atom = xcb.XCB_ATOM_WM_NAME;
        window.handlePropertyNotify(&ev);
    }

    // Marked, not fetched: one dirty window, cache still at the admission
    // default (no title was ever fetched for this window).
    try std.testing.expectEqual(@as(usize, 1), window.pendingPropertyRefreshCount());
    try std.testing.expectEqualStrings("", title_cache.peekTitle(win));

    // Batch end: one refresh per dirty window, converging on "three".
    window.flushPropertyRefresh();
    try std.testing.expectEqual(@as(usize, 0), window.pendingPropertyRefreshCount());
    try std.testing.expectEqualStrings("three", title_cache.peekTitle(win));
}

/// Writes an 8-bit string property on `win` the way a client sets a title.
fn setTitleProperty(fx: *fixture.Fx, win: u32, prop: u32, prop_type: u32, data: []const u8) void {
    _ = xcb.xcb_change_property(
        fx.conn,
        xcb.XCB_PROP_MODE_REPLACE,
        win,
        prop,
        prop_type,
        8,
        @intCast(data.len),
        data.ptr,
    );
    fx.flush();
}

/// Marks `win`'s title dirty through the production event entry point, then
/// runs the batch-end flush that actually fetches it.
fn refreshTitleOverWire(fx: *fixture.Fx, win: u32) void {
    var ev: xcb.xcb_property_notify_event_t = std.mem.zeroes(xcb.xcb_property_notify_event_t);
    ev.response_type = xcb.XCB_PROPERTY_NOTIFY;
    ev.window = win;
    ev.atom = atoms.getAtomOrZero("_NET_WM_NAME");
    window.handlePropertyNotify(&ev);
    window.flushPropertyRefresh();
    fx.flush();
}

// The title fetch asks for `max_title_len` 32-bit units -- four bytes each --
// so the server returns up to 1024 bytes and the reply can outrun the 256-byte
// cache buffer. Rejecting that reply (the old `len > buf.len` guard) refused
// BOTH properties, pickTitle fell through to "", and the bar painted a blank
// title segment for exactly the windows with the longest titles. The reply
// must be truncated instead of dropped.
test "actions: an over-long title is cached truncated instead of dropped" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();

    // Both properties past the cap, so the WM_NAME fallback cannot mask a
    // _NET_WM_NAME miss (that is the real-world shape: toolkits set both).
    var long: [400]u8 = undefined;
    @memset(&long, 'a');
    long[0] = 'A';
    const net_wm_name = atoms.getAtomOrZero("_NET_WM_NAME");
    const utf8_string = atoms.getAtomOrZero("UTF8_STRING");
    try std.testing.expect(net_wm_name != 0 and utf8_string != 0);
    setTitleProperty(fx, win, net_wm_name, utf8_string, &long);
    setTitleProperty(fx, win, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, &long);
    refreshTitleOverWire(fx, win);

    const got = title_cache.peekTitle(win);
    try std.testing.expectEqual(@as(usize, title_cache.max_title_len), got.len);
    try std.testing.expectEqualStrings(long[0..title_cache.max_title_len], got);
}

// The byte cap can land inside a multi-byte UTF-8 character (the arrow's lead
// byte sits exactly on the cap's last byte here). Pango rejects invalid UTF-8
// outright and paints NOTHING, so a truncated title must end on a whole
// character -- otherwise the fix for the blank segment would just move the
// blank from "no bytes" to "invalid bytes".
test "actions: a title cut mid-character caches the last whole character" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();

    var long: [300]u8 = undefined;
    @memset(&long, 'a');
    long[255] = 0xE2; // U+2192 RIGHTWARDS ARROW, lead byte on the cap's last byte
    long[256] = 0x86;
    long[257] = 0x92;
    const net_wm_name = atoms.getAtomOrZero("_NET_WM_NAME");
    const utf8_string = atoms.getAtomOrZero("UTF8_STRING");
    try std.testing.expect(net_wm_name != 0 and utf8_string != 0);
    setTitleProperty(fx, win, net_wm_name, utf8_string, &long);
    refreshTitleOverWire(fx, win);

    const got = title_cache.peekTitle(win);
    try std.testing.expectEqual(@as(usize, 255), got.len);
    try std.testing.expectEqualStrings(long[0..255], got);
    try std.testing.expect(std.unicode.utf8ValidateSlice(got));
}

// P1-15: global_layout must make a layout cycle propagate to EVERY
// workspace; with the flag off, only the current workspace changes. This
// pins the flag as real behavior (it was a parsed-but-inert knob before).
test "actions: global_layout propagates a layout cycle to all workspaces" {
    var fx = try fixture.setUp("actions_test");
    defer fx.deinit();
    const m = pipeline.state();
    const cfg_layouts = core.getState().config.tiling.layouts.items;
    if (cfg_layouts.len < 2) return error.SkipZigTest; // need something to cycle to

    // global_layout = true: every workspace's kind follows the current one.
    core.getState().config.tiling.global_layout = true;
    const start_kind = m.ws[m.current.index].params.kind;
    window.cycleLayoutKind(1);
    const cycled = m.ws[m.current.index].params.kind;
    try std.testing.expect(cycled != start_kind);
    for (m.ws, 0..) |s, i| {
        if (i == m.current.index) continue;
        try std.testing.expectEqual(cycled, s.params.kind);
        try std.testing.expectEqual(@as(u8, 0), s.params.variant_idx);
    }

    // global_layout = false: only the current workspace moves; the rest keep
    // the kind the previous (global) cycle stamped.
    core.getState().config.tiling.global_layout = false;
    const before = m.ws[m.current.index].params.kind;
    const other_idx = (m.current.index + 1) % m.ws.len;
    const other_before = m.ws[other_idx].params.kind;
    window.cycleLayoutKind(1);
    try std.testing.expect(m.ws[m.current.index].params.kind != before);
    try std.testing.expectEqual(other_before, m.ws[other_idx].params.kind);
}

// P1-19 / P1-40: onWindowGone must fan out EXACTLY once per window
// lifecycle. Every hook binding it is idempotent (find-then-clear), so
// module state alone cannot show a double fire -- only registry's dispatch
// fire count can. The events.zig pre-fire that used to fire BEFORE
// delegating to the destroy path is gone; this test drives THAT handler (the
// events-level entry), so re-adding a second fire site regresses it even
// though every hook would stay happy.
test "actions: a managed destroy fires onWindowGone exactly once" {
    var fx = try fixture.setUp("actions_destroy");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();
    try std.testing.expect(m.store.has(win));

    registry.onWindowGone_fires = 0;
    var e: xcb.xcb_destroy_notify_event_t = std.mem.zeroes(xcb.xcb_destroy_notify_event_t);
    e.response_type = xcb.XCB_DESTROY_NOTIFY;
    e.event = win;
    e.window = win;
    events.handleDestroyNotify(@ptrCast(&e));
    fx.flush();

    try std.testing.expectEqual(@as(usize, 1), registry.onWindowGone_fires);
    try std.testing.expect(!m.store.has(win));
}

test "actions: the withdraw route fires onWindowGone once; its later destroy adds none" {
    var fx = try fixture.setUp("actions_withdraw");
    defer fx.deinit();
    const m = pipeline.state();

    const win = fx.createWindow();
    window.mapRequest(win, 0, true, null, null);
    fx.flush();

    registry.onWindowGone_fires = 0;
    var unmap: xcb.xcb_unmap_notify_event_t = std.mem.zeroes(xcb.xcb_unmap_notify_event_t);
    unmap.response_type = xcb.XCB_UNMAP_NOTIFY;
    unmap.event = win;
    unmap.window = win;
    window.handleUnmapNotify(&unmap); // the ONLY fire on the withdraw route
    fx.flush();
    try std.testing.expectEqual(@as(usize, 1), registry.onWindowGone_fires);
    try std.testing.expect(!m.store.has(win));

    // The DestroyNotify that follows a withdraw must add NO second fire:
    // the entry is already gone (handleDestroyNotify's managed gate) and
    // events no longer pre-fires.
    var d: xcb.xcb_destroy_notify_event_t = std.mem.zeroes(xcb.xcb_destroy_notify_event_t);
    d.response_type = xcb.XCB_DESTROY_NOTIFY;
    d.event = win;
    d.window = win;
    events.handleDestroyNotify(@ptrCast(&d));
    fx.flush();
    try std.testing.expectEqual(@as(usize, 1), registry.onWindowGone_fires);
}
