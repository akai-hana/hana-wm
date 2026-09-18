//! Unit tests for the shared commit throttle state machine, which now lives
//! in the slider core (slider.zig). White-box where the window needs to be
//! closed: the scheduler reads the wall clock, so tests fast-forward
//! `Throttle.last_ms` instead of sleeping.

const std = @import("std");
const slider = @import("slider");
const testing = std.testing;

var g_calls: usize = 0;
var g_last_pct: u8 = 0;

fn record(pct: u8) void {
    g_calls += 1;
    g_last_pct = pct;
}

test "native commits apply on every event, never throttled" {
    var t = slider.Throttle{ .interval_ms = 80 };
    g_calls = 0;
    t.last_ms = slider.nowMs();
    t.apply(true, 50, record);
    t.apply(true, 51, record);
    try testing.expectEqual(@as(usize, 2), g_calls);
    try testing.expectEqual(@as(u8, 51), g_last_pct);
    try testing.expectEqual(false, t.pending);
}

test "spawn commits throttle, coalesce, and flush after the window" {
    var t = slider.Throttle{ .interval_ms = 80 };
    g_calls = 0;
    t.apply(false, 40, record); // first spawn: the window is "elapsed"
    try testing.expectEqual(@as(usize, 1), g_calls);
    try testing.expectEqual(false, t.pending);

    t.apply(false, 41, record); // inside the window: owed, not sent
    try testing.expectEqual(@as(usize, 1), g_calls);
    try testing.expectEqual(true, t.pending);

    t.flushOwed(42, record); // window not elapsed: still owed
    try testing.expectEqual(@as(usize, 1), g_calls);

    t.last_ms = slider.nowMs() - t.interval_ms - 1; // close the window
    t.flushOwed(43, record); // sweep lands the newest value
    try testing.expectEqual(@as(usize, 2), g_calls);
    try testing.expectEqual(@as(u8, 43), g_last_pct);
    try testing.expectEqual(false, t.pending);
}

test "finish lands an owed value at drag end regardless of the window" {
    var t = slider.Throttle{ .interval_ms = 80 };
    g_calls = 0;
    t.apply(false, 10, record);
    try testing.expectEqual(@as(usize, 1), g_calls);

    t.apply(false, 11, record); // owed
    t.finish(12, record); // drag end force-lands it
    try testing.expectEqual(@as(usize, 2), g_calls);
    try testing.expectEqual(@as(u8, 12), g_last_pct);
    try testing.expectEqual(false, t.pending);

    t.finish(13, record); // nothing owed: no write
    try testing.expectEqual(@as(usize, 2), g_calls);
}

test "reset restarts the clock and clears an owed commit" {
    var t = slider.Throttle{ .interval_ms = 80 };
    g_calls = 0;
    t.apply(false, 1, record);
    t.apply(false, 2, record); // owed
    try testing.expectEqual(true, t.pending);

    t.reset();
    try testing.expectEqual(false, t.pending);

    t.last_ms = slider.nowMs() - t.interval_ms - 1; // close the window
    t.flushOwed(3, record); // reset settled the owe, so nothing sends
    try testing.expectEqual(@as(usize, 1), g_calls);
}
