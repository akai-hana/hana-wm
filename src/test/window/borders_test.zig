//! Border policy tests (resolution half, X-gated).
//!
//! `borders.resolveBorderColorWith()` and `core.borderWidth()` are the pure
//! public reads: color resolves the covering-mode policy + config colors
//! against live MODEL focus, width resolves the tiling border width against
//! the screen height. Both run over the shared window fixture (real model
//! state), self-skipping when no X display is reachable. The X-issuing half
//! (`applyWith/applyWidth`, the sent ledger) requires a live connection and is
//! covered by the integration layer instead.

const std = @import("std");
const testing = std.testing;

const core = @import("core");
const pipeline = @import("pipeline");
const borders = @import("borders");
const fixture = @import("fixture");
const model = @import("model");
const constants = @import("constants");
const types = @import("types");
const scaling = @import("scaling");

test "core.borderWidth resolves absolute and percentage border widths" {
    const fx = try fixture.setUp("borders.width");
    defer fx.deinit();

    // Config mutations this file makes must not leak into the process-global
    // core state: later X-gated tests read core.borderWidth() against a fresh
    // shared Fx reset, so restore it here.
    const saved_width = fx.config.tiling.border_width;
    defer fx.config.tiling.border_width = saved_width;

    // Default config: absolute 2px, percentage disabled.
    try testing.expectEqual(@as(u16, 2), core.borderWidth());

    // A percentage is half the reference dimension (a border insets two
    // sides). Derive the expectation from the LIVE screen height so any
    // display geometry passes -- that live-resolution binding is the part only
    // this file can test; the arithmetic is covered headlessly.
    fx.config.tiling.border_width = types.ScalableValue.percentage(2.0);
    const expected = scaling.scaleBorderWidth(
        types.ScalableValue.percentage(2.0),
        fx.scr.*.height_in_pixels,
    );
    try testing.expectEqual(expected, core.borderWidth());

    // Absolute mode ignores the reference dimension entirely.
    fx.config.tiling.border_width = types.ScalableValue.absolute(7.0);
    try testing.expectEqual(@as(u16, 7), core.borderWidth());
}

test "borders.resolveBorderColorWith resolves focused vs unfocused config colors" {
    const fx = try fixture.setUp("borders.color");
    defer fx.deinit();

    const saved_focused = fx.config.tiling.border_focused;
    const saved_unfocused = fx.config.tiling.border_unfocused;
    defer fx.config.tiling.border_focused = saved_focused;
    defer fx.config.tiling.border_unfocused = saved_unfocused;

    fx.config.tiling.border_focused = 0x111111;
    fx.config.tiling.border_unfocused = 0x222222;

    const m = pipeline.mut();
    try model.register(m, 1, model.WSId.fromIndex(0));
    try model.register(m, 2, model.WSId.fromIndex(0));

    // The occupant table is cover-state-only, so one build per test covers
    // every focus step below (focus reads stay live inside the With-form).
    var occupants: [constants.max_workspaces]?model.WindowId = @splat(null);
    model.coveringOccupants(m, &occupants);

    // Nothing focused yet: both windows take the unfocused color.
    try testing.expectEqual(@as(u32, 0x222222), borders.resolveBorderColorWith(1, &occupants));
    try testing.expectEqual(@as(u32, 0x222222), borders.resolveBorderColorWith(2, &occupants));

    // Focus moves: the focused window flips color, the other stays unfocused.
    model.setFocus(m, 1);
    try testing.expectEqual(@as(u32, 0x111111), borders.resolveBorderColorWith(1, &occupants));
    try testing.expectEqual(@as(u32, 0x222222), borders.resolveBorderColorWith(2, &occupants));

    model.setFocus(m, 2);
    try testing.expectEqual(@as(u32, 0x222222), borders.resolveBorderColorWith(1, &occupants));
    try testing.expectEqual(@as(u32, 0x111111), borders.resolveBorderColorWith(2, &occupants));
}

test "borders.resolveBorderColorWith is 0 for a screen-covering window" {
    const fx = try fixture.setUp("borders.covering");
    defer fx.deinit();

    const saved_focused = fx.config.tiling.border_focused;
    const saved_unfocused = fx.config.tiling.border_unfocused;
    defer fx.config.tiling.border_focused = saved_focused;
    defer fx.config.tiling.border_unfocused = saved_unfocused;

    fx.config.tiling.border_focused = 0x111111;
    fx.config.tiling.border_unfocused = 0x222222;

    const m = pipeline.mut();
    try model.register(m, 1, model.WSId.fromIndex(0));
    // A covering capture makes the window borderless via the bw=0/pixel=0
    // policy, mirrored here for callers outside reconcile (fullscreen).
    m.store.getPtr(1).?.covering_ws = model.WSId.fromIndex(0);

    var occupants: [constants.max_workspaces]?model.WindowId = @splat(null);
    model.coveringOccupants(m, &occupants);
    try testing.expectEqual(@as(u32, 0), borders.resolveBorderColorWith(1, &occupants));
}
