//! Unit tests for the clock segment's pure deadline arithmetic.
//! Everything else in clock.zig is main-thread rendering against the live
//! wall clock; deadlineFromMs is the only piece with input-independent
//! behavior worth pinning down (docs/clock-plan.md §5.4).

const std = @import("std");
const clock = @import("clock");

test "deadlineFromMs returns ms to next whole-second boundary" {
    // Exactly on a boundary: a full second to the next one.
    try std.testing.expectEqual(@as(i32, 1000), clock.deadlineFromMs(1_700_000_000_000));
    // 1ms past a boundary: 999ms remain.
    try std.testing.expectEqual(@as(i32, 999), clock.deadlineFromMs(1_700_000_000_001));
    // 999ms past a boundary: 1ms remains.
    try std.testing.expectEqual(@as(i32, 1), clock.deadlineFromMs(1_700_000_000_999));
}

test "deadlineFromMs is always in [1, 1000] across an arbitrary sample" {
    var now_ms: i64 = 86_400_000 - 137; // arbitrary non-round anchor
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const d = clock.deadlineFromMs(now_ms);
        try std.testing.expect(d >= 1 and d <= 1000);
        now_ms += 7; // coprime stride sweeps all residues over time
    }
}
