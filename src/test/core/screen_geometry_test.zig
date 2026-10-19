//! P1-36: burst dedup on the RandR dispatch path.
//!
//! One physical mode change (resolution switch, rotate, monitor plug) fires
//! an event BURST at refreshScreenGeometry -- and the trailing events of that
//! burst must be free: no state write, no log, and (through the `false`
//! return) no downstream DPI re-read or debounced re-detect from the caller
//! in events.zig. A live server cannot pin that (the write of an identical
//! value is invisible from outside and the log is not asserted), so the
//! comparison/apply half is extracted as `core.applyScreenGeometry` and the
//! dedup contract is pinned here against a bare screen struct.
//!
//! Headless: no fixture, no connection -- the seam only needs a
//! `xcb_screen_t` to compare and write two dimension fields.

const std = @import("std");
const testing = std.testing;

const core = @import("core");

fn screenAt(w: u16, h: u16) core.xcb.xcb_screen_t {
    var s = std.mem.zeroes(core.xcb.xcb_screen_t);
    s.width_in_pixels = w;
    s.height_in_pixels = h;
    return s;
}

test "changed geometry: reported true and applied to the cached screen" {
    var s = screenAt(1920, 1080);

    try testing.expect(core.applyScreenGeometry(&s, 2560, 1440));
    try testing.expectEqual(@as(u16, 2560), @as(u16, s.width_in_pixels));
    try testing.expectEqual(@as(u16, 1440), @as(u16, s.height_in_pixels));
}

test "unchanged geometry: false, state untouched" {
    var s = screenAt(1920, 1080);

    try testing.expect(!core.applyScreenGeometry(&s, 1920, 1080));
    try testing.expectEqual(@as(u16, 1920), @as(u16, s.width_in_pixels));
    try testing.expectEqual(@as(u16, 1080), @as(u16, s.height_in_pixels));
}

test "burst dedup: the first event pays, the trailing ones are free" {
    var s = screenAt(1920, 1080);

    // Leading event of the burst: real change, applied, reported.
    try testing.expect(core.applyScreenGeometry(&s, 1280, 720));
    // Trailing events carry the same size: the dedup that keeps the rest of
    // the burst from re-logging and re-triggering downstream work.
    try testing.expect(!core.applyScreenGeometry(&s, 1280, 720));
    try testing.expect(!core.applyScreenGeometry(&s, 1280, 720));
    try testing.expectEqual(@as(u16, 1280), @as(u16, s.width_in_pixels));
    try testing.expectEqual(@as(u16, 720), @as(u16, s.height_in_pixels));

    // A later genuine change reports again (dedup must not latch).
    try testing.expect(core.applyScreenGeometry(&s, 3840, 2160));
    try testing.expectEqual(@as(u16, 3840), @as(u16, s.width_in_pixels));
    try testing.expectEqual(@as(u16, 2160), @as(u16, s.height_in_pixels));
}

test "a change in either dimension alone counts" {
    var s = screenAt(1920, 1080);

    try testing.expect(core.applyScreenGeometry(&s, 1920, 1200)); // height only
    try testing.expectEqual(@as(u16, 1920), @as(u16, s.width_in_pixels));
    try testing.expectEqual(@as(u16, 1200), @as(u16, s.height_in_pixels));

    try testing.expect(core.applyScreenGeometry(&s, 3440, 1200)); // width only
    try testing.expectEqual(@as(u16, 3440), @as(u16, s.width_in_pixels));
    try testing.expectEqual(@as(u16, 1200), @as(u16, s.height_in_pixels));
}
