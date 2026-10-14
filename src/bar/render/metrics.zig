//! The bar's derived metrics, as a VALUE.
//!
//! The effective font point size and the bar's pixel height are not user
//! input and not screen state: they are *derived* from (configured font size,
//! configured height, screen) and, in two of the four cases, from a font
//! measurement. They used to live in a module-level `var` written by
//! `bar.calcBarHeightAndFontSize` and read back out of the global by
//! `fonts.SizedFontList`, which made the bar's own font size reachable
//! only through mutable process state that a half-finished reload could leave
//! wrong -- and that a failed reload had to save and restore by hand.
//!
//! The whole resolution is one pure function here. Its only impure input is
//! the font probe, passed in as a callback, so the rules are unit-testable
//! without Pango, a screen, or a live config.
//!
//! The LIVE adapters -- reading the current config/screen and measuring the
//! fonts through Pango's throwaway surface -- sit at the bottom of this
//! file (they moved here from bar.zig, which used to own the "supply the
//! live pieces" section). They are the impure half; `resolve` above stays
//! exactly as testable as it was.

const std = @import("std");

const core = @import("core");
const fonts = @import("fonts");
const scale = @import("dpi");
const types = @import("types");

/// A trial point size for measuring the configured fonts. Arbitrary but
/// stable: only the ascent+descent TOTAL is used, as a px-per-point ratio, so
/// the absolute value cancels out. It must be comfortably large for the ratio
/// to survive rounding at small point sizes.
const probe_trial_pt: u16 = 100;

/// The bar's resolved metrics. A value: it is fully described by where it
/// came from, so nothing has to be repaired if the bar it belonged to dies.
pub const Metrics = struct {
    /// Effective point size for the bar's own text: the configured size
    /// DPI-scaled, then refined against the bar height when configured as a
    /// percentage.
    font_size: u16 = fonts.default_scaled_font_size,
    /// The bar's pixel height. Always resolved -- either the configured height
    /// scaled into the policy's range, or the fonts' own ascent+descent.
    height: u16 = 0,
};

/// Everything the resolution is derived from. Deliberately a plain value: no
/// `core.getState()`, so the rules cannot depend on state the caller did not
/// pass in.
pub const Inputs = struct {
    font_size: types.ScalableValue,
    /// `null` means "the fonts decide the height".
    height: ?types.ScalableValue = null,
    /// The only screen property either scaling rule reads.
    screen_height: u16,
};

/// Measures the configured fonts at `trial_pt`, returning ascent+descent, or
/// null when no font could be loaded or measured. The TOTAL is the only thing
/// either caller needs (a px-per-point ratio, or a bar height), so that is
/// all this exposes -- and it keeps the leaf free of any drawing type.
pub const Probe = *const fn (trial_pt: u16) ?u32;

/// Resolves the bar's metrics from (inputs, probe). Total, and in one place:
///
///  * a configured height is scaled into the policy range and is FINAL -- the
///    fonts cannot change a height the user asked for;
///  * a percentage font size is then refined against that height, because
///    "20% of the bar" is only meaningful once the bar's height is known;
///  * with no configured height, the fonts decide it: measure at the
///    DPI-scaled size and take ascent+descent, falling back to the policy
///    default when nothing could be measured.
pub fn resolve(in: Inputs, probe: Probe) Metrics {
    const base = scale.scaleFontSizeForHeight(in.font_size, in.screen_height);

    if (in.height) |h| {
        const height = scale.scaleBarHeight(h, in.screen_height);
        if (in.font_size.is_percentage) {
            if (percentageOf(in, height, probe)) |size| {
                return .{ .font_size = size, .height = height };
            }
        }
        return .{ .font_size = base, .height = height };
    }

    // No configured height: measure the configured fonts at the DPI-scaled
    // size and let their own metrics set the bar. A failed measurement is not
    // an error -- the bar still has to exist -- so it takes the policy default
    // at the base size, which is what drawing will then measure anyway.
    const total = probe(base) orelse
        return .{ .font_size = base, .height = scale.bar_height_policy.default_px };
    return .{ .font_size = base, .height = scale.clampBarHeight(@intCast(@max(1, total))) };
}

/// The font size a percentage configuration means at `bar_height`: the
/// tallest point size whose ascent+descent fits the bar, times the configured
/// percentage. Null when the probe failed, in which case the caller keeps the
/// DPI-scaled base rather than inventing a size from nothing.
fn percentageOf(in: Inputs, bar_height: u16, probe: Probe) ?u16 {
    const trial = probe_trial_pt;
    const total = probe(trial) orelse return null;
    const px_per_pt = @as(f32, @floatFromInt(@max(1, total))) /
        @as(f32, @floatFromInt(trial));
    const max_size_pt = @as(f32, @floatFromInt(bar_height)) / px_per_pt;
    const cfg_pct = in.font_size.value / 100.0;
    // Clamp before casting, mirroring types.scaleToU16: a large font_size
    // percentage must not wrap the u16 cast into UB in ReleaseFast.
    const clamped = std.math.clamp(
        max_size_pt * cfg_pct,
        1.0,
        @as(f32, std.math.maxInt(u16)),
    );
    return @as(u16, @intFromFloat(@round(clamped)));
}

// Bar height / font-size resolution.
//
// The RULES live in `resolve` above, which is pure: it
// takes the configured values, the screen, and a font probe, and returns a
// `Metrics` value. These adapters only supply the two live pieces -- the
// current config, and a probe that measures through
// fonts.probeFontMetrics' throwaway surface (no live DrawContext is
// touched) -- and threads the result into bar creation, draw-context
// construction, and the surviving State's own value. No global, no config
// mutation, and no save/restore: a bar's metrics belong to that bar.

/// Measures the configured fonts at `trial_pt`. The point size is always
/// explicit: the only two callers are the metric probe itself (a fixed trial
/// size) and `resolve`'s height decision, which measures at the
/// DPI-scaled base.
fn probeMetrics(trial_pt: u16) ?fonts.FontMetrics {
    const cs = core.getState();
    var sized = fonts.SizedFontList.build(cs.alloc, cs.config.bar.fonts.items, trial_pt) catch return null;
    defer sized.deinit();
    return fonts.probeFontMetrics(
        cs.alloc,
        core.dpi(),
        sized.items,
    );
}

/// Resolves the bar's metrics from the live config and screen. The rules
/// themselves live in `metrics.resolve`; this only supplies them.
pub fn resolveBarMetrics() Metrics {
    const cs = core.getState();
    return resolve(.{
        .font_size = cs.config.bar.font_size,
        .height = cs.config.bar.height,
        .screen_height = cs.screen.height_in_pixels,
    }, probeTextHeight);
}

/// The `Probe` adapter: the configured fonts' ascent+descent at a
/// trial point size, or null when none could be measured.
///
/// Pango reports i16 and a descent is a positive-downward distance here, so
/// the total is taken in i32 and floored at 0: a font that reports a
/// pathological negative total must clamp to "no measurement" rather than
/// wrap through `@intCast` in ReleaseFast.
fn probeTextHeight(trial_pt: u16) ?u32 {
    const m = probeMetrics(trial_pt) orelse return null;
    const total: i32 = @as(i32, m.ascent) + @as(i32, m.descent);
    if (total <= 0) return null;
    return @intCast(total);
}
