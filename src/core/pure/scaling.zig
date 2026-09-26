//! Canonical scaling formulas: pure functions of a ScalableValue, no DPI
//! lookup.
//!
//! `display/dpi.zig` (which measures DPI) and `config/` (which parses
//! ScalableValues) both call into these, so there is exactly one formula to
//! maintain. X-free and allocation-free: the DPI probe stays on the x11 side.

const std = @import("std");

/// Resolves a ScalableValue to a ratio: `v%` becomes v/100, an absolute
/// value stays as-is.
pub inline fn asRatio(value: anytype) f32 {
    return if (value.is_percentage) value.value / 100.0 else value.value;
}

/// Resolves a ScalableValue against a reference dimension: `v%` becomes
/// reference * v/100, an absolute value stays as-is (reference unused).
pub inline fn scaleToPixels(value: anytype, reference: f32) f32 {
    return if (value.is_percentage) reference * (value.value / 100.0) else value.value;
}

/// Resolves a border-width ScalableValue: `v%` becomes half the reference
/// dimension (a border insets two sides), an absolute value stays as-is.
pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
    const v: f32 = if (value.is_percentage)
        (value.value / 100.0) * 0.5 * @as(f32, @floatFromInt(reference_dimension))
    else
        value.value;
    return roundToU16(v, 0.0);
}

/// Rounds `v` to the nearest integer and clamps it into [min, maxInt(u16)].
pub inline fn roundToU16(v: f32, min: f32) u16 {
    const clamped = std.math.clamp(@round(v), min, @as(f32, std.math.maxInt(u16)));
    return @intFromFloat(clamped);
}

/// Clamps a u32 into the u16 range.
pub inline fn clampToU16(v: u32) u16 {
    return @intCast(std.math.clamp(v, 0, std.math.maxInt(u16)));
}
