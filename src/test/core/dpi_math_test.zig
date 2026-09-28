//! Tests for the display-free half of DPI resolution (pure/dpi_math.zig).
//!
//! 6.3 exists so these could be written at all: the Xft.dpi parser is a
//! hand-rolled parser over a USER-EDITABLE X resource string, and it used to
//! live on the x11 side of the shelf with no way to exercise it.

const std = @import("std");
const testing = std.testing;

const dpi_math = @import("dpi_math");

fn expectClose(expected: f32, actual: f32) !void {
    try testing.expect(@abs(expected - actual) < 0.01);
}

test "parseXftDpi reads a plain entry" {
    try expectClose(96.0, dpi_math.parseXftDpi("Xft.dpi:\t96").?);
    try expectClose(144.0, dpi_math.parseXftDpi("Xft.dpi:  144  ").?);
}

test "parseXftDpi stops at the newline and ignores later entries" {
    const rm = "*background:\t#000000\nXft.dpi:\t120\nXft.antialias:\ttrue\n";
    try expectClose(120.0, dpi_math.parseXftDpi(rm).?);
}

test "parseXftDpi finds the entry wherever it sits" {
    // The real Xft.dpi is never first: RESOURCE_MANAGER starts with the
    // client's own resources.
    const rm = "Xcursor.size:\t24\nXft.antialias:\ttrue\nXft.dpi:\t168\n*background:\t#202020";
    try expectClose(168.0, dpi_math.parseXftDpi(rm).?);
}

test "parseXftDpi rejects absent, empty and unparseable values" {
    try testing.expect(dpi_math.parseXftDpi("") == null);
    try testing.expect(dpi_math.parseXftDpi("*background:\t#000000") == null);
    try testing.expect(dpi_math.parseXftDpi("Xft.dpi:") == null);
    try testing.expect(dpi_math.parseXftDpi("Xft.dpi:\n") == null);
    try testing.expect(dpi_math.parseXftDpi("Xft.dpi:\tabc") == null);
    // A DIFFERENT key whose name ends in "Xft.dpi:" is not hana's setting.
    // This was a real bug: the old bare indexOf match returned 96 here, so a
    // client's "NotXft.dpi" silently overrode the real resolution.
    try testing.expect(dpi_math.parseXftDpi("NotXft.dpi:\t96") == null);
    try testing.expect(dpi_math.parseXftDpi("MyXft.dpi:\t144") == null);
}

test "calcDpiFromGeometry averages the two axes" {
    // A 1920x1080 panel reported as 508mm x 285mm (~96 dpi).
    const g = dpi_math.Geometry{ .width_px = 1920, .height_px = 1080, .width_mm = 508, .height_mm = 285 };
    // 1920/508mm and 1080/285mm are not the same axis DPI; the formula
    // averages them, so this is ~96.13, not exactly 96.
    try expectClose(96.13, dpi_math.calcDpiFromGeometry(g).?);
}

test "calcDpiFromGeometry returns null on a 0mm screen" {
    // Virtual/headless X reports 0mm; this must not divide by zero.
    try testing.expect(dpi_math.calcDpiFromGeometry(.{ .width_px = 1920, .height_px = 1080, .width_mm = 0, .height_mm = 285 }) == null);
    try testing.expect(dpi_math.calcDpiFromGeometry(.{ .width_px = 1920, .height_px = 1080, .width_mm = 508, .height_mm = 0 }) == null);
    try testing.expect(dpi_math.calcDpiFromGeometry(.{ .width_px = 0, .height_px = 0, .width_mm = 0, .height_mm = 0 }) == null);
}

test "isReasonableDpi rejects the values that would break font metrics" {
    try testing.expect(!dpi_math.isReasonableDpi(0));
    try testing.expect(!dpi_math.isReasonableDpi(-96));
    try testing.expect(!dpi_math.isReasonableDpi(std.math.nan(f32)));
    try testing.expect(!dpi_math.isReasonableDpi(std.math.inf(f32)));
    try testing.expect(!dpi_math.isReasonableDpi(49.9));
    try testing.expect(!dpi_math.isReasonableDpi(300.1));

    // Band edges are inclusive, and the common values are inside it.
    try testing.expect(dpi_math.isReasonableDpi(50.0));
    try testing.expect(dpi_math.isReasonableDpi(300.0));
    try testing.expect(dpi_math.isReasonableDpi(96.0));
    try testing.expect(dpi_math.isReasonableDpi(192.0));
}

test "parseXftDpi matches the real key after a decoy sharing its tail" {
    // The decoy is first; the real binding later on its own line still wins.
    try expectClose(120.0, dpi_math.parseXftDpi("NotXft.dpi:\t96\nXft.dpi:\t120").?);
    // A longer key that merely starts the same way is not a match.
    try testing.expect(dpi_math.parseXftDpi("Xft.dpi2:\t96") == null);
    // Repeated occurrences: the first LINE-START match is the one that counts.
    try expectClose(96.0, dpi_math.parseXftDpi("Xft.dpi:\t96\nXft.dpi:\t144").?);
}
