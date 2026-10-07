//! Per-window cache for window metadata.
//! Caches the window title as the single source
//! of truth. Title reads use cache-only peeks (no X11 on the draw path), with
//! pipelined batch admission (_NET_WM_NAME preferred over WM_NAME) and a
//! single-window refresh on rename. Geometry remains in the model/sync ledger.
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
const atoms = @import("atoms");
const requests = @import("requests");
const idmap = @import("idmap");

/// Cached-title capacity, in bytes. A title longer than this is truncated at
/// store time.
///
/// 256 is chosen from the consumer, not from the 1024-byte `title_fetch_len`
/// fetch: the bar truncates for display against the available width, so the
/// tail of a long title was never rendered anyway. Keeping the cache inline
/// costs `max_window_cache` (512) x this, so a buffer sized to the FETCH
/// rather than to the DISPLAY would have tripled the cache for bytes no
/// reader can see.
/// Hard cap on a cached title, so the inline buffer is a fixed size.
pub const max_title_len = 256;

const WindowData = struct {
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

/// Hard upper bound on cached windows: the store is a fixed-capacity
/// `IdMap`, so this ceiling bounds memory outright — no heap, no growth
/// path. A normal desktop never exceeds a few dozen managed windows; 512
/// is a generous ceiling that prevents a runaway client from costing
/// unbounded memory. Shared with icccm's focus-property cache.
///
/// The ceiling is deliberately ABOVE the model's store_capacity, not equal
/// to it: an unmapped or never-admitted client can still deliver property
/// notifications and earn a cache entry, so sizing the cache AT the model
/// bound would let transient clients evict live entries and make the cache
/// the binding constraint where the model is meant to be.
const max_entries = constants.max_window_cache;

// Module-level singleton: always-valid and allocation-free. Before init()
// (and after deinit()) it is simply empty — peeks miss and writes land —
// so there is no lifecycle guard to get wrong; init()/deinit() reset the
// table only, matching every other module's restart discipline.
var cache: idmap.IdMap(WindowData, max_entries) = .{};

/// How many windows currently hold a cache entry (0 before init).
///
/// (11.9) This replaces the test's `getOpt() |c| c.count()`, which forced
/// the map type out of the file as an unnameable pointer in the API surface.
/// The test wanted one integer -- the evidence that the ceiling actually
/// dropped an entry rather than overwriting one -- so the integer is what
/// is exposed.
pub fn cachedWindowCount() usize {
    return cache.count();
}

/// Allocation-free store: nothing to release, so init/deinit only reset
/// the table (a deinit()+init() cycle — session restart, test harness —
/// must not carry stale titles over). The ignored allocator keeps the
/// standard module-lifecycle signature window.init calls.
pub fn init(_: std.mem.Allocator) void {
    cache.clear();
}

pub fn deinit() void {
    cache.clear();
}

/// Evict a window's entire cache entry. No-op when never cached.
pub fn removeWindow(window_id: u32) void {
    _ = cache.remove(window_id);
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

/// Caches `title` for `win` by copying it into the entry's inline buffer
/// (POD storage, no heap, no free). Public because it is the cache's write
/// side (the pipelined admission path reaches it through
/// `collectTitleCookies`), which the headless `wincache_test` exercises for
/// the overwrite/cap lifecycle.
///
/// THE AT-CAPACITY POLICY (11.6), in one place: a full store drops a NEW
/// window's title rather than evicting an existing one — overwrites of
/// already-cached windows hit `getPtr` first and are exempt from the
/// ceiling. Caching is an optimization and every reader has a correct
/// fall-through, so a dropped entry costs a slower path, never a wrong
/// answer. A writer whose value MUST reach the server never goes through
/// here at all: border-pixel/width dedup asks the sent ledger instead
/// (`ledger.markSentBorderPixelIfChanged` owns the "send anyway" rule).
pub fn storeTitle(win: u32, title: []const u8) void {
    const wd = cache.getPtr(win) orelse blk: {
        // New entry: `put` inserts a default when the table has room and
        // reports full (false) when it does not — the drop above; overwrites
        // never reach this path.
        if (!cache.put(win, .{})) return;
        break :blk cache.getPtr(win).?;
    };
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
///
/// ## BORROW CONTRACT (11.9)
///
/// The returned slice ALIASES the cache's own `title_buf` for `win`. It is
/// valid until the next `storeTitle`/`setTitle` for that SAME window, and the
/// call is not const-correct about it: nothing in the type says so, which is
/// why the bar copies instead of retaining (see `focused_title_buf`). A caller
/// that needs the title to survive a cache write must copy it -- there is no
/// ownership transfer here and the "" for an unknown window is a static
/// string, not a per-window one.
pub fn peekTitle(win: u32) []const u8 {
    const wd = cache.getPtr(win) orelse return "";
    return wd.title();
}
