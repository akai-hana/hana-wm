//! X atom interning: the name -> atom-id table every property request reads.
//!
//! Split out of the former `wire` module, which named a transport but held a
//! client-side memo table for 40% of its length. Interning is a round trip
//! with the server's atom table, not wire I/O, and it is a distinct concern
//! from the request shims that consume the ids.

const std = @import("std");

// Imported from the leaf xcb hub (pure @cImport) rather than from `core`, so
// this layer stays a DAG root: `core` re-exports these decls upward, and
// reaching back into it here would close the loop.
const xcb = @import("xcb");
const Connection = xcb.Connection;

// Atom cache
//
// Field names match X11 atom strings exactly, so getAtomCached resolves
// them with a single @field call: no switch, no enum, no second place to
// add entries when a new atom is needed. Public so `requests.zig` can prove
// at comptime that its advertised EWMH set is a subset of these fields.
pub const AtomCache = struct {
    WM_PROTOCOLS: u32,
    WM_DELETE_WINDOW: u32,
    WM_TAKE_FOCUS: u32,
    _NET_WM_NAME: u32,
    UTF8_STRING: u32,
    WM_CLASS: u32,
    // Root window EWMH-conformance atoms, see requests.advertiseEwmhSupport.
    _NET_SUPPORTED: u32,
    _NET_SUPPORTING_WM_CHECK: u32,
    // Bar window property atoms, batched here so setWindowProperties pays
    // zero X round-trips instead of 10 serial ones.
    _NET_WM_STRUT_PARTIAL: u32,
    _NET_WM_WINDOW_TYPE: u32,
    _NET_WM_WINDOW_TYPE_DOCK: u32,
    _NET_WM_STATE: u32,
    _NET_WM_STATE_FULLSCREEN: u32,
    _NET_WM_STATE_ABOVE: u32,
    _NET_WM_STATE_STICKY: u32,
    _NET_WM_ALLOWED_ACTIONS: u32,
    _NET_WM_ACTION_CLOSE: u32,
    _NET_WM_ACTION_ABOVE: u32,
    _NET_WM_ACTION_STICK: u32,
    _NET_WM_PID: u32,
    // Root-window focus advertisement: read by focus.zig's setFocus path.
    _NET_ACTIVE_WINDOW: u32,
    // X resource-database atom: read by display/dpi.zig for Xft.dpi.
    RESOURCE_MANAGER: u32,
};

var atom_cache: ?AtomCache = null;

/// Interns all atoms in a single round-trip batch. Atom names come from
/// `AtomCache`'s field names at comptime, so adding a field is the only
/// change required, no parallel array, no index-order mismatch risk.
pub fn initAtomCache(conn: Connection) !void {
    const fields = std.meta.fields(AtomCache);
    var cookies: [fields.len]xcb.xcb.xcb_intern_atom_cookie_t = undefined;

    inline for (fields, 0..) |f, i|
        cookies[i] = xcb.xcb.xcb_intern_atom(conn, 0, @intCast(f.name.len), f.name.ptr);

    var cache: AtomCache = undefined;
    inline for (fields, 0..) |f, i| {
        const reply = xcb.xcb.xcb_intern_atom_reply(conn, cookies[i], null) orelse {
            for (i + 1..fields.len) |j| xcb.xcb.xcb_discard_reply(conn, cookies[j].sequence);
            return error.AtomFailed;
        };
        defer std.c.free(reply);
        @field(cache, f.name) = reply.*.atom;
    }
    atom_cache = cache;
}

/// Looks up a cached atom by name, or null when the atom cache isn't ready.
/// Unknown names produce a compile error rather than a silent runtime failure.
pub inline fn getAtomCached(comptime name: []const u8) ?u32 {
    comptime if (!@hasField(AtomCache, name)) @compileError("atom not in cache: " ++ name);
    const cache = atom_cache orelse return null;
    return @field(cache, name);
}

/// Like getAtomCached but returns 0 (the X11 "no atom" sentinel) instead of
/// null when the cache isn't ready. Callers guard `if (atom != 0)` before
/// issuing an X request.
pub inline fn getAtomOrZero(comptime name: []const u8) u32 {
    return getAtomCached(name) orelse 0;
}
