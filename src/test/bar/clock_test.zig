//! Unit tests for the clock segment's pure mode-cycle and deadline arithmetic.
//! Everything else in clock.zig is main-thread rendering against the live
//! wall clock; deadlineFromMs, effectiveFormatFor, and cycledMode are the only
//! pieces with input-independent behavior worth pinning down.

// (28.6) Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: seg_clock

const std = @import("std");
const clock = @import("clock");
const scaffold = @import("scaffold");
const contract = @import("contract");

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

test "a width stored for one mode is not reserved for the next" {
    // The clock's row reservation comes from the width it measured for the
    // ACTIVE mode. A stored width belonging to the mode being left behind is
    // already too wide for the incoming one, so the hook must fall back to the
    // bar's fresh probe for that mode. Reporting the stale slot is what left
    // the row laid out at the previous mode's length after a click.
    const W = scaffold.keyedWidthState("clock_test", clock.DisplayMode);
    const ctx: *const contract.Frame = undefined; // the clock hook reads nothing from it
    const wide: u16 = 190; // date_time
    const narrow: u16 = 80; // time

    // Before any store the fresh probe width applies (a fresh bar).
    W.invalidate();
    try std.testing.expectEqual(wide, W.naturalWidth(.date_time, ctx, wide));

    W.store(.date_time, wide);
    try std.testing.expectEqual(wide, W.naturalWidth(.date_time, ctx, wide));
    // The cycle itself: stale under the new key, so the narrow probe wins.
    try std.testing.expectEqual(narrow, W.naturalWidth(.time, ctx, narrow));
    // And it does not come back to the old slot for a mode it was never
    // measured for either.
    try std.testing.expectEqual(narrow, W.naturalWidth(.date, ctx, narrow));
    W.invalidate();
}

test "staleness keys on the format's bytes, not its address" {
    // Same second, same bytes, different slices: NOT stale.
    try std.testing.expect(!clock.stalenessFor(7, 7, "%H:%M", "%H:%M"));
    // Same second, same address, different bytes: stale (the pointer compare
    // this replaced would have called this unchanged).
    var buf: [5]u8 = "%H:%M".*;
    try std.testing.expect(clock.stalenessFor(7, 7, "%H:%M:%S", &buf));
    // Different second: stale regardless of format.
    try std.testing.expect(clock.stalenessFor(8, 7, "%H:%M", "%H:%M"));
    // Format change of equal length: stale.
    try std.testing.expect(clock.stalenessFor(7, 7, "%I:%M", "%H:%M"));
    // Prefix relationship: stale.
    try std.testing.expect(clock.stalenessFor(7, 7, "%H:%M:%S", "%H:%M"));
}
