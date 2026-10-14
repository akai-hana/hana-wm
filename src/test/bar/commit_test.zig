//! Unit tests for the shared commit throttle state machine, which now lives
//! in the slider core (slider.zig). White-box where the window needs to be
//! closed: the scheduler reads the wall clock, so tests fast-forward
//! `Throttle.last_ms` instead of sleeping.

const std = @import("std");
const time = @import("time");
const slider = @import("slider");
const testing = std.testing;

var g_calls: usize = 0;
var g_last_pct: u8 = 0;

/// The scheduler's target, in the shape it now holds: a `write` hook that
/// takes a `Write` mode. The test only ever drives the `.commit` path, so the
/// other two modes are the no-ops they would be for a control that only
/// records -- what is under test is WHEN a commit lands, not what a mode does.
fn record(w: slider.Write, pct: u8) void {
    if (w != .commit) return;
    g_calls += 1;
    g_last_pct = pct;
}

test "immediate commits apply on every event, never throttled" {
    var t = slider.Throttle{ .interval_ms = 80, .write = record };
    g_calls = 0;
    t.last_ms = time.realtimeMs();
    t.apply(.immediate, 50);
    t.apply(.immediate, 51);
    try testing.expectEqual(@as(usize, 2), g_calls);
    try testing.expectEqual(@as(u8, 51), g_last_pct);
    try testing.expectEqual(false, t.pending);
}

test "rate-limited commits throttle, coalesce, and flush after the window" {
    var t = slider.Throttle{ .interval_ms = 80, .write = record };
    g_calls = 0;
    t.apply(.rate_limited, 40); // first spawn: the window is "elapsed"
    try testing.expectEqual(@as(usize, 1), g_calls);
    try testing.expectEqual(false, t.pending);

    t.apply(.rate_limited, 41); // inside the window: owed, not sent
    try testing.expectEqual(@as(usize, 1), g_calls);
    try testing.expectEqual(true, t.pending);

    t.flushOwed(42); // window not elapsed: still owed
    try testing.expectEqual(@as(usize, 1), g_calls);

    t.last_ms = time.realtimeMs() - t.interval_ms - 1; // close the window
    t.flushOwed(43); // sweep lands the newest value
    try testing.expectEqual(@as(usize, 2), g_calls);
    try testing.expectEqual(@as(u8, 43), g_last_pct);
    try testing.expectEqual(false, t.pending);
}

test "finish lands an owed value at drag end regardless of the window" {
    var t = slider.Throttle{ .interval_ms = 80, .write = record };
    g_calls = 0;
    t.apply(.rate_limited, 10);
    try testing.expectEqual(@as(usize, 1), g_calls);

    t.apply(.rate_limited, 11); // owed
    t.finish(12); // drag end force-lands it
    try testing.expectEqual(@as(usize, 2), g_calls);
    try testing.expectEqual(@as(u8, 12), g_last_pct);
    try testing.expectEqual(false, t.pending);

    t.finish(13); // nothing owed: no write
    try testing.expectEqual(@as(usize, 2), g_calls);
}

test "reset restarts the clock and clears an owed commit" {
    var t = slider.Throttle{ .interval_ms = 80, .write = record };
    g_calls = 0;
    t.apply(.rate_limited, 1);
    t.apply(.rate_limited, 2); // owed
    try testing.expectEqual(true, t.pending);

    t.reset();
    try testing.expectEqual(false, t.pending);

    t.last_ms = time.realtimeMs() - t.interval_ms - 1; // close the window
    t.flushOwed(3); // reset settled the owe, so nothing sends
    try testing.expectEqual(@as(usize, 1), g_calls);
}
