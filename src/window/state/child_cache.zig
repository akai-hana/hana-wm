//! Child XID -> managed toplevel XID cache backing findManagedWindow's fast
//! path (window.zig).
//!
//! Electron/Qt/GTK toolkits render into child windows beneath their managed
//! toplevel, so ButtonPress/EnterNotify often land on a child, not the window
//! we manage. findManagedWindow walks the X11 tree upward (each step a
//! blocking round-trip) to find the managed ancestor; this cache maps child
//! XID -> managed toplevel XID so repeat hovers cost zero XCB calls. Entries
//! are evicted when their toplevel is unmanaged (evictFor). A fixed flat
//! array is enough: Electron nests at most 3-5 children per app.
//!
//! A BoundedList needed a linear scan per lookup, and the lookup sits on the
//! slow path of a BLOCKING xcb_query_tree round trip -- a list miss cost a
//! linear scan, a hit cost a round trip saved, and at cap the append silently
//! dropped so the walk repeated forever. Keyed storage makes the hit O(1) with
//! no capacity cliff.

const idmap = @import("idmap");

/// Child-window cache ceiling: bounds findManagedWindow's child->toplevel
/// rows (a flat array; Electron/Qt nest at most a handful of children per app).
const capacity: usize = 64;

/// child XID -> managed toplevel (IdMap, not a BoundedList).
var cache: idmap.IdMap(u32, capacity) = .{};

/// Re-arm for a deinit()+init() cycle (window.init's reset discipline).
pub fn reset() void {
    cache = .{};
}

/// Record that `child` resolves to `managed` so future tree walks are skipped.
pub fn put(child: u32, managed: u32) void {
    if (child == managed) return; // direct hit, not a child, nothing to cache
    // At cap, put returns false and the entry is dropped; the tree walk
    // fallback is always correct, so a miss only costs the walk it would have
    // paid anyway.
    _ = cache.put(child, managed);
}

/// Cached child->toplevel resolution; null on miss (fresh tree walk).
pub fn get(child: u32) ?u32 {
    return cache.get(child);
}

/// Called from unmanageWindow so stale child entries don't linger.
///
/// A value-keyed sweep, which is the one thing keyed storage does NOT make
/// O(1): collect first, then remove. Removing inside the iteration would
/// tombstone slots the live iterator is walking over.
pub fn evictFor(managed_win: u32) void {
    var stale: [capacity]u32 = undefined;
    var n: usize = 0;
    var it = cache.iterator();
    while (it.next()) |item| {
        if (item.val.* != managed_win) continue;
        stale[n] = item.key;
        n += 1;
    }
    for (stale[0..n]) |child| _ = cache.remove(child);
}
