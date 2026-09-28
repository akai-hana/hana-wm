//! Unit tests for the slider core's pure geometry helpers (slider.zig).
//! The multi-slot reference implementation lives HERE (slider is single-slot
//! per segment in production; the reference type + hit-tester exist only to
//! exercise the mapping logic).
//! These are state-free so they run against the real registry without
//! touching state; the subprocess-free paths avoid touching devices.

const std = @import("std");
const slider = @import("slider");
const testing = std.testing;

const Slot = struct {
    x: u16,
    w: u16,
};

fn slotAt(offset: u16, slots: []const Slot) ?usize {
    const off: u32 = offset;
    for (slots, 0..) |s, i| {
        if (s.w == 0) continue;
        if (off >= s.x and off < @as(u32, s.x) + s.w) return i;
    }
    return null;
}

test "pctFromSlot maps an offset across a slot" {
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(10, 100, 10));
    try testing.expectEqual(@as(u8, 50), slider.pctFromSlot(10, 100, 60));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(10, 100, 110));
    try testing.expectEqual(@as(u8, 1), slider.pctFromSlot(10, 100, 11));
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(10, 100, 0));
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(0, 0, 0));
}

test "slotAt hits the owning slot and only it" {
    const slots = [_]Slot{
        .{ .x = 0, .w = 40 },
        .{ .x = 40, .w = 60 },
    };
    try testing.expectEqual(@as(?usize, 0), slotAt(0, &slots));
    try testing.expectEqual(@as(?usize, 0), slotAt(39, &slots));
    try testing.expectEqual(@as(?usize, 1), slotAt(40, &slots));
    try testing.expectEqual(@as(?usize, 1), slotAt(99, &slots));
    try testing.expectEqual(@as(?usize, null), slotAt(100, &slots));
}

test "slotAt skips zero-width slots" {
    const slots = [_]Slot{
        .{ .x = 0, .w = 0 },
        .{ .x = 0, .w = 30 },
    };
    try testing.expectEqual(@as(?usize, 1), slotAt(0, &slots));
    try testing.expectEqual(@as(?usize, null), slotAt(31, &slots));
}

test "a zero-width slot still maps an offset instead of dividing by zero" {
    // The first-click case (26.3): before the segment's first draw there is
    // no painted width, so the mapping must still be defined and monotonic.
    // pctFromSlot clamps the denominator to 1, so any offset saturates rather
    // than wrapping or trapping.
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(0, 0, 0));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(0, 0, 1));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(0, 0, 99));
}

test "pctFromSlot is the same mapping the click hit-test bounds" {
    // The hit-test rejects `offset >= bound` and the mapping saturates at
    // offset == bound, so no in-range click can land outside 0-100 and no
    // out-of-range click is accepted.
    const bound: u16 = 80;
    for (0..@as(u32, bound) * 2) |raw| {
        const off: u16 = @intCast(raw);
        if (off >= bound) continue;
        const pct = slider.pctFromSlot(0, bound, off);
        try testing.expect(pct <= 100);
    }
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(0, bound, 0));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(0, bound, bound));
}
