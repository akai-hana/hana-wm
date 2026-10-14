//! Unit tests for the model layer.
// Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: minimize, fullscreen, floating, workspaces, tiling

const std = @import("std");
const testing = std.testing;

// Overflow tests (MRU/order/max budgets) deliberately trip BoundedList's
// warn-level overflow diagnostic; src/core/pure/log.zig silences all
// std.log diagnostics in test binaries, so this stays quiet on success.
const model = @import("model");
const constants = @import("constants");
const helpers = @import("helpers");
const build_options = @import("build_options");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const floating = if (build_options.has_floating) @import("floating") else struct {};
const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};
// The model's kind is an opaque u8 stepped through a representative config
// name list (no-op when the tiling subsystem is absent).
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};
const test_cycle_names = helpers.std_layout_names;
fn stepCycle(m: *Model, dir: i32) void {
    if (!build_options.has_tiling) return;
    m.ws[m.current.index].params.kind = tiling.cycleKind(
        m.ws[m.current.index].params.kind,
        dir,
        &test_cycle_names,
    );
    m.ws[m.current.index].params.variant_idx = 0;
}

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;
const max_minimized = constants.max_minimized;
const SmallStore = model.Store(u32, u8, 2);

/// Sentinel id for "a window that was never registered": every negative-path
/// assertion (unknown/unregistered lookups) uses it instead of a literal.
const unknown_win: WindowId = 999;
/// Out-of-range tiled position: reorder must clamp it to the last slot.
const far_position: usize = 99;

/// Resetting fixture: a fresh model on deterministically re-armed module
/// stores (minimize/fullscreen), so tests pass in any order regardless of
/// what records an earlier test left behind.
const makeModel = helpers.makeModel; // Reset is now the default, not a separate entry point

const regCur = helpers.regCur;
const expectOrder = helpers.expectOrder;
const addFloating = helpers.addFloating;
const registerRange = helpers.registerRange;

fn eqBase(a: model.BaseMode, b: model.BaseMode) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .tiled => true,
        .floating => |r| r.eql(b.floating),
    };
}

fn eqEntry(a: *const model.Entry, b: *const model.Entry) bool {
    return a.mask == b.mask and a.presence == b.presence and eqBase(a.anchor, b.anchor);
}

fn eqModel(a: *const Model, b: *const Model) bool {
    if (a.store.count() != b.store.count()) return false;
    for (0..a.store.count()) |i| {
        const ia = a.store.at(i);
        const ib = b.store.at(i);
        if (ia.key != ib.key) return false;
        if (!eqEntry(ia.val, ib.val)) return false;
    }
    if (a.current.index != b.current.index) return false;
    if (a.focused != b.focused) return false;
    if (a.all_view_active != b.all_view_active) return false;
    for (&a.ws, &b.ws) |*sa, *sb| {
        if (!std.mem.eql(WindowId, sa.tiled_order.constSlice(), sb.tiled_order.constSlice()))
            return false;
        if (!std.mem.eql(WindowId, sa.focus_mru.constSlice(), sb.focus_mru.constSlice()))
            return false;
        if (sa.params.kind != sb.params.kind) return false;
        if (sa.params.variant_idx != sb.params.variant_idx) return false;
        if (sa.params.primary_width != sb.params.primary_width) return false;
        if (sa.params.primary_count != sb.params.primary_count) return false;
        if (sa.params.secondary_balance != sb.params.secondary_balance) return false;
        // The viewport fields were NOT compared, so a determinism replay
        // that diverged in scroll offset or history passed as equal. Both are
        // per-workspace layout params that a preReconcile duty mutates, which
        // is exactly the kind of state a replay has to catch.
        if (sa.params.viewport_offset != sb.params.viewport_offset) return false;
        if (sa.params.viewport_prev_count != sb.params.viewport_prev_count) return false;
    }
    return true;
}

/// Every window whose anchor is tiled AND present appears in EXACTLY ONE workspace's
/// list; every listed id exists in the store (single-membership invariant).
/// Floating and parked (minimized) windows are home-free.
fn assertSingleMembership(m: *const Model) !void {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        // A parked window keeps its anchor but has no tiled slot by design.
        const tiled = (it.val.anchor == .tiled and it.val.presence == .present);
        if (!tiled) continue;
        var homes: usize = 0;
        var actual_home: WSId = undefined;
        for (&m.ws, 0..) |*s, wi| {
            if (s.tiled_order.indexOfScalar(it.key) != null) {
                homes += 1;
                actual_home = WSId.fromIndex(wi);
            }
        }
        try testing.expectEqual(@as(usize, 1), homes);
        // The cached home_ws must name the workspace that ACTUALLY holds
        // the window. The single-membership count above only proves exactly
        // one list mentions it; a stale home_ws pointing elsewhere is the
        // "stranded home" bug, and the count check cannot see it.
        try testing.expectEqual(actual_home, it.val.home_ws);
    }
    for (&m.ws) |*s| {
        for (s.tiled_order.constSlice()) |w| {
            try testing.expect(m.store.has(w));
        }
    }
}

test "register tiles on current workspace, sets mask, is idempotent" {
    var m = makeModel();

    regCur(&m, 1);
    regCur(&m, 2);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2 });
    const e = m.store.get(2).?;
    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)), e.mask);
    try testing.expect(e.anchor == .tiled);
    // Re-registering an existing window changes nothing.
    regCur(&m, 1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2 });
    try testing.expectEqual(@as(usize, 2), m.store.count());
}

// register with hint_ws -> mask bit of hinted workspace.
test "register honors hinted workspace" {
    var m = makeModel();

    regCur(&m, 1);
    try model.register(&m, 2, WSId.fromIndex(3));
    try expectOrder(&m, WSId.fromIndex(0), &.{1});
    try expectOrder(&m, WSId.fromIndex(3), &.{2});
    try testing.expectEqual(model.bit(model.WSId.fromIndex(3)), m.store.get(2).?.mask);
    try testing.expectEqual(WSId.fromIndex(3), model.findHome(&m, 2).?);
}

// switchTo updates current; visible-set helper correctness.
test "switchTo and visibleOn" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 1);
    // Give window 1 a second tag.
    m.store.getPtr(1).?.mask |= model.bit(model.WSId.fromIndex(1));
    regCur(&m, 2); // ws0 only
    try testing.expect(model.visibleOn(&m, 1, WSId.fromIndex(0)));
    try testing.expect(model.visibleOn(&m, 1, WSId.fromIndex(1)));
    try testing.expect(!model.visibleOn(&m, 1, WSId.fromIndex(2)));
    try testing.expect(model.visibleOn(&m, 2, WSId.fromIndex(0)));
    try testing.expect(!model.visibleOn(&m, 2, WSId.fromIndex(1)));

    workspaces.switchTo(&m, WSId.fromIndex(1));
    try testing.expectEqual(WSId.fromIndex(1), m.current);

    // Minimized windows are invisible regardless of tags/all-view.
    try minimize.minimize(&m, 1);
    try testing.expect(!model.visibleOn(&m, 1, WSId.fromIndex(0)));
    try testing.expect(!model.visibleOn(&m, 1, WSId.fromIndex(1)));
    _ = workspaces.allViewToggle(&m);
    try testing.expect(model.visibleOn(&m, 2, WSId.fromIndex(1))); // untagged, all-view on
    try testing.expect(!model.visibleOn(&m, 1, WSId.fromIndex(1))); // still minimized
    // Unknown windows are never visible.
    try testing.expect(!model.visibleOn(&m, unknown_win, WSId.fromIndex(0)));
}

// moveWindowToWs retargets mask; minimized record follows.
test "moveWindowToWs for tiled, minimized, and pinned" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 1);
    regCur(&m, 2);
    regCur(&m, 3);
    workspaces.moveWindowToWs(&m, 1, WSId.fromIndex(2));
    try testing.expectEqual(model.bit(model.WSId.fromIndex(2)), m.store.get(1).?.mask);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 2, 3 });
    try expectOrder(&m, WSId.fromIndex(2), &.{1});
    try testing.expectEqual(WSId.fromIndex(2), model.findHome(&m, 1).?);

    // Minimized: only the record moves; restore lands on the new workspace.
    minimize.restore(&m, 1);
    workspaces.moveWindowToWs(&m, 1, WSId.fromIndex(2));
    try minimize.minimize(&m, 1);
    workspaces.moveWindowToWs(&m, 1, WSId.fromIndex(3));
    try testing.expectEqual(model.bit(model.WSId.fromIndex(3)), m.store.get(1).?.mask);
    minimize.restore(&m, 1);
    try expectOrder(&m, WSId.fromIndex(3), &.{1});
    try expectOrder(&m, WSId.fromIndex(2), &.{});

    // Pinned windows ignore tag-moves entirely.
    workspaces.pinToggle(&m, 1);
    try testing.expectEqual(model.ALL_MASK, m.store.get(1).?.mask);
    workspaces.moveWindowToWs(&m, 1, WSId.fromIndex(4));
    try testing.expectEqual(model.ALL_MASK, m.store.get(1).?.mask);
}

// pinToggle sets/clears all-bits; composes with every mode.
test "pinToggle across all modes" {
    var m = makeModel();

    regCur(&m, 1); // tiled
    const r: model.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    try addFloating(&m, 2, r); // floating
    regCur(&m, 3);
    _ = fullscreen.toggleFullscreen(&m, 3); // fullscreen
    regCur(&m, 4);
    try minimize.minimize(&m, 4); // minimized

    const wins = [_]WindowId{ 1, 2, 3, 4 };
    for (wins) |w| {
        workspaces.pinToggle(&m, w);
        try testing.expectEqual(model.ALL_MASK, m.store.get(w).?.mask);
        workspaces.pinToggle(&m, w);
        try testing.expectEqual(model.bit(m.current), m.store.get(w).?.mask);
    }
    // Anchor/presence were untouched by pinning; the fullscreen window is
    // still covering and the minimized window is still parked.
    try testing.expect(m.store.get(3).?.presence == .covering);
    try testing.expect(model.isCovering(&m, 3));
    try testing.expect(minimize.isMinimized(&m, 4));
    try testing.expect(m.store.get(4).?.presence == .parked);
}

// allViewToggle round trip; the all-view flag drives per-window
// visibility.
test "all-view flag drives visibility for every stored window" {
    var m = makeModel();

    regCur(&m, 1);
    try model.register(&m, 2, WSId.fromIndex(2));
    try testing.expect(!model.visibleOn(&m, 1, WSId.fromIndex(1)));
    try testing.expect(!model.visibleOn(&m, 2, WSId.fromIndex(0)));

    try testing.expect(workspaces.allViewToggle(&m)); // -> active
    try testing.expect(m.all_view_active);
    try testing.expect(model.visibleOn(&m, 1, WSId.fromIndex(1)));
    try testing.expect(model.visibleOn(&m, 2, WSId.fromIndex(0)));
    try testing.expect(model.visibleOn(&m, 2, WSId.fromIndex(5)));

    try testing.expect(!workspaces.allViewToggle(&m)); // -> inactive
    try testing.expect(!m.all_view_active);
    try testing.expect(!model.visibleOn(&m, 1, WSId.fromIndex(1)));
    try testing.expect(!model.visibleOn(&m, 2, WSId.fromIndex(0)));
}

// reorderTiled bounds-checked; swapPrimary primary/next-slot swap.
test "reorder and swapPrimary" {
    var m = makeModel();

    for ([_]WindowId{ 1, 2, 3, 4 }) |w| regCur(&m, w);

    // Out-of-range target clamps to last position.
    model.reorderTiled(&m, 1, far_position);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 2, 3, 4, 1 });
    model.reorderTiled(&m, 1, 0);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2, 3, 4 });
    model.reorderTiled(&m, 3, 0);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 3, 1, 2, 4 });

    // Floating/unknown windows have no home; reordering is a no-op.
    try addFloating(&m, 9, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    model.reorderTiled(&m, 9, 0);
    model.reorderTiled(&m, unknown_win, 0);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 3, 1, 2, 4 });

    // swapPrimary exchanges slots 0 and 1.
    model.swapPrimary(&m);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 3, 2, 4 });
    model.swapPrimary(&m);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 3, 1, 2, 4 });

    // Fewer than two tiled windows: no-op.
    var small = makeModel();

    regCur(&small, 7);
    model.swapPrimary(&small);
    try expectOrder(&small, WSId.fromIndex(0), &.{7});
}

// swapFocusedWithPrevious exchanges the focused and the previously focused
// window's tiled slots wherever they sit, honouring the swap_master "current
// and previous windows" contract (unlike swapPrimary's head/follower swap).
test "swapFocusedWithPrevious swaps focused and previous slots" {
    var m = makeModel();

    for ([_]WindowId{ 1, 2, 3 }) |w| regCur(&m, w);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2, 3 });

    // Focus 2 then 3: MRU = [3,2,1]; focused 3 in the LAST slot, previous 2
    // in the middle. The swap must exchange them right where they sit, not
    // the list head/follower.
    model.setFocus(&m, 2);
    model.setFocus(&m, 3);
    model.swapFocusedWithPrevious(&m);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 3, 2 });
    try testing.expectEqual(@as(?WindowId, 3), m.focused);

    // Toggling again swaps the same pair back (alt-tab shape).
    model.swapFocusedWithPrevious(&m);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2, 3 });

    // Single MRU entry (first focus): no-op.
    var lone = makeModel();
    regCur(&lone, 7);
    model.setFocus(&lone, 7);
    model.swapFocusedWithPrevious(&lone);
    try expectOrder(&lone, WSId.fromIndex(0), &.{7});

    // No focus at all: no-op.
    var none_focus = makeModel();
    for ([_]WindowId{ 8, 9 }) |w| regCur(&none_focus, w);
    model.swapFocusedWithPrevious(&none_focus);
    try expectOrder(&none_focus, WSId.fromIndex(0), &.{ 8, 9 });

    // Previously focused window has no tiled slot here (floating): no-op.
    var floating_prev = makeModel();
    for ([_]WindowId{ 10, 11 }) |w| regCur(&floating_prev, w);
    model.setFocus(&floating_prev, 10);
    try addFloating(&floating_prev, 12, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    model.setFocus(&floating_prev, 12); // focused 12, previous 10 (tiled)
    model.swapFocusedWithPrevious(&floating_prev);
    try expectOrder(&floating_prev, WSId.fromIndex(0), &.{ 10, 11 });
}

// stepTiled (dwm stack rotate) wraps around the tiled_order edges,
// mirroring the modulo wrap of the focus cycle; middle slots move by one.
test "stepTiled wraps at both ends" {
    var m = makeModel();

    for ([_]WindowId{ 1, 2, 3, 4 }) |w| regCur(&m, w);

    // Forward from the last slot wraps to the head.
    model.stepTiled(&m, 4, 1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 4, 1, 2, 3 });
    // Backward from the head wraps to the tail.
    model.stepTiled(&m, 4, -1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2, 3, 4 });

    // Middle slots step by one without touching the edges.
    model.stepTiled(&m, 2, 1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 3, 2, 4 });
    model.stepTiled(&m, 2, -1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2, 3, 4 });

    // Repeated forward steps rotate the window completely around the ring.
    for (0..4) |_| model.stepTiled(&m, 4, 1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2, 3, 4 });

    // Lone tiled windows and unknown windows are no-ops.
    var lone = makeModel();

    regCur(&lone, 7);
    model.stepTiled(&lone, 7, 1);
    try expectOrder(&lone, WSId.fromIndex(0), &.{7});
    model.stepTiled(&m, unknown_win, 1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2, 3, 4 });
}

// The focus-cycle pool (Mod+j/k) is derived from the current workspace's
// tiled_order, so the cycle follows the arrangement on screen instead of the
// window-id order the windows happened to be created in. The tiled_order and
// the pool are two different lists, so the test drives the mutations that
// rewrite the first and asserts the second moved with it.
test "cycle pool follows tiled order through swaps and moves" {
    var m = makeModel();
    var buf: [model.store_capacity]WindowId = undefined;
    const ws = WSId.fromIndex(0);

    // Ids deliberately ascend opposite to the tiled order, so a pool that
    // still walked the store would be caught by the very first assertion.
    for ([_]WindowId{ 30, 10, 20 }) |w| regCur(&m, w);
    try expectOrder(&m, ws, &.{ 30, 10, 20 });
    try testing.expectEqual(@as(usize, 3), model.collectCyclePool(&m, ws, &buf));
    try testing.expectEqualSlices(WindowId, &.{ 30, 10, 20 }, buf[0..3]);

    // Mod+Tab (swap_master_focus_swap) exchanges two slots: the cycle must
    // show the exchanged positions, not the pre-swap one.
    model.setFocus(&m, 10);
    model.setFocus(&m, 20);
    model.swapFocusedWithPrevious(&m);
    try expectOrder(&m, ws, &.{ 30, 20, 10 });
    _ = model.collectCyclePool(&m, ws, &buf);
    try testing.expectEqualSlices(WindowId, &.{ 30, 20, 10 }, buf[0..3]);

    // Mod+Shift+j/k (stepTiled) moves a window one slot: same requirement.
    model.stepTiled(&m, 30, 1);
    try expectOrder(&m, ws, &.{ 20, 30, 10 });
    _ = model.collectCyclePool(&m, ws, &buf);
    try testing.expectEqualSlices(WindowId, &.{ 20, 30, 10 }, buf[0..3]);
}

// The pool admits untiled windows (floating, and multi-tagged windows homed
// on another workspace) after the tiled run, and hides the ones the
// focus-visible model hides.
test "cycle pool appends untiled windows and honors visibility" {
    var m = makeModel();
    var buf: [model.store_capacity]WindowId = undefined;
    const ws = WSId.fromIndex(0);

    regCur(&m, 1);
    regCur(&m, 2);
    // Floating on workspace 0: no tiled slot, so it trails the tiled run.
    try addFloating(&m, 5, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    // Tiled on workspace 1 but ALSO tagged on workspace 0: visible here, no slot here.
    try model.register(&m, 3, WSId.fromIndex(1));
    if (m.store.getPtr(3)) |e| e.mask = model.bit(ws) | model.bit(WSId.fromIndex(1));

    try testing.expectEqual(@as(usize, 4), model.collectCyclePool(&m, ws, &buf));
    try testing.expectEqualSlices(WindowId, &.{ 1, 2, 3, 5 }, buf[0..4]);

    // A parked window leaves the pool (mirrors visibleEntry).
    m.store.getPtr(1).?.presence = .parked;
    _ = model.collectCyclePool(&m, ws, &buf);
    try testing.expectEqualSlices(WindowId, &.{ 2, 3, 5 }, buf[0..3]);

    // Untagging hides it too, unless all-view relaxes the tag test.
    if (m.store.getPtr(3)) |e| e.mask = model.bit(WSId.fromIndex(1));
    _ = model.collectCyclePool(&m, ws, &buf);
    try testing.expectEqualSlices(WindowId, &.{ 2, 5 }, buf[0..2]);
    m.all_view_active = true;
    _ = model.collectCyclePool(&m, ws, &buf);
    try testing.expectEqualSlices(WindowId, &.{ 2, 3, 5 }, buf[0..3]);
    m.all_view_active = false;

    // A covering occupant owns the screen: the pool collapses to it, so a
    // cycle step can never fade focus into what is behind it.
    m.store.getPtr(2).?.presence = .covering;
    m.store.getPtr(2).?.covering_ws = ws;
    try testing.expectEqual(@as(usize, 1), model.collectCyclePool(&m, ws, &buf));
    try testing.expectEqual(@as(WindowId, 2), buf[0]);

    // Off-current workspaces pool their own windows, in their own order.
    var other = makeModel();
    regCur(&other, 4);
    try model.register(&other, 6, WSId.fromIndex(1));
    try testing.expectEqual(@as(usize, 1), model.collectCyclePool(&other, WSId.fromIndex(1), &buf));
    try testing.expectEqual(@as(WindowId, 6), buf[0]);
}

// unregister cleans tiled_order/MRU/minimized/fs refs everywhere.
test "unregister cleans all references" {
    var m = makeModel();

    regCur(&m, 1);
    regCur(&m, 2);
    model.setFocus(&m, 1);
    try minimize.minimize(&m, 2);
    regCur(&m, 3);
    _ = fullscreen.toggleFullscreen(&m, 3);

    model.unregister(&m, 1);
    try testing.expect(!m.store.has(1));
    // Window 2 left tiled_order when it was minimized; only 3 remains.
    try expectOrder(&m, WSId.fromIndex(0), &.{3});
    for (&m.ws) |*s| {
        try testing.expect(s.focus_mru.indexOfScalar(1) == null);
    }
    try testing.expect(m.focused != 1);

    // Destroying a minimized window clears its only ref (the store entry).
    try testing.expectEqual(@as(u32, 1), minimize.count()); // window 2 minimized
    try testing.expect(minimize.isMinimized(&m, 2));
    model.unregister(&m, 2);
    try testing.expect(!m.store.has(2));
    try testing.expectEqual(@as(usize, 1), m.store.count());
    // model.unregister never touches module bookkeeping; the WIRE layer fires
    // onWindowGone (simulated here), then the module must be clean.
    minimize.onWindowGone(2);
    try testing.expectEqual(@as(u32, 0), minimize.count());
    try testing.expect(!minimize.isMinimized(&m, 2));

    // Destroying a fullscreen window leaves no dangling refs either.
    model.unregister(&m, 3);
    try testing.expect(!m.store.has(3));
    try expectOrder(&m, WSId.fromIndex(0), &.{});

    // Unknown/double unregister are safe.
    model.unregister(&m, 1);
    model.unregister(&m, unknown_win);
}

// honorConfigureRequest decisions per anchor/presence.
test "ConfigureRequest honoring per mode" {
    var m = makeModel();

    regCur(&m, 1); // tiled
    const r0: model.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    try addFloating(&m, 2, r0);
    regCur(&m, 3);
    _ = fullscreen.toggleFullscreen(&m, 3);
    regCur(&m, 4);
    try minimize.minimize(&m, 4);

    // Floating: geometry accepted and recorded in the model.
    try testing.expectEqual(
        model.HonorDecision.geometry_applied,
        floating.honorConfigureRequest(&m, 2, .{ .x = 50, .y = 60, .width = 320, .height = 240 }),
    );
    try testing.expectEqual(@as(i16, 50), m.store.get(2).?.anchor.floating.x);
    try testing.expectEqual(@as(i16, 60), m.store.get(2).?.anchor.floating.y);
    try testing.expectEqual(@as(u16, 320), m.store.get(2).?.anchor.floating.width);
    try testing.expectEqual(@as(u16, 240), m.store.get(2).?.anchor.floating.height);

    // Tiled: geometry denied; BW honored (recording is sync's job).
    try testing.expectEqual(
        model.HonorDecision.ignored,
        floating.honorConfigureRequest(&m, 1, .{ .x = 1, .y = 1 }),
    );
    try testing.expectEqual(
        model.HonorDecision.border_only,
        floating.honorConfigureRequest(&m, 1, .{ .border_width = 3 }),
    );
    try testing.expectEqual(
        model.HonorDecision.border_only,
        floating.honorConfigureRequest(&m, 1, .{ .x = 1, .border_width = 3 }),
    );

    // Covering (fullscreen)/minimized/unknown: denied outright.
    try testing.expectEqual(
        model.HonorDecision.ignored,
        floating.honorConfigureRequest(&m, 3, .{ .x = 1, .border_width = 3 }),
    );
    try testing.expectEqual(
        model.HonorDecision.ignored,
        floating.honorConfigureRequest(&m, 4, .{ .border_width = 3 }),
    );
    try testing.expectEqual(
        model.HonorDecision.ignored,
        floating.honorConfigureRequest(&m, unknown_win, .{ .x = 1 }),
    );
}

// applyConfigReload replaces layout params but preserves scroll
// viewport runtime state.
test "config reload rescales params, keeps scroll viewport" {
    var m = makeModel();

    regCur(&m, 1);
    m.ws[0].params = .{ .kind = 1, .primary_width = 0.7, .primary_count = 3 };
    m.ws[0].params.viewport_offset = 42;
    m.ws[0].params.viewport_prev_count = 2;
    m.ws[1].params.primary_width = 0.9;

    const tpl: model.LayoutParams = .{ .kind = 2, .primary_width = 0.6 };
    model.applyConfigReload(&m, tpl);

    for (&m.ws) |*s| {
        try testing.expectEqual(@as(u8, 2), s.params.kind);
        try testing.expectEqual(@as(f32, 0.6), s.params.primary_width);
        try testing.expectEqual(@as(u8, 1), s.params.primary_count);
    }
    try testing.expectEqual(@as(i32, 42), m.ws[0].params.viewport_offset);
    try testing.expectEqual(@as(u32, 2), m.ws[0].params.viewport_prev_count);
}

// setFocus updates focused+MRU; MRU capped (mru_capacity).
test "focus MRU ordering and cap" {
    var m = makeModel();

    const wins = registerRange(&m, model.mru_capacity + 4, 50);
    for (wins) |w| model.setFocus(&m, w);
    try testing.expectEqual(@as(?WindowId, wins[wins.len - 1]), m.focused);
    const mru = m.ws[0].focus_mru.constSlice();
    try testing.expectEqual(@as(usize, model.mru_capacity), mru.len);
    try testing.expectEqual(wins[wins.len - 1], mru[0]);
    try testing.expectEqual(wins[4], mru[mru.len - 1]); // oldest four evicted
    // Refocusing an existing entry moves it to the front without duplicating.
    model.setFocus(&m, wins[10]);
    try testing.expectEqual(wins[10], m.ws[0].focus_mru.constSlice()[0]);
    try testing.expectEqual(@as(usize, model.mru_capacity), m.ws[0].focus_mru.len);
    // Unknown window: focused unchanged.
    model.setFocus(&m, unknown_win);
    try testing.expectEqual(@as(?WindowId, wins[10]), m.focused);
}

// store iteration stays deterministic across removals.
// Sorted-key store: removals shift elements left, iteration stays sorted.
test "store iteration stays deterministic across removals" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    for ([_]WindowId{ 1, 2, 3, 4 }) |w|
        _ = try m.store.put(w, .{ .mask = model.bit(model.WSId.fromIndex(0)), .anchor = .tiled });

    inline for (
        .{ @as(WindowId, 1), @as(WindowId, 2), @as(WindowId, 3), @as(WindowId, 4) },
        0..,
    ) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    try testing.expect(m.store.remove(2));
    inline for (
        .{ @as(WindowId, 1), @as(WindowId, 3), @as(WindowId, 4) },
        0..,
    ) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    _ = try m.store.put(5, .{ .mask = model.bit(model.WSId.fromIndex(0)), .anchor = .tiled });
    inline for (
        .{ @as(WindowId, 1), @as(WindowId, 3), @as(WindowId, 4), @as(WindowId, 5) },
        0..,
    ) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    try testing.expect(m.store.remove(1)); // head
    try testing.expect(m.store.remove(5)); // tail
    inline for (.{ @as(WindowId, 3), @as(WindowId, 4) }, 0..) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    try testing.expect(!m.store.remove(77));

    // Model-level single-membership holds alongside the raw store: clear the
    // raw-store fixtures so every remaining entry was transitioned in.
    _ = m.store.remove(3);
    _ = m.store.remove(4);
    for ([_]WindowId{ 30, 31, 32 }) |w| regCur(&m, w);
    workspaces.moveWindowToWs(&m, 31, WSId.fromIndex(1));
    try minimize.minimize(&m, 32);
    try assertSingleMembership(&m);
}

// no function mutates before its capacity check.
test "capacity refusals happen before any mutation" {
    // Raw store: full-store put refuses and leaves content untouched.
    var small: SmallStore = .{};
    _ = try small.put(1, 10);
    _ = try small.put(2, 20);
    try testing.expectError(error.CapacityFull, small.put(3, 30));
    try testing.expectEqual(@as(usize, 2), small.count());
    try testing.expectEqual(@as(u8, 10), small.get(1).?);
    try testing.expectEqual(@as(u8, 20), small.get(2).?);
    try testing.expect(!small.has(3));
    // Existing-key overwrite never hits the capacity wall.
    _ = try small.put(1, 11);
    try testing.expectEqual(@as(u8, 11), small.get(1).?);

    // Model minimize: the refused call leaves the model byte-identical
    // because the capacity guard runs before any mutation.
    var m = makeModel();
    var wins: [max_minimized + 1]WindowId = undefined;
    {
        try minimize.init();
        defer minimize.deinit();
        wins = registerRange(&m, max_minimized + 1, 200);
        for (wins[0 .. wins.len - 1]) |w| try minimize.minimize(&m, w);
        model.setFocus(&m, wins[wins.len - 1]);
        try testing.expectError(error.CapacityFull, minimize.minimize(&m, wins[wins.len - 1]));
    }

    // The module's minimized store is process-global, so the replay fixture
    // needs a clean module lifetime (else the prefix minimizes no-op).
    {
        try minimize.init();
        defer minimize.deinit();
        var ref = makeModel();

        for (wins) |w| {
            try model.register(&ref, w, null);
        }
        for (wins[0 .. wins.len - 1]) |w| try minimize.minimize(&ref, w);
        model.setFocus(&ref, wins[wins.len - 1]);
        // The refused model equals a pristine replay of the accepted prefix...
        try testing.expect(eqModel(&m, &ref));
        // ...and specifically, the attempted window was NOT parked/minimized:
        // still present (tiled anchor), not in the module's minimized set.
        try testing.expect(m.store.get(wins[wins.len - 1]).?.anchor == .tiled);
        try testing.expect(m.store.get(wins[wins.len - 1]).?.presence == .present);
        try testing.expect(!minimize.isMinimized(&m, wins[wins.len - 1]));
    }

    // register refusal: the home-list bound is the defined overflow and
    // refuses before mutation. Fill workspace 0's tiled list to capacity.
    var fm = Model{};
    var i: WindowId = 500;
    while (fm.ws[0].tiled_order.len < model.max_tiled_per_ws) : (i += 1) {
        try model.register(&fm, i, null);
    }
    try testing.expectError(error.CapacityFull, model.register(&fm, i, null));
    try testing.expect(!fm.store.has(i));
}

// determinism -- same op sequence => identical model state, twice.
test "identical operation sequences produce identical models" {
    const seq = struct {
        fn run(m: *Model) !void {
            for ([_]WindowId{ 1, 2, 3, 4, 5 }) |w| try model.register(m, w, null);
            try model.register(m, 6, WSId.fromIndex(2));
            workspaces.switchTo(m, WSId.fromIndex(1));
            try model.register(m, 7, null);
            workspaces.switchTo(m, WSId.fromIndex(0));
            model.reorderTiled(m, 3, 0);
            model.swapPrimary(m);
            try minimize.minimize(m, 4);
            minimize.restore(m, 4);
            try minimize.minimize(m, 5);
            _ = fullscreen.toggleFullscreen(m, 2);
            floating.setFloatingRect(m, 6, .{ .x = 1, .y = 2, .width = 30, .height = 40 });
            workspaces.pinToggle(m, 1);
            workspaces.moveWindowToWs(m, 7, model.WSId.fromIndex(1));
            stepCycle(m, 1);
            model.adjustPrimaryWidth(m, 0.1);
            model.setFocus(m, 3);
            model.setFocus(m, 1);
            _ = workspaces.allViewToggle(m);
            _ = workspaces.allViewToggle(m);
            model.unregister(m, 5);
            model.applyConfigReload(m, .{ .kind = 3 });
        }
    };
    var a = makeModel();
    try seq.run(&a);
    // b's fresh stores (makeModel resets the process-global minimize,
    // fullscreen and floating state at construction) must be created AFTER
    // a's run: the
    // toggle in `seq` flips OFF for a window that still has a fullscreen
    // record, so the replay needs the same clean stores a's run started with.
    var b = makeModel();
    try seq.run(&b);
    try testing.expect(eqModel(&a, &b));
    try assertSingleMembership(&a);

    // Sanity: the comparator distinguishes divergent histories.
    var c = makeModel();
    try seq.run(&c);
    model.setFocus(&c, 2);
    try testing.expect(!eqModel(&a, &c));
}

test "home_ws: register sets cache to current workspace" {
    var m = makeModel();
    regCur(&m, 1); // register on workspace 0
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(1).?.home_ws);
}

test "home_ws: register on non-zero workspace" {
    var m = makeModel();
    try model.register(&m, 1, WSId.fromIndex(3));
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(3)), m.store.get(1).?.home_ws);
}

test "home_ws: findHome uses cache" {
    var m = makeModel();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(1).?.home_ws);
    // findHome reads the cached home.
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.findHome(&m, 1));
}

test "home_ws: findHome scan fallback when cache is null" {
    var m = makeModel();
    regCur(&m, 1);
    // A null cache simulates an entry with no recorded home.
    m.store.getPtr(1).?.home_ws = null;
    // findHome scans tiled_order and recovers the correct home.
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.findHome(&m, 1));
}

test "home_ws: minimize clears cache" {
    var m = makeModel();
    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(1).?.home_ws);
    try minimize.minimize(&m, 1);
    try testing.expectEqual(@as(?WSId, null), m.store.get(1).?.home_ws);
    try testing.expect(m.store.get(1).?.presence == .parked);
}

test "home_ws: restore sets cache after re-add" {
    var m = makeModel();
    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 1);
    try minimize.minimize(&m, 1);
    try testing.expectEqual(@as(?WSId, null), m.store.get(1).?.home_ws);
    minimize.restore(&m, 1);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(1).?.home_ws);
    try testing.expect(m.store.get(1).?.presence == .present);
}

test "home_ws: moveWindowToWs uses cache" {
    var m = makeModel();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(1).?.home_ws);
    // moveWindowToWs reads the cached home rather than scanning.
    workspaces.moveWindowToWs(&m, 1, WSId.fromIndex(5));
    // home_ws tracks the original home, not the current workspace, so it
    // stays 0 while the window lands on workspace 5.
    try expectOrder(&m, WSId.fromIndex(5), &.{1});
}

test "home_ws: detachToFloating clears cache" {
    var m = makeModel();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(1).?.home_ws);
    // The window-layer detach path clears home_ws; verify the result state
    // (a floating entry carries null home_ws).
    const e = m.store.getPtr(1).?;
    e.anchor = .{ .floating = .{ .x = 0, .y = 0, .width = 100, .height = 100 } };
    e.home_ws = null;
    try testing.expectEqual(@as(?WSId, null), e.home_ws);
}

// adjustPrimaryWidth clamps to [0.05, 0.95].
test "adjustPrimaryWidth clamps" {
    var m = makeModel();

    workspaces.switchTo(&m, WSId.fromIndex(0));
    model.adjustPrimaryWidth(&m, 10.0); // far above the ceiling
    try testing.expect(m.ws[0].params.primary_width <= 0.95);
    model.adjustPrimaryWidth(&m, -10.0); // far below the floor
    try testing.expect(m.ws[0].params.primary_width >= 0.05);
}

// Spawn path: on-current spawn tiles+focuses; off-current spawn tiles
// on its target workspace but does NOT take focus (mirrors actions.mapRequest).
test "spawn admission tiles (on-current focused; off-current target-only)" {
    var m = makeModel();

    // On-current spawn: register(m, win, null) + setFocus (mirrors
    // actions.mapRequest's on_current=true path).
    try model.register(&m, 1, null);
    model.setFocus(&m, 1);
    var e = m.store.get(1).?;
    try testing.expect(e.anchor == .tiled);
    try testing.expect(e.presence == .present);
    try expectOrder(&m, WSId.fromIndex(0), &.{1});
    try testing.expectEqual(@as(?WindowId, 1), m.focused);

    // Off-current spawn: current moves away, a new window targets workspace 0.
    // register(m, win, 0) tiles it there; mapRequest's on_current=false early
    // return means it must NOT steal model focus.
    workspaces.switchTo(&m, WSId.fromIndex(2));
    try model.register(&m, 2, WSId.fromIndex(0));
    e = m.store.get(2).?;
    try testing.expect(e.anchor == .tiled);
    try testing.expect(e.presence == .present);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2 });
    try testing.expectEqual(@as(?WindowId, 1), m.focused); // not stolen
    try assertSingleMembership(&m);
}

// A border_width-only honor on a TILED window (border_only) must not
// disturb tiling membership; it stays tiled/present for the next retile.
test "border-width honor leaves tiled membership intact across a retile" {
    var m = makeModel();

    try fullscreen.init();
    defer fullscreen.deinit();
    regCur(&m, 1);
    regCur(&m, 2);

    // Tiled configure request carrying only border_width: geometry denied,
    // width honored (the ConfigureRequest honoring path).
    try testing.expectEqual(
        model.HonorDecision.border_only,
        floating.honorConfigureRequest(&m, 1, .{ .border_width = 3 }),
    );
    // The decision left the window tiled/present in its slot.
    const e = m.store.get(1).?;
    try testing.expect(e.anchor == .tiled);
    try testing.expect(e.presence == .present);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2 });

    // A retile (slot swap) still finds the window; membership/mask intact.
    model.swapPrimary(&m);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 2, 1 });
    try testing.expectEqual(model.bit(model.WSId.fromIndex(0)), m.store.get(1).?.mask);
    try assertSingleMembership(&m);
}

// Tag-move of a minimized window: the parked record (and tag mask) follows it,
// so a later
// restore lands on the NEW workspace while the old workspace's stack is left
// undisturbed.
test "tag-move of a minimized window moves the record; restore lands on the new workspace" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();

    try model.register(&m, 30, WSId.fromIndex(0)); // home 0
    try model.register(&m, 31, WSId.fromIndex(0));
    try minimize.minimize(&m, 30);
    try testing.expect(minimize.isMinimized(&m, 30));

    // Move the parked window to workspace 2: only the record moves (the tag mask
    // follows per workspaces.moveWindowToWs); it stays minimized, and the old
    // stack keeps only 31.
    workspaces.moveWindowToWs(&m, 30, WSId.fromIndex(2));
    try testing.expectEqual(model.bit(model.WSId.fromIndex(2)), m.store.get(30).?.mask);
    try testing.expect(minimize.isMinimized(&m, 30));
    try expectOrder(&m, WSId.fromIndex(0), &.{31});

    // Restore lands on the NEW workspace (lowest bit of the moved mask); the
    // old workspace still only holds 31.
    minimize.restore(&m, 30);
    try expectOrder(&m, WSId.fromIndex(2), &.{30});
    try expectOrder(&m, WSId.fromIndex(0), &.{31});
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(2)), m.store.get(30).?.home_ws);
    try testing.expect(!minimize.isMinimized(&m, 30));
    try assertSingleMembership(&m);
}

test "fixture: makeModel re-arms floating's leaked drag state" {
    if (!build_options.has_floating) return error.SkipZigTest;
    // Dirty the global exactly the way an un-ended drag would.
    floating.seedLeakedDragForTest(1);
    try testing.expect(floating.isDragging());

    // A fresh fixture re-arms it, so the next test can start a drag.
    _ = makeModel();
    try testing.expect(!floating.isDragging());
}

test "fixture: makeBareModel deliberately leaves module stores alone" {
    // The contrast that documents the opt-out: the bench files rely on this
    // one skipping the reset, so it must be a real behavioural difference, not
    // a second name for the same thing.
    if (!build_options.has_floating) return error.SkipZigTest;
    floating.seedLeakedDragForTest(1);

    _ = helpers.makeBareModel();
    try testing.expect(floating.isDragging());

    floating.resetState(); // leave the global clean for the next test
    try testing.expect(!floating.isDragging());
}
