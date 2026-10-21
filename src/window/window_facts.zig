//! Per-window cache for window metadata — the single source of truth for
//! window titles. Admission fires _NET_WM_NAME + WM_NAME as part of the
//! pipelined admission cookie batch and caches the winner per window id; a
//! title PropertyNotify re-fetches that one window. The bar reads via
//! peekTitle() — a cache hit, no X11 on the draw path, and no positional
//! title slot anywhere, so a fetch can never land on the wrong window.
//! Geometry remains in the model/sync ledger.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const icccm = @import("icccm");
const atoms = @import("atoms");
const requests = @import("requests");
const idmap = @import("idmap");

/// Hard cap on a cached title, in bytes; longer titles are truncated at
/// store time (`setTitle`). Sized from the consumer: the bar truncates for
/// display against the available width, so the tail of a long title is never
/// rendered, and the inline buffer costs `max_window_cache` (512) x this, so
/// a bigger buffer would only buy bytes no reader can see.
pub const max_title_len = 256;

const WindowData = struct {
    /// Cached _NET_WM_NAME / WM_NAME in a fixed inline buffer: POD
    /// storage, no allocator, no free paths -- `removeWindow`/`deinit` are
    /// plain map operations and no title rewrite can leak.
    title_buf: [max_title_len]u8 = @splat(0),
    title_len: u16 = 0,

    fn title(self: *const WindowData) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// Hard upper bound on cached windows: the store is a fixed-capacity
/// `IdMap`, so this ceiling bounds memory outright — no heap, no growth
/// path. A normal desktop never exceeds a few dozen managed windows; 512
/// prevents a runaway client from costing unbounded memory. Shared with
/// icccm's focus-property cache.
///
/// Deliberately ABOVE the model's store_capacity, not equal to it: an
/// unmapped or never-admitted client can still deliver property
/// notifications and earn a cache entry, so sizing the cache AT the model
/// bound would let transient clients evict live entries and make the cache
/// the binding constraint where the model is meant to be.
const max_entries = idmap.max_window_cache;

// Module-level singleton: always-valid and allocation-free. Before init()
// (and after deinit()) it is simply empty — peeks miss and writes land — so
// there is no lifecycle guard to get wrong.
var cache: idmap.IdMap(WindowData, max_entries) = .{};

/// How many windows currently hold a cache entry (0 before init). Bare
/// integer so the map type stays private to this file; a test that needs
/// evidence the ceiling dropped an entry rather than overwriting one reads
/// this.
pub fn cachedWindowCount() usize {
    return cache.count();
}

/// Allocation-free store: nothing to release, so init/deinit only reset the
/// table AND the latched title-atom resolution (a deinit()+init() cycle must
/// not carry stale titles or stale atom ids over). The ignored allocator
/// keeps the standard module-lifecycle signature window.init calls.
pub fn init(_: std.mem.Allocator) void {
    cache.clear();
    resetAtoms();
}

pub fn deinit() void {
    cache.clear();
    resetAtoms();
}

/// Evict a window's entire cache entry. No-op when never cached.
pub fn removeWindow(window_id: u32) void {
    _ = cache.remove(window_id);
}

const property_no_delete = icccm.property_no_delete;

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
    // `getAtomCached` answers null only while the atom cache is NOT READY
    // yet (a transient boot/test ordering) — never "the server lacks the
    // atom": interning is all-or-nothing at `atoms.initAtomCache`, and a
    // failure there aborts init. Latching that null before success would
    // permanently disable _NET_WM_NAME for the whole session, so only a full
    // answer latches and the null is retried next time.
    const name = atoms.getAtomCached("_NET_WM_NAME") orelse return;
    const utf = atoms.getAtomCached("UTF8_STRING") orelse return;
    net_wm_name = name;
    utf8_string = utf;
    atoms_resolved = true;
}

/// Drop the latched title-atom resolution with the rest of the module state:
/// the restart discipline above promises a deinit()+init() cycle starts
/// empty, and the atom ids belong to that cycle as much as the titles do —
/// a latch surviving a restart would carry the previous session's
/// resolution into a fresh one.
fn resetAtoms() void {
    atoms_resolved = false;
    net_wm_name = null;
    utf8_string = null;
}

/// Test seam: run the lazy atom resolution NOW and report what it latched.
/// The production callers (`fireTitleCookies`/`pickTitle`) only reach
/// `ensureAtoms` through a live connection, so the latch rule (a null answer
/// must NOT latch) is otherwise unobservable headless.
pub fn resolveTitleAtomsForTest() struct { resolved: bool, net_wm_name: ?u32, utf8_string: ?u32 } {
    ensureAtoms();
    return .{
        .resolved = atoms_resolved,
        .net_wm_name = net_wm_name,
        .utf8_string = utf8_string,
    };
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
            max_title_len,
        ),
        .wm_name = xcb.xcb_get_property(
            conn,
            property_no_delete,
            win,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            0,
            max_title_len,
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
    var buf: [max_title_len]u8 = undefined;
    storeTitle(win, pickTitle(conn, cookies, &buf));
}

/// Standalone refresh for one renamed window (PropertyNotify path). Blocking,
/// but single-window and rare -- never in the draw path.
pub fn refreshTitle(conn: core.Connection, win: u32) bool {
    const cookies = fireTitleCookies(conn, win);
    var buf: [max_title_len]u8 = undefined;
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
    // The fetch asks for `max_title_len` 32-bit units — four bytes each — so
    // a long title's reply can outrun this buffer. Truncate to the buffer
    // instead of refusing the reply: a `len > buf.len` guard would drop BOTH
    // properties (the WM_NAME fallback goes through the same check), so the
    // longest titles — exactly the ones the bar most needs to show — get a
    // blank segment. `setTitle` owns the final bound and the
    // character-boundary trim; this copy just feeds it the head of the value.
    const n = @min(len, buf.len);
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    @memcpy(buf[0..n], value_ptr[0..n]);
    return buf[0..n];
}

/// Caches `title` for `win` by copying it into the entry's inline buffer
/// (POD storage, no heap, no free). Public because it is the cache's write
/// side (the pipelined admission path reaches it through
/// `collectTitleCookies`), which `window_facts_test` exercises for the
/// overwrite/cap lifecycle.
///
/// THE AT-CAPACITY POLICY, in one place: a full store drops a NEW window's
/// title rather than evicting an existing one — overwrites of already-cached
/// windows hit `getPtr` first and are exempt from the ceiling. Caching is an
/// optimization and every reader has a correct fall-through, so a dropped
/// entry costs a slower path, never a wrong answer. A writer whose value
/// MUST reach the server never goes through here at all: border-pixel/width
/// dedup asks the sent ledger instead
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
///
/// The cut can land inside a multi-byte UTF-8 sequence (the wire reply is
/// first truncated to this buffer, and the reply may itself end mid-char).
/// Pango rejects an invalid UTF-8 slice outright by painting nothing — the
/// blank title segment this guards against — so back the cut up to the last
/// whole character: walk off any trailing continuation bytes to their lead,
/// then drop that lead too when its sequence does not fit the kept bytes.
/// A complete title is returned unchanged; ASCII reaches at most one
/// non-continuation test.
fn setTitle(wd: *WindowData, title: []const u8) void {
    // Completeness is judged against the CUT end, not the source tail: a
    // source longer than the buffer may well hold the continuation bytes we
    // already refused to keep.
    const cut_end: usize = @min(title.len, max_title_len);
    var n = cut_end;
    while (n > 0 and (title[n - 1] & 0xC0) == 0x80) n -= 1;
    if (n > 0) {
        const lead = title[n - 1];
        const seq_len: usize = if (lead < 0x80)
            1
        else if (lead & 0xE0 == 0xC0)
            2
        else if (lead & 0xF0 == 0xE0)
            3
        else if (lead & 0xF8 == 0xF0)
            4
        else
            1; // invalid lead: keep the byte; the title is already invalid
        if (n - 1 + seq_len > cut_end) n -= 1; // incomplete tail: drop the lead
    }
    @memcpy(wd.title_buf[0..n], title[0..n]);
    wd.title_len = @intCast(n);
}

/// The bar's read path: the cached title for `win`, or "" when absent.
/// Pure cache hit — never touches the wire.
///
/// ## BORROW CONTRACT
///
/// The returned slice ALIASES the cache's own `title_buf` for `win`. It is
/// valid until the next `storeTitle`/`setTitle` for that SAME window, and
/// nothing in the type says so, which is why the bar copies instead of
/// retaining (see `focused_title_buf`). A caller that needs the title to
/// survive a cache write must copy it — there is no ownership transfer
/// here and the "" for an unknown window is a static string.
pub fn peekTitle(win: u32) []const u8 {
    const wd = cache.getPtr(win) orelse return "";
    return wd.title();
}
