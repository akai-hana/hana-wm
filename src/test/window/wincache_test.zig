//! Headless wincache tests (pure cache paths only).
//!
//! Everything here runs without an X connection: the cache's entry lifecycle
//! (hints, title ownership, at-capacity drop) is pure allocation bookkeeping,
//! so the leak-checking testing allocator pins it. The wire-touching half
//! (fireTitleCookies/collectTitleCookies, sendBorderColorIfChanged, and the
//! border-width dedup, which lives in the sync ledger now) needs a live
//! display and stays in the integration layer.

const std = @import("std");
const testing = std.testing;

const wincache = @import("wincache");

test "size-hints round-trip and empty-hints no-op" {
    const alloc = std.testing.allocator;
    wincache.init(alloc);
    defer wincache.deinit();

    try testing.expectEqual(wincache.SizeHints{}, wincache.peekHints(3));
    const hints = wincache.SizeHints{
        .min_width = 320,
        .min_height = 200,
        .max_width = 1024,
        .max_height = 768,
    };
    wincache.cacheSizeHints(3, hints);
    try testing.expectEqual(hints, wincache.peekHints(3));

    // All-zero hints declare nothing and must not create an entry.
    wincache.cacheSizeHints(4, .{});
    try testing.expectEqual(wincache.SizeHints{}, wincache.peekHints(4));
}

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

    // Fill past the ceiling with size-hint writes (the shared getOrPutDefault
    // path enforces the cap).
    var i: u32 = 0;
    while (i < max) : (i += 1) {
        wincache.cacheSizeHints(i, .{ .min_width = @intCast(320 + @as(u32, i)) });
        try testing.expectEqual(@as(u32, @intCast(320 + i)), wincache.peekHints(i).min_width);
    }
    // The ceiling+1st NEW window is dropped: no entry materializes.
    wincache.cacheSizeHints(max, .{ .min_width = 999 });
    try testing.expectEqual(max, wincache.cachedWindowCount());
    try testing.expectEqual(wincache.SizeHints{}, wincache.peekHints(max));

    // Overwrites of an already-cached window remain exempt from the ceiling.
    wincache.storeTitle(0, "still writable");
    try testing.expectEqualStrings("still writable", wincache.peekTitle(0));
}
