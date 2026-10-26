//! Unit tests for the fullscreen module's model-facing surface: the
//! covering-occupant state machine asserted through the model it
//! mutates (toggle round-trips, minimize-from-fullscreen restore,
//! covering_ws intent, occupant scans, parked-ghost exclusion) and
//! the module's own PendingBarTable (the deferred-bar intents).

// build-gate: fullscreen, minimize, workspaces
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
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};

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
const expectOrder = helpers.expectOrder;
const addFloating = helpers.addFloating;

/// Single-membership invariant (see `model.checkInvariants`): every tiled,
/// present window sits in EXACTLY ONE workspace list, and every listed id exists.
fn assertSingleMembership(m: *const Model) !void {
    try model.checkInvariants(m);
}

// toggleFullscreen round trips; minimize-from-fullscreen keeps its
// record (parked) and restore returns straight back to fullscreen.
test "fullscreen toggling and minimize-from-fullscreen" {
    var m = makeModel();

    // Tiled round trip.
    regCur(&m, 1);
    try testing.expect(fullscreen.toggleFullscreen(&m, 1));
    var e = m.store.get(1).?;
    try testing.expect(e.presence == .covering);
    try testing.expectEqual(WSId.fromIndex(0), model.coveringWsOf(&m, 1).?);
    try testing.expect(e.anchor == .tiled); // anchor retained
    try testing.expect(fullscreen.toggleFullscreen(&m, 1));
    e = m.store.get(1).?;
    try testing.expect(e.presence == .present);
    try testing.expect(e.anchor == .tiled);
    try testing.expect(!model.isCovering(&m, 1));

    // Floating base survives minimize-from-fullscreen.
    const r: model.Rect = .{ .x = 5, .y = 6, .width = 640, .height = 480 };
    try addFloating(&m, 2, r);
    _ = fullscreen.toggleFullscreen(&m, 2);
    try minimize.minimize(&m, 2);
    try testing.expect(minimize.isMinimized(&m, 2));
    e = m.store.get(2).?;
    try testing.expect(e.presence == .parked);
    // Anchor is UNCHANGED while parked (still floating; fs rec is a ghost).
    try testing.expect(e.anchor == .floating);
    try testing.expect(r.eql(e.anchor.floating));
    // Ghost fullscreen record STILL reports the workspace while parked.
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.coveringWsOf(&m, 2));
    minimize.restore(&m, 2);
    e = m.store.get(2).?;
    // Restoring a fullscreen-carrying window returns it to covering (the
    // model is the single authority; the window re-claims the screen).
    try testing.expect(e.presence == .covering);
    try testing.expect(!minimize.isMinimized(&m, 2));
    try testing.expect(model.isCovering(&m, 2));
    try testing.expect(r.eql(e.anchor.floating));
}

// fullscreen -> minimize -> restore -> un-fullscreen must not strand the
// window base-tiled but HOME-LESS.
test "fullscreen-prev restore re-adds slot; exit-fullscreen retiles" {
    var m = makeModel();

    regCur(&m, 1);
    regCur(&m, 2);
    _ = fullscreen.toggleFullscreen(&m, 1);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2 }); // fullscreen windows keep their slot
    try minimize.minimize(&m, 1);
    try testing.expect(minimize.isMinimized(&m, 1));
    try testing.expect(m.store.get(1).?.presence == .parked);
    try testing.expect(model.isCovering(&m, 1)); // record RETAINED
    try expectOrder(&m, WSId.fromIndex(0), &.{2}); // slot freed while hidden

    minimize.restore(&m, 1); // straight back into fullscreen ...
    const e = m.store.get(1).?;
    try testing.expect(e.presence == .covering);
    try testing.expect(model.isCovering(&m, 1));
    try testing.expectEqual(WSId.fromIndex(0), model.coveringWsOf(&m, 1).?);
    // ... AND the saved slot must be re-added (THE FIX under test).
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2 });
    try assertSingleMembership(&m);

    // The reported final step: leaving fullscreen must return a TILEABLE,
    // tiling-placed window - not a home-less stranded orphan.
    try testing.expect(fullscreen.toggleFullscreen(&m, 1));
    const back = m.store.get(1).?;
    try testing.expect(back.anchor == .tiled and back.presence == .present);
    try expectOrder(&m, WSId.fromIndex(0), &.{ 1, 2 });
    try assertSingleMembership(&m);
}

// minimizing-from-fullscreen KEEPS the mode, so the ghost record still
// reports the workspace while parked, but visibleOn is false. Callers must gate on
// visibility (coverage/occupancy query), not the raw mode.
test "fullscreenWsOf keeps the workspace while minimized-from-fullscreen" {
    var m = makeModel();

    regCur(&m, 30);
    regCur(&m, 31);
    try testing.expectEqual(@as(?WSId, null), model.coveringWsOf(&m, 30));
    try testing.expectEqual(@as(?WSId, null), model.coveringWsOf(&m, unknown_win)); // unknown

    _ = fullscreen.toggleFullscreen(&m, 30);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.coveringWsOf(&m, 30));
    try testing.expectEqual(@as(?WSId, null), model.coveringWsOf(&m, 31)); // not fullscreen

    // Minimize-from-fullscreen: the MODE is retained, but the parked window
    // is neither visible nor an occupant.
    try minimize.minimize(&m, 30);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.coveringWsOf(&m, 30));
    try testing.expect(m.store.get(30).?.presence == .parked);
    try testing.expect(!model.visibleOn(&m, 30, WSId.fromIndex(0)));
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
}

// FSQ: model fullscreen semantics: mode ignores visibility, on-workspace checks the
// RECORD's workspace only, and occupancy also requires visibility.
test "FSQ: model fullscreen queries (mode / on-workspace / visible occupant)" {
    var m = makeModel();

    regCur(&m, 50);
    try testing.expect(!model.isCovering(&m, 50));
    try testing.expect(!model.isCoveringOn(&m, 50, WSId.fromIndex(0)));
    try testing.expect(!model.isCovering(&m, unknown_win)); // unknown id
    try testing.expect(!model.isCoveringOn(&m, unknown_win, WSId.fromIndex(0))); // unknown id
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));

    _ = fullscreen.toggleFullscreen(&m, 50); // record targets current workspace (0)
    try testing.expect(model.isCovering(&m, 50));
    try testing.expect(model.isCoveringOn(&m, 50, WSId.fromIndex(0)));
    try testing.expect(!model.isCoveringOn(&m, 50, WSId.fromIndex(1))); // other-workspace record
    try testing.expectEqual(@as(?WindowId, 50), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));

    // A record for a workspace the window isn't tagged to is NOT an occupant:
    // occupancy requires visibility (sync parks such strays).
    try window_state_ops.register(&m, 51, WSId.fromIndex(1)); // tagged to ws1 only
    _ = fullscreen.toggleFullscreen(&m, 51); // record `ws` = current (0)
    try testing.expect(model.isCovering(&m, 51));
    try testing.expect(model.isCoveringOn(&m, 51, WSId.fromIndex(0)));
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.coveringWsOf(&m, 51));
    try testing.expectEqual(@as(?WindowId, 50), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));

    // Minimize-from-fullscreen: MODE retained, but parked => not an occupant.
    try minimize.minimize(&m, 50);
    try testing.expect(model.isCovering(&m, 50));
    try testing.expect(model.isCoveringOn(&m, 50, WSId.fromIndex(0)));
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.coveringWsOf(&m, 50));
    try testing.expect(!model.visibleOn(&m, 50, WSId.fromIndex(0)));
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
}

// The occupant scan claims the covering winner per workspace and excludes parked
// ghosts (minimized-from-fullscreen windows never claim the screen). A
// switch claim (new window covers while another owns the workspace) releases the
// previous occupant, so one workspace never has two live covering claims. The module
// hook delegates to the pure model scan; the two agree by construction.
test "occupant scan winner resolution and parked-ghost exclusion" {
    var m = makeModel();

    regCur(&m, 60);
    regCur(&m, 61);
    try testing.expectEqual(@as(?model.WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
    _ = fullscreen.toggleFullscreen(&m, 60); // covering on workspace 0
    try testing.expectEqual(@as(?model.WindowId, 60), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
    _ = fullscreen.toggleFullscreen(&m, 61); // switch: 61 releases 60's claim
    try testing.expectEqual(@as(?model.WindowId, 61), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
    try testing.expectEqual(@as(?model.WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(1), .anchored_and_visible));
    // Parked ghost: the covering intent survives but never claims the screen.
    try minimize.minimize(&m, 61);
    try testing.expectEqual(@as(?model.WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), model.coveringWsOf(&m, 61).?);
    minimize.restore(&m, 61);
    try testing.expectEqual(@as(?model.WindowId, 61), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
}

// toggleFullscreen drives the model's covering_ws core intent in lockstep
// with the covering presence: ON sets covering_ws, OFF clears it.
test "toggleFullscreen writes covering_ws core intent" {
    var m = makeModel();

    regCur(&m, 90);

    // Before entering fullscreen the core intent is absent.
    try testing.expectEqual(@as(?WSId, null), m.store.get(90).?.covering_ws);
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_or_visible));

    _ = fullscreen.toggleFullscreen(&m, 90); // on workspace 0
    var e = m.store.get(90).?;
    try testing.expect(e.presence == .covering);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), e.covering_ws);
    try testing.expectEqual(@as(?WindowId, 90), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_or_visible));

    // Exit clears the core intent.
    _ = fullscreen.toggleFullscreen(&m, 90);
    e = m.store.get(90).?;
    try testing.expect(e.presence == .present);
    try testing.expectEqual(@as(?WSId, null), e.covering_ws);
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_or_visible));
}

// The module occupant hook delegates to the model scan and agrees with it on
// the parked-ghost exclusion.
test "coveringOccupantOn excludes parked ghosts" {
    var m = makeModel();

    regCur(&m, 91);
    _ = fullscreen.toggleFullscreen(&m, 91);
    try testing.expectEqual(@as(?WindowId, 91), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_or_visible));
    try testing.expectEqual(@as(?WindowId, 91), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));

    // Minimize-from-fullscreen: covering_ws is KEPT (ghost) but presence is
    // parked, so neither the module hook nor the model helper reports an
    // occupant on workspace 0.
    try minimize.minimize(&m, 91);
    try testing.expect(m.store.get(91).?.presence == .parked);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(91).?.covering_ws);
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_or_visible));
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));

    // Restore re-surfaces the window: it re-enters covering (the model's
    // covering intent is the single authority for re-claiming the screen).
    minimize.restore(&m, 91);
    try testing.expect(m.store.get(91).?.presence == .covering);
    try testing.expect(model.isCovering(&m, 91));
    try testing.expectEqual(@as(?WindowId, 91), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_or_visible));
    try testing.expectEqual(@as(?WindowId, 91), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_and_visible));
}

// A move/tag retarget (workspaces path) keeps the model's covering_ws in
// lockstep with the retargeted module record.
test "move/tag retarget tracks covering_ws to the new workspace" {
    var m = makeModel();

    regCur(&m, 93); // home workspace 0
    _ = fullscreen.toggleFullscreen(&m, 93); // covering workspace 0
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(0)), m.store.get(93).?.covering_ws);

    // moveWindowToWs retargets the covering window to workspace 2 (destination free):
    // the module record AND the model's covering_ws must both follow.
    workspaces.moveWindowToWs(&m, 93, WSId.fromIndex(2));
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(2)), m.store.get(93).?.covering_ws);
    try testing.expectEqual(@as(?WSId, WSId.fromIndex(2)), model.coveringWsOf(&m, 93));
    try testing.expect(m.store.get(93).?.presence == .covering);
    try testing.expectEqual(@as(?WindowId, 93), model.coveringOccupantOn(&m, WSId.fromIndex(2), .anchored_or_visible));
    try testing.expectEqual(@as(?WindowId, null), model.coveringOccupantOn(&m, WSId.fromIndex(0), .anchored_or_visible));
}

test "Deferred bar pending is per-window, not a single slot" {
    if (!build_options.has_fullscreen) return error.SkipZigTest;
    const Table = fullscreen.PendingBarTable;
    const max = Table.max;

    // The bug this replaces: two windows arming a transition, the second
    // silently evicting the first, whose ConfigureNotify then found nothing
    // pending and never bumped -- a hide that never hides, silently.
    var t: Table = .{};
    t.arm(7, true);
    t.arm(9, false);
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqual(@as(?u32, 7), if (t.take(7)) |p| p.win else null);
    try testing.expectEqual(@as(?u32, 9), if (t.take(9)) |p| p.win else null);
    try testing.expectEqual(@as(usize, 0), t.len);

    // Arming the same window again is an UPSERT, not a second entry: the two
    // intents are mutually exclusive per window.
    t.arm(7, true);
    t.arm(7, false);
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(false, t.take(7).?.hide);

    // Taking an entry that is not there is a no-op, not a corruption: a
    // ConfigureNotify for an unrelated window must leave the table alone.
    t.arm(11, true);
    try testing.expectEqual(@as(?fullscreen.PendingBar, null), t.take(12));
    try testing.expectEqual(@as(usize, 1), t.len);
    try testing.expectEqual(@as(?u32, 11), if (t.take(11)) |p| p.win else null);

    // At the bound the table refuses to grow: the new arm takes the LAST slot,
    // whose previous holder (max-1) loses its transition. Every other window
    // still round-trips, and `len` never exceeds the ceiling. This is the
    // documented bound behaviour, distinct from the single-slot bug above --
    // that one dropped a transition on the SECOND arm.
    t.clear();
    for (0..max) |i| t.arm(@intCast(i), true);
    try testing.expectEqual(max, t.len);
    t.arm(999, false);
    try testing.expectEqual(max, t.len);
    for (0..max - 1) |i| {
        const got = t.take(@intCast(i));
        try testing.expectEqual(@as(u32, @intCast(i)), got.?.win);
        try testing.expectEqual(true, got.?.hide);
    }
    // The evicted holder is gone; the newcomer holds the last slot.
    try testing.expectEqual(@as(?fullscreen.PendingBar, null), t.take(max - 1));
    try testing.expectEqual(@as(u32, 999), t.take(999).?.win);
    try testing.expectEqual(@as(usize, 0), t.len);

    // clear() drops everything (resetState / deinit path).
    t.arm(1, true);
    t.arm(2, true);
    t.clear();
    try testing.expectEqual(@as(usize, 0), t.len);
    try testing.expectEqual(@as(?fullscreen.PendingBar, null), t.take(1));
}
