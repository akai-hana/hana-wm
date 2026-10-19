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
const atoms = @import("atoms");

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

test "title store: an oversize title never ends mid-character" {
    const alloc = std.testing.allocator;
    title_cache.init(alloc);
    defer title_cache.deinit();

    // The cap's last byte is the lead byte of a 3-byte character: a plain
    // byte cut would store an invalid UTF-8 tail, which Pango rejects by
    // painting nothing -- the blank title segment this guards against.
    var long: [300]u8 = @splat('a');
    long[255] = 0xE2; // U+2192 RIGHTWARDS ARROW, split by the 256-byte cap
    long[256] = 0x86;
    long[257] = 0x92;
    title_cache.storeTitle(3, &long);
    const got = title_cache.peekTitle(3);
    try testing.expectEqual(@as(usize, 255), got.len);
    try testing.expectEqualSlices(u8, long[0..255], got);
    try testing.expect(std.unicode.utf8ValidateSlice(got));

    // An ASCII-only oversize title still uses the full buffer: the trim only
    // ever removes a partial trailing character.
    var ascii: [300]u8 = @splat('x');
    ascii[0] = 'z';
    title_cache.storeTitle(4, &ascii);
    const got_ascii = title_cache.peekTitle(4);
    try testing.expectEqual(@as(usize, 256), got_ascii.len);
    try testing.expectEqual(@as(u8, 'z'), got_ascii[0]);
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

// ---------------------------------------------------------------------------
// Title-atom latch (P1-37). `ensureAtoms` used to latch `atoms_resolved = true`
// BEFORE reading the atom cache, so a null answer (atom cache not ready yet)
// disabled _NET_WM_NAME for the entire session. The latch rule: only a full
// answer latches; init/deinit drop the latch with everything else. Both
// sequences need a primed-then-cleared atom cache, driven through the
// `atoms.swapAtomCacheForTest` seam (restored on defer, so a real cache a
// prior test installed in this process survives).

test "title atoms: a null answer never latches; the retry resolves later" {
    const saved = atoms.swapAtomCacheForTest(null);
    defer _ = atoms.swapAtomCacheForTest(saved);
    title_cache.init(std.testing.allocator);
    defer title_cache.deinit();

    // Atom cache not ready: both lookups answer null. The pre-fix latch
    // recorded resolved=true HERE and _NET_WM_NAME was dead from then on.
    const cold = title_cache.resolveTitleAtomsForTest();
    try testing.expect(!cold.resolved);
    try testing.expectEqual(@as(?u32, null), cold.net_wm_name);
    try testing.expectEqual(@as(?u32, null), cold.utf8_string);

    // Cache becomes ready (initAtomCache in production): the next attempt
    // must pick up what the null attempt gave up on.
    var primed = std.mem.zeroes(atoms.AtomCache);
    primed._NET_WM_NAME = 42;
    primed.UTF8_STRING = 43;
    _ = atoms.swapAtomCacheForTest(primed);
    const warm = title_cache.resolveTitleAtomsForTest();
    try testing.expect(warm.resolved);
    try testing.expectEqual(@as(?u32, 42), warm.net_wm_name);
    try testing.expectEqual(@as(?u32, 43), warm.utf8_string);
}

test "title atoms: a deinit()+init() cycle drops a primed latch (cleared cache)" {
    const saved = atoms.swapAtomCacheForTest(null);
    defer _ = atoms.swapAtomCacheForTest(saved);

    title_cache.init(std.testing.allocator);
    // Prime and resolve: the latch now holds real ids...
    var primed = std.mem.zeroes(atoms.AtomCache);
    primed._NET_WM_NAME = 77;
    primed.UTF8_STRING = 78;
    _ = atoms.swapAtomCacheForTest(primed);
    const warm = title_cache.resolveTitleAtomsForTest();
    try testing.expect(warm.resolved);
    try testing.expectEqual(@as(?u32, 77), warm.net_wm_name);

    // ...then the cache is cleared and the module cycles. A latch surviving
    // deinit()/init() would still report the stale ids as resolved; with the
    // reset it re-asks, sees null, and does not latch again.
    _ = atoms.swapAtomCacheForTest(null);
    title_cache.deinit();
    title_cache.init(std.testing.allocator);
    defer title_cache.deinit();
    const cold = title_cache.resolveTitleAtomsForTest();
    try testing.expect(!cold.resolved);
    try testing.expectEqual(@as(?u32, null), cold.net_wm_name);

    // And a fresh cycle resolves again once the atoms are back.
    _ = atoms.swapAtomCacheForTest(primed);
    const again = title_cache.resolveTitleAtomsForTest();
    try testing.expect(again.resolved);
    try testing.expectEqual(@as(?u32, 77), again.net_wm_name);
}
