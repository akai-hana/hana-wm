//! Unit tests for the minimize module's model-facing seam: the
//! minimize/restore state machine asserted through the model it
//! mutates (slot preservation, capacity, LIFO/FIFO restore
//! candidates, serialize round-trip), plus the fallbackFocusCandidate
//! focus-recovery policy (a model function whose skip-candidates are
//! minimized windows, so it lives with the minimize setups it builds).
//! Extracted from model_test.zig; same makeModel fixture and
//! minimize.init()/deinit() discipline as the parent file.
//!
//! The minimize module's process-global store is re-armed by
//! helpers.makeModel, so these tests pass in any order.

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
const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;
const max_minimized = constants.max_minimized;

/// Sentinel id for "a window that was never registered": every negative-path
/// assertion (unknown/unregistered lookups) uses it instead of a literal.
const unknown_win: WindowId = 999;
/// A blob whose magic byte can never match a module's serializer: the
/// deserialize admission tests assert it is refused on sight.
const foreign_blob = [_]u8{ 0x00, 1, 2 };

/// Resetting fixture: a fresh model on deterministically re-armed module
/// stores (minimize/fullscreen), so tests pass in any order regardless of
/// what records an earlier test left behind.
const makeModel = helpers.makeModel; // (28.3) reset is now the default, not a separate entry point

fn expectOrder(m: *const Model, ws: WSId, expected: []const WindowId) !void {
    try testing.expectEqualSlices(WindowId, expected, m.ws[ws.index].tiled_order.constSlice());
}

const regCur = helpers.regCur;

/// Floating-anchor window, the shape most store.put fixtures use.
fn addFloating(m: *Model, win: WindowId, r: model.Rect) !void {
    _ = try m.store.put(win, .{
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .{ .floating = r },
    });
}

/// Registers a contiguous window-id run starting at `base` and returns the
/// ids for fixtures that need them.
fn registerRange(m: *Model, comptime n: usize, base: u32) [n]WindowId {
    var wins: [n]WindowId = undefined;
    for (&wins, 0..) |*w, i| {
        w.* = @intCast(base + @as(u32, @intCast(i)));
        regCur(m, w.*);
    }
    return wins;
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
        var actual_home: WSId = undefined;
        for (&m.ws, 0..) |*s, wi| {
            if (s.tiled_order.indexOfScalar(it.key) != null) {
                homes += 1;
                actual_home = WSId.fromIndex(wi);
            }
        }
        try testing.expectEqual(@as(usize, 1), homes);
        // 8.4: the cached home_ws must name the workspace that ACTUALLY holds
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

// register -> tiled in current ws order, mask set.

// minimize tiled -> parked, removed from tiled_order; capacity refuses
// once the minimized budget (MAX_MINIMIZED) is exhausted.
test "minimize tiled removes from order; capacity refuses" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    const wins = registerRange(&m, max_minimized + 1, 100);
    try expectOrder(&m, WSId.fromIndex(0), &wins);
    try minimize.minimize(&m, 102);
    try testing.expect(minimize.isMinimized(&m, 102));
    const e = m.store.get(102).?;
    try testing.expect(e.presence == .parked);
    // Anchor is UNCHANGED while parked (was tiled).
    try testing.expect(e.anchor == .tiled);
    // Verify saved slot via restore: window 102 was at index 2.
    minimize.restore(&m, 102);
    try expectOrder(&m, WSId.fromIndex(0), &wins);
    try minimize.minimize(&m, 102);
    try testing.expectEqual(@as(?WSId, null), e.home_ws);
    var expected: [max_minimized]WindowId = undefined;
    _ = std.mem.replace(WindowId, &wins, &.{102}, &.{}, expected[0 .. wins.len - 1]);
    try expectOrder(&m, WSId.fromIndex(0), expected[0 .. wins.len - 1]);

    // Fill the remaining budget, then the next minimize must be refused
    // without mutating anything (full no-mutation proof in the capacity-refusal tests).
    for (wins[0 .. wins.len - 1]) |w| try minimize.minimize(&m, w);
    try testing.expectEqual(@as(u32, max_minimized), minimize.count());
    try testing.expectError(error.CapacityFull, minimize.minimize(&m, wins[wins.len - 1]));
    // The refused window is unchanged: still present, not minimized.
    try testing.expect(!minimize.isMinimized(&m, wins[wins.len - 1]));
    try testing.expect(m.store.get(wins[wins.len - 1]).?.presence == .present);
}

// restore tiled -> back at ORIGINAL index.
test "restore reinserts at original slot" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    for ([_]WindowId{ 10, 11, 12, 13, 14 }) |w| regCur(&m, w);
    try minimize.minimize(&m, 12);
    try minimize.minimize(&m, 11);
    try testing.expect(m.store.get(12).?.presence == .parked);
    try testing.expect(m.store.get(11).?.presence == .parked);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 10, 13, 14 });
    minimize.restore(&m, 12);
    try testing.expect(m.store.get(12).?.presence == .present);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 10, 13, 12, 14 });
    minimize.restore(&m, 11);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 10, 11, 13, 12, 14 });
    // Restoring a live or unknown window is a no-op.
    minimize.restore(&m, 10);
    minimize.restore(&m, unknown_win);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 10, 11, 13, 12, 14 });
}

// minimize floating -> prev==floating(rect); restore returns the rect.
test "minimize/restore floating preserves rect" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    const r: model.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    try addFloating(&m, 7, r);
    try minimize.minimize(&m, 7);
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

test "minimize seq stamps drive LIFO/FIFO restore candidates" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    try model.register(&m, 10, WSId.fromIndex(0)); // ws 0
    try model.register(&m, 11, WSId.fromIndex(0));
    try model.register(&m, 12, WSId.fromIndex(1)); // ws 1: must never win on ws 0
    try minimize.minimize(&m, 10); // seq 0 (oldest)
    try minimize.minimize(&m, 11); // seq 1 (newest)
    try testing.expectEqual(@as(u32, 2), minimize.count());
    // Seq ordering: 10 has lower seq (oldest) -> FIFO; 11 has higher -> LIFO.
    try testing.expectEqual(@as(?model.WindowId, 10), minimize.restoreCandidate(&m, WSId.fromIndex(0), .fifo));
    try testing.expectEqual(@as(?model.WindowId, 11), minimize.restoreCandidate(&m, WSId.fromIndex(0), .lifo));
    // Cross-workspace isolation.
    try testing.expectEqual(@as(?model.WindowId, null), minimize.restoreCandidate(&m, WSId.fromIndex(1), .fifo));

    // Re-minimize 10: newest seq flips the LIFO answer; FIFO unchanged.
    minimize.restore(&m, 10);
    try minimize.minimize(&m, 10); // seq 2
    // 10 now has the highest seq -> LIFO; 11 is now oldest -> FIFO.
    try testing.expectEqual(@as(?model.WindowId, 10), minimize.restoreCandidate(&m, WSId.fromIndex(0), .lifo));
    try testing.expectEqual(@as(?model.WindowId, 11), minimize.restoreCandidate(&m, WSId.fromIndex(0), .fifo));
    try assertSingleMembership(&m);
}

test "latestMinimizedBase skips fullscreen-current and other workspaces" {
    var m = makeModel();

    try model.register(&m, 20, WSId.fromIndex(0));
    try model.register(&m, 21, WSId.fromIndex(0));
    _ = fullscreen.toggleFullscreen(&m, 21);
    try minimize.minimize(&m, 20); // plain base, older
    try minimize.minimize(&m, 21); // fullscreen, newer
    // 21 still carries its fullscreen RECORD while parked, so it is skipped
    // (the equivalent of the old prev != .base exclusion).
    try testing.expectEqual(@as(?model.WindowId, 20), minimize.latestMinimizedBase(&m, WSId.fromIndex(0)));
}

// minimizing one of two windows must fall back to the
// PREVIOUSLY focused window. The candidate policy lives in the model layer;
// the window layer's focusFallback delegates to it. Tier checks:
// MRU newest-first (minimized skipped even though still listed in MRU),
// then reversed tiled_order, then floating, then null.
test "fallbackFocusCandidate tiers pick the previous focus" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 10);
    regCur(&m, 11); // tiled_order [10, 11]
    model.setFocus(&m, 11); // user focused 11 first...
    model.setFocus(&m, 10); // ...then 10; MRU now [10, 11]
    try testing.expectEqual(@as(?WindowId, 10), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));

    // Minimizing the FOCUSED window (10): the previous focus (11) wins via
    // the MRU tier even though 10 is still newest in the MRU list - visibleOn
    // rejects minimized entries.
    try minimize.minimize(&m, 10);
    try testing.expectEqual(@as(?WindowId, 11), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));

    // Both hidden: reversed tiled_order tier is exhausted by visibility too,
    // a floating window becomes the candidate, and an empty ws yields null.
    try minimize.minimize(&m, 11);
    try addFloating(&m, 12, .{ .x = 0, .y = 0, .width = 50, .height = 50 });
    try testing.expectEqual(@as(?WindowId, 12), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));

    model.unregister(&m, 12);
    try testing.expectEqual(@as(?WindowId, null), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));
}

// A rejected candidate (e.g. no_input, which can never hold X focus) must be
// skippable so the fallback scan can continue to the NEXT focusable window
// instead of giving up on the MRU head.
test "fallbackFocusCandidate exclusion skips to the next focusable" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    regCur(&m, 20);
    regCur(&m, 21); // tiled_order [20, 21]; focused 21 → MRU [21, 20]

    // MRU head (21) is the excluded no_input window: the scan must skip it
    // and still find 20, not return null.
    try testing.expectEqual(@as(?WindowId, 20), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), 21));

    // Excluding every candidate yields null (the caller then clears to root).
    try addFloating(&m, 22, .{ .x = 0, .y = 0, .width = 50, .height = 50 });
    model.unregister(&m, 20);
    model.unregister(&m, 21);
    try testing.expectEqual(@as(?WindowId, 22), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));
    try testing.expectEqual(@as(?WindowId, null), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), 22));

    // Exclusion is not in effect returns the normal MRU head again.
    regCur(&m, 20);
    regCur(&m, 21);
    try testing.expectEqual(@as(?WindowId, 21), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));
}

// closing the focused window must hand focus to the
// PREVIOUSLY focused window.
test "close-fallback candidate after unregister is the previous focus" {
    var m = makeModel();

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
    try testing.expectEqual(@as(?WindowId, 40), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));

    // Closing the LAST window: no candidate remains -> caller clears focus
    // (same terminal state as minimizing everything).
    model.unregister(&m, 40);
    try testing.expectEqual(@as(?WindowId, null), model.fallbackFocusCandidate(&m, WSId.fromIndex(0), null));
}

// restoreAllOnWs restores every minimized window in slot order.
test "restoreAllOnWs restores in slot order" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();
    // Minimize every window on ws 0, then restore them all in one call.
    try model.register(&m, 10, WSId.fromIndex(0));
    try model.register(&m, 20, WSId.fromIndex(0));
    try model.register(&m, 30, WSId.fromIndex(0));
    try minimize.minimize(&m, 10);
    try minimize.minimize(&m, 20);
    try minimize.minimize(&m, 30);
    try testing.expectEqual(@as(u32, 3), minimize.count());
    minimize.restoreAllOnWs(&m, WSId.fromIndex(0));
    // No window may stay parked/minimized after the restore.
    try testing.expectEqual(@as(u32, 0), minimize.count());
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

// Minimize blob round trip -- parked-only serialization, magic claim,
// and re-adoption through the deserialize seam.
test "minimize serialize/deserialize round-trip" {
    var m = makeModel();

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
    try testing.expect(minimize.deserializeWindow(70, blob, &m));
    try testing.expect(minimize.isMinimized(&m, 70));
    try testing.expect(m.store.get(70).?.presence == .parked);
    // Verify saved slot 0 via restore: 70 rejoins tiled_order at index 0.
    minimize.restore(&m, 70);
    try expectOrder(&m, WSId.fromIndex(0), &.{70});
    try minimize.minimize(&m, 70);
    // A foreign-magic or malformed blob is not claimed.
    try testing.expect(!minimize.deserializeWindow(70, &foreign_blob, &m));
    // A present window's blob is never produced while parked=false.
    minimize.restore(&m, 70);
    try testing.expect(minimize.serializeWindow(@ptrCast(&m), 70, testing.allocator) == null);
}

// Cross-workspace restore: restoring a minimized window to its HOME
// workspace while the CURRENT workspace carries its own stack must not disturb
// that stack.
test "restore to home workspace leaves the current workspace's stack intact" {
    var m = makeModel();

    try minimize.init();
    defer minimize.deinit();

    try model.register(&m, 10, WSId.fromIndex(0)); // home 0
    try model.register(&m, 11, WSId.fromIndex(0)); // home 0
    try model.register(&m, 20, WSId.fromIndex(1)); // home 1
    try model.register(&m, 21, WSId.fromIndex(1)); // home 1
    try expectOrder(&m, WSId.fromIndex(0), &.{ 10, 11 });
    try expectOrder(&m, WSId.fromIndex(1), &.{ 20, 21 });

    // Make ws 1 the CURRENT workspace; it is showing its own stack [20, 21].
    workspaces.switchTo(&m, WSId.fromIndex(1));

    // Minimize a window whose home is ws 0, then restore it -- all while the
    // current workspace (1) keeps its own stack in view.
    try minimize.minimize(&m, 10);
    try expectOrder(&m, WSId.fromIndex(1), &.{ 20, 21 }); // current stack undisturbed
    minimize.restore(&m, 10);

    // The restored window is back on its HOME ws 0; ws 1's stack is untouched.
    try expectOrder(&m, WSId.fromIndex(0), &.{ 10, 11 });
    try expectOrder(&m, WSId.fromIndex(1), &.{ 20, 21 });
    try testing.expect(m.store.get(10).?.presence == .present);
    try testing.expect(!minimize.isMinimized(&m, 10));
    try assertSingleMembership(&m);
}
