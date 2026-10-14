//! `probeFontMetrics` exercise tests (headless: Pango needs no X display).
//!
//! SCOPE, stated up front because it is easy to over-read this file: these
//! tests do NOT prove the font-description leak is fixed. They cannot. A
//! `PangoFontDescription` is allocated by Pango through GLib's allocator, not
//! through the `std.mem.Allocator` handed to `probeFontMetrics`, so
//! `std.testing.allocator` -- which is what makes a leak test a leak test
//! elsewhere in this suite -- never sees the allocation at all. Verified
//! rather than assumed: removing `defer font.deinit()` leaves this file green.
//!
//! What they do buy is the half that IS observable. `probeFontMetrics`
//! constructs a `FontState` and a Pango layout per call, and the fix added a
//! `defer font.deinit()` to a function with a `catch return null` on the line
//! after the state is built. A `defer` placed before the last read of the
//! description -- the natural-looking refactor -- is a use-after-free, not a
//! clean miss, and this is the only place the ordering gets exercised. So:
//! repeated invocation, both font-name branches, and no crash.
//!
//! The leak fix itself is recorded in the ledger with this same
//! limitation. Detecting it would need a GLib-level allocation counter or an
//! RSS-delta test, both of which are environment-fragile enough that they
//! would flake more often than the leak they watch.

const std = @import("std");
const testing = std.testing;

const drawing = @import("drawing");

test "probeFontMetrics runs repeatedly on the named-font path" {
    const families = [_][]const u8{"Sans"};
    for (0..8) |_| {
        const m = drawing.probeFontMetrics(testing.allocator, 96.0, &families);
        try testing.expect(m != null);
    }
}

test "probeFontMetrics runs repeatedly on the fallback-font path" {
    // Empty list -> loadFonts loads `fallbackFont` instead. A separate
    // `pango_font_description_from_string` call inside `loadFont`, so it is a
    // distinct branch for a `defer`-ordering mistake to hide in.
    for (0..8) |_| {
        const m = drawing.probeFontMetrics(testing.allocator, 96.0, &.{});
        try testing.expect(m != null);
    }
}

test "probeFontMetrics completes and returns, even with no resolvable font" {
    // Deliberately does NOT assert ascent > 0. In a headless container Pango
    // builds the layout and the description but may resolve no family, so
    // getMetrics legitimately returns 0/0. Asserting the numbers would make
    // this file fail on fontconfig availability, which is not what it is for.
    const m = drawing.probeFontMetrics(testing.allocator, 96.0, &[_][]const u8{"Sans"});
    try testing.expect(m != null);
}
