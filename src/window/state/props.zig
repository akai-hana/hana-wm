//! Per-window ICCCM focus-property cache: storage only, keyed by window ID.
//! protocol/icccm.zig owns the X11 queries and the PropertyNotify refresh
//! logic; this file owns the map and its lifecycle.
//!
//! Populated at map time, invalidated on WM_PROTOCOLS/WM_HINTS
//! PropertyNotify and on destruction. Caches accepts_input (WM_HINTS.input),
//! wm_delete (WM_DELETE_WINDOW), and take_focus (WM_TAKE_FOCUS in
//! WM_PROTOCOLS). Safe because the mask-first map ordering guarantees
//! PropertyNotify before any post-seed change can stale.

const constants = @import("constants");
const idmap = @import("idmap");

/// Per-window properties cached from WM_HINTS and WM_PROTOCOLS. Kept in
/// sync via PropertyNotify; take_focus is safe to cache because the mask-first
/// map ordering guarantees it cannot stale.
pub const CachedProps = struct {
    accepts_input: bool,
    wm_delete: bool,
    take_focus: bool,
};

// Upper bound on live cache entries. The backing IdMap is a fixed
// allocation-free open-addressed table, so lookups are O(1) even at the cap.
// Windows beyond max_window_cache still work; they just fall through to the
// live X11 path.
pub const max_window_cache: usize = constants.max_window_cache;

var cache_slots: idmap.IdMap(CachedProps, max_window_cache) = .{};

/// Drops every cache entry, at the window init/deinit boundary (init starts
/// from an empty map; deinit clears before focus/query teardown, whose
/// managed-window sweeps must not encounter a partially-valid cache). No
/// armed flag: an empty map already reads as "not yet seen" for every window,
/// so reset IS the disabled state, and nothing runs between the boundary's
/// clear and the next event-loop turn to repopulate it.
pub fn reset() void {
    cache_slots.clear();
}

/// Removes a window's cache entry on unmanage so a reused XID can't borrow a
/// stale focus verdict.
pub fn evict(win: u32) void {
    _ = cache_slots.remove(win);
}

/// Silently drops the entry when the cache is full;
/// the live-query fallback is always correct.
pub fn put(win: u32, p: CachedProps) void {
    // No warn on failure: a capacity miss only degrades that window to the
    // live-query fallback, which the docs already say is correct; a log line
    // on the property-notify hot path would be noise the reader has to
    // disprove.
    _ = cache_slots.put(win, p);
}

/// Returns cached props without triggering a live query, or null on a miss.
/// The null case means the window's WM_HINTS/WM_PROTOCOLS have not been seen
/// since the cache seeded (or the cache is full); callers fall back to a
/// live query or a pre-fired cookie.
pub fn peek(win: u32) ?CachedProps {
    return cache_slots.get(win);
}
