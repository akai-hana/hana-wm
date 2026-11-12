//! The shared linear slot<->level mapping, tested at its source in
//! `bar/level.zig`.
//!
//! The slider core re-exports the same functions as `slider.pctFromSlot`; a
//! test importing them from the slider would pass equally well and pin nothing
//! about where the mapping lives, so these go directly to `level`.

// build-gate: level

const std = @import("std");
const level = @import("level");

test "snapHalf steps the 2.5 % detent grid" {
    // From a clean level, one wheel step is 2.5 % (five half-percent units).
    try std.testing.expectEqual(@as(u16, 5), level.snapHalf(0, 1));
    try std.testing.expectEqual(@as(u16, 10), level.snapHalf(5, 1));
    // A whole-percent level off the grid snaps to the next detent in the
    // direction of travel: 71 % -> 72.5 % up, 70 % down.
    try std.testing.expectEqual(@as(u16, 145), level.snapHalf(142, 1));
    try std.testing.expectEqual(@as(u16, 140), level.snapHalf(142, -1));
    // On the grid the step is a full detent.
    try std.testing.expectEqual(@as(u16, 150), level.snapHalf(145, 1));
    try std.testing.expectEqual(@as(u16, 140), level.snapHalf(145, -1));
}

test "snapHalf saturates at 0 and 100 %" {
    try std.testing.expectEqual(@as(u16, 0), level.snapHalf(0, -1));
    try std.testing.expectEqual(@as(u16, 0), level.snapHalf(1, -1));
    try std.testing.expectEqual(@as(u16, 200), level.snapHalf(200, 1));
    try std.testing.expectEqual(@as(u16, 200), level.snapHalf(199, 1));
    try std.testing.expectEqual(@as(u16, 195), level.snapHalf(200, -1));
    // An over-range cursor is clamped before stepping, not after.
    try std.testing.expectEqual(@as(u16, 200), level.snapHalf(999, 1));
}

test "snapHalfVisible skips a detent the label cannot show" {
    // 72 % -> 72.5 % truncates back to 72, so the visible step is 75 %.
    try std.testing.expectEqual(@as(u16, 150), level.snapHalfVisible(144, 1, 72));
    // 2 % -> 2.5 % is the same case at the bottom of the range.
    try std.testing.expectEqual(@as(u16, 10), level.snapHalfVisible(4, 1, 2));
    // A detent that does change the label is kept: 71 % -> 72.5 % -> "72".
    try std.testing.expectEqual(@as(u16, 145), level.snapHalfVisible(142, 1, 71));
    // The ends saturate instead of wrapping or looping forever.
    try std.testing.expectEqual(@as(u16, 200), level.snapHalfVisible(200, 1, 100));
    try std.testing.expectEqual(@as(u16, 0), level.snapHalfVisible(0, -1, 0));
}

test "every wheel landing is on the 2.5 % grid" {
    // Starting from an arbitrary backend reading, each step lands on a
    // detent -- never on an in-between value like 71 or 54.
    var up: u16 = 142;
    var down: u16 = 142;
    for (0..40) |_| {
        up = level.snapHalf(up, 1);
        down = level.snapHalf(down, -1);
        try std.testing.expectEqual(@as(u16, 0), up % level.detent_half_pct);
        try std.testing.expectEqual(@as(u16, 0), down % level.detent_half_pct);
    }
}

test "pctFromSlot maps an offset across a slot" {
    try std.testing.expectEqual(@as(u8, 0), level.pctFromSlot(10, 100, 10));
    try std.testing.expectEqual(@as(u8, 50), level.pctFromSlot(10, 100, 60));
    try std.testing.expectEqual(@as(u8, 100), level.pctFromSlot(10, 100, 110));
    try std.testing.expectEqual(@as(u8, 1), level.pctFromSlot(10, 100, 11));
    try std.testing.expectEqual(@as(u8, 0), level.pctFromSlot(10, 100, 0));
    try std.testing.expectEqual(@as(u8, 0), level.pctFromSlot(0, 0, 0));
}

test "offsetFromPct inverts pctFromSlot, with nearest rounding" {
    // Midpoint of a 100-wide slot is 50 %, not 49: the same nearest-rounding
    // rule the device-range helpers use.
    try std.testing.expectEqual(@as(u16, 60), level.offsetFromPct(10, 100, 50));
    try std.testing.expectEqual(@as(u16, 10), level.offsetFromPct(10, 100, 0));
    try std.testing.expectEqual(@as(u16, 110), level.offsetFromPct(10, 100, 100));
    // An odd width has no exact midpoint. 50 % of a 3-wide slot is 1.5, and
    // rounding must land on 2 -- truncation would give 1, which would put the
    // fill's midpoint a pixel left of the pointer that set it.
    try std.testing.expectEqual(@as(u16, 2), level.offsetFromPct(0, 3, 50));
    // And 49 % is 1.47, so it stays on the nearer side of that boundary.
    try std.testing.expectEqual(@as(u16, 1), level.offsetFromPct(0, 3, 49));
    try std.testing.expectEqual(@as(u16, 3), level.offsetFromPct(0, 3, 100));
    try std.testing.expectEqual(@as(u16, 0), level.offsetFromPct(0, 3, 0));
    // Out-of-range levels clamp rather than escaping the slot.
    try std.testing.expectEqual(@as(u16, 110), level.offsetFromPct(10, 100, 200));
    // A zero-width slot has a single pixel, so EVERY level maps to it --
    // including 100 %, which would otherwise land one pixel outside the
    // control.
    try std.testing.expectEqual(@as(u16, 10), level.offsetFromPct(10, 0, 100));
    try std.testing.expectEqual(@as(u16, 10), level.offsetFromPct(10, 0, 0));
    try std.testing.expectEqual(@as(u16, 10), level.offsetFromPct(10, 0, 55));
    // For a 1-wide slot, 100 % is the right EDGE of the only pixel, which is
    // one past it -- the offset is a fill boundary, not a pixel index, and
    // pctFromSlot reads that same boundary as full.
    try std.testing.expectEqual(@as(u16, 11), level.offsetFromPct(10, 1, 100));
    try std.testing.expectEqual(@as(u16, 10), level.offsetFromPct(10, 1, 0));
    // Two u16 slot arguments can exceed u16; the result must still be one.
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), level.offsetFromPct(60000, 60000, 100));
    try std.testing.expectEqual(@as(u16, 60000), level.offsetFromPct(60000, 60000, 0));
}
