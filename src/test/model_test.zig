//! Unit tests for the model layer (WP1, test table T01-T18).
//! Run via `zig build test` (standalone `zig test` cannot resolve named
//! imports -- see build.zig comment on the test step).
const std = @import("std");
const testing = std.testing;
const model = @import("model");
const constants = @import("constants");
const utils = @import("utils");

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;
const max_minimized = constants.max_minimized;
const SmallStore = @import("store").Store(u32, u8, 2);

fn makeModel() Model {
    return .{}; // bounded lists: no allocator, no deinit (I8 totality)
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

fn eqPrev(a: model.PrevMode, b: model.PrevMode) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    return switch (a) {
        .base => return eqBase(a.base, b.base),
        .fullscreen => |fa| return fa.ws == b.fullscreen.ws and eqBase(fa.base, b.fullscreen.base),
    };
}

fn eqMode(a: model.Mode, b: model.Mode) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;
    switch (a) {
        .base => return eqBase(a.base, b.base),
        .fullscreen => |fa| return fa.ws == b.fullscreen.ws and eqBase(fa.base, b.fullscreen.base),
        .minimized => |ma| {
            return ma.slot == b.minimized.slot and eqPrev(ma.prev, b.minimized.prev);
        },
    }
}

fn eqEntry(a: *const model.Entry, b: *const model.Entry) bool {
    return a.mask == b.mask and eqMode(a.mode, b.mode);
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
        if (!std.mem.eql(WindowId, sa.tiled_order.constSlice(), sb.tiled_order.constSlice())) return false;
        if (!std.mem.eql(WindowId, sa.focus_mru.constSlice(), sb.focus_mru.constSlice())) return false;
        if (sa.params.kind != sb.params.kind) return false;
        if (sa.params.variant_idx != sb.params.variant_idx) return false;
        if (sa.params.master_width != sb.params.master_width) return false;
        if (sa.params.master_count != sb.params.master_count) return false;
        if (sa.params.stack_balance != sb.params.stack_balance) return false;
        if (sa.params.scroll_prev != sb.params.scroll_prev) return false;
    }
    return true;
}

/// Every window whose effective base is tiled appears in EXACTLY ONE ws
/// list; every listed id exists in the store (single-membership invariant).
/// Floating (C-D1) and minimized windows are legitimately home-free.
fn assertSingleMembership(m: *const Model) !void {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        const base: ?model.BaseMode = switch (it.val.mode) {
            .minimized => null, // parked: no tiled slot by design
            .base => |b| b,
            .fullscreen => |f| f.base,
        };
        const tiled = if (base) |b| b == .tiled else false;
        if (!tiled) continue;
        var homes: usize = 0;
        for (&m.ws) |*s| {
            if (model.findInOrder(&s.tiled_order, it.key) != null) homes += 1;
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
    try testing.expect(e.mode == .base);
    try testing.expect(e.mode.base == .tiled);
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

// T03: minimize tiled -> prev==base(.tiled); removed from tiled_order;
// CapacityFull when store's minimized budget is exhausted (pre-refused, T17).
test "T03: minimize tiled removes from order; capacity refuses" {
    var m = makeModel();
    defer deinitModel(&m);
    var wins: [max_minimized + 1]WindowId = undefined;
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(100 + i);
        regCur(&m, w.*);
    }
    try expectOrder(&m, 0, &wins);
    model.minimize(&m, 102) catch unreachable;
    const e = m.store.get(102).?;
    try testing.expect(e.mode == .minimized);
    try testing.expect(e.mode.minimized.prev == .base);
    try testing.expect(e.mode.minimized.prev.base == .tiled);
    try testing.expectEqual(@as(?usize, 2), e.mode.minimized.slot);
    var expected: [max_minimized]WindowId = undefined;
    _ = std.mem.replace(WindowId, &wins, &.{102}, &.{}, expected[0 .. wins.len - 1]);
    try expectOrder(&m, 0, expected[0 .. wins.len - 1]);

    // Fill the remaining budget, then the next minimize must be refused
    // without mutating anything (I8; full no-mutation proof in T17).
    for (wins[0 .. wins.len - 1]) |w| model.minimize(&m, w) catch unreachable;
    try testing.expectError(error.CapacityFull, model.minimize(&m, wins[wins.len - 1]));
}

// T04: restore tiled -> back at ORIGINAL index.
test "T04: restore reinserts at original slot" {
    var m = makeModel();
    defer deinitModel(&m);
    for ([_]WindowId{ 10, 11, 12, 13, 14 }) |w| regCur(&m, w);
    model.minimize(&m, 12) catch unreachable;
    model.minimize(&m, 11) catch unreachable;
    try expectOrder(&m, 0, &.{ 10, 13, 14 });
    model.restore(&m, 12);
    try expectOrder(&m, 0, &.{ 10, 13, 12, 14 });
    model.restore(&m, 11);
    try expectOrder(&m, 0, &.{ 10, 11, 13, 12, 14 });
    // Restoring a live or unknown window is a no-op.
    model.restore(&m, 10);
    model.restore(&m, 999);
    try expectOrder(&m, 0, &.{ 10, 11, 13, 12, 14 });
}

// T05: minimize floating -> prev==floating(rect); restore returns the rect.
test "T05: minimize/restore floating preserves rect" {
    var m = makeModel();
    defer deinitModel(&m);
    const r: utils.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    _ = m.store.put(7, .{
        .mask = model.bit(0),
        .mode = .{ .base = .{ .floating = r } },
    }) catch unreachable;
    model.minimize(&m, 7) catch unreachable;
    const e = m.store.get(7).?;
    try testing.expect(e.mode == .minimized);
    try testing.expect(e.mode.minimized.prev == .base);
    try testing.expect(e.mode.minimized.prev.base == .floating);
    try testing.expect(r.eql(e.mode.minimized.prev.base.floating));
    try testing.expectEqual(@as(?usize, null), e.mode.minimized.slot);
    model.restore(&m, 7);
    const back = m.store.get(7).?;
    try testing.expect(back.mode == .base);
    try testing.expect(back.mode.base == .floating);
    try testing.expect(r.eql(back.mode.base.floating));
    // Fix P2-7: floating-prev restore must NOT join any tiled_order (a
    // phantom member would shift every other window's layout slot).
    for (&m.ws) |*s| try testing.expect(model.findInOrder(&s.tiled_order, 7) == null);
}

// T06: toggleFullscreen round trips; fullscreen_saved preserved through
// minimize-from-fullscreen (BC08).
test "T06: fullscreen toggling and BC08 minimize-from-fullscreen" {
    var m = makeModel();
    defer deinitModel(&m);
    // Tiled round trip.
    regCur(&m, 1);
    try testing.expect(model.toggleFullscreen(&m, 1));
    var e = m.store.get(1).?;
    try testing.expect(e.mode == .fullscreen);
    try testing.expectEqual(@as(WSId, 0), e.mode.fullscreen.ws);
    try testing.expect(e.mode.fullscreen.base == .tiled);
    try testing.expect(model.toggleFullscreen(&m, 1));
    e = m.store.get(1).?;
    try testing.expect(e.mode == .base);
    try testing.expect(e.mode.base == .tiled);

    // Floating base survives minimize-from-fullscreen (BC08 exact).
    const r: utils.Rect = .{ .x = 5, .y = 6, .width = 640, .height = 480 };
    _ = m.store.put(2, .{
        .mask = model.bit(0),
        .mode = .{ .base = .{ .floating = r } },
    }) catch unreachable;
    _ = model.toggleFullscreen(&m, 2);
    model.minimize(&m, 2) catch unreachable;
    e = m.store.get(2).?;
    try testing.expect(e.mode == .minimized);
    try testing.expect(eqPrev(
        .{ .fullscreen = .{ .ws = 0, .base = .{ .floating = r } } },
        e.mode.minimized.prev,
    ));
    model.restore(&m, 2);
    e = m.store.get(2).?;
    try testing.expect(e.mode == .fullscreen);
    try testing.expect(r.eql(e.mode.fullscreen.base.floating));

    // Fullscreen toggle on a minimized window is refused.
    model.minimize(&m, 1) catch unreachable;
    try testing.expect(!model.toggleFullscreen(&m, 1));
    try testing.expect(m.store.get(1).?.mode == .minimized);
}

// T07: switchTo updates current; visible-set helper correctness.
test "T07: switchTo and visibleOn" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    // Give window 1 a second tag.
    m.store.getPtr(1).?.mask |= model.bit(1);
    regCur(&m, 2); // ws0 only
    try testing.expect(model.visibleOn(&m, 1, 0));
    try testing.expect(model.visibleOn(&m, 1, 1));
    try testing.expect(!model.visibleOn(&m, 1, 2));
    try testing.expect(model.visibleOn(&m, 2, 0));
    try testing.expect(!model.visibleOn(&m, 2, 1));

    model.switchTo(&m, 1);
    try testing.expectEqual(@as(WSId, 1), m.current);

    // Minimized windows are invisible regardless of tags/all-view.
    model.minimize(&m, 1) catch unreachable;
    try testing.expect(!model.visibleOn(&m, 1, 0));
    try testing.expect(!model.visibleOn(&m, 1, 1));
    _ = model.allViewToggle(&m);
    try testing.expect(model.visibleOn(&m, 2, 1)); // untagged, all-view on
    try testing.expect(!model.visibleOn(&m, 1, 1)); // still minimized
    // Unknown windows are never visible.
    try testing.expect(!model.visibleOn(&m, 999, 0));
}

// T08: moveWindowToWs retargets mask; minimized record follows (BC12).
test "T08: moveWindowToWs for tiled, minimized, and pinned" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    regCur(&m, 2);
    regCur(&m, 3);
    model.moveWindowToWs(&m, 1, 2);
    try testing.expectEqual(model.bit(2), m.store.get(1).?.mask);
    try expectOrder(&m, 0, &.{ 2, 3 });
    try expectOrder(&m, 2, &.{1});
    try testing.expectEqual(@as(WSId, 2), model.findHome(&m, 1).?);

    // Minimized: only the record moves; restore lands on the new ws (BC12).
    model.restore(&m, 1);
    model.moveWindowToWs(&m, 1, 2);
    model.minimize(&m, 1) catch unreachable;
    model.moveWindowToWs(&m, 1, 3);
    try testing.expectEqual(model.bit(3), m.store.get(1).?.mask);
    model.restore(&m, 1);
    try expectOrder(&m, 3, &.{1});
    try expectOrder(&m, 2, &.{});

    // Pinned windows ignore tag-moves entirely.
    model.pinToggle(&m, 1);
    try testing.expectEqual(model.ALL_MASK, m.store.get(1).?.mask);
    model.moveWindowToWs(&m, 1, 4);
    try testing.expectEqual(model.ALL_MASK, m.store.get(1).?.mask);
}

// T09: pinToggle sets/clears all-bits; composes with every mode.
test "T09: pinToggle across all modes" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1); // tiled
    const r: utils.Rect = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
    _ = m.store.put(2, .{ .mask = model.bit(0), .mode = .{ .base = .{ .floating = r } } }) catch unreachable; // floating
    regCur(&m, 3);
    _ = model.toggleFullscreen(&m, 3); // fullscreen
    regCur(&m, 4);
    model.minimize(&m, 4) catch unreachable; // minimized

    const wins = [_]WindowId{ 1, 2, 3, 4 };
    for (wins) |w| {
        model.pinToggle(&m, w);
        try testing.expectEqual(model.ALL_MASK, m.store.get(w).?.mask);
        model.pinToggle(&m, w);
        try testing.expectEqual(model.bit(m.current), m.store.get(w).?.mask);
    }
    // Modes were untouched by pinning.
    try testing.expect(m.store.get(3).?.mode == .fullscreen);
    try testing.expect(m.store.get(4).?.mode == .minimized);
}

// T10: allViewToggle round trip; visibility parity with legacy enterAllView
// (temp-window tracking deleted per changelog 2026-08-21; BC17 emerges from
// the visibility model).
test "T10: all-view flag drives visibility for every stored window" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    model.register(&m, 2, 2) catch unreachable;
    try testing.expect(!model.visibleOn(&m, 1, 1));
    try testing.expect(!model.visibleOn(&m, 2, 0));

    try testing.expect(model.allViewToggle(&m)); // -> active
    try testing.expect(m.all_view_active);
    try testing.expect(model.visibleOn(&m, 1, 1));
    try testing.expect(model.visibleOn(&m, 2, 0));
    try testing.expect(model.visibleOn(&m, 2, 5));

    try testing.expect(!model.allViewToggle(&m)); // -> inactive
    try testing.expect(!m.all_view_active);
    try testing.expect(!model.visibleOn(&m, 1, 1));
    try testing.expect(!model.visibleOn(&m, 2, 0));
}

// T11: reorderTiled bounds-checked; swapMaster master/stack swap.
test "T11: reorder and swapMaster" {
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
    _ = m.store.put(9, .{ .mask = model.bit(0), .mode = .{ .base = .{ .floating = .{ .x = 0, .y = 0, .width = 1, .height = 1 } } } }) catch unreachable;
    model.reorderTiled(&m, 9, 0);
    model.reorderTiled(&m, 42, 0);
    try expectOrder(&m, 0, &.{ 3, 1, 2, 4 });

    // swapMaster swaps slots 0 and 1.
    model.swapMaster(&m);
    try expectOrder(&m, 0, &.{ 1, 3, 2, 4 });
    model.swapMaster(&m);
    try expectOrder(&m, 0, &.{ 3, 1, 2, 4 });

    // Fewer than two tiled windows: no-op.
    var small = makeModel();
    defer deinitModel(&small);
    regCur(&small, 7);
    model.swapMaster(&small);
    try expectOrder(&small, 0, &.{7});
}

// T12: unregister cleans tiled_order/MRU/minimized/fs refs everywhere (BC11).
test "T12: unregister cleans all references" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    regCur(&m, 2);
    model.setFocus(&m, 1);
    m.ws[0].params.scroll_prev = 1;
    model.minimize(&m, 2) catch unreachable;
    regCur(&m, 3);
    _ = model.toggleFullscreen(&m, 3);

    model.unregister(&m, 1);
    try testing.expect(!m.store.has(1));
    // Window 2 left tiled_order when it was minimized; only 3 remains.
    try expectOrder(&m, 0, &.{3});
    for (&m.ws) |*s| {
        try testing.expect(s.focus_mru.indexOfScalar(1) == null);
        try testing.expect(s.params.scroll_prev != 1);
    }
    try testing.expect(m.focused != 1);

    // Destroying a minimized window clears its only ref (the store entry).
    model.unregister(&m, 2);
    try testing.expect(!m.store.has(2));
    try testing.expectEqual(@as(usize, 1), m.store.count());

    // Destroying a fullscreen window leaves no dangling refs either.
    model.unregister(&m, 3);
    try testing.expect(!m.store.has(3));
    try expectOrder(&m, 0, &.{});

    // Unknown/double unregister are safe.
    model.unregister(&m, 1);
    model.unregister(&m, 999);
}

// T13: honorConfigureRequest decisions per mode.
test "T13: ConfigureRequest honoring per mode" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1); // tiled
    const r0: utils.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    _ = m.store.put(2, .{ .mask = model.bit(0), .mode = .{ .base = .{ .floating = r0 } } }) catch unreachable;
    regCur(&m, 3);
    _ = model.toggleFullscreen(&m, 3);
    regCur(&m, 4);
    model.minimize(&m, 4) catch unreachable;

    // Floating: geometry accepted and recorded in the model (P5/I5).
    try testing.expectEqual(
        model.HonorDecision.geometry_applied,
        model.honorConfigureRequest(&m, 2, .{ .x = 50, .y = 60, .width = 320, .height = 240 }),
    );
    try testing.expectEqual(@as(i16, 50), m.store.get(2).?.mode.base.floating.x);
    try testing.expectEqual(@as(i16, 60), m.store.get(2).?.mode.base.floating.y);
    try testing.expectEqual(@as(u16, 320), m.store.get(2).?.mode.base.floating.width);
    try testing.expectEqual(@as(u16, 240), m.store.get(2).?.mode.base.floating.height);

    // Tiled: geometry denied; BW honored (recording is sync's job).
    try testing.expectEqual(
        model.HonorDecision.ignored,
        model.honorConfigureRequest(&m, 1, .{ .x = 1, .y = 1 }),
    );
    try testing.expectEqual(
        model.HonorDecision.border_only,
        model.honorConfigureRequest(&m, 1, .{ .border_width = 3 }),
    );
    try testing.expectEqual(
        model.HonorDecision.border_only,
        model.honorConfigureRequest(&m, 1, .{ .x = 1, .border_width = 3 }),
    );

    // Fullscreen/minimized/unknown: denied outright.
    try testing.expectEqual(
        model.HonorDecision.ignored,
        model.honorConfigureRequest(&m, 3, .{ .x = 1, .border_width = 3 }),
    );
    try testing.expectEqual(
        model.HonorDecision.ignored,
        model.honorConfigureRequest(&m, 4, .{ .border_width = 3 }),
    );
    try testing.expectEqual(
        model.HonorDecision.ignored,
        model.honorConfigureRequest(&m, 999, .{ .x = 1 }),
    );
}

// T14: applyConfigReload replaces layout params but preserves scroll_prev.
test "T14: config reload rescales params, keeps scroll_prev" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    m.ws[0].params = .{ .kind = .scroll, .master_width = 0.7, .master_count = 3 };
    m.ws[0].params.scroll_prev = 1;
    m.ws[1].params.master_width = 0.9;

    const tpl: model.LayoutParams = .{ .kind = .grid, .master_width = 0.6 };
    model.applyConfigReload(&m, tpl);

    for (&m.ws) |*s| {
        try testing.expectEqual(model.LayoutKind.grid, s.params.kind);
        try testing.expectEqual(@as(f32, 0.6), s.params.master_width);
        try testing.expectEqual(@as(u8, 1), s.params.master_count);
    }
    try testing.expectEqual(@as(?WindowId, 1), m.ws[0].params.scroll_prev);
    try testing.expectEqual(@as(?WindowId, null), m.ws[1].params.scroll_prev);
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

    // C-D2: focusing while current layout is scroll updates scroll_prev.
    m.ws[0].params.kind = .scroll;
    model.setFocus(&m, wins[3]);
    try testing.expectEqual(@as(?WindowId, wins[3]), m.ws[0].params.scroll_prev);
}

// T16: store remove-swap keeps iteration deterministic (+ single-membership).
// Swap-remove semantics (C-D5): the tail element inherits the freed slot, so
// it takes over the removed element's position in the iteration sequence.
test "T16: store iteration stays deterministic across removals" {
    var m = makeModel();
    defer deinitModel(&m);
    for ([_]WindowId{ 1, 2, 3, 4 }) |w| _ = m.store.put(w, .{ .mask = model.bit(0), .mode = .{ .base = .tiled } }) catch unreachable;

    inline for (.{ @as(WindowId, 1), @as(WindowId, 2), @as(WindowId, 3), @as(WindowId, 4) }, 0..) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    try testing.expect(m.store.remove(2));
    inline for (.{ @as(WindowId, 1), @as(WindowId, 4), @as(WindowId, 3) }, 0..) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    _ = m.store.put(5, .{ .mask = model.bit(0), .mode = .{ .base = .tiled } }) catch unreachable;
    inline for (.{ @as(WindowId, 1), @as(WindowId, 4), @as(WindowId, 3), @as(WindowId, 5) }, 0..) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    try testing.expect(m.store.remove(1)); // head
    try testing.expect(m.store.remove(5)); // tail
    inline for (.{ @as(WindowId, 3), @as(WindowId, 4) }, 0..) |w, i| {
        try testing.expectEqual(w, m.store.at(i).key);
    }
    try testing.expect(!m.store.remove(77));

    // Model-level single-membership invariant holds alongside the raw store.
    // Clear the raw-store fixtures above so every remaining entry is one the
    // transitions placed themselves.
    _ = m.store.remove(3);
    _ = m.store.remove(4);
    for ([_]WindowId{ 30, 31, 32 }) |w| regCur(&m, w);
    model.moveWindowToWs(&m, 31, 1);
    model.minimize(&m, 32) catch unreachable;
    try assertSingleMembership(&m);
}

// T17: INVARIANT(I8) -- no function mutates before its capacity check.
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

    // Model minimize: refused call leaves the entire model byte-identical.
    var m = makeModel();
    defer deinitModel(&m);
    var wins: [max_minimized + 1]WindowId = undefined;
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(200 + i);
        regCur(&m, w.*);
    }
    for (wins[0 .. wins.len - 1]) |w| model.minimize(&m, w) catch unreachable;
    model.setFocus(&m, wins[wins.len - 1]);
    try testing.expectError(error.CapacityFull, model.minimize(&m, wins[wins.len - 1]));

    var ref = makeModel();
    defer deinitModel(&ref);
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(200 + i);
        model.register(&ref, w.*, if (i == wins.len - 1) null else 0) catch unreachable;
        if (i < wins.len - 1) model.minimize(&ref, w.*) catch unreachable;
    }
    model.setFocus(&ref, wins[wins.len - 1]);
    // The refused model equals a pristine replay of the accepted prefix...
    try testing.expect(eqModel(&m, &ref));
    // ...and specifically, the attempted window was NOT minimized.
    try testing.expect(m.store.get(wins[wins.len - 1]).?.mode == .base);

    // register refusal: a full home-list bound refuses BEFORE mutation and
    // undoes the store insert (bounded lists have no OOM path; the bound IS
    // the defined overflow). Fill ws 0's tiled list to capacity.
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
    const seq = struct {
        fn run(m: *Model) void {
            for ([_]WindowId{ 1, 2, 3, 4, 5 }) |w| model.register(m, w, null) catch unreachable;
            model.register(m, 6, 2) catch unreachable;
            model.switchTo(m, 1);
            model.register(m, 7, null) catch unreachable;
            model.switchTo(m, 0);
            model.reorderTiled(m, 3, 0);
            model.swapMaster(m);
            model.minimize(m, 4) catch unreachable;
            model.restore(m, 4);
            model.minimize(m, 5) catch unreachable;
            _ = model.toggleFullscreen(m, 2);
            model.setFloatingRect(m, 6, .{ .x = 1, .y = 2, .width = 30, .height = 40 });
            model.pinToggle(m, 1);
            model.moveWindowToWs(m, 7, 1);
            model.cycleLayout(m, 1);
            model.adjustMasterWidth(m, 0.1);
            model.setFocus(m, 3);
            model.setFocus(m, 1);
            _ = model.allViewToggle(m);
            _ = model.allViewToggle(m);
            model.unregister(m, 5);
            model.applyConfigReload(m, .{ .kind = .leaf });
        }
    };
    var a = makeModel();
    defer deinitModel(&a);
    var b = makeModel();
    defer deinitModel(&b);
    seq.run(&a);
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
    model.register(&m, 10, 0) catch unreachable; // ws 0
    model.register(&m, 11, 0) catch unreachable;
    model.register(&m, 12, 1) catch unreachable; // ws 1: must never win on ws 0
    try model.minimize(&m, 10); // seq 0 (oldest)
    try model.minimize(&m, 11); // seq 1 (newest)
    try testing.expectEqual(@as(u32, 2), m.next_seq);

    try testing.expectEqual(@as(?model.WindowId, 10), model.restoreCandidate(&m, 0, .fifo));
    try testing.expectEqual(@as(?model.WindowId, 11), model.restoreCandidate(&m, 0, .lifo));
    // Cross-workspace isolation.
    try testing.expectEqual(@as(?model.WindowId, null), model.restoreCandidate(&m, 1, .fifo));

    // Re-minimize 10: newest seq flips the LIFO answer; FIFO unchanged.
    model.restore(&m, 10);
    try model.minimize(&m, 10); // seq 2
    try testing.expectEqual(@as(?model.WindowId, 10), model.restoreCandidate(&m, 0, .lifo));
    try testing.expectEqual(@as(?model.WindowId, 11), model.restoreCandidate(&m, 0, .fifo));
    try assertSingleMembership(&m);
}

test "T32: latestMinimizedBase skips fullscreen-prev and other workspaces" {
    var m = makeModel();
    defer deinitModel(&m);
    model.register(&m, 20, 0) catch unreachable;
    model.register(&m, 21, 0) catch unreachable;
    _ = model.toggleFullscreen(&m, 21);
    try model.minimize(&m, 20); // plain base, older
    try model.minimize(&m, 21); // fullscreen-prev, newer — excluded from BC09 focus
    try testing.expectEqual(@as(?model.WindowId, 20), model.latestMinimizedBase(&m, 0));
}

// T33 (user bug report): fullscreen -> minimize -> restore -> un-fullscreen
// used to strand the window base-tiled but HOME-LESS: restore() only
// re-entered the slot for base-tiled prevs, so the fullscreen-prev window's
// saved slot was dropped. After the later exit-fullscreen it was invisible to
// the engine (stale geometry) and untileable via toggle_floating_window.
// BC08 pins the correct behavior: "slot re-added THEN fullscreen re-entered".
test "T33: fullscreen-prev restore re-adds slot; exit-fullscreen retiles" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 1);
    regCur(&m, 2);
    _ = model.toggleFullscreen(&m, 1);
    try expectOrder(&m, 0, &.{ 1, 2 }); // fullscreen windows keep their slot
    try model.minimize(&m, 1);
    try testing.expect(m.store.get(1).?.mode == .minimized);
    try expectOrder(&m, 0, &.{2}); // slot freed while hidden

    model.restore(&m, 1); // BC08: straight back into fullscreen ...
    const e = m.store.get(1).?;
    try testing.expect(e.mode == .fullscreen);
    try testing.expectEqual(@as(WSId, 0), e.mode.fullscreen.ws);
    // ... AND the saved slot must be re-added (THE FIX under test).
    try expectOrder(&m, 0, &.{ 1, 2 });
    try assertSingleMembership(&m);

    // The reported final step: leaving fullscreen must return a TILEABLE,
    // engine-placed window — not a home-less base.tiled orphan.
    try testing.expect(model.toggleFullscreen(&m, 1));
    const back = m.store.get(1).?;
    try testing.expect(back.mode == .base and back.mode.base == .tiled);
    try expectOrder(&m, 0, &.{ 1, 2 });
    try assertSingleMembership(&m);
}

// T33b: floating-base fullscreen round trip stays home-free (C-D1 / fix
// P2-7) — the wants_home refinement must not regress T06's exact contract.
test "T33b: floating-base fullscreen minimize/restore never joins a list" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 5);
    const r: utils.Rect = .{ .x = 3, .y = 4, .width = 100, .height = 80 };
    _ = m.store.put(6, .{
        .mask = model.bit(0),
        .mode = .{ .base = .{ .floating = r } },
    }) catch unreachable;
    _ = model.toggleFullscreen(&m, 6);
    try model.minimize(&m, 6);
    model.restore(&m, 6);
    const e = m.store.get(6).?;
    try testing.expect(e.mode == .fullscreen);
    try testing.expect(r.eql(e.mode.fullscreen.base.floating));
    for (&m.ws) |*s| try testing.expect(model.findInOrder(&s.tiled_order, 6) == null);
}

// T34 (user bug report): minimizing one of two windows must fall back to the
// PREVIOUSLY focused window. The candidate policy lives in the model layer;
// actions.pickFallback delegates to it verbatim. Tier checks:
// MRU newest-first (minimized skipped even though still listed in MRU),
// then reversed tiled_order, then floating, then null.
test "T34: fallbackFocusCandidate tiers pick the previous focus" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 10);
    regCur(&m, 11); // tiled_order [10, 11]
    model.setFocus(&m, 11); // user focused 11 first...
    model.setFocus(&m, 10); // ...then 10; MRU now [10, 11]
    try testing.expectEqual(@as(?WindowId, 10), model.fallbackFocusCandidate(&m, 0));

    // Minimizing the FOCUSED window (10): the previous focus (11) wins via
    // the MRU tier even though 10 is still newest in the MRU list — visibleOn
    // rejects minimized entries.
    try model.minimize(&m, 10);
    try testing.expectEqual(@as(?WindowId, 11), model.fallbackFocusCandidate(&m, 0));

    // Both hidden: reversed tiled_order tier is exhausted by visibility too,
    // a floating window becomes the candidate, and an empty ws yields null.
    try model.minimize(&m, 11);
    _ = m.store.put(12, .{
        .mask = model.bit(0),
        .mode = .{ .base = .{ .floating = .{ .x = 0, .y = 0, .width = 50, .height = 50 } } },
    }) catch unreachable;
    try testing.expectEqual(@as(?WindowId, 12), model.fallbackFocusCandidate(&m, 0));

    model.unregister(&m, 12);
    try testing.expectEqual(@as(?WindowId, null), model.fallbackFocusCandidate(&m, 0));
}

// T35: fullscreenWsOf is the pre-removal read primitive for unmanage paths
// (bug: closing/minimizing away a fullscreened window never restored the bar
// because the query ran after the store entry was already gone).
test "T35: fullscreenWsOf reports the record and null otherwise" {
    var m = makeModel();
    defer deinitModel(&m);
    regCur(&m, 30);
    regCur(&m, 31);
    try testing.expectEqual(@as(?WSId, null), model.fullscreenWsOf(&m, 30));
    try testing.expectEqual(@as(?WSId, null), model.fullscreenWsOf(&m, 999)); // unknown

    _ = model.toggleFullscreen(&m, 30);
    try testing.expectEqual(@as(?WSId, 0), model.fullscreenWsOf(&m, 30));
    try testing.expectEqual(@as(?WSId, null), model.fullscreenWsOf(&m, 31)); // not fullscreen

    // After minimize-from-fullscreen the record is GONE (parked inside
    // prev) — callers must capture before dropping/removal, never after.
    try model.minimize(&m, 30);
    try testing.expectEqual(@as(?WSId, null), model.fullscreenWsOf(&m, 30));
}
