//! Headless title_cache tests (pure cache paths only).
//!
//! Everything here runs without an X connection: the cache's entry lifecycle
//! (title ownership, at-capacity drop) is pure allocation bookkeeping,
//! so the leak-checking testing allocator pins it. The wire-touching half
//! (fireTitleCookies/collectTitleCookies and the
//! border-width dedup, which lives in the sync ledger) needs a live
//! display and stays in the integration layer. Size hints are NOT tested
//! here: they have a single store (the model entry, threaded through
//! admission as a parameter), so there is no cache path to pin.

const std = @import("std");
const testing = std.testing;

const title_cache = @import("title_cache");

// The title is a fixed inline buffer, so there is no ownership to free --
// which is the point. What is pinned here is the copy semantics and the
// truncation bound of that buffer.
test "title store: overwrite replaces in place, remove clears, oversize truncates" {
    const alloc = std.testing.allocator;
    title_cache.init(alloc);
    defer title_cache.deinit();

    title_cache.storeTitle(7, "hello");
    try testing.expectEqualStrings("hello", title_cache.peekTitle(7));
    title_cache.storeTitle(7, "edited");
    try testing.expectEqualStrings("edited", title_cache.peekTitle(7));
    title_cache.removeWindow(7);
    try testing.expectEqualStrings("", title_cache.peekTitle(7));
    // Non-cached window and double remove are no-ops.
    title_cache.removeWindow(7);
    title_cache.storeTitle(99, "");
    try testing.expectEqualStrings("", title_cache.peekTitle(99));

    // Truncation at the inline bound: a title longer than the buffer is cut,
    // and the result is a valid slice (sliced by title_len, not terminator-
    // terminated), so nothing reads past what was stored.
    var long: [1024]u8 = @splat('x');
    long[0] = 'a';
    title_cache.storeTitle(7, &long);
    const got = title_cache.peekTitle(7);
    try testing.expectEqual(@as(usize, 256), got.len);
    try testing.expectEqual(@as(u8, 'a'), got[0]);
    try testing.expectEqual(@as(u8, 'x'), got[255]);

    // A short title after a long one is NOT padded with the old bytes: the
    // length is authoritative, so the stale tail cannot leak into the read.
    title_cache.storeTitle(7, "short");
    try testing.expectEqualStrings("short", title_cache.peekTitle(7));
}

test "at-capacity cache drops new entries but keeps overwrites" {
    const alloc = std.testing.allocator;
    title_cache.init(alloc);
    defer title_cache.deinit();

    const max = @import("idmap").max_window_cache;

    // Fill past the ceiling with title writes (the fixed-capacity IdMap
    // enforces the cap; key 0 is its never-used sentinel, so the ids here
    // start at 1, matching the real XIDs production feeds it).
    var i: u32 = 1;
    while (i <= max) : (i += 1) {
        title_cache.storeTitle(i, "fill");
        try testing.expectEqualStrings("fill", title_cache.peekTitle(i));
    }
    // The ceiling+1st NEW window is dropped: no entry materializes.
    title_cache.storeTitle(max + 1, "dropped");
    try testing.expectEqual(max, title_cache.cachedWindowCount());
    try testing.expectEqualStrings("", title_cache.peekTitle(max + 1));

    // Overwrites of an already-cached window remain exempt from the ceiling.
    title_cache.storeTitle(1, "still writable");
    try testing.expectEqualStrings("still writable", title_cache.peekTitle(1));
}
