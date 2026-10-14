//! The shared linear slot<->level mapping, tested at the home it was lifted to (26.8).
//!
//! These used to live in slider_test.zig against `slider.pctFromSlot`. The core
//! still re-exports that name, so the old entry point keeps working -- but the
//! function is no longer the slider's, and a test that imports it as the
//! slider's would quietly keep passing after the lift with the mapping gone
//! from where the test claims to be checking it. Testing `level` directly is
//! what makes the move real rather than a rename.

// build-gate: level

const std = @import("std");
const level = @import("level");

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
    // including 100 %, which the unclamped form reported one pixel outside the
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
