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

    // Fill past the ceiling with size-hint writes (the shared getOrPutDefault
    // path enforces the cap).
    var i: u32 = 0;
    while (i < max) : (i += 1) {
        wincache.cacheSizeHints(i, .{ .min_width = @intCast(320 + @as(u32, i)) });
        try testing.expectEqual(@as(u32, @intCast(320 + i)), wincache.peekHints(i).min_width);
    }
    // The ceiling+1st NEW window is dropped: no entry materializes.
    wincache.cacheSizeHints(max, .{ .min_width = 999 });
    if (wincache.getOpt()) |c|
        try testing.expectEqual(max, c.count());
    try testing.expectEqual(wincache.SizeHints{}, wincache.peekHints(max));

    // Overwrites of an already-cached window remain exempt from the ceiling.
    wincache.storeTitle(0, "still writable");
    try testing.expectEqualStrings("still writable", wincache.peekTitle(0));
}
