//! The bar's metric resolution rules (bar/metrics.zig).
//!
//! These rules used to be a module-level `var` in bar.zig that writing the
//! height and then overwriting the font size in two steps, reachable only
//! through process state, so there was nowhere to test them: exercising "20% of
//! the bar" needed a live config, a screen, and Pango. `resolve` is pure and
//! takes the font probe as a callback, so every branch below is now testable
//! headlessly -- including the ones a real screen would rarely produce.

const std = @import("std");

const dpi = @import("dpi");
const metrics = @import("metrics");
const types = @import("types");

const px = types.ScalableValue;
const policy = dpi.bar_height_policy;

/// A font that measures `PerPoint` (ascent+descent) px per point, so the probe
/// scales with the trial size the way a real font's does.
fn Probe(PerPoint: u32) type {
    return struct {
        fn p(trial_pt: u16) ?u32 {
            return @as(u32, trial_pt) * PerPoint;
        }
    };
}

fn probeLinear(comptime per_point: u32) metrics.Probe {
    return Probe(per_point).p;
}

/// A font that always fails to measure.
fn probeFails(_: u16) ?u32 {
    return null;
}

test "a configured height is final: the fonts cannot change it" {
    // 12pt font, 40px bar. The font is irrelevant to the height here.
    const m = metrics.resolve(.{
        .font_size = px.absolute(12),
        .height = px.absolute(40),
        .screen_height = 1080,
    }, probeFails);
    try std.testing.expectEqual(@as(u16, 40), m.height);
    try std.testing.expectEqual(@as(u16, 12), m.font_size);
}

test "with no configured height the fonts decide it" {
    // 10pt of a font measuring 2px per point => 20px of text. That is below
    // the policy floor, so the clamp is what decides -- and it is the policy
    // floor, not 0 and not the raw measurement.
    const m = metrics.resolve(.{
        .font_size = px.absolute(10),
        .screen_height = 1080,
    }, probeLinear(2));
    try std.testing.expectEqual(policy.min_px, m.height);

    // A big font lands inside the range untouched.
    const big = metrics.resolve(.{
        .font_size = px.absolute(10),
        .screen_height = 1080,
    }, probeLinear(15));
    try std.testing.expectEqual(@as(u16, 150), big.height);
}

test "an auto-sized height is still capped by the policy" {
    // A huge fallback font must not take the whole screen.
    const m = metrics.resolve(.{
        .font_size = px.absolute(10),
        .screen_height = 1080,
    }, probeLinear(100));
    try std.testing.expectEqual(policy.max_px, m.height);
}

test "an unmeasurable font falls back to the policy default, not to a crash" {
    const m = metrics.resolve(.{
        .font_size = px.absolute(10),
        .screen_height = 1080,
    }, probeFails);
    try std.testing.expectEqual(policy.default_px, m.height);
    // And the size is still the configured one: the bar draws, just at the
    // default height, with whatever font it can still load.
    try std.testing.expectEqual(@as(u16, 10), m.font_size);
}

test "a percentage font size refines against the bar height" {
    // 40px bar, font measuring 2px per point => 20pt is the largest size that
    // fills it exactly. 50% of that is 10pt.
    const m = metrics.resolve(.{
        .font_size = px.percentage(50),
        .height = px.absolute(40),
        .screen_height = 1080,
    }, probeLinear(2));
    try std.testing.expectEqual(@as(u16, 40), m.height);
    try std.testing.expectEqual(@as(u16, 10), m.font_size);
}

test "a percentage is a fraction of the largest size that FILLS the bar" {
    // 40px bar, 2px-per-point font: 20pt is exactly what fills it, and the
    // percentage is taken of THAT, not of the configured absolute size. This
    // is the rule the old bar-local helper implemented, now pinned.
    const full = metrics.resolve(.{
        .font_size = px.percentage(100),
        .height = px.absolute(40),
        .screen_height = 1080,
    }, probeLinear(2));
    try std.testing.expectEqual(@as(u16, 20), full.font_size);

    // Over 100% is the user asking for text taller than the bar, and the
    // resolver honours it (the config layer owns whether to warn, not this
    // one). Pinned because it is a real, reachable config -- not because it is
    // desirable: the bar clips, and a >100% font_size should be treated as a
    // config question.
    const over = metrics.resolve(.{
        .font_size = px.percentage(500),
        .height = px.absolute(40),
        .screen_height = 1080,
    }, probeLinear(2));
    try std.testing.expectEqual(@as(u16, 100), over.font_size);
}

test "a percentage font size with no configured height uses the DPI-scaled base" {
    // There is no height to be a percentage OF, so the percentage resolves
    // against the screen the way any other scalable value does. The height
    // then comes from measuring that size -- no second guessing of the size
    // the user asked for.
    const m = metrics.resolve(.{
        .font_size = px.percentage(1.5),
        .screen_height = 1080,
    }, probeLinear(1));
    // 1.5% of a 1080px baseline, measured at 1px per point, is a 2px strip --
    // and an auto-sized bar never shrinks below the policy floor.
    try std.testing.expectEqual(@as(u16, 2), m.font_size);
    try std.testing.expectEqual(policy.min_px, m.height);
}

test "a failed percentage probe keeps the DPI-scaled base rather than inventing one" {
    // The bar still has to render, so the fallback is the plain scaled size --
    // not zero, and not a size derived from no measurement at all.
    const m = metrics.resolve(.{
        .font_size = px.percentage(50),
        .height = px.absolute(40),
        .screen_height = 1080,
    }, probeFails);
    try std.testing.expectEqual(@as(u16, 40), m.height);
    try std.testing.expectEqual(
        dpi.scaleFontSizeForHeight(px.percentage(50), 1080),
        m.font_size,
    );
    try std.testing.expect(m.font_size > 0);
}

test "resolution is a function of its inputs alone" {
    // The old global made this impossible to state: the same config resolved
    // to different font sizes depending on what the previous bar had written.
    const in: metrics.Inputs = .{
        .font_size = px.percentage(50),
        .height = px.absolute(40),
        .screen_height = 1080,
    };
    const a = metrics.resolve(in, probeLinear(2));
    // Something else resolving in between must not move the answer.
    _ = metrics.resolve(.{
        .font_size = px.absolute(99),
        .height = px.absolute(4),
        .screen_height = 480,
    }, probeLinear(9));
    const b = metrics.resolve(in, probeLinear(2));
    try std.testing.expectEqual(a, b);
}
