//! Headless wincache tests (pure cache paths only).
//!
//! Everything here runs without an X connection: the cache's entry lifecycle
//! (title ownership, at-capacity drop) is pure allocation bookkeeping,
//! so the leak-checking testing allocator pins it. The wire-touching half
//! (fireTitleCookies/collectTitleCookies, sendBorderColorIfChanged, and the
//! border-width dedup, which lives in the sync ledger now) needs a live
//! display and stays in the integration layer. Size hints are NOT tested
//! here: they have a single store (the model entry, threaded through
//! admission as a parameter), so there is no cache path to pin.

const std = @import("std");
const testing = std.testing;

const wincache = @import("wincache");

// 11.5: the title is a fixed inline buffer now, so there is no ownership left
// to test -- which is the point. This used to be "title ownership: overwrite
// frees prior, remove frees owned", which asserted the three free paths that
// no longer exist. What remains worth pinning is the copy semantics they used
// to interfere with, plus the truncation bound that replaced the allocator.
test "title store: overwrite replaces in place, remove clears, oversize truncates" {
    const alloc = std.testing.allocator;
    wincache.init(alloc);
    defer wincache.deinit();

    wincache.storeTitle(7, "hello");
    try testing.expectEqualStrings("hello", wincache.peekTitle(7));
    wincache.storeTitle(7, "edited");
    try testing.expectEqualStrings("edited", wincache.peekTitle(7));
    wincache.removeWindow(7);
    try testing.expectEqualStrings("", wincache.peekTitle(7));
    // Non-cached window and double remove are no-ops.
    wincache.removeWindow(7);
    wincache.storeTitle(99, "");
    try testing.expectEqualStrings("", wincache.peekTitle(99));

    // Truncation at the inline bound: a title longer than the buffer is cut,
    // and the result is a valid slice (sliced by title_len, not terminator-
    // terminated), so nothing reads past what was stored.
    var long: [1024]u8 = @splat('x');
    long[0] = 'a';
    wincache.storeTitle(7, &long);
    const got = wincache.peekTitle(7);
    try testing.expectEqual(@as(usize, 256), got.len);
    try testing.expectEqual(@as(u8, 'a'), got[0]);
    try testing.expectEqual(@as(u8, 'x'), got[255]);

    // A short title after a long one is NOT padded with the old bytes: the
    // length is authoritative, so the stale tail cannot leak into the read.
    wincache.storeTitle(7, "short");
    try testing.expectEqualStrings("short", wincache.peekTitle(7));
}

test "at-capacity cache drops new entries but keeps overwrites" {
    const alloc = std.testing.allocator;
    wincache.init(alloc);
    defer wincache.deinit();

    const max = @import("icccm").max_window_cache;

    // Fill past the ceiling with title writes (the fixed-capacity IdMap
    // enforces the cap; key 0 is its never-used sentinel, so the ids here
    // start at 1, matching the real XIDs production feeds it).
    var i: u32 = 1;
    while (i <= max) : (i += 1) {
        wincache.storeTitle(i, "fill");
        try testing.expectEqualStrings("fill", wincache.peekTitle(i));
    }
    // The ceiling+1st NEW window is dropped: no entry materializes.
    wincache.storeTitle(max + 1, "dropped");
    try testing.expectEqual(max, wincache.cachedWindowCount());
    try testing.expectEqualStrings("", wincache.peekTitle(max + 1));

    // Overwrites of an already-cached window remain exempt from the ceiling.
    wincache.storeTitle(1, "still writable");
    try testing.expectEqualStrings("still writable", wincache.peekTitle(1));
}
