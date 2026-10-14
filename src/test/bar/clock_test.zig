//! Unit tests for the clock segment's pure mode-cycle and deadline arithmetic.
//! Everything else in clock.zig is main-thread rendering against the live
//! wall clock; deadlineFromMs, effectiveFormatFor, and cycledMode are the only
//! pieces with input-independent behavior worth pinning down.

// (28.6) Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: seg_clock

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

test "a mode cycle is stale even when the effective format bytes do not move" {
    // The mode, not just the format, carries the reservation change: date_time
    // configured as the built-in time format and time mode render identical
    // bytes, but their width probes (and therefore the row reservation)
    // differ. The predicate must go stale on the mode itself -- that staleness
    // is what drives the budget re-derivation the deleted mode-keyed width
    // cache used to own.
    const base = "%H:%M:%S";
    try std.testing.expectEqualStrings(
        clock.effectiveFormatFor(base, .date_time),
        clock.effectiveFormatFor(base, .time),
    );
    try std.testing.expect(clock.stalenessFor(7, 7, .date_time, .time, base, base));
    // Same mode, same bytes: not stale.
    try std.testing.expect(!clock.stalenessFor(7, 7, .time, .time, base, base));
}

test "staleness keys on the format's bytes, not its address" {
    // Same second, same bytes, different slices: NOT stale.
    try std.testing.expect(!clock.stalenessFor(7, 7, .date_time, .date_time, "%H:%M", "%H:%M"));
    // Same second, same address, different bytes: stale (the pointer compare
    // this replaced would have called this unchanged).
    var buf: [5]u8 = "%H:%M".*;
    try std.testing.expect(clock.stalenessFor(7, 7, .date_time, .date_time, "%H:%M:%S", &buf));
    // Different second: stale regardless of format.
    try std.testing.expect(clock.stalenessFor(8, 7, .date_time, .date_time, "%H:%M", "%H:%M"));
    // Format change of equal length: stale.
    try std.testing.expect(clock.stalenessFor(7, 7, .date_time, .date_time, "%I:%M", "%H:%M"));
    // Prefix relationship: stale.
    try std.testing.expect(clock.stalenessFor(7, 7, .date_time, .date_time, "%H:%M:%S", "%H:%M"));
    // Same second, same bytes, different mode: stale.
    try std.testing.expect(clock.stalenessFor(7, 7, .date_time, .time, "%H:%M", "%H:%M"));
}

test "unrenderable formats compare on their clipped prefix" {
    // formatTime rejects a format of fmt_limit bytes or more, so such a
    // format never paints; the record keeps only its clip. Two of them
    // agreeing on the clip are equally unpaintable and must NOT read as
    // stale, or a permanently failing clock_format would retry its doomed
    // render every event batch instead of once per second boundary.
    var long_fmt: [clock.fmt_limit + 2]u8 = undefined;
    @memset(&long_fmt, 'a');
    var record: [clock.fmt_limit]u8 = undefined;
    @memcpy(&record, long_fmt[0..clock.fmt_limit]);
    try std.testing.expect(!clock.stalenessFor(
        7,
        7,
        .date_time,
        .date_time,
        &long_fmt,
        &record,
    ));
    // A change inside the clip is stale, even past the render limit.
    long_fmt[5] = 'b';
    try std.testing.expect(clock.stalenessFor(
        7,
        7,
        .date_time,
        .date_time,
        &long_fmt,
        &record,
    ));
    // Returning to a renderable format is stale too (the clip lengths differ).
    try std.testing.expect(clock.stalenessFor(
        7,
        7,
        .date_time,
        .date_time,
        "%H:%M",
        &record,
    ));
}
