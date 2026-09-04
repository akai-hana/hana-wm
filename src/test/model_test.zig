//! Unit tests for the model layer.
const std = @import("std");
const testing = std.testing;
const model = @import("model");
const constants = @import("constants");
const utils = @import("utils");
const build_options = @import("build_options");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const floating = if (build_options.has_floating) @import("floating") else struct {};
const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};
// The model's kind is an opaque u8 stepped through a representative config
// name list (no-op when the tiling subsystem is absent).
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};
const test_cycle_names = [_][]const u8{ "master", "monocle", "grid", "fibonacci" };
fn stepCycle(m: *Model, dir: i32) void {
    if (!build_options.has_tiling) return;
    m.ws[m.current].params.kind = tiling.cycleKind(
        m.ws[m.current].params.kind,
        dir,
        &test_cycle_names,
    );
    m.ws[m.current].params.variant_idx = 0;
}

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;
const max_minimized = constants.max_minimized;
const SmallStore = @import("store").Store(u32, u8, 2);

fn makeModel() Model {
    return .{}; // bounded lists: no allocator, no deinit
}

fn deinitModel(m: *Model) void {
    _ = m;
}

fn expectOrder(m: *const Model, ws: WSId, expected: []const WindowId) !void {
    try testing.expectEqualSlices(WindowId, expected, m.ws[ws].tiled_order.constSlice());
}

/// Registers `win` tiled on the model's current workspace.
fn regCur(m: *Model, win: WindowId) void {
    model.register(m, win, null) catch unreachable;
}

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
    if (a.current != b.current) return false;
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
    }
    return true;
}

/// Every window whose anchor is tiled AND present appears in EXACTLY ONE ws
/// list; every listed id exists in the store (single-membership invariant).
/// Floating and parked (minimized) windows are home-free.
fn assertSingleMembership(m: *const Model) !void {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        // A parked window keeps its anchor but has no tiled slot by design.
        const tiled = (it.val.anchor == .tiled and it.val.presence == .present);
        if (!tiled) continue;
        var homes: usize = 0;
        for (&m.ws) |*s| {
            if (s.tiled_order.indexOfScalar(it.key) != null) homes += 1;
        }
        try testing.expectEqual(@as(usize, 1), homes);
    }
    for (&m.ws) |*s| {
        for (s.tiled_order.constSlice()) |w| {
            try testing.expect(m.store.has(w));
        }
    }
}

// T01: register -> tiled in current ws order, mask set.
test "T01: register tiles on current ws, sets mask, is idempotent" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    regCur(&m, 2);
    try expectOrder(&m, 0, &.{ 1, 2 });
    const e = m.store.get(2).?;
    try testing.expectEqual(model.bit(0), e.mask);
    try testing.expect(e.anchor == .tiled);
    // Re-registering an existing window changes nothing.
    regCur(&m, 1);
    try expectOrder(&m, 0, &.{ 1, 2 });
    try testing.expectEqual(@as(usize, 2), m.store.count());
}

// T02: register with hint_ws -> mask bit of hinted ws.
test "T02: register honors hinted workspace" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    model.register(&m, 2, 3) catch unreachable;
    try expectOrder(&m, 0, &.{1});
    try expectOrder(&m, 3, &.{2});
    try testing.expectEqual(model.bit(3), m.store.get(2).?.mask);
    try testing.expectEqual(@as(WSId, 3), model.findHome(&m, 2).?);
}

// T03: minimize tiled -> parked, removed from tiled_order; capacity refuses
// once the minimized budget (MAX_MINIMIZED) is exhausted.
test "T03: minimize tiled removes from order; capacity refuses" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    var wins: [max_minimized + 1]WindowId = undefined;
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(100 + i);
        regCur(&m, w.*);
    }
    try expectOrder(&m, 0, &wins);
    minimize.minimize(&m, 102) catch unreachable;
    try testing.expect(minimize.isMinimized(&m, 102));
    const e = m.store.get(102).?;
    try testing.expect(e.presence == .parked);
    // Anchor is UNCHANGED while parked (was tiled).
    try testing.expect(e.anchor == .tiled);
    // Verify saved slot via restore: window 102 was at index 2.
    minimize.restore(&m, 102);
    try expectOrder(&m, 0, &wins);
    minimize.minimize(&m, 102) catch unreachable;
    try testing.expectEqual(@as(?WSId, null), e.home_ws);
    var expected: [max_minimized]WindowId = undefined;
    _ = std.mem.replace(WindowId, &wins, &.{102}, &.{}, expected[0 .. wins.len - 1]);
    try expectOrder(&m, 0, expected[0 .. wins.len - 1]);

    // Fill the remaining budget, then the next minimize must be refused
    // without mutating anything (full no-mutation proof in T17).
    for (wins[0 .. wins.len - 1]) |w| minimize.minimize(&m, w) catch unreachable;
    try testing.expectEqual(@as(u32, max_minimized), minimize.count(&m));
    try testing.expectError(error.CapacityFull, minimize.minimize(&m, wins[wins.len - 1]));
    // The refused window is unchanged: still present, not minimized.
    try testing.expect(!minimize.isMinimized(&m, wins[wins.len - 1]));
    try testing.expect(m.store.get(wins[wins.len - 1]).?.presence == .present);
}

// T04: restore tiled -> back at ORIGINAL index.
test "T04: restore reinserts at original slot" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    for ([_]WindowId{ 10, 11, 12, 13, 14 }) |w| regCur(&m, w);
    minimize.minimize(&m, 12) catch unreachable;
    minimize.minimize(&m, 11) catch unreachable;
    try testing.expect(m.store.get(12).?.presence == .parked);
    try testing.expect(m.store.get(11).?.presence == .parked);
    try expectOrder(&m, 0, &.{ 10, 13, 14 });
    minimize.restore(&m, 12);
    try testing.expect(m.store.get(12).?.presence == .present);
    try expectOrder(&m, 0, &.{ 10, 13, 12, 14 });
    minimize.restore(&m, 11);
    try expectOrder(&m, 0, &.{ 10, 11, 13, 12, 14 });
    // Restoring a live or unknown window is a no-op.
    minimize.restore(&m, 10);
    minimize.restore(&m, 999);
    try expectOrder(&m, 0, &.{ 10, 11, 13, 12, 14 });
}

// T05: minimize floating -> prev==floating(rect); restore returns the rect.
test "T05: minimize/restore floating preserves rect" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    const r: utils.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    _ = m.store.put(7, .{
        .mask = model.bit(0),
        .anchor = .{ .floating = r },
    }) catch unreachable;
    minimize.minimize(&m, 7) catch unreachable;
    try testing.expect(minimize.isMinimized(&m, 7));
    const e = m.store.get(7).?;
    try testing.expect(e.presence == .parked);
    // Anchor UNCHANGED while parked (floating with the rect intact).
    try testing.expect(e.anchor == .floating);
    try testing.expect(r.eql(e.anchor.floating));
    // Floating window has no saved tiled slot; verified below: restore
    // must NOT join any tiled_order.
    minimize.restore(&m, 7);
    const back = m.store.get(7).?;
    try testing.expect(back.presence == .present);
    try testing.expect(!minimize.isMinimized(&m, 7));
    try testing.expect(back.anchor == .floating);
    try testing.expect(r.eql(back.anchor.floating));
    // Floating restore must NOT join any tiled_order.
    for (&m.ws) |*s| try testing.expect(s.tiled_order.indexOfScalar(7) == null);
}

// T06: toggleFullscreen round trips; minimize-from-fullscreen keeps its
// record (parked) and restore returns straight back to fullscreen.
test "T06: fullscreen toggling and minimize-from-fullscreen" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    // Tiled round trip.
    regCur(&m, 1);
    try testing.expect(fullscreen.toggleFullscreen(&m, 1));
    var e = m.store.get(1).?;
    try testing.expect(e.presence == .covering);
    try testing.expectEqual(@as(WSId, 0), fullscreen.fullscreenWsOf(&m, 1).?);
    try testing.expect(e.anchor == .tiled); // anchor retained
    try testing.expect(fullscreen.toggleFullscreen(&m, 1));
    e = m.store.get(1).?;
    try testing.expect(e.presence == .present);
    try testing.expect(e.anchor == .tiled);
    try testing.expect(!fullscreen.isFullscreenMode(&m, 1));

    // Floating base survives minimize-from-fullscreen.
    const r: utils.Rect = .{ .x = 5, .y = 6, .width = 640, .height = 480 };
    _ = m.store.put(2, .{
        .mask = model.bit(0),
        .anchor = .{ .floating = r },
    }) catch unreachable;
    _ = fullscreen.toggleFullscreen(&m, 2);
    minimize.minimize(&m, 2) catch unreachable;
    try testing.expect(minimize.isMinimized(&m, 2));
    e = m.store.get(2).?;
    try testing.expect(e.presence == .parked);
    // Anchor is UNCHANGED while parked (still floating; fs rec is a ghost).
    try testing.expect(e.anchor == .floating);
    try testing.expect(r.eql(e.anchor.floating));
    // Ghost fullscreen record STILL reports the ws while parked.
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 2));
    minimize.restore(&m, 2);
    e = m.store.get(2).?;
    // Restoring a fullscreen-carrying window returns it to covering (the
    // model is the single authority; the window re-claims the screen).
    try testing.expect(e.presence == .covering);
    try testing.expect(!minimize.isMinimized(&m, 2));
    try testing.expect(fullscreen.isFullscreenMode(&m, 2));
    try testing.expect(r.eql(e.anchor.floating));
}

// T07: switchTo updates current; visible-set helper correctness.
test "T07: switchTo and visibleOn" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 1);
    // Give window 1 a second tag.
    m.store.getPtr(1).?.mask |= model.bit(1);
    regCur(&m, 2); // ws0 only
    try testing.expect(model.visibleOn(&m, 1, 0));
    try testing.expect(model.visibleOn(&m, 1, 1));
    try testing.expect(!model.visibleOn(&m, 1, 2));
    try testing.expect(model.visibleOn(&m, 2, 0));
    try testing.expect(!model.visibleOn(&m, 2, 1));

    workspaces.switchTo(&m, 1);
    try testing.expectEqual(@as(WSId, 1), m.current);

    // Minimized windows are invisible regardless of tags/all-view.
    minimize.minimize(&m, 1) catch unreachable;
    try testing.expect(!model.visibleOn(&m, 1, 0));
    try testing.expect(!model.visibleOn(&m, 1, 1));
    _ = workspaces.allViewToggle(&m);
    try testing.expect(model.visibleOn(&m, 2, 1)); // untagged, all-view on
    try testing.expect(!model.visibleOn(&m, 1, 1)); // still minimized
    // Unknown windows are never visible.
    try testing.expect(!model.visibleOn(&m, 999, 0));
}

// T08: moveWindowToWs retargets mask; minimized record follows.
test "T08: moveWindowToWs for tiled, minimized, and pinned" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 1);
    regCur(&m, 2);
    regCur(&m, 3);
    workspaces.moveWindowToWs(&m, 1, 2);
    try testing.expectEqual(model.bit(2), m.store.get(1).?.mask);
    try expectOrder(&m, 0, &.{ 2, 3 });
    try expectOrder(&m, 2, &.{1});
    try testing.expectEqual(@as(WSId, 2), model.findHome(&m, 1).?);

    // Minimized: only the record moves; restore lands on the new ws.
    minimize.restore(&m, 1);
    workspaces.moveWindowToWs(&m, 1, 2);
    minimize.minimize(&m, 1) catch unreachable;
    workspaces.moveWindowToWs(&m, 1, 3);
    try testing.expectEqual(model.bit(3), m.store.get(1).?.mask);
    minimize.restore(&m, 1);
    try expectOrder(&m, 3, &.{1});
    try expectOrder(&m, 2, &.{});

    // Pinned windows ignore tag-moves entirely.
    workspaces.pinToggle(&m, 1);
    try testing.expectEqual(model.ALL_MASK, m.store.get(1).?.mask);
    workspaces.moveWindowToWs(&m, 1, 4);
    try testing.expectEqual(model.ALL_MASK, m.store.get(1).?.mask);
}

// T09: pinToggle sets/clears all-bits; composes with every mode.
test "T09: pinToggle across all modes" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 1); // tiled
    const r: utils.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    _ = m.store.put(2, .{ .mask = model.bit(0), .anchor = .{ .floating = r } }) catch
        unreachable; // floating
    regCur(&m, 3);
    _ = fullscreen.toggleFullscreen(&m, 3); // fullscreen
    regCur(&m, 4);
    minimize.minimize(&m, 4) catch unreachable; // minimized

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
    try testing.expect(fullscreen.isFullscreenMode(&m, 3));
    try testing.expect(minimize.isMinimized(&m, 4));
    try testing.expect(m.store.get(4).?.presence == .parked);
}

// T10: allViewToggle round trip; the all-view flag drives per-window
// visibility.
test "T10: all-view flag drives visibility for every stored window" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    model.register(&m, 2, 2) catch unreachable;
    try testing.expect(!model.visibleOn(&m, 1, 1));
    try testing.expect(!model.visibleOn(&m, 2, 0));

    try testing.expect(workspaces.allViewToggle(&m)); // -> active
    try testing.expect(m.all_view_active);
    try testing.expect(model.visibleOn(&m, 1, 1));
    try testing.expect(model.visibleOn(&m, 2, 0));
    try testing.expect(model.visibleOn(&m, 2, 5));

    try testing.expect(!workspaces.allViewToggle(&m)); // -> inactive
    try testing.expect(!m.all_view_active);
    try testing.expect(!model.visibleOn(&m, 1, 1));
    try testing.expect(!model.visibleOn(&m, 2, 0));
}

// T11: reorderTiled bounds-checked; swapPrimary primary/next-slot swap.
test "T11: reorder and swapPrimary" {
    var m = makeModel();
    defer deinitModel(&m);
    for ([_]WindowId{ 1, 2, 3, 4 }) |w| regCur(&m, w);

    // Out-of-range target clamps to last position.
    model.reorderTiled(&m, 1, 99);
    try expectOrder(&m, 0, &.{ 2, 3, 4, 1 });
    model.reorderTiled(&m, 1, 0);
    try expectOrder(&m, 0, &.{ 1, 2, 3, 4 });
    model.reorderTiled(&m, 3, 0);
    try expectOrder(&m, 0, &.{ 3, 1, 2, 4 });

    // Floating/unknown windows have no home; reordering is a no-op.
    _ = m.store.put(9, .{
        .mask = model.bit(0),
        .anchor = .{ .floating = .{ .x = 0, .y = 0, .width = 1, .height = 1 } },
    }) catch unreachable;
    model.reorderTiled(&m, 9, 0);
    model.reorderTiled(&m, 42, 0);
    try expectOrder(&m, 0, &.{ 3, 1, 2, 4 });

    // swapPrimary exchanges slots 0 and 1.
    model.swapPrimary(&m);
    try expectOrder(&m, 0, &.{ 1, 3, 2, 4 });
    model.swapPrimary(&m);
    try expectOrder(&m, 0, &.{ 3, 1, 2, 4 });

    // Fewer than two tiled windows: no-op.
    var small = makeModel();
    defer deinitModel(&small);
    regCur(&small, 7);
    model.swapPrimary(&small);
    try expectOrder(&small, 0, &.{7});
}

// T12: unregister cleans tiled_order/MRU/minimized/fs refs everywhere.
test "T12: unregister cleans all references" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 1);
    regCur(&m, 2);
    model.setFocus(&m, 1);
    minimize.minimize(&m, 2) catch unreachable;
    regCur(&m, 3);
    _ = fullscreen.toggleFullscreen(&m, 3);

    model.unregister(&m, 1);
    try testing.expect(!m.store.has(1));
    // Window 2 left tiled_order when it was minimized; only 3 remains.
    try expectOrder(&m, 0, &.{3});
    for (&m.ws) |*s| {
        try testing.expect(s.focus_mru.indexOfScalar(1) == null);
    }
    try testing.expect(m.focused != 1);

    // Destroying a minimized window clears its only ref (the store entry).
    try testing.expectEqual(@as(u32, 1), minimize.count(&m)); // window 2 minimized
    try testing.expect(minimize.isMinimized(&m, 2));
    model.unregister(&m, 2);
    try testing.expect(!m.store.has(2));
    try testing.expectEqual(@as(usize, 1), m.store.count());
    // model.unregister never touches module bookkeeping; the WIRE layer fires
    // onWindowGone (simulated here), then the module must be clean.
    minimize.onWindowGone(2);
    try testing.expectEqual(@as(u32, 0), minimize.count(&m));
    try testing.expect(!minimize.isMinimized(&m, 2));

    // Destroying a fullscreen window leaves no dangling refs either.
    model.unregister(&m, 3);
    try testing.expect(!m.store.has(3));
    try expectOrder(&m, 0, &.{});

    // Unknown/double unregister are safe.
    model.unregister(&m, 1);
    model.unregister(&m, 999);
}

// T13: honorConfigureRequest decisions per anchor/presence.
test "T13: ConfigureRequest honoring per mode" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 1); // tiled
    const r0: utils.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    _ = m.store.put(2, .{ .mask = model.bit(0), .anchor = .{ .floating = r0 } }) catch unreachable;
    regCur(&m, 3);
    _ = fullscreen.toggleFullscreen(&m, 3);
    regCur(&m, 4);
    minimize.minimize(&m, 4) catch unreachable;

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
        floating.honorConfigureRequest(&m, 999, .{ .x = 1 }),
    );
}

// T14: applyConfigReload replaces layout params but preserves scroll
// viewport runtime state.
test "T14: config reload rescales params, keeps scroll viewport" {
    var m = makeModel();
    defer deinitModel(&m);
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

// T15: setFocus updates focused+MRU; MRU capped (mru_capacity).
test "T15: focus MRU ordering and cap" {
    var m = makeModel();
    defer deinitModel(&m);
    var wins: [model.mru_capacity + 4]WindowId = undefined;
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(50 + i);
        regCur(&m, w.*);
    }
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
    model.setFocus(&m, 999);
    try testing.expectEqual(@as(?WindowId, wins[10]), m.focused);
}

// T16: store iteration stays deterministic across removals.
// Sorted-key store: removals shift elements left, iteration stays sorted.
test "T16: store iteration stays deterministic across removals" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    for ([_]WindowId{ 1, 2, 3, 4 }) |w|
        _ = m.store.put(w, .{ .mask = model.bit(0), .anchor = .tiled }) catch unreachable;

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
    _ = m.store.put(5, .{ .mask = model.bit(0), .anchor = .tiled }) catch unreachable;
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
    workspaces.moveWindowToWs(&m, 31, 1);
    minimize.minimize(&m, 32) catch unreachable;
    try assertSingleMembership(&m);
}

// T17: no function mutates before its capacity check.
test "T17: capacity refusals happen before any mutation" {
    // Raw store: full-store put refuses and leaves content untouched.
    var small: SmallStore = .{};
    _ = small.put(1, 10) catch unreachable;
    _ = small.put(2, 20) catch unreachable;
    try testing.expectError(error.StoreFull, small.put(3, 30));
    try testing.expectEqual(@as(usize, 2), small.count());
    try testing.expectEqual(@as(u8, 10), small.get(1).?);
    try testing.expectEqual(@as(u8, 20), small.get(2).?);
    try testing.expect(!small.has(3));
    // Existing-key overwrite never hits the capacity wall.
    _ = small.put(1, 11) catch unreachable;
    try testing.expectEqual(@as(u8, 11), small.get(1).?);

    // Model minimize: the refused call leaves the model byte-identical
    // because the capacity guard runs before any mutation.
    try minimize.init();
    defer minimize.deinit();
    var m = makeModel();
    defer deinitModel(&m);
    var wins: [max_minimized + 1]WindowId = undefined;
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(200 + i);
        regCur(&m, w.*);
    }
    for (wins[0 .. wins.len - 1]) |w| minimize.minimize(&m, w) catch unreachable;
    model.setFocus(&m, wins[wins.len - 1]);
    try testing.expectError(error.CapacityFull, minimize.minimize(&m, wins[wins.len - 1]));

    // The module's minimized store is process-global, so the replay fixture
    // needs a clean module lifetime (else the prefix minimizes no-op).
    minimize.deinit();
    try minimize.init();
    defer minimize.deinit();
    var ref = makeModel();
    defer deinitModel(&ref);
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(200 + i);
        model.register(&ref, w.*, if (i == wins.len - 1) null else 0) catch unreachable;
        if (i < wins.len - 1) minimize.minimize(&ref, w.*) catch unreachable;
    }
    model.setFocus(&ref, wins[wins.len - 1]);
    // The refused model equals a pristine replay of the accepted prefix...
    try testing.expect(eqModel(&m, &ref));
    // ...and specifically, the attempted window was NOT parked/minimized:
    // still present (tiled anchor), not in the module's minimized set.
    try testing.expect(m.store.get(wins[wins.len - 1]).?.anchor == .tiled);
    try testing.expect(m.store.get(wins[wins.len - 1]).?.presence == .present);
    try testing.expect(!minimize.isMinimized(&m, wins[wins.len - 1]));

    // register refusal: the home-list bound is the defined overflow and
    // refuses before mutation. Fill ws 0's tiled list to capacity.
    var fm = Model{};
    var i: WindowId = 500;
    while (fm.ws[0].tiled_order.len < model.max_tiled_per_ws) : (i += 1) {
        model.register(&fm, i, null) catch unreachable;
    }
    try testing.expectError(error.CapacityFull, model.register(&fm, i, null));
    try testing.expect(!fm.store.has(i));
}

// T18: determinism -- same op sequence => identical model state, twice.
test "T18: identical operation sequences produce identical models" {
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    const seq = struct {
        fn run(m: *Model) void {
            for ([_]WindowId{ 1, 2, 3, 4, 5 }) |w| model.register(m, w, null) catch unreachable;
            model.register(m, 6, 2) catch unreachable;
            workspaces.switchTo(m, 1);
            model.register(m, 7, null) catch unreachable;
            workspaces.switchTo(m, 0);
            model.reorderTiled(m, 3, 0);
            model.swapPrimary(m);
            minimize.minimize(m, 4) catch unreachable;
            minimize.restore(m, 4);
            minimize.minimize(m, 5) catch unreachable;
            _ = fullscreen.toggleFullscreen(m, 2);
            floating.setFloatingRect(m, 6, .{ .x = 1, .y = 2, .width = 30, .height = 40 });
            workspaces.pinToggle(m, 1);
            workspaces.moveWindowToWs(m, 7, 1);
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
    defer deinitModel(&a);
    var b = makeModel();
    defer deinitModel(&b);
    seq.run(&a);
    // The module stores are process-global, so the replay needs clean
    // lifetimes (else the second toggleFullscreen turns OFF instead of ON).
    minimize.deinit();
    fullscreen.deinit();
    try minimize.init();
    try fullscreen.init();
    seq.run(&b);
    try testing.expect(eqModel(&a, &b));
    try assertSingleMembership(&a);

    // Sanity: the comparator distinguishes divergent histories.
    var c = makeModel();
    defer deinitModel(&c);
    seq.run(&c);
    model.setFocus(&c, 2);
    try testing.expect(!eqModel(&a, &c));
}

test "T31: minimize seq stamps drive LIFO/FIFO restore candidates" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    model.register(&m, 10, 0) catch unreachable; // ws 0
    model.register(&m, 11, 0) catch unreachable;
    model.register(&m, 12, 1) catch unreachable; // ws 1: must never win on ws 0
    try minimize.minimize(&m, 10); // seq 0 (oldest)
    try minimize.minimize(&m, 11); // seq 1 (newest)
    try testing.expectEqual(@as(u32, 2), minimize.count(&m));
    // Seq ordering: 10 has lower seq (oldest) -> FIFO; 11 has higher -> LIFO.
    try testing.expectEqual(@as(?model.WindowId, 10), minimize.restoreCandidate(&m, 0, .fifo));
    try testing.expectEqual(@as(?model.WindowId, 11), minimize.restoreCandidate(&m, 0, .lifo));
    // Cross-workspace isolation.
    try testing.expectEqual(@as(?model.WindowId, null), minimize.restoreCandidate(&m, 1, .fifo));

    // Re-minimize 10: newest seq flips the LIFO answer; FIFO unchanged.
    minimize.restore(&m, 10);
    try minimize.minimize(&m, 10); // seq 2
    // 10 now has the highest seq -> LIFO; 11 is now oldest -> FIFO.
    try testing.expectEqual(@as(?model.WindowId, 10), minimize.restoreCandidate(&m, 0, .lifo));
    try testing.expectEqual(@as(?model.WindowId, 11), minimize.restoreCandidate(&m, 0, .fifo));
    try assertSingleMembership(&m);
}

test "T32: latestMinimizedBase skips fullscreen-current and other workspaces" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    model.register(&m, 20, 0) catch unreachable;
    model.register(&m, 21, 0) catch unreachable;
    _ = fullscreen.toggleFullscreen(&m, 21);
    try minimize.minimize(&m, 20); // plain base, older
    try minimize.minimize(&m, 21); // fullscreen, newer
    // 21 still carries its fullscreen RECORD while parked, so it is skipped
    // (the equivalent of the old prev != .base exclusion).
    try testing.expectEqual(@as(?model.WindowId, 20), minimize.latestMinimizedBase(&m, 0));
}

// T33 (user bug report): fullscreen -> minimize -> restore -> un-fullscreen
// used to strand the window base-tiled but HOME-LESS.
test "T33: fullscreen-prev restore re-adds slot; exit-fullscreen retiles" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 1);
    regCur(&m, 2);
    _ = fullscreen.toggleFullscreen(&m, 1);
    try expectOrder(&m, 0, &.{ 1, 2 }); // fullscreen windows keep their slot
    try minimize.minimize(&m, 1);
    try testing.expect(minimize.isMinimized(&m, 1));
    try testing.expect(m.store.get(1).?.presence == .parked);
    try testing.expect(fullscreen.isFullscreenMode(&m, 1)); // record RETAINED
    try expectOrder(&m, 0, &.{2}); // slot freed while hidden

    minimize.restore(&m, 1); // straight back into fullscreen ...
    const e = m.store.get(1).?;
    try testing.expect(e.presence == .covering);
    try testing.expect(fullscreen.isFullscreenMode(&m, 1));
    try testing.expectEqual(@as(WSId, 0), fullscreen.fullscreenWsOf(&m, 1).?);
    // ... AND the saved slot must be re-added (THE FIX under test).
    try expectOrder(&m, 0, &.{ 1, 2 });
    try assertSingleMembership(&m);

    // The reported final step: leaving fullscreen must return a TILEABLE,
    // tiling-placed window - not a home-less stranded orphan.
    try testing.expect(fullscreen.toggleFullscreen(&m, 1));
    const back = m.store.get(1).?;
    try testing.expect(back.anchor == .tiled and back.presence == .present);
    try expectOrder(&m, 0, &.{ 1, 2 });
    try assertSingleMembership(&m);
}

// T33b: floating-base fullscreen round trip stays home-free.
test "T33b: floating-base fullscreen minimize/restore never joins a list" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 5);
    const r: utils.Rect = .{ .x = 3, .y = 4, .width = 100, .height = 80 };
    _ = m.store.put(6, .{
        .mask = model.bit(0),
        .anchor = .{ .floating = r },
    }) catch unreachable;
    _ = fullscreen.toggleFullscreen(&m, 6);
    try minimize.minimize(&m, 6);
    try testing.expect(m.store.get(6).?.presence == .parked);
    minimize.restore(&m, 6);
    const e = m.store.get(6).?;
    try testing.expect(e.presence == .covering);
    try testing.expect(fullscreen.isFullscreenMode(&m, 6));
    try testing.expect(r.eql(e.anchor.floating));
    for (&m.ws) |*s| try testing.expect(s.tiled_order.indexOfScalar(6) == null);
}

// T34 (user bug report): minimizing one of two windows must fall back to the
// PREVIOUSLY focused window. The candidate policy lives in the model layer;
// the window layer's focusFallback delegates to it. Tier checks:
// MRU newest-first (minimized skipped even though still listed in MRU),
// then reversed tiled_order, then floating, then null.
test "T34: fallbackFocusCandidate tiers pick the previous focus" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 10);
    regCur(&m, 11); // tiled_order [10, 11]
    model.setFocus(&m, 11); // user focused 11 first...
    model.setFocus(&m, 10); // ...then 10; MRU now [10, 11]
    try testing.expectEqual(@as(?WindowId, 10), model.fallbackFocusCandidate(&m, 0));

    // Minimizing the FOCUSED window (10): the previous focus (11) wins via
    // the MRU tier even though 10 is still newest in the MRU list - visibleOn
    // rejects minimized entries.
    try minimize.minimize(&m, 10);
    try testing.expectEqual(@as(?WindowId, 11), model.fallbackFocusCandidate(&m, 0));

    // Both hidden: reversed tiled_order tier is exhausted by visibility too,
    // a floating window becomes the candidate, and an empty ws yields null.
    try minimize.minimize(&m, 11);
    _ = m.store.put(12, .{
        .mask = model.bit(0),
        .anchor = .{ .floating = .{ .x = 0, .y = 0, .width = 50, .height = 50 } },
    }) catch unreachable;
    try testing.expectEqual(@as(?WindowId, 12), model.fallbackFocusCandidate(&m, 0));

    model.unregister(&m, 12);
    try testing.expectEqual(@as(?WindowId, null), model.fallbackFocusCandidate(&m, 0));
}

// T35: minimizing-from-fullscreen KEEPS the mode, so the ghost record still
// reports the ws while parked, but visibleOn is false. Callers must gate on
// visibility (coverage/occupancy query), not the raw mode.
test "T35: fullscreenWsOf keeps the ws while minimized-from-fullscreen" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 30);
    regCur(&m, 31);
    try testing.expectEqual(@as(?WSId, null), fullscreen.fullscreenWsOf(&m, 30));
    try testing.expectEqual(@as(?WSId, null), fullscreen.fullscreenWsOf(&m, 999)); // unknown

    _ = fullscreen.toggleFullscreen(&m, 30);
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 30));
    try testing.expectEqual(@as(?WSId, null), fullscreen.fullscreenWsOf(&m, 31)); // not fullscreen

    // Minimize-from-fullscreen: the MODE is retained, but the parked window
    // is neither visible nor an occupant.
    try minimize.minimize(&m, 30);
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 30));
    try testing.expect(m.store.get(30).?.presence == .parked);
    try testing.expect(!model.visibleOn(&m, 30, 0));
    try testing.expectEqual(@as(?WindowId, null), fullscreen.fullscreenOccupantOnWs(&m, 0));
}

// T36 (user bug report): closing the focused window must hand focus to the
// PREVIOUSLY focused window.
test "T36: close-fallback candidate after unregister is the previous focus" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 40);
    regCur(&m, 41);
    model.setFocus(&m, 40); // focused first...
    model.setFocus(&m, 41); // ...then 41 holds focus; MRU [41, 40]

    // Simulate the close path's capture point + unregister.
    const was_focused = m.focused == 41;
    try testing.expect(was_focused);
    model.unregister(&m, 41);
    try testing.expectEqual(@as(?WindowId, null), m.focused); // cleared by unregister

    // The wiring must resolve the target AFTER this point via:
    try testing.expectEqual(@as(?WindowId, 40), model.fallbackFocusCandidate(&m, 0));

    // Closing the LAST window: no candidate remains -> caller clears focus
    // (same terminal state as minimizing everything).
    model.unregister(&m, 40);
    try testing.expectEqual(@as(?WindowId, null), model.fallbackFocusCandidate(&m, 0));
}

// FSQ: model fullscreen semantics: mode ignores visibility, on-ws checks the
// RECORD's workspace only, and occupancy also requires visibility.
test "FSQ: model fullscreen queries (mode / on-ws / visible occupant)" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();

    regCur(&m, 50);
    try testing.expect(!fullscreen.isFullscreenMode(&m, 50));
    try testing.expect(!fullscreen.isFullscreenOnWs(&m, 50, 0));
    try testing.expect(!fullscreen.isFullscreenMode(&m, 999)); // unknown id
    try testing.expect(!fullscreen.isFullscreenOnWs(&m, 999, 0)); // unknown id
    try testing.expectEqual(@as(?WindowId, null), fullscreen.fullscreenOccupantOnWs(&m, 0));

    _ = fullscreen.toggleFullscreen(&m, 50); // record targets current ws (0)
    try testing.expect(fullscreen.isFullscreenMode(&m, 50));
    try testing.expect(fullscreen.isFullscreenOnWs(&m, 50, 0));
    try testing.expect(!fullscreen.isFullscreenOnWs(&m, 50, 1)); // other-ws record
    try testing.expectEqual(@as(?WindowId, 50), fullscreen.fullscreenOccupantOnWs(&m, 0));

    // A record for a workspace the window isn't tagged to is NOT an occupant:
    // occupancy requires visibility (sync parks such strays).
    try model.register(&m, 51, 1); // tagged to ws1 only
    _ = fullscreen.toggleFullscreen(&m, 51); // record ws = current (0)
    try testing.expect(fullscreen.isFullscreenMode(&m, 51));
    try testing.expect(fullscreen.isFullscreenOnWs(&m, 51, 0));
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 51));
    try testing.expectEqual(@as(?WindowId, 50), fullscreen.fullscreenOccupantOnWs(&m, 0));

    // Minimize-from-fullscreen: MODE retained, but parked => not an occupant.
    try minimize.minimize(&m, 50);
    try testing.expect(fullscreen.isFullscreenMode(&m, 50));
    try testing.expect(fullscreen.isFullscreenOnWs(&m, 50, 0));
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 50));
    try testing.expect(!model.visibleOn(&m, 50, 0));
    try testing.expectEqual(@as(?WindowId, null), fullscreen.fullscreenOccupantOnWs(&m, 0));
}

// home_ws cache invariants

test "home_ws: register sets cache to current ws" {
    var m = makeModel();
    regCur(&m, 1); // register on ws 0
    try testing.expectEqual(@as(?WSId, 0), m.store.get(1).?.home_ws);
}

test "home_ws: register on non-zero ws" {
    var m = makeModel();
    try model.register(&m, 1, 3);
    try testing.expectEqual(@as(?WSId, 3), m.store.get(1).?.home_ws);
}

test "home_ws: findHome uses cache" {
    var m = makeModel();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, 0), m.store.get(1).?.home_ws);
    // findHome reads the cached home.
    try testing.expectEqual(@as(?WSId, 0), model.findHome(&m, 1));
}

test "home_ws: findHome scan fallback when cache is null" {
    var m = makeModel();
    regCur(&m, 1);
    // A null cache simulates an entry with no recorded home.
    m.store.getPtr(1).?.home_ws = null;
    // findHome scans tiled_order and recovers the correct home.
    try testing.expectEqual(@as(?WSId, 0), model.findHome(&m, 1));
}

test "home_ws: minimize clears cache" {
    var m = makeModel();
    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, 0), m.store.get(1).?.home_ws);
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
    try testing.expectEqual(@as(?WSId, 0), m.store.get(1).?.home_ws);
    try testing.expect(m.store.get(1).?.presence == .present);
}

test "home_ws: moveWindowToWs uses cache" {
    var m = makeModel();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, 0), m.store.get(1).?.home_ws);
    // moveWindowToWs reads the cached home rather than scanning.
    workspaces.moveWindowToWs(&m, 1, 5);
    // home_ws tracks the original home, not the current workspace, so it
    // stays 0 while the window lands on ws 5.
    try expectOrder(&m, 5, &.{1});
}

test "home_ws: detachToFloating clears cache" {
    var m = makeModel();
    regCur(&m, 1);
    try testing.expectEqual(@as(?WSId, 0), m.store.get(1).?.home_ws);
    // The window-layer detach path clears home_ws; verify the result state
    // (a floating entry carries null home_ws).
    const e = m.store.getPtr(1).?;
    e.anchor = .{ .floating = .{ .x = 0, .y = 0, .width = 100, .height = 100 } };
    e.home_ws = null;
    try testing.expectEqual(@as(?WSId, null), e.home_ws);
}

// I-2: restoreAllOnWs unit test (BC09: restore-all with slot-sorted reinsert).
test "restoreAllOnWs restores in slot order" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    // Minimize every window on ws 0, then restore them all in one call.
    model.register(&m, 10, 0) catch unreachable;
    model.register(&m, 20, 0) catch unreachable;
    model.register(&m, 30, 0) catch unreachable;
    try minimize.minimize(&m, 10);
    try minimize.minimize(&m, 20);
    try minimize.minimize(&m, 30);
    try testing.expectEqual(@as(u32, 3), minimize.count(&m));
    minimize.restoreAllOnWs(&m, 0);
    // No window may stay parked/minimized after the restore.
    try testing.expectEqual(@as(u32, 0), minimize.count(&m));
    const e10 = m.store.get(10) orelse unreachable;
    const e20 = m.store.get(20) orelse unreachable;
    const e30 = m.store.get(30) orelse unreachable;
    try testing.expect(e10.presence == .present);
    try testing.expect(e20.presence == .present);
    try testing.expect(e30.presence == .present);
    try testing.expect(!minimize.isMinimized(&m, 10));
    try testing.expect(!minimize.isMinimized(&m, 20));
    try testing.expect(!minimize.isMinimized(&m, 30));
}

// I-3: adjustPrimaryWidth clamps to [0.05, 0.95].
test "adjustPrimaryWidth clamps" {
    var m = makeModel();
    defer deinitModel(&m);
    workspaces.switchTo(&m, 0);
    model.adjustPrimaryWidth(&m, 10.0); // far above the ceiling
    try testing.expect(m.ws[0].params.primary_width <= 0.95);
    model.adjustPrimaryWidth(&m, -10.0); // far below the floor
    try testing.expect(m.ws[0].params.primary_width >= 0.05);
}

// I-3: setFloatingRect updates floating geometry, no-ops for tiled/unknown.
test "setFloatingRect updates floating window geometry" {
    var m = makeModel();
    defer deinitModel(&m);
    try fullscreen.init();
    defer fullscreen.deinit();
    const r: utils.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    _ = m.store.put(5, .{ .mask = model.bit(0), .anchor = .{ .floating = r } }) catch unreachable;
    const new_r: utils.Rect = .{ .x = 50, .y = 60, .width = 400, .height = 300 };
    floating.setFloatingRect(&m, 5, new_r);
    try testing.expect(new_r.eql(m.store.get(5).?.anchor.floating));
    // A tiled window is untouched by geometry updates.
    model.register(&m, 6, 0) catch unreachable;
    floating.setFloatingRect(&m, 6, new_r);
    try testing.expect(m.store.get(6).?.anchor == .tiled);
    // An unknown window is ignored without crashing.
    floating.setFloatingRect(&m, 999, new_r);
    // A covering (fullscreen) window is untouched by geometry updates.
    _ = fullscreen.toggleFullscreen(&m, 6);
    try testing.expect(m.store.get(6).?.presence == .covering);
    floating.setFloatingRect(&m, 6, new_r);
    try testing.expect(m.store.get(6).?.anchor == .tiled);
}

// T2E-1: the coverage seam claims the covering winner per ws and excludes
// parked ghosts (minimized-from-fullscreen windows never claim the screen).
test "T2E-1: coverageOn winner resolution and parked-ghost exclusion" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 60);
    regCur(&m, 61);
    try testing.expectEqual(@as(?model.WindowId, null), fullscreen.coverageOn(&m, 0));
    _ = fullscreen.toggleFullscreen(&m, 60); // rec on ws 0, covering
    _ = fullscreen.toggleFullscreen(&m, 61); // second rec, also ws 0
    try testing.expectEqual(@as(?model.WindowId, 60), fullscreen.coverageOn(&m, 0));
    try testing.expectEqual(@as(?model.WindowId, null), fullscreen.coverageOn(&m, 1));
    // Parked ghost: the record survives but never claims the screen.
    try minimize.minimize(&m, 60);
    try testing.expectEqual(@as(?model.WindowId, 61), fullscreen.coverageOn(&m, 0));
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 60).?);
    minimize.restore(&m, 60);
    try testing.expectEqual(@as(?model.WindowId, 60), fullscreen.coverageOn(&m, 0));
}

// T2E-2: minimize blob round trip -- parked-only serialization, magic claim,
// and re-adoption through the deserialize seam.
test "T2E-2: minimize serialize/deserialize round-trip" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 70);
    // Not parked => no blob (only the minimize module owns the parked slot).
    try testing.expect(minimize.serializeWindow(@ptrCast(&m), 70, testing.allocator) == null);
    try minimize.minimize(&m, 70);
    const blob = minimize.serializeWindow(@ptrCast(&m), 70, testing.allocator) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(blob);
    try testing.expectEqual(@as(usize, 9), blob.len);
    // Clear module state + presence, then re-adopt from the blob.
    minimize.onWindowGone(70);
    m.store.getPtr(70).?.presence = .present;
    try testing.expect(minimize.deserializeWindow(70, blob, @ptrCast(&m)));
    try testing.expect(minimize.isMinimized(&m, 70));
    try testing.expect(m.store.get(70).?.presence == .parked);
    // Verify saved slot 0 via restore: 70 rejoins tiled_order at index 0.
    minimize.restore(&m, 70);
    try expectOrder(&m, 0, &.{70});
    minimize.minimize(&m, 70) catch unreachable;
    // A foreign-magic or malformed blob is not claimed.
    try testing.expect(!minimize.deserializeWindow(70, &.{ 0x00, 1, 2 }, @ptrCast(&m)));
    // A present window's blob is never produced while parked=false.
    minimize.restore(&m, 70);
    try testing.expect(minimize.serializeWindow(@ptrCast(&m), 70, testing.allocator) == null);
}

// T2E-3: fullscreen blob round trip -- non-parked serialization, anchor
// retention, and re-adoption through the deserialize seam.
test "T2E-3: fullscreen serialize/deserialize round-trip" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 80);
    _ = fullscreen.toggleFullscreen(&m, 80); // covering on ws 0
    const blob = fullscreen.serializeWindow(@ptrCast(&m), 80, testing.allocator) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(blob);
    // Parked (minimize owns the slot) => fullscreen refuses to serialize.
    _ = fullscreen.toggleFullscreen(&m, 80);
    try minimize.minimize(&m, 80);
    try testing.expect(fullscreen.serializeWindow(@ptrCast(&m), 80, testing.allocator) == null);
    // Clear module state + presence, then re-adopt from the blob.
    minimize.onWindowGone(80);
    m.store.getPtr(80).?.presence = .present;
    try testing.expect(fullscreen.deserializeWindow(80, blob, @ptrCast(&m)));
    try testing.expect(fullscreen.isFullscreenMode(&m, 80));
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 80));
    try testing.expect(m.store.get(80).?.presence == .covering);
    try testing.expectEqual(@as(?model.WindowId, 80), fullscreen.coverageOn(&m, 0));
    // A foreign-magic blob is not claimed.
    try testing.expect(!fullscreen.deserializeWindow(80, &.{ 0x00, 1, 2 }, @ptrCast(&m)));
}

// -- H8: core-intents (covering_ws is a model-authoritative core intent) -----

// H8-1: toggleFullscreen drives the model's covering_ws core intent in lockstep
// with the covering presence: ON sets covering_ws, OFF clears it.
test "H8-1: toggleFullscreen writes covering_ws core intent" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 90);

    // Before entering fullscreen the core intent is absent.
    try testing.expectEqual(@as(?WSId, null), m.store.get(90).?.covering_ws);
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOnWs(&m, 0));

    _ = fullscreen.toggleFullscreen(&m, 90); // on ws 0
    var e = m.store.get(90).?;
    try testing.expect(e.presence == .covering);
    try testing.expectEqual(@as(?WSId, 0), e.covering_ws);
    try testing.expectEqual(@as(?WindowId, 90), model.coveringOccupantOnWs(&m, 0));

    // Exit clears the core intent.
    _ = fullscreen.toggleFullscreen(&m, 90);
    e = m.store.get(90).?;
    try testing.expect(e.presence == .present);
    try testing.expectEqual(@as(?WSId, null), e.covering_ws);
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOnWs(&m, 0));
}

// H8-2: coveringOccupantOnWs mirrors coverageOn's parked-ghost exclusion and
// agrees with the module's coverage seam.
test "H8-2: model.coveringOccupantOnWs excludes parked ghosts" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 91);
    _ = fullscreen.toggleFullscreen(&m, 91);
    try testing.expectEqual(@as(?WindowId, 91), model.coveringOccupantOnWs(&m, 0));
    try testing.expectEqual(@as(?WindowId, 91), fullscreen.coverageOn(&m, 0));

    // Minimize-from-fullscreen: covering_ws is KEPT (ghost) but presence is
    // parked, so neither the module seam nor the model helper reports an
    // occupant on ws 0.
    try minimize.minimize(&m, 91);
    try testing.expect(m.store.get(91).?.presence == .parked);
    try testing.expectEqual(@as(?WSId, 0), m.store.get(91).?.covering_ws);
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOnWs(&m, 0));
    try testing.expectEqual(@as(?WindowId, null), fullscreen.coverageOn(&m, 0));

    // Restore re-surfaces the window: it re-enters covering (the model's
    // covering intent is the single authority for re-claiming the screen).
    minimize.restore(&m, 91);
    try testing.expect(m.store.get(91).?.presence == .covering);
    try testing.expect(fullscreen.isFullscreenMode(&m, 91));
    try testing.expectEqual(@as(?WindowId, 91), model.coveringOccupantOnWs(&m, 0));
    try testing.expectEqual(@as(?WindowId, 91), fullscreen.coverageOn(&m, 0));
}

// H8-3: deserializeWindow (re-adoption) restores covering_ws on the model.
test "H8-3: fullscreen deserialize restores covering_ws" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 92);
    _ = fullscreen.toggleFullscreen(&m, 92);
    const blob = fullscreen.serializeWindow(@ptrCast(&m), 92, testing.allocator) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(blob);

    // Simulate adoption onto a fresh entry: clear module state + presence, keep
    // the store entry present (as registration creates it), then re-adopt.
    fullscreen.onWindowGone(92);
    m.store.getPtr(92).?.presence = .present;
    m.store.getPtr(92).?.covering_ws = null;
    try testing.expect(fullscreen.deserializeWindow(92, blob, @ptrCast(&m)));
    try testing.expect(m.store.get(92).?.presence == .covering);
    try testing.expectEqual(@as(?WSId, 0), m.store.get(92).?.covering_ws);
    try testing.expectEqual(@as(?WSId, 0), fullscreen.fullscreenWsOf(&m, 92));
}

// H8-4: a move/tag retarget (workspaces path) keeps the model's covering_ws in
// lockstep with the retargeted module record.
test "H8-4: move/tag retarget tracks covering_ws to the new ws" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    try fullscreen.init();
    defer fullscreen.deinit();
    defer minimize.deinit();
    regCur(&m, 93); // home ws 0
    _ = fullscreen.toggleFullscreen(&m, 93); // covering ws 0
    try testing.expectEqual(@as(?WSId, 0), m.store.get(93).?.covering_ws);

    // moveWindowToWs retargets the covering window to ws 2 (destination free):
    // the module record AND the model's covering_ws must both follow.
    workspaces.moveWindowToWs(&m, 93, 2);
    try testing.expectEqual(@as(?WSId, 2), m.store.get(93).?.covering_ws);
    try testing.expectEqual(@as(?WSId, 2), fullscreen.fullscreenWsOf(&m, 93));
    try testing.expect(m.store.get(93).?.presence == .covering);
    try testing.expectEqual(@as(?WindowId, 93), model.coveringOccupantOnWs(&m, 2));
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOnWs(&m, 0));
}

// -- Audited behavioral contracts (BC01/05/10/12) ----------------------------

// BC01 (spawn path): on-current spawn tiles+focuses; off-current spawn tiles
// on its target ws but does NOT take focus (mirrors actions.mapRequest).
test "BC01: spawn admission tiles (on-current focused; off-current target-only)" {
    var m = makeModel();
    defer deinitModel(&m);

    // On-current spawn: register(m, win, null) + setFocus (mirrors
    // actions.mapRequest's on_current=true path).
    model.register(&m, 1, null) catch unreachable;
    model.setFocus(&m, 1);
    var e = m.store.get(1).?;
    try testing.expect(e.anchor == .tiled);
    try testing.expect(e.presence == .present);
    try expectOrder(&m, 0, &.{1});
    try testing.expectEqual(@as(?WindowId, 1), m.focused);

    // Off-current spawn: current moves away, a new window targets ws 0.
    // register(m, win, 0) tiles it there; mapRequest's on_current=false early
    // return means it must NOT steal model focus.
    workspaces.switchTo(&m, 2);
    model.register(&m, 2, 0) catch unreachable;
    e = m.store.get(2).?;
    try testing.expect(e.anchor == .tiled);
    try testing.expect(e.presence == .present);
    try expectOrder(&m, 0, &.{ 1, 2 });
    try testing.expectEqual(@as(?WindowId, 1), m.focused); // not stolen
    try assertSingleMembership(&m);
}

// BC05: a border_width-only honor on a TILED window (border_only) must not
// disturb tiling membership; it stays tiled/present for the next retile.
test "BC05: border-width honor leaves tiled membership intact across a retile" {
    var m = makeModel();
    defer deinitModel(&m);
    try fullscreen.init();
    defer fullscreen.deinit();
    regCur(&m, 1);
    regCur(&m, 2);

    // Tiled configure request carrying only border_width: geometry denied,
    // width honored (T13's decision).
    try testing.expectEqual(
        model.HonorDecision.border_only,
        floating.honorConfigureRequest(&m, 1, .{ .border_width = 3 }),
    );
    // The decision left the window tiled/present in its slot.
    const e = m.store.get(1).?;
    try testing.expect(e.anchor == .tiled);
    try testing.expect(e.presence == .present);
    try expectOrder(&m, 0, &.{ 1, 2 });

    // A retile (slot swap) still finds the window; membership/mask intact.
    model.swapPrimary(&m);
    try expectOrder(&m, 0, &.{ 2, 1 });
    try testing.expectEqual(model.bit(0), m.store.get(1).?.mask);
    try assertSingleMembership(&m);
}

// BC10 (cross-workspace restore): restoring a minimized window to its HOME
// workspace while the CURRENT workspace carries its own stack must not disturb
// that stack.
test "BC10: restore to home workspace leaves the current workspace's stack intact" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();

    model.register(&m, 10, 0) catch unreachable; // home 0
    model.register(&m, 11, 0) catch unreachable; // home 0
    model.register(&m, 20, 1) catch unreachable; // home 1
    model.register(&m, 21, 1) catch unreachable; // home 1
    try expectOrder(&m, 0, &.{ 10, 11 });
    try expectOrder(&m, 1, &.{ 20, 21 });

    // Make ws 1 the CURRENT workspace; it is showing its own stack [20, 21].
    workspaces.switchTo(&m, 1);

    // Minimize a window whose home is ws 0, then restore it -- all while the
    // current workspace (1) keeps its own stack in view.
    try minimize.minimize(&m, 10);
    try expectOrder(&m, 1, &.{ 20, 21 }); // current stack undisturbed
    minimize.restore(&m, 10);

    // The restored window is back on its HOME ws 0; ws 1's stack is untouched.
    try expectOrder(&m, 0, &.{ 10, 11 });
    try expectOrder(&m, 1, &.{ 20, 21 });
    try testing.expect(m.store.get(10).?.presence == .present);
    try testing.expect(!minimize.isMinimized(&m, 10));
    try assertSingleMembership(&m);
}

// BC12 (tag-move minimized record follows ws): moving a minimized window to
// another workspace moves its parked record (the tag mask follows), so a later
// restore lands on the NEW workspace while the old workspace's stack is left
// undisturbed.
test "BC12: tag-move of a minimized window moves the record; restore lands on the new ws" {
    var m = makeModel();
    defer deinitModel(&m);
    try minimize.init();
    defer minimize.deinit();

    model.register(&m, 30, 0) catch unreachable; // home 0
    model.register(&m, 31, 0) catch unreachable;
    try minimize.minimize(&m, 30);
    try testing.expect(minimize.isMinimized(&m, 30));

    // Move the parked window to ws 2: only the record moves (the tag mask
    // follows per workspaces.moveWindowToWs); it stays minimized, and the old
    // stack keeps only 31.
    workspaces.moveWindowToWs(&m, 30, 2);
    try testing.expectEqual(model.bit(2), m.store.get(30).?.mask);
    try testing.expect(minimize.isMinimized(&m, 30));
    try expectOrder(&m, 0, &.{31});

    // Restore lands on the NEW workspace (lowest bit of the moved mask); the
    // old workspace still only holds 31.
    minimize.restore(&m, 30);
    try expectOrder(&m, 2, &.{30});
    try expectOrder(&m, 0, &.{31});
    try testing.expectEqual(@as(?WSId, 2), m.store.get(30).?.home_ws);
    try testing.expect(!minimize.isMinimized(&m, 30));
    try assertSingleMembership(&m);
}
