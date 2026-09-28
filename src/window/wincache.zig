//! Per-window window-data cache.
//! Dedupes border color/width for sync, bridges WM_NORMAL_HINTS into the
//! model, and owns the WM's per-window title cache. Geometry lives in the
//! model/sync ledger instead.
//!
//! The title cache is the single source of truth for window titles: admission
//! fires _NET_WM_NAME + WM_NAME as part of the pipelined admission cookie
//! batch and caches the winner per window id; a title PropertyNotify
//! re-fetches that one window. The bar reads via peekTitle() -- a cache hit,
//! no X11 in the draw path, and no positional title slot anywhere, so the old
//! fetch-to-wrong-window scramble cannot recur.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const model_mod = @import("model");

const atoms = @import("atoms");
const requests = @import("requests");
/// Single logical type: the model's SizeHints. The former layouts.SizeHints
/// copy (with its comptime shape guard) is gone -- caching stores model
/// entries directly, so the actions.mapRequest bridge needs no conversion.
pub const SizeHints = model_mod.SizeHints;

/// Cached-title capacity, in bytes. A title longer than this is truncated at
/// store time.
///
/// 256 is chosen from the consumer, not from the 1024-byte `title_fetch_len`
/// fetch: the bar truncates for display against the available width, so the
/// tail of a long title was never rendered anyway. Keeping the cache inline
/// costs `max_window_cache` (512) x this, so a buffer sized to the FETCH
/// rather than to the DISPLAY would have tripled the cache for bytes no
/// reader can see.
const max_title_len = 256;

const WindowData = struct {
    hints: SizeHints = .{},
    /// Cached _NET_WM_NAME / WM_NAME in a fixed inline buffer (11.5).
    ///
    /// This was heap-duped into a module allocator, which made the title the
    /// only non-POD field in the entry and bought three ownership
    /// obligations: free on overwrite, free on removeWindow, and a
    /// free-everything walk in deinit. Every one of those was a place to
    /// forget the free -- `storeTitle` had to free the fresh copy on the
    /// at-capacity path, and a missed free leaked per title rewrite, bounded
    /// by nothing but the client's patience. The entry is now POD: no
    /// allocator, no free paths, nothing to leak, and `removeWindow`/`deinit`
    /// are plain map operations.
    title_buf: [max_title_len]u8 = @splat(0),
    title_len: u16 = 0,

    fn title(self: *const WindowData) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

const CacheMap = std.AutoHashMap(u32, WindowData);

/// Hard upper bound on cached windows.  A normal desktop never exceeds a
/// few dozen managed windows; 512 is a generous ceiling that prevents
/// unbounded heap growth from a runaway client without impacting
/// legitimate use. Shared with icccm's focus-property cache.
const max_entries = constants.max_window_cache;

// Module-level singleton

// Null before init(), non-null for the rest of the process lifetime.
var cache: ?CacheMap = null;

/// Allocator titles are duped into; set by init alongside the map's.
/// Returns a pointer to the live cache. Panics in all build modes when
/// called before init(); never silent UB.
inline fn live() *CacheMap {
    if (cache) |*c| return c;
    @panic("wincache: accessed before init()");
}

/// Safe pre-init query; returns null only during the narrow startup window
/// before init().
pub inline fn getOpt() ?*CacheMap {
    return if (cache) |*c| c else null;
}

pub fn init(alloc: std.mem.Allocator) void {
    cache = CacheMap.init(alloc);
}

pub fn deinit() void {
    if (cache) |*c| c.deinit();
    cache = null;
}

/// Centralizes the get-or-put-with-default pattern for writers that don't
/// distinguish "existing" from "new".  Returns `error.CacheFull` when the
/// cache has reached `max_entries`.
///
/// THE AT-CAPACITY POLICY (11.6), in one place, because it used to be
/// re-decided per writer: a cache that is at capacity SKIPS the update and
/// carries on. Caching is an optimization -- every reader has a correct
/// fall-through -- so dropping an entry costs a slower path, never a wrong
/// answer. The two rules that follow from that, both enforced by callers:
///
///  * a writer holding a freshly allocated value frees it before returning
///    (storeTitle), and
///  * a writer whose value MUST reach the server does not go through here at
///    all. That was the third, divergent behavior: the border-pixel dedup
///    used to catch `error.CacheFull` and send unconditionally, because a
///    skipped dedup must not become a skipped send. It now asks the sent
///    ledger instead (ledger.markSentBorderPixelIfChanged), which owns that
///    "send anyway" rule on its own.
///
/// The ceiling is deliberately ABOVE the model's store_capacity, not equal to
/// it: an unmapped or never-admitted client can still deliver property
/// notifications and earn a cache entry, so sizing the cache AT the model
/// bound would let transient clients evict live entries and make the cache the
/// binding constraint where the model is meant to be.
fn getOrPutDefault(win: u32) !*WindowData {
    const c = live();
    if (c.count() >= max_entries) return error.CacheFull;
    const gop = try c.getOrPut(win);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// No-op if every field is zero (nothing declared).
pub fn cacheSizeHints(win: u32, hints: SizeHints) void {
    if (hints.isEmpty()) return;
    const wd = getOrPutDefault(win) catch return; // at capacity: skip (see getOrPutDefault)
    wd.hints = hints;
}

/// Read-only pointer to a live cache entry, or null when the cache is
/// unavailable or the window is uncached. Shared by the peek* accessors.
fn dataFor(win: u32) ?*const WindowData {
    if (getOpt()) |c| return c.getPtr(win);
    return null;
}

/// PIPELINE bridge: read-back accessor so actions can copy cached hints into
/// the model entry at registration time. Defaults when absent.
pub fn peekHints(win: u32) SizeHints {
    const wd = dataFor(win) orelse return .{};
    return wd.hints;
}

/// Evict a window's entire cache entry: border dedup data, the embedded
/// WM_NORMAL_HINTS and the cached title in one operation. No-op when never
/// cached.
pub fn removeWindow(window_id: u32) void {
    _ = live().remove(window_id);
}

// Window-title cache

/// How many bytes of a title to fetch. Generous for real titles; longer
/// titles are truncated (parity with the old bar title fetches).
const title_fetch_len: u32 = 1024;

const property_no_delete = constants.property_no_delete;

// EWMH atoms, resolved once (null when the server lacks them).
var net_wm_name: ?u32 = null;
var utf8_string: ?u32 = null;
var atoms_resolved: bool = false;

/// The two title property queries fired for a window.
pub const TitleCookies = struct {
    net_wm: xcb.xcb_get_property_cookie_t,
    wm_name: xcb.xcb_get_property_cookie_t,
};

fn ensureAtoms() void {
    if (atoms_resolved) return;
    atoms_resolved = true;
    net_wm_name = atoms.getAtomCached("_NET_WM_NAME") orelse null;
    utf8_string = atoms.getAtomCached("UTF8_STRING") orelse null;
}

/// Fires both title queries without waiting (no flush: the caller's batch
/// flush follows). Both are always requested up-front so the legacy WM_NAME
/// fallback never costs an extra round-trip; when the UTF-8 title exists the
/// WM_NAME reply is simply ignored.
pub fn fireTitleCookies(conn: core.Connection, win: u32) TitleCookies {
    ensureAtoms();
    const utf_type = utf8Type();
    return .{
        .net_wm = xcb.xcb_get_property(
            conn,
            property_no_delete,
            win,
            net_wm_name orelse 0,
            utf_type,
            0,
            title_fetch_len,
        ),
        .wm_name = xcb.xcb_get_property(
            conn,
            property_no_delete,
            win,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            0,
            title_fetch_len,
        ),
    };
}

/// Discards a fired TitleCookies pair (adoption path: failed attribute gate
/// or a window that vanished between the fire and the drain passes).
pub fn discardTitleCookies(conn: core.Connection, cookies: TitleCookies) void {
    xcb.xcb_discard_reply(conn, cookies.net_wm.sequence);
    xcb.xcb_discard_reply(conn, cookies.wm_name.sequence);
}

/// Drains a fired TitleCookies pair and caches the winner for `win`:
/// _NET_WM_NAME when it carries bytes, else the legacy WM_NAME. Blocking, so
/// it rides the admission drain exactly like the other cached properties.
pub fn collectTitleCookies(conn: core.Connection, win: u32, cookies: TitleCookies) void {
    var buf: [title_fetch_len]u8 = undefined;
    storeTitle(win, pickTitle(conn, cookies, &buf));
}

/// Standalone refresh for one renamed window (PropertyNotify path). Blocking,
/// but single-window and rare -- never in the draw path.
pub fn refreshTitle(conn: core.Connection, win: u32) bool {
    const cookies = fireTitleCookies(conn, win);
    var buf: [title_fetch_len]u8 = undefined;
    const title = pickTitle(conn, cookies, &buf);
    if (std.mem.eql(u8, title, peekTitle(win))) return false;
    storeTitle(win, title);
    return true;
}

/// The property-type atom used to query _NET_WM_NAME: prefer UTF8_STRING,
/// falling back to XCB_ATOM_STRING when the server lacks it.
inline fn utf8Type() u32 {
    return utf8_string orelse xcb.XCB_ATOM_STRING;
}

/// Picks the winning title from a fired TitleCookies pair, preferring
/// _NET_WM_NAME (queried as UTF8_STRING) over the legacy WM_NAME. Captures
/// the bytes into `buf`; returns "" when neither reply yields a valid title.
/// Shared by the pipelined admission drain and the rename-refresh path.
fn pickTitle(conn: core.Connection, cookies: TitleCookies, buf: []u8) []const u8 {
    ensureAtoms();
    var title: []const u8 = "";
    if (net_wm_name != null) {
        if (takePropertyReply(conn, cookies.net_wm, utf8Type(), buf)) |t| title = t;
    }
    if (title.len == 0) {
        if (takePropertyReply(conn, cookies.wm_name, xcb.XCB_ATOM_STRING, buf)) |t| title = t;
    }
    return title;
}

/// Reads a single in-batch get_property reply into `buf`. Mirrors
/// wire's property validation (8-bit encoded, matching property type) but
/// consumes an already-fired cookie instead of issuing its own request, so it
/// can ride the pipelined admission batch.
fn takePropertyReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_property_cookie_t,
    atom_type: u32,
    buf: []u8,
) ?[]const u8 {
    const reply = requests.collectPropertyReply(conn, cookie) orelse return null;
    defer std.c.free(reply);
    const r = reply.*;
    if (r.format != 8 or r.value_len == 0 or r.type != atom_type) return null;
    const len: usize = @intCast(r.value_len);
    if (len > buf.len) return null;
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    @memcpy(buf[0..len], value_ptr[0..len]);
    return buf[0..len];
}

/// Caches `title` for `win`, duplicating the string and freeing the previous
/// copy (if any). A full cache drops a NEW window's title rather than evicting
/// an existing one (overwrites of already-cached windows still work).
/// Public because it is the cache's write side (the pipelined admission path
/// reaches it through `collectTitleCookies`), which the headless
/// `wincache_test` exercises for the overwrite/free/cap lifecycle.
pub fn storeTitle(win: u32, title: []const u8) void {
    const c = live();
    if (c.getPtr(win)) |wd| {
        setTitle(wd, title);
        return;
    }
    // New entry: the shared getOrPutDefault path enforces the at-capacity
    // drop; overwrites above stay exempt from the ceiling.
    const wd = getOrPutDefault(win) catch return;
    setTitle(wd, title);
}

/// Copy into the inline buffer, truncating at `max_title_len`. A short title
/// does NOT need a terminator: `peekTitle` slices by `title_len`.
fn setTitle(wd: *WindowData, title: []const u8) void {
    const n = @min(title.len, max_title_len);
    @memcpy(wd.title_buf[0..n], title[0..n]);
    wd.title_len = @intCast(n);
}

/// The bar's read path: the cached title for `win`, or "" when absent.
/// Pure cache hit -- never touches the wire.
pub fn peekTitle(win: u32) []const u8 {
    const wd = dataFor(win) orelse return "";
    return wd.title();
}
