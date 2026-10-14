//! Unit tests for the floating module's model-facing seam: the
//! floating anchor's geometry (setFloatingRect) and the
//! floating-base fullscreen/minimize interaction, asserted through
//! the model they mutate. Extracted from model_test.zig; same
//! makeModel fixture as the parent file.

// build-gate: floating, fullscreen, minimize
const std = @import("std");
const testing = std.testing;

// Overflow tests (MRU/order/max budgets) deliberately trip BoundedList's
// warn-level overflow diagnostic; src/core/pure/log.zig silences all
// std.log diagnostics in test binaries, so this stays quiet on success.
const model = @import("model");
const helpers = @import("helpers");
const build_options = @import("build_options");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const floating = if (build_options.has_floating) @import("floating") else struct {};

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;

/// Sentinel id for "a window that was never registered": every negative-path
/// assertion (unknown/unregistered lookups) uses it instead of a literal.
const unknown_win: WindowId = 999;

/// Resetting fixture: a fresh model on deterministically re-armed module
/// stores (minimize/fullscreen), so tests pass in any order regardless of
/// what records an earlier test left behind.
const makeModel = helpers.makeModel; // (28.3) reset is now the default, not a separate entry point

const regCur = helpers.regCur;

/// Floating-anchor window, the shape most store.put fixtures use.
fn addFloating(m: *Model, win: WindowId, r: model.Rect) !void {
    _ = try m.store.put(win, .{
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .{ .floating = r },
    });
}

// Floating-base fullscreen round trip stays home-free.
test "floating-base fullscreen minimize/restore never joins a list" {
    var m = makeModel();

    regCur(&m, 5);
    const r: model.Rect = .{ .x = 3, .y = 4, .width = 100, .height = 80 };
    try addFloating(&m, 6, r);
    _ = fullscreen.toggleFullscreen(&m, 6);
    try minimize.minimize(&m, 6);
    try testing.expect(m.store.get(6).?.presence == .parked);
    minimize.restore(&m, 6);
    const e = m.store.get(6).?;
    try testing.expect(e.presence == .covering);
    try testing.expect(model.isCovering(&m, 6));
    try testing.expect(r.eql(e.anchor.floating));
    for (&m.ws) |*s| try testing.expect(s.tiled_order.indexOfScalar(6) == null);
}

// setFloatingRect updates floating geometry; no-ops for tiled/unknown.
test "setFloatingRect updates floating window geometry" {
    var m = makeModel();

    try fullscreen.init();
    defer fullscreen.deinit();
    const r: model.Rect = .{ .x = 10, .y = 20, .width = 300, .height = 200 };
    try addFloating(&m, 5, r);
    const new_r: model.Rect = .{ .x = 50, .y = 60, .width = 400, .height = 300 };
    floating.setFloatingRect(&m, 5, new_r);
    try testing.expect(new_r.eql(m.store.get(5).?.anchor.floating));
    // A tiled window is untouched by geometry updates.
    try model.register(&m, 6, WSId.fromIndex(0));
    floating.setFloatingRect(&m, 6, new_r);
    try testing.expect(m.store.get(6).?.anchor == .tiled);
    // An unknown window is ignored without crashing.
    floating.setFloatingRect(&m, unknown_win, new_r);
    // A covering (fullscreen) window is untouched by geometry updates.
    _ = fullscreen.toggleFullscreen(&m, 6);
    try testing.expect(m.store.get(6).?.presence == .covering);
    floating.setFloatingRect(&m, 6, new_r);
    try testing.expect(m.store.get(6).?.anchor == .tiled);
}
