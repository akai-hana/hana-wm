//! Border policy tests (resolution half, X-gated).
//!
//! `borders.color()`/`width()` are the pure public reads: color resolves the
//! covering-mode policy + config colors against live MODEL focus, width
//! resolves the tiling border width against the screen height. Both run over
//! the shared window fixture (real core/pipeline/model state), self-skipping
//! when no X display is reachable. The X-issuing half (`apply/applyWidth`,
//! border cache) requires a live connection and is covered by the integration
//! layer instead.

const std = @import("std");
const testing = std.testing;

const pipeline = @import("pipeline");
const borders = @import("borders");
const fixture = @import("fixture");
const model = @import("model");
const parser = @import("parser");
const utils = @import("utils");

test "borders.width resolves absolute and percentage border widths" {
    const fx = fixture.setUp("borders.width") orelse return;
    defer fx.deinit();

    // Default config: absolute 2px, percentage disabled.
    try testing.expectEqual(@as(u16, 2), borders.width());

    // A percentage is half the reference dimension (a border insets two
    // sides). Derive the expectation from the LIVE screen height so any
    // display geometry passes.
    fx.config.tiling.border_width = parser.ScalableValue.percentage(2.0);
    const expected = utils.scaling.scaleBorderWidth(
        parser.ScalableValue.percentage(2.0),
        fx.scr.*.height_in_pixels,
    );
    try testing.expectEqual(expected, borders.width());

    // Absolute mode ignores the reference dimension entirely.
    fx.config.tiling.border_width = parser.ScalableValue.absolute(7.0);
    try testing.expectEqual(@as(u16, 7), borders.width());
}

test "borders.color resolves focused vs unfocused config colors" {
    const fx = fixture.setUp("borders.color") orelse return;
    defer fx.deinit();
    fx.config.tiling.border_focused = 0x111111;
    fx.config.tiling.border_unfocused = 0x222222;

    var gate: pipeline.Gate = .{};
    const m = pipeline.mut(&gate);
    model.register(m, 1, model.WSId.fromIndex(0)) catch unreachable;
    model.register(m, 2, model.WSId.fromIndex(0)) catch unreachable;

    // Nothing focused yet: both windows take the unfocused color.
    try testing.expectEqual(@as(u32, 0x222222), borders.color(1));
    try testing.expectEqual(@as(u32, 0x222222), borders.color(2));

    // Focus moves: the focused window flips color, the other stays unfocused.
    model.setFocus(m, 1);
    try testing.expectEqual(@as(u32, 0x111111), borders.color(1));
    try testing.expectEqual(@as(u32, 0x222222), borders.color(2));

    model.setFocus(m, 2);
    try testing.expectEqual(@as(u32, 0x222222), borders.color(1));
    try testing.expectEqual(@as(u32, 0x111111), borders.color(2));
}

test "borders.color is 0 for a screen-covering window" {
    const fx = fixture.setUp("borders.covering") orelse return;
    defer fx.deinit();
    fx.config.tiling.border_focused = 0x111111;
    fx.config.tiling.border_unfocused = 0x222222;

    var gate: pipeline.Gate = .{};
    const m = pipeline.mut(&gate);
    model.register(m, 1, model.WSId.fromIndex(0)) catch unreachable;
    // A covering capture makes the window borderless via the bw=0/pixel=0
    // policy, mirrored here for callers outside reconcile (fullscreen).
    m.store.getPtr(1).?.covering_ws = model.WSId.fromIndex(0);

    try testing.expectEqual(@as(u32, 0), borders.color(1));
}
