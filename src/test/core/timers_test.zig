//! Tests for the event loop's deadline reducer (`core/loop/timers.zig`).
//!
//! Pure arithmetic over a source list, so it runs headless: the reduction is
//! what decides whether the loop blocks forever, and the cases that matter are
//! "nothing wants a wakeup" and "the shortest answer wins".

const std = @import("std");
const testing = std.testing;

const timers = @import("timers");

// Sources are named no-arg functions rather than closures over locals: a
// `Source` is a bare function pointer, so each answer gets its own decl.
const silent: timers.Source = struct {
    fn call() ?i32 {
        return null;
    }
}.call;
const at0: timers.Source = struct {
    fn call() ?i32 {
        return 0;
    }
}.call;
const at40: timers.Source = struct {
    fn call() ?i32 {
        return 40;
    }
}.call;
const at400: timers.Source = struct {
    fn call() ?i32 {
        return 400;
    }
}.call;
const at900: timers.Source = struct {
    fn call() ?i32 {
        return 900;
    }
}.call;

var calls: usize = 0;
const counted: timers.Source = struct {
    fn call() ?i32 {
        calls += 1;
        return 500;
    }
}.call;

test "an empty source set blocks forever" {
    const none: timers.Timers = .{ .sources = &.{} };
    try testing.expect(none.deadlineMs() == null);
}

test "sources that want no wakeup do not become a deadline" {
    const set: timers.Timers = .{ .sources = &.{ silent, silent } };
    try testing.expect(set.deadlineMs() == null);
}

test "the shortest answered source wins" {
    const set: timers.Timers = .{ .sources = &.{ at400, silent, at40, at900 } };
    try testing.expectEqual(@as(?i32, 40), set.deadlineMs());
}

test "a zero answer is a wakeup, not an absence" {
    const set: timers.Timers = .{ .sources = &.{at0} };
    try testing.expectEqual(@as(?i32, 0), set.deadlineMs());
}

test "every source is consulted, even after one has answered" {
    // A later source can want to wake SOONER, so a reduction that stopped at
    // the first answer would be wrong; the count pins that it does not.
    calls = 0;
    const set: timers.Timers = .{ .sources = &.{ at900, counted, at40 } };
    try testing.expectEqual(@as(?i32, 40), set.deadlineMs());
    try testing.expectEqual(@as(usize, 1), calls);
}
