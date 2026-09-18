//! Unit tests for the slider core's pure geometry helpers (slider.zig).
//! These are state-free so they run against the real registry without
//! touching state; the subprocess-free paths avoid touching devices.

const std = @import("std");
const slider = @import("slider");
const testing = std.testing;

test "pctFromSlot maps an offset across a slot" {
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(10, 100, 10));
    try testing.expectEqual(@as(u8, 50), slider.pctFromSlot(10, 100, 60));
    try testing.expectEqual(@as(u8, 100), slider.pctFromSlot(10, 100, 110));
    try testing.expectEqual(@as(u8, 1), slider.pctFromSlot(10, 100, 11));
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(10, 100, 0));
    try testing.expectEqual(@as(u8, 0), slider.pctFromSlot(0, 0, 0));
}

test "slotAt hits the owning slot and only it" {
    const slots = [_]slider.Slot{
        .{ .x = 0, .w = 40 },
        .{ .x = 40, .w = 60 },
    };
    try testing.expectEqual(@as(?usize, 0), slider.slotAt(0, &slots));
    try testing.expectEqual(@as(?usize, 0), slider.slotAt(39, &slots));
    try testing.expectEqual(@as(?usize, 1), slider.slotAt(40, &slots));
    try testing.expectEqual(@as(?usize, 1), slider.slotAt(99, &slots));
    try testing.expectEqual(@as(?usize, null), slider.slotAt(100, &slots));
}

test "slotAt skips zero-width slots" {
    const slots = [_]slider.Slot{
        .{ .x = 0, .w = 0 },
        .{ .x = 0, .w = 30 },
    };
    try testing.expectEqual(@as(?usize, 1), slider.slotAt(0, &slots));
    try testing.expectEqual(@as(?usize, null), slider.slotAt(31, &slots));
}
