//! The shared linear mapping: a pointer position along a horizontal slot
//! <-> a 0-100 level. Lives here, not in the slider core, because it is
//! not a slider concept: every horizontal meter needs the same mapping and
//! the same two edge rules -- a zero-width slot must stay defined, and an
//! offset past the far edge must saturate rather than exceed 100 -- and
//! each copy is a chance to get one wrong. Deliberately not a "physics"
//! model: a bar is 0-100 by definition at the wire level, so there is no
//! curve or non-linearity to configure.
//!
//! The wheel detent lives here too because it is the same vocabulary one
//! step finer: levels are kept in half-percent units for the 2.5 % grid,
//! while the wire and the label stay whole percent (the fraction truncates
//! away on display).

const std = @import("std");

/// Levels are 0-100 %, i.e. 0-200 half-percent units.
pub const max_half_pct: u16 = 200;
/// One wheel detent: 2.5 %, in half-percent units.
pub const detent_half_pct: u16 = 5;

/// The next 2.5 % detent strictly above (`dir > 0`) or below (`dir <= 0`)
/// `half`, saturating at 0/100 %. Callers that speak whole percent display
/// `target / 2`; the fraction is what lets a later wheel step continue from
/// the detent instead of truncating it again.
pub fn snapHalf(half: u16, dir: i8) u16 {
    const h = @min(half, max_half_pct);
    if (dir > 0) {
        const next = (h / detent_half_pct + 1) * detent_half_pct;
        return @min(next, max_half_pct);
    }
    if (h == 0) return 0;
    return ((h - 1) / detent_half_pct) * detent_half_pct;
}

/// Like `snapHalf`, but skips detents whose whole-percent truncation equals
/// `shown`: a wheel tick must move the label, and 72.5 % displays as 72 %.
/// The 0/100 % ends are real boundaries, not invisible detents.
pub fn snapHalfVisible(half: u16, dir: i8, shown: u8) u16 {
    var target = snapHalf(half, dir);
    while (target / 2 == @as(u16, shown) and target != 0 and target != max_half_pct)
        target = snapHalf(target, dir);
    return target;
}

/// Maps a pointer offset to 0-100 % of the slot spanning
/// [slot_x, slot_x+slot_w). Saturating at both ends. `offset` is relative
/// to the segment start -- pass the same `slot_x` the slot was drawn at.
///
/// The zero-width case is why this is shared: before a slider's first draw
/// there is no painted width, yet the first press still has to map. A naive
/// `base * 100 / w` divides by zero; the denominator is clamped to 1, so
/// any offset saturates instead of trapping or wrapping.
pub fn pctFromSlot(slot_x: u16, slot_w: u16, offset: u16) u8 {
    const w: u32 = @max(slot_w, 1);
    const base: u32 = @as(u32, offset) -| @as(u32, slot_x);
    const v: u32 = base * 100 / w;
    return @intCast(@min(v, 100));
}

/// The inverse: the pixel offset within a slot that a 0-100 level sits at.
///
/// Rounds rather than truncating, so the midpoint of a slot is 50 % and not
/// 49 -- the same nearest-rounding rule `pctFromRaw` uses, and the reason a
/// 50 % fill lines up with the pointer that set it.
///
/// What needs clamping is the u32 -> u16 narrowing: two u16 slot arguments
/// can sum past u16, and an unchecked @intCast is a panic in a safe build
/// and a wrap in ReleaseFast.
pub fn offsetFromPct(slot_x: u16, slot_w: u16, pct: u8) u16 {
    const x: u32 = slot_x;
    const clamped: u32 = @min(pct, 100);
    const at = x + (@as(u32, slot_w) * clamped + 50) / 100;
    return @intCast(@min(at, @as(u32, std.math.maxInt(u16))));
}
