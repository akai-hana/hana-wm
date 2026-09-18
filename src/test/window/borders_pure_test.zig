//! Headless tests for borders.zig's PURE decision logic: the covering-occupant
//! borderless rule and the focused/unfocused pixel pick. The X-touching
//! send/apply half stays in the X-gated borders_test; these functions take
//! their state as parameters so they run without a server.

const std = @import("std");
const model = @import("model");
const borders = @import("borders");
const helpers = @import("helpers");

const ws0 = model.WSId.fromIndex(0);
const ws1 = model.WSId.fromIndex(1);

/// Registers `win` tiled on `ws` in a fresh model and returns the model.
fn modelWithTiled(on_ws: model.WSId) model.Model {
    var m = helpers.makeModel();
    model.register(&m, 10, on_ws) catch unreachable;
    return m;
}

/// Marks `occupant` as the covering occupant of `ws` (a pure model-store
/// transition; no feature module needed for the pure rule).
fn setCovering(m: *model.Model, occupant: model.WindowId, ws: model.WSId) void {
    const e = m.store.getPtr(occupant).?;
    e.presence = .covering;
    e.covering_ws = ws;
}

/// Detaches `win` from every tiled slot so findHome returns null (the
/// "stray" shape: no home_ws cache, no tiled_order membership).
fn detach(m: *model.Model, win: model.WindowId) void {
    const e = m.store.getPtr(win).?;
    e.home_ws = null;
    for (0..m.ws.len) |i| {
        model.removeValue(&m.ws[i].tiled_order, win);
    }
}

test "borderColorOf picks focused vs unfocused pixel" {
    try std.testing.expectEqual(@as(u32, 0x11223344), borders.borderColorOf(true, 0x11223344, 0x55667788));
    try std.testing.expectEqual(@as(u32, 0x55667788), borders.borderColorOf(false, 0x11223344, 0x55667788));
}

test "member of a workspace without a covering occupant keeps its color" {
    var m = modelWithTiled(ws0);
    try std.testing.expect(!borders.coveredByOccupant(&m, 10, false, ws0, true));
}

test "member of a workspace with a covering occupant renders borderless" {
    var m = modelWithTiled(ws1);
    model.register(&m, 20, ws1) catch unreachable;
    setCovering(&m, 20, ws1);
    try std.testing.expect(borders.coveredByOccupant(&m, 10, false, ws0, true));
}

test "covering-mode member follows its capture anchor over blended tags" {
    var m = modelWithTiled(ws1);
    model.register(&m, 20, ws0) catch unreachable;
    // 20 is tagged on ws0 but covering-anchors to ws1: the rule must follow
    // the covering anchor, not the tagged home.
    setCovering(&m, 20, ws1);
    try std.testing.expect(borders.coveredByOccupant(&m, 10, true, ws0, true));
}

test "member of a workspace with only a foreign-anchored occupant keeps its color" {
    var m = modelWithTiled(ws0);
    model.register(&m, 20, ws1) catch unreachable;
    setCovering(&m, 20, ws1);
    // 10 lives on ws0; the occupant is anchored to ws1, so nothing covers ws0.
    try std.testing.expect(!borders.coveredByOccupant(&m, 10, false, ws0, true));
}

test "window with no resolvable workspace falls back to the current ws occupant" {
    var m = modelWithTiled(ws0);
    _ = m.store.put(30, .{ .mask = 0, .anchor = .tiled }) catch null;
    detach(&m, 30);
    try std.testing.expectEqual(null, model.findHome(&m, 30));
    model.register(&m, 40, ws0) catch unreachable;
    setCovering(&m, 40, ws0);
    // No home: the current-ws fallback sees the occupant and goes borderless.
    try std.testing.expect(borders.coveredByOccupant(&m, 30, false, ws0, true));
    // Without any occupant on the current ws, the fallback keeps the color.
    model.unregister(&m, 40);
    try std.testing.expect(!borders.coveredByOccupant(&m, 30, false, ws0, true));
}

test "fullscreen-absent build ignores the entity's own covering anchor" {
    var m = modelWithTiled(ws0);
    model.register(&m, 20, ws1) catch unreachable;
    setCovering(&m, 20, ws1);
    // 10 lives on ws0; the occupant anchors ws1. has_fullscreen=false disables
    // the member's own covering-anchor branch, so home (ws0) wins and no
    // occupant sits on ws0. (With the anchor enabled -- the mirror shape of the
    // covering-mode test above -- the same setup resolves to borderless.)
    try std.testing.expect(!borders.coveredByOccupant(&m, 10, true, ws0, false));
}
