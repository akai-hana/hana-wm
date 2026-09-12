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
const utils = @import("utils");
const constants = @import("constants");
const model_mod = @import("model");

/// Single logical type: the model's SizeHints. The former layouts.SizeHints
/// copy (with its comptime shape guard) is gone -- caching stores model
/// entries directly, so the actions.mapRequest bridge needs no conversion.
pub const SizeHints = model_mod.SizeHints;

pub const WindowData = struct {
    border: u32 = 0,
    hints: SizeHints = .{},
    /// Last BORDER_WIDTH value sent for this window; null until first sent.
    /// The optional matters: 0 is a legitimate configured width, and treating
    /// it as "never sent" would re-issue the configure forever, while treating
    /// "never sent" as 0 could skip the first send and leave a client-created
    /// non-zero width standing.
    applied_border_width: ?u16 = null,
    /// Cached _NET_WM_NAME / WM_NAME, duped into `title_alloc`. Owned: freed
    /// on overwrite (storeTitle), on removeWindow, and on deinit. The only
    /// non-POD field in the entry; every other writer touches only its own
    /// field, so no other path can leak or clobber it.
    title: []const u8 = "",
};

pub const CacheMap = std.AutoHashMap(u32, WindowData);

/// Hard upper bound on cached windows.  A normal desktop never exceeds a
/// few dozen managed windows; 512 is a generous ceiling that prevents
/// unbounded heap growth from a runaway client without impacting
/// legitimate use. Shared with icccm's focus-property cache.
const max_entries = @import("icccm").max_window_cache;

// Module-level singleton

// Null before init(), non-null for the rest of the process lifetime.
var cache: ?CacheMap = null;

/// Allocator titles are duped into; set by init alongside the map's.
var title_alloc: ?std.mem.Allocator = null;

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
    title_alloc = alloc;
}

pub fn deinit() void {
    if (cache) |*c| {
        const a = title_alloc.?;
        var it = c.iterator();
        while (it.next()) |e| freeTitle(a, e.value_ptr.title);
        c.deinit();
    }
    cache = null;
    title_alloc = null;
}

inline fn freeTitle(alloc: std.mem.Allocator, title: []const u8) void {
    if (title.len != 0) alloc.free(title);
}

/// Centralizes the get-or-put-with-default pattern for writers that don't
/// distinguish "existing" from "new".  Returns `error.CacheFull` when the
/// cache has reached `max_entries`, which callers treat like OOM (skip the
/// update gracefully).
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
    const wd = getOrPutDefault(win) catch return; // OOM: leave hints uncached.
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

/// Record `w` as the BORDER_WIDTH last sent to `win`. Returns true when the
/// entry already held exactly that value, letting callers skip a redundant
/// configure_window. Windows without a cache entry always report "changed"
/// (and gain one) so the first apply after registration is never skipped.
pub fn cacheBorderWidth(win: u32, w: u16) bool {
    const wd = getOrPutDefault(win) catch return false;
    if (wd.applied_border_width) |applied| {
        if (applied == w) return true;
    }
    wd.applied_border_width = w;
    return false;
}

/// Evict a window's entire cache entry: geometry, border dedup data, the
/// embedded WM_NORMAL_HINTS AND the cached title in one operation. No-op when
/// never cached.
pub fn removeWindow(window_id: u32) void {
    const c = live();
    if (c.getPtr(window_id)) |wd| {
        const a = title_alloc.?;
        freeTitle(a, wd.title);
        _ = c.remove(window_id);
    }
}

fn updateBorderColor(
    conn: core.Connection,
    win: u32,
    color: u32,
) bool {
    // Bounded by max_entries like every other writer: refuse to grow past
    // the ceiling so WM-churn of distinct windows can't bloat the cache
    // (the caller falls back to an unconditional send in that case).
    const wd = getOrPutDefault(win) catch return false;
    if (wd.border == color) return true;
    wd.border = color;
    utils.setBorderPixel(conn, win, color);
    return true;
}

/// Sends the border-pixel change for `win` unless the cache already shows
/// that exact color as applied, and RECORDS the color either way. The
/// recording is load-bearing, not just an optimization: values forced
/// outside this function (fullscreen's pixel 0) must end up in the cache,
/// or the next real color change dedups against a stale value and is
/// silently skipped -- the un-fullscreen "lost borders" bug. Returns false
/// only when the cache is unavailable (not initialized); callers then fall
/// back to an unconditional send.
pub fn sendBorderColorIfChanged(win: u32, color: u32) bool {
    const conn = core.getState().conn;
    return updateBorderColor(conn, win, color);
}

// ---------------------------------------------------------------------------
// Window-title cache
// ---------------------------------------------------------------------------

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
    net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch null;
    utf8_string = utils.getAtomCached("UTF8_STRING") catch null;
}

/// Fires both title queries without waiting (no flush: the caller's batch
/// flush follows). Both are always requested up-front so the legacy WM_NAME
/// fallback never costs an extra round-trip; when the UTF-8 title exists the
/// WM_NAME reply is simply ignored.
pub fn fireTitleCookies(conn: core.Connection, win: u32) TitleCookies {
    ensureAtoms();
    const utf_type = utf8_string orelse xcb.XCB_ATOM_STRING;
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
    ensureAtoms();
    const utf_type = utf8_string orelse xcb.XCB_ATOM_STRING;
    var buf: [title_fetch_len]u8 = undefined;

    var title: ?[]const u8 = null;
    if (net_wm_name != null) {
        title = takePropertyReply(conn, cookies.net_wm, utf_type, &buf);
    }
    if (title == null or title.?.len == 0) {
        title = takePropertyReply(conn, cookies.wm_name, xcb.XCB_ATOM_STRING, &buf);
    }
    storeTitle(win, title orelse "");
}

/// Standalone refresh for one renamed window (PropertyNotify path). Blocking,
/// but single-window and rare -- never in the draw path.
pub fn refreshTitle(conn: core.Connection, win: u32) bool {
    const cookies = fireTitleCookies(conn, win);
    ensureAtoms();
    const utf = utf8_string orelse xcb.XCB_ATOM_STRING;
    var buf: [title_fetch_len]u8 = undefined;

    var title: []const u8 = "";
    if (net_wm_name != null) {
        if (takePropertyReply(conn, cookies.net_wm, utf, &buf)) |t| title = t;
    }
    if (title.len == 0) {
        if (takePropertyReply(conn, cookies.wm_name, xcb.XCB_ATOM_STRING, &buf)) |t| title = t;
    }
    if (std.mem.eql(u8, title, peekTitle(win))) return false;
    storeTitle(win, title);
    return true;
}

/// Reads a single in-batch get_property reply into `buf`. Mirrors
/// `utils.fetchPropertyToBuffer`'s validation (8-bit encoded, matching
/// property type) but consumes an already-fired cookie instead of issuing its
/// own request, so it can ride the pipelined admission batch.
fn takePropertyReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_property_cookie_t,
    atom_type: u32,
    buf: []u8,
) ?[]const u8 {
    const reply = utils.collectPropertyReply(conn, cookie) orelse return null;
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
fn storeTitle(win: u32, title: []const u8) void {
    const alloc = title_alloc orelse return;
    const c = live();
    const owned = alloc.dupe(u8, title) catch return;
    if (c.getPtr(win)) |wd| {
        freeTitle(alloc, wd.title);
        wd.title = owned;
        return;
    }
    // New entry: the shared getOrPutDefault path enforces the at-capacity
    // drop; overwrites above stay exempt from the ceiling.
    const wd = getOrPutDefault(win) catch {
        alloc.free(owned);
        return;
    };
    wd.title = owned;
}

/// The bar's read path: the cached title for `win`, or "" when absent.
/// Pure cache hit -- never touches the wire.
pub fn peekTitle(win: u32) []const u8 {
    const wd = dataFor(win) orelse return "";
    return wd.title;
}

test "peekTitle returns cached OR-set title" {
    const alloc = std.testing.allocator;
    init(alloc);
    defer deinit();

    try std.testing.expectEqualStrings("", peekTitle(7));
    storeTitle(7, "hello");
    try std.testing.expectEqualStrings("hello", peekTitle(7));
    storeTitle(7, "edited");
    try std.testing.expectEqualStrings("edited", peekTitle(7));
    removeWindow(7);
    try std.testing.expectEqualStrings("", peekTitle(7));
}
