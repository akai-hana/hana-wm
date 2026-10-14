//! Headless tests for borders.zig's PURE decision logic: the covering-occupant
//! borderless rule and the focused/unfocused pixel pick. The X-touching
//! send/apply half stays in the X-gated borders_test; these functions take
//! their state as parameters so they run without a server.

const std = @import("std");
const model = @import("model");
const constants = @import("constants");
const borders = @import("borders");
const helpers = @import("helpers");

const ws0 = model.WSId.fromIndex(0);
const ws1 = model.WSId.fromIndex(1);

/// The rule as production evaluates it: build the per-workspace occupant
/// table (one store pass), then ask the With-form against it.
fn behind(m: *const model.Model, win: u32, current: model.WSId, comptime has_fullscreen: bool) bool {
    var occupants: [constants.max_workspaces]?model.WindowId = @splat(null);
    model.coveringOccupants(m, &occupants);
    return borders.isBehindCoveringWindowWith(m, win, current, has_fullscreen, &occupants);
}

/// Registers `win` tiled on `ws` in a fresh model and returns the model.
fn modelWithTiled(on_ws: model.WSId) !model.Model {
    var m = helpers.makeModel();
    try model.register(&m, 10, on_ws);
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

test "member of a workspace without a covering occupant keeps its color" {
    var m = try modelWithTiled(ws0);
    try std.testing.expect(!behind(&m, 10, ws0, true));
}

test "member of a workspace with a covering occupant renders borderless" {
    var m = try modelWithTiled(ws1);
    try model.register(&m, 20, ws1);
    setCovering(&m, 20, ws1);
    try std.testing.expect(behind(&m, 10, ws0, true));
}

test "member is covered by an occupant anchored to its home over blended tags" {
    var m = try modelWithTiled(ws1);
    try model.register(&m, 20, ws0);
    // 20 is tagged on ws0 but covering-anchors to ws1 (a blended window):
    // the rule resolves WIN's home (ws1, where 10 lives) and sees the
    // anchored occupant there, going borderless -- it does not chase the
    // occupant's tag-mask home.
    setCovering(&m, 20, ws1);
    try std.testing.expect(behind(&m, 10, ws0, true));
}

test "member of a workspace with only a foreign-anchored occupant keeps its color" {
    var m = try modelWithTiled(ws0);
    try model.register(&m, 20, ws1);
    setCovering(&m, 20, ws1);
    // 10 lives on ws0; the occupant is anchored to ws1, so nothing covers ws0.
    try std.testing.expect(!behind(&m, 10, ws0, true));
}

test "an occupant anchored elsewhere still covers workspaces its mask shows" {
    var m = try modelWithTiled(ws0);
    try model.register(&m, 20, ws1);
    setCovering(&m, 20, ws1);
    // tagAdd's whole effect is the mask: 20 stays anchored to ws1 but becomes
    // visible on ws0 too. The table must flag both workspaces — the scan
    // form's (anchored or visible) rule — not just the anchor slot.
    m.store.getPtr(20).?.mask |= model.bit(ws0);
    var occupants: [constants.max_workspaces]?model.WindowId = @splat(null);
    model.coveringOccupants(&m, &occupants);
    try std.testing.expectEqual(@as(?model.WindowId, 20), occupants[ws0.index]);
    try std.testing.expectEqual(@as(?model.WindowId, 20), occupants[ws1.index]);
    try std.testing.expect(behind(&m, 10, ws0, true));
}

test "window with no resolvable workspace falls back to the current workspace occupant" {
    var m = try modelWithTiled(ws0);
    _ = m.store.put(30, .{ .mask = 0, .anchor = .tiled }) catch null;
    detach(&m, 30);
    try std.testing.expectEqual(null, model.findHome(&m, 30));
    try model.register(&m, 40, ws0);
    setCovering(&m, 40, ws0);
    // No home: the current-workspace fallback sees the occupant and goes borderless.
    try std.testing.expect(behind(&m, 30, ws0, true));
    // Without any occupant on the current workspace, the fallback keeps the color.
    model.unregister(&m, 40);
    try std.testing.expect(!behind(&m, 30, ws0, true));
}

test "fullscreen-absent build never resolves the current-workspace fallback" {
    var m = try modelWithTiled(ws0);
    _ = m.store.put(30, .{ .mask = 0, .anchor = .tiled }) catch null;
    detach(&m, 30);
    try std.testing.expectEqual(null, model.findHome(&m, 30));
    try model.register(&m, 40, ws0);
    setCovering(&m, 40, ws0);
    // No home, but has_fullscreen=false gates the whole covering resolution
    // off: the window keeps its color despite the current-workspace occupant.
    try std.testing.expect(!behind(&m, 30, ws0, false));
}

// The pure cores of the two live reads borders_test covers. The item asked
// for the borders_test assertions to move here headless; taken literally that
// is impossible, because `core.borderWidth()` and
// `borders.resolveBorderColorWith()` both read `core.getState()` --
// process-global live state that does not exist without a server. What IS
// movable, and was genuinely uncovered, is the pure decision each one
// delegates to: borders_test used `scaling.scaleBorderWidth` as its ORACLE
// while never testing it, so a regression in the scaling rule would have
// quietly changed both sides of its own assertion at the same time.

test "scaleBorderWidth: absolute passes through, percentage is half the reference" {
    const scaling = @import("scaling");
    const types = @import("types");

    // Absolute ignores the reference dimension entirely -- a border is a
    // border, not a fraction of the screen.
    try std.testing.expectEqual(@as(u16, 7), scaling.scaleBorderWidth(types.ScalableValue.absolute(7.0), 600));
    try std.testing.expectEqual(@as(u16, 7), scaling.scaleBorderWidth(types.ScalableValue.absolute(7.0), 4000));

    // Percentage: a border insets two sides, so 2% of the height is 0.5x.
    try std.testing.expectEqual(@as(u16, 6), scaling.scaleBorderWidth(types.ScalableValue.percentage(2.0), 600));
    // Scales with the reference, unlike the absolute case.
    try std.testing.expectEqual(@as(u16, 40), scaling.scaleBorderWidth(types.ScalableValue.percentage(2.0), 4000));
}

test "scaleBorderWidth: rounds half away from zero and clamps negatives" {
    const scaling = @import("scaling");
    const types = @import("types");

    // 3% of 150 = 2.25 -> 2, 3% of 350 = 5.25 -> 5. A truncating
    // implementation would agree on both, so use one that straddles .5:
    // 3% of 50 = 0.75 -> 1, and 1% of 50 = 0.25 -> 0.
    try std.testing.expectEqual(@as(u16, 1), scaling.scaleBorderWidth(types.ScalableValue.percentage(3.0), 50));
    try std.testing.expectEqual(@as(u16, 0), scaling.scaleBorderWidth(types.ScalableValue.percentage(1.0), 50));
    // A negative config value clamps to 0 rather than wrapping to 65535.
    try std.testing.expectEqual(@as(u16, 0), scaling.scaleBorderWidth(types.ScalableValue.absolute(-4.0), 600));
}

test "focusedBorderColor reads the MODEL's focus, not a second copy" {
    // The single decision behind resolveBorderColorWith. Testing it headless
    // is what lets borders_test keep being a thin integration check instead of
    // the only place the color policy is exercised.
    var m = helpers.makeModel();
    try model.register(&m, 1, ws0);
    try model.register(&m, 2, ws0);

    // Nothing focused: the comparison is against m.focused, which is unset.
    try std.testing.expectEqual(@as(u32, 0x222222), model.focusedBorderColor(&m, 1, 0x111111, 0x222222));

    model.setFocus(&m, 1);
    try std.testing.expectEqual(@as(u32, 0x111111), model.focusedBorderColor(&m, 1, 0x111111, 0x222222));
    try std.testing.expectEqual(@as(u32, 0x222222), model.focusedBorderColor(&m, 2, 0x111111, 0x222222));

    model.setFocus(&m, 2);
    try std.testing.expectEqual(@as(u32, 0x222222), model.focusedBorderColor(&m, 1, 0x111111, 0x222222));
    try std.testing.expectEqual(@as(u32, 0x111111), model.focusedBorderColor(&m, 2, 0x111111, 0x222222));
}
