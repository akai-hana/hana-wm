//! The shared linear mapping: a pointer position along a horizontal slot
//! <-> a 0-100 level. Lives here, not in the slider core, because it is
//! not a slider concept: every horizontal meter needs the same mapping and
//! the same two edge rules -- a zero-width slot must stay defined, and an
//! offset past the far edge must saturate rather than exceed 100 -- and
//! each copy is a chance to get one wrong. Deliberately not a "physics"
//! model: a bar is 0-100 by definition at the wire level, so there is no
//! curve, detent or non-linearity to configure.

const std = @import("std");

/// Maps a pointer offset to 0-100 % of the slot spanning
/// [slot_x, slot_x+slot_w). Saturating at both ends. `offset` is relative
/// to the segment start -- pass the same `slot_x` the slot was drawn at.
///
/// The zero-width case is why this is shared rather than inlined: before a
/// slider's first draw there is no painted width, and the first press on a
/// freshly laid-out one still has to map. A naive `base * 100 / w` divides
/// by zero there; the denominator is clamped to 1, so any offset saturates
/// instead of trapping or wrapping.
pub fn pctFromSlot(slot_x: u16, slot_w: u16, offset: u16) u8 {
    const w: u32 = @max(slot_w, 1);
    const base: u32 = @as(u32, offset) -| @as(u32, slot_x);
    const v: u32 = base * 100 / w;
    return @intCast(@min(v, 100));
}

/// The inverse: the pixel offset within a slot that a 0-100 level sits at.
///
/// Rounds rather than truncating, so the midpoint of a slot is 50 % and not
/// 49 -- the same nearest-rounding rule `pctFromRaw` uses for device
/// ranges, and the reason a 50 % fill lines up with the pointer that set it.
///
/// A zero-width slot has a single pixel, so every level maps there (the
/// arithmetic already does that: `0 * pct / 100 == 0`). What DOES need
/// clamping is the u32 -> u16 narrowing: two u16 slot arguments can sum
/// past u16, and an unchecked @intCast is a panic in a safe build and a
/// wrap in ReleaseFast.
pub fn offsetFromPct(slot_x: u16, slot_w: u16, pct: u8) u16 {
    const x: u32 = slot_x;
    const clamped: u32 = @min(pct, 100);
    const at = x + (@as(u32, slot_w) * clamped + 50) / 100;
    return @intCast(@min(at, @as(u32, std.math.maxInt(u16))));
}
