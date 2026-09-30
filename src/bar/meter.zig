//! The shared linear meter mapping: a pointer position along a horizontal slot
//! <-> a 0-100 level.
//!
//! It lives here, not in the slider core, because it is not a slider concept.
//! Every horizontal meter in the bar needs the same mapping and the same two
//! edge rules -- a zero-width slot must stay defined, and an offset past the
//! far edge must saturate rather than exceed 100 -- and each copy is a chance
//! to get one of them wrong. The slider core was the first user, and when a
//! second meter arrived it would have been the second copy. (26.8)
//!
//! The mapping is deliberately not a "physics" model: a bar is 0-100 by
//! definition at the wire level, so there is no curve, no detent and no
//! non-linearity to configure. What callers get is one documented function and
//! two named edge cases, instead of the same three lines of arithmetic.

const std = @import("std");

/// Maps a pointer offset to 0-100 % of the slot spanning [slot_x, slot_x+slot_w).
///
/// Saturating at both ends: an offset left of the slot reads 0, an offset at
/// or past its far edge reads 100. `offset` is relative to the segment start,
/// so it is the caller's job to subtract nothing -- pass the same `slot_x` the
/// slot was drawn at.
///
/// The zero-width case is the reason this is shared rather than inlined: before
/// a slider's first draw there is no painted width, and the very first press on
/// a freshly laid-out one still has to map. A naive `base * 100 / w` divides by
/// zero there. The denominator is clamped to 1, which makes any offset saturate
/// instead of trapping or wrapping.
pub fn pctFromSlot(slot_x: u16, slot_w: u16, offset: u16) u8 {
    const w: u32 = @max(slot_w, 1);
    const base: u32 = @as(u32, offset) -| @as(u32, slot_x);
    const v: u32 = base * 100 / w;
    return @intCast(@min(v, 100));
}

/// The inverse: the pixel offset within a slot that a 0-100 level sits at.
///
/// Rounds rather than truncating, so the midpoint of a slot is 50 % and not 49
/// -- the same nearest-rounding rule `pctFromRaw` uses for device ranges, and
/// the reason a 50 % fill lines up with the pointer that set it.
///
/// A zero-width slot has a single pixel, so every level maps to that pixel --
/// the arithmetic already does that, because `0 * pct / 100 == 0`. It used to be
/// clamped against the slot end as well, which was dead: `pct <= 100` makes
/// `at <= x + w` always true, so the clamp could never bind. (A mutation that
/// widened `end` by one survived, which is how the deadness was found.)
/// What DOES need clamping is the u32 -> u16 narrowing: two u16 slot arguments
/// can sum past u16, and an unchecked @intCast is a panic in a safe build and
/// a wrap in ReleaseFast.
pub fn offsetFromPct(slot_x: u16, slot_w: u16, pct: u8) u16 {
    const x: u32 = slot_x;
    const clamped: u32 = @min(pct, 100);
    const at = x + (@as(u32, slot_w) * clamped + 50) / 100;
    return @intCast(@min(at, @as(u32, std.math.maxInt(u16))));
}

test {
    std.testing.refAllDecls(@This());
}
