//! Unit tests for the clock segment's pure mode-cycle and deadline arithmetic.
//! Everything else in clock.zig is main-thread rendering against the live
//! wall clock; deadlineFromMs, effectiveFormatFor, and cycledMode are the only
//! pieces with input-independent behavior worth pinning down.

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

test "left-click cycle wraps date_time -> time -> date -> date_time" {
    try std.testing.expectEqual(clock.DisplayMode.time, clock.cycledMode(.date_time, true));
    try std.testing.expectEqual(clock.DisplayMode.date, clock.cycledMode(.time, true));
    try std.testing.expectEqual(clock.DisplayMode.date_time, clock.cycledMode(.date, true));
}

test "right-click cycle wraps the opposite direction" {
    try std.testing.expectEqual(clock.DisplayMode.date, clock.cycledMode(.date_time, false));
    try std.testing.expectEqual(clock.DisplayMode.time, clock.cycledMode(.date, false));
    try std.testing.expectEqual(clock.DisplayMode.date_time, clock.cycledMode(.time, false));
}

test "date_time mode passes the configured format through" {
    const base = "%H:%M %d/%m/%Y";
    try std.testing.expectEqual(
        base,
        clock.effectiveFormatFor(base, .date_time),
    );
}

test "time and date modes use their built-in formats" {
    try std.testing.expectEqualStrings(
        "%H:%M:%S",
        clock.effectiveFormatFor("%Y-%m-%d %H:%M:%S", clock.DisplayMode.time),
    );
    try std.testing.expectEqualStrings(
        "%Y-%m-%d",
        clock.effectiveFormatFor("%Y-%m-%d %H:%M:%S", clock.DisplayMode.date),
    );
}

test "each mode reserves its own stable width probe" {
    try std.testing.expectEqualStrings("0000-00-00 00:00:00", clock.measureStringFor(.date_time));
    try std.testing.expectEqualStrings("00:00:00", clock.measureStringFor(.time));
    try std.testing.expectEqualStrings("0000-00-00", clock.measureStringFor(.date));
    // The probes are distinct, so a mode cycle actually changes the slot.
    try std.testing.expect(!std.mem.eql(
        u8,
        clock.measureStringFor(.date_time),
        clock.measureStringFor(.time),
    ));
}
