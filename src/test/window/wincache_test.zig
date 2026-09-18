//! Headless wincache tests (pure cache paths only).
//!
//! Everything here runs without an X connection: the cache's entry lifecycle
//! (hints, applied-border dedup, title ownership, at-capacity drop) is pure
//! allocation bookkeeping, so the leak-checking testing allocator pins it.
//! The wire-touching half (fireTitleCookies/collectTitleCookies,
//! sendBorderColorIfChanged) needs a live display and stays in the
//! integration layer.

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

test "applied border width dedup records and reports sameness" {
    const alloc = std.testing.allocator;
    wincache.init(alloc);
    defer wincache.deinit();

    // Unseen window reports "changed" so the first configure is never skipped.
    try testing.expectEqual(false, wincache.cacheBorderWidth(11, 2));
    try testing.expectEqual(true, wincache.cacheBorderWidth(11, 2));
    // A different width reports "changed" again.
    try testing.expectEqual(false, wincache.cacheBorderWidth(11, 4));
    try testing.expectEqual(true, wincache.cacheBorderWidth(11, 4));
    // Eviction resets the applied-width memory.
    wincache.removeWindow(11);
    try testing.expectEqual(false, wincache.cacheBorderWidth(11, 4));
}

test "title ownership: overwrite frees prior, remove frees owned" {
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
}

test "at-capacity cache drops new entries but keeps overwrites" {
    const alloc = std.testing.allocator;
    wincache.init(alloc);
    defer wincache.deinit();

    const max = @import("icccm").max_window_cache;

    // Fill past the ceiling with border-width writes (the shared
    // getOrPutDefault path enforces the cap).
    var i: u32 = 0;
    while (i < max) : (i += 1) {
        try testing.expectEqual(false, wincache.cacheBorderWidth(i, 1));
    }
    // The ceiling+1st NEW window is dropped: write reports unchanged, no
    // entry materializes.
    try testing.expectEqual(false, wincache.cacheBorderWidth(max, 1));

    if (wincache.getOpt()) |c|
        try testing.expectEqual(max, c.count());

    // Overwrites of an already-cached window remain exempt from the ceiling.
    wincache.storeTitle(0, "still writable");
    try testing.expectEqualStrings("still writable", wincache.peekTitle(0));
}
