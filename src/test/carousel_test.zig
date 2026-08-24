//! Unit tests for the title-carousel state machine (carousel.zig).
//!
//! The module is pure deadline/offset math driven by an injected monotonic
//! clock, so every scenario below is deterministic: no sleeps, no rendering.

const std = @import("std");
const testing = std.testing;

const carousel = @import("carousel");

const short_title = "Short";
const long_title = "A window title long enough to overflow any reasonable bar slot";

/// Offsets are fractional; compare with a small tolerance.
fn expectOffset(expected: f32, actual: f32) !void {
    try testing.expectApproxEqAbs(expected, actual, 0.001);
}

fn reset() void {
    carousel.resetForTesting();
}

/// Convenience wrapper: enabled scroll of `text_w` in an `avail_w` slot.
fn tick(win: u32, text_w: u16, avail_w: u16, speed: u16, now_ms: i64) f32 {
    return carousel.offsetFor(win, long_title, text_w, avail_w, true, speed, now_ms);
}

test "fitting title stays static and inactive" {
    reset();
    const off = carousel.offsetFor(1, short_title, 40, 100, true, 30, 1000);
    try expectOffset(0, off);
    try testing.expect(!carousel.scrollingActive());
}

test "disabled carousel never scrolls" {
    reset();
    const off = carousel.offsetFor(1, long_title, 500, 100, false, 30, 1000);
    try expectOffset(0, off);
    try testing.expect(!carousel.scrollingActive());
}

test "overflow starts at zero and advances with elapsed time" {
    reset();
    // First frame of a new cell: head of the title, motion begins next frame.
    try expectOffset(0, tick(1, 500, 100, 30, 1000));
    try testing.expect(carousel.scrollingActive());

    // 30 px/s for one second.
    try expectOffset(30, tick(1, 500, 100, 30, 2000));
    // Another half second adds 15 more.
    try expectOffset(45, tick(1, 500, 100, 30, 2500));
}

test "offset wraps modulo text width plus gap" {
    reset();
    // cycle = 100 + gap_px = 148. Advance 1500 px: 1500 mod 148 = 20.
    _ = tick(1, 100, 50, 1, 0);
    const off = tick(1, 100, 50, 1500, 1000); // speed*dt = 1500 px
    try expectOffset(20, off);
}

test "offset is sub-pixel between frames" {
    reset();
    _ = tick(1, 500, 100, 125, 0);
    // 125 px/s for one refresh period at 144 Hz (~6.94 ms) moves < 1 px.
    const off = tick(1, 500, 100, 125, 7);
    try testing.expect(off > 0.8 and off < 0.9);
}

test "focus change resets the scroll" {
    reset();
    _ = tick(1, 500, 100, 30, 0);
    _ = tick(1, 500, 100, 30, 10_000);
    // Different window: restart from the head.
    try expectOffset(0, tick(2, 500, 100, 30, 10_001));
    // Same window again: restarts once more (identity flipped back).
    try expectOffset(0, tick(1, 500, 100, 30, 10_002));
}

test "title content change resets the scroll" {
    reset();
    _ = carousel.offsetFor(1, long_title, 500, 100, true, 30, 0);
    _ = carousel.offsetFor(1, long_title, 500, 100, true, 30, 5_000);
    // Renamed title (same window): restart from the head.
    try expectOffset(0, carousel.offsetFor(1, long_title ++ " (edited)", 500, 100, true, 30, 5_001));
}

test "re-enabling after a fit title starts over" {
    reset();
    // Overflowing, scrolled partway.
    _ = tick(1, 500, 100, 30, 0);
    _ = tick(1, 500, 100, 30, 1_000);
    // Title shrinks to fit: marquee deactivates.
    try expectOffset(0, tick(1, 80, 100, 30, 2_000));
    try testing.expect(!carousel.scrollingActive());
    // Overflows again: fresh start at zero.
    try expectOffset(0, tick(1, 500, 100, 30, 3_000));
}

test "poll deadline paces to the monitor refresh rate" {
    reset();
    try testing.expectEqual(@as(i32, -1), carousel.pollDeadlineMs(1000, true, 60));

    _ = tick(1, 500, 100, 30, 1000);
    // One display period at 60 Hz: ceil(1000/60) = 17 ms.
    try testing.expectEqual(@as(i32, 17), carousel.pollDeadlineMs(1000, true, 60));
    // At 144 Hz the wake lands sooner: ceil(1000/144) = 7 ms.
    try testing.expectEqual(@as(i32, 7), carousel.pollDeadlineMs(1000, true, 144));
    // Overdue by any amount clamps to an immediate wake.
    try testing.expectEqual(@as(i32, 1), carousel.pollDeadlineMs(1000 + 9999, true, 60));
    // Config-disabled: no contribution even mid-scroll.
    try testing.expectEqual(@as(i32, -1), carousel.pollDeadlineMs(1020, false, 60));
}
