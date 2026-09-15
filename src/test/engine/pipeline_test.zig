//! X-gated integration tests for the reconcile pipeline
//! (src/core/sync + src/core/pipeline). Runs the real engine -> Ctx -> sink
//! chain against a live X server and asserts the server state matches the
//! logged placements, plus the covering (fullscreen) winner/park branches.
//! Self-skips without a server so `zig build test` stays green headless.

const std = @import("std");

const core = @import("core");
const model = @import("model");
const pipeline = @import("pipeline");
const sync = @import("sync");
const actions = @import("actions");
const fixture = @import("fixture");

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
    var fx = fixture.setUp("pipeline_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const w1, const w2 = seedTwo(fx);

    try std.testing.expectEqual(w2, m.focused.?);
    const order = m.ws[m.current].tiled_order.items;
    try std.testing.expectEqual(w1, order[0]);
    try std.testing.expectEqual(w2, order[1]);

    // Both windows land exactly on their engine placements.
    try fx.expectTiledGeometry(w1);
    try fx.expectTiledGeometry(w2);

    // The sent ledger matches the actual server geometry.
    const lr = sync.lastRectFor(w1) orelse return error.NoLedgerEntry;
    const g1 = fx.geometry(w1) orelse return error.ClosedWindow;
    try std.testing.expectEqual(lr.width, g1.width);
    try std.testing.expectEqual(lr.height, g1.height);
    try std.testing.expectEqual(lr.x, @as(i32, g1.x));
    try std.testing.expectEqual(lr.y, @as(i32, g1.y));
}

test "pipeline: fullscreen winner covers the screen and parks siblings" {
    var fx = fixture.setUp("pipeline_test") orelse return;
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
    var fx = fixture.setUp("pipeline_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const w1, const w2 = seedTwo(fx);

    actions.fullscreenToggleWindow(w1);
    fx.flush();
    try std.testing.expectEqual(w1, (model.coveringOccupantOnWs(m, m.current) orelse return error.NoOccupant));

    // Direct covering hand-off: claiming a second window while occupied.
    actions.fullscreenToggleWindow(w2);
    fx.flush();
    try std.testing.expectEqual(w2, (model.coveringOccupantOnWs(m, m.current) orelse return error.NoOccupant));
    try fx.expectParked(w1);

    // Exit: both windows return to their tiled placements.
    actions.fullscreenToggleWindow(w2);
    fx.flush();
    try std.testing.expect(model.coveringOccupantOnWs(m, m.current) == null);
    try fx.expectTiledGeometry(w1);
    try fx.expectTiledGeometry(w2);
}
