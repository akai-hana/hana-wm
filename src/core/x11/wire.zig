//! X11 wire primitives (D6 split from utils.zig): the ONLY xcb-dependent
//! half. Atom cache, EWMH root advertisement, property fetchers, and the
//! configure/raise/grab/offscreen request shims that sync's sink and the
//! allowlisted entry points call. Pure geometry (Rect/Margins/scaling)
//! stays in utils.zig so model/tiling never import this file.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const debug = @import("debug");
const utils = @import("utils");

const max_property_length = constants.property_max_length;
/// Passed as the `delete` argument to xcb_get_property; 0 means do not consume the property.
const property_no_delete = constants.property_no_delete;

// ---------------------------------------------------------------------------
// Geometry <-> wire conversions

/// Builds a Rect from a get_geometry reply (moved out of Rect so the pure
/// geometry type in utils.zig stays xcb-free (D6 layer boundary).
pub inline fn rectFromXcb(geom: *const xcb.xcb_get_geometry_reply_t) utils.Rect {
    return .{ .x = geom.x, .y = geom.y, .width = geom.width, .height = geom.height, .border_width = geom.border_width };
}

// ---------------------------------------------------------------------------
// Configure/raise/park primitives

/// Moves and resizes `win` without touching border_width.
pub inline fn configureWindow(conn: core.Connection, win: u32, rect: utils.Rect) void {
    _ = xcb.xcb_configure_window(
        conn,
        win,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &[_]u32{ utils.toXcbCoord(rect.x), utils.toXcbCoord(rect.y), rect.width, rect.height },
    );
}

pub inline fn raiseWindow(conn: core.Connection, win: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub inline fn setBorderPixel(conn: core.Connection, win: u32, pixel: u32) void {
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{pixel});
}

// X server grab state
//
// The grab body runs on the main WM thread; grabServer/ungrabServer bracket
// every reconcile batch so the queued request run reaches the server
// atomically (zero-round-trip rule).

/// Always pair with ungrabServer()/ungrabAndFlush().
pub inline fn grabServer(conn: core.Connection) void {
    _ = xcb.xcb_grab_server(conn);
}

/// Releases the X server grab without flushing pending requests.
pub inline fn ungrabServer(conn: core.Connection) void {
    _ = xcb.xcb_ungrab_server(conn);
}

/// Defined here so every module can share one copy.
pub inline fn ungrabAndFlush(conn: core.Connection) void {
    ungrabServer(conn);
    _ = xcb.xcb_flush(conn);
}

// ---------------------------------------------------------------------------
// Atom cache
//
// Field names match X11 atom strings exactly, so getAtomCached resolves
// them with a single @field call: no switch, no enum, no second place to
// add entries when a new atom is needed.
const AtomCache = struct {
    WM_PROTOCOLS: u32,
    WM_DELETE_WINDOW: u32,
    WM_TAKE_FOCUS: u32,
    _NET_WM_NAME: u32,
    UTF8_STRING: u32,
    WM_CLASS: u32,
    // Root window EWMH-conformance atoms, see advertiseEwmhSupport() below.
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
    // X resource-database atom: read by scale.zig for Xft.dpi.
    RESOURCE_MANAGER: u32,
};

var atom_cache: ?AtomCache = null;

/// Interns all atoms in a single round-trip batch. Atom names come from
/// `AtomCache`'s field names at comptime, so adding a field is the only
/// change required, no parallel array, no index-order mismatch risk.
pub fn initAtomCache(conn: core.Connection) !void {
    const fields = std.meta.fields(AtomCache);
    var cookies: [fields.len]xcb.xcb_intern_atom_cookie_t = undefined;

    inline for (fields, 0..) |f, i|
        cookies[i] = xcb.xcb_intern_atom(conn, 0, @intCast(f.name.len), f.name.ptr);

    var cache: AtomCache = undefined;
    inline for (fields, 0..) |f, i| {
        const reply = xcb.xcb_intern_atom_reply(conn, cookies[i], null) orelse {
            for (i + 1..fields.len) |j| xcb.xcb_discard_reply(conn, cookies[j].sequence);
            return error.AtomFailed;
        };
        defer std.c.free(reply);
        @field(cache, f.name) = reply.*.atom;
    }
    atom_cache = cache;
}

/// Looks up a cached atom by name.
/// Unknown names produce a compile error rather than a silent runtime failure.
pub inline fn getAtomCached(comptime name: []const u8) error{AtomCacheNotInitialized}!u32 {
    comptime if (!@hasField(AtomCache, name)) @compileError("atom not in cache: " ++ name);
    const cache = atom_cache orelse return error.AtomCacheNotInitialized;
    return @field(cache, name);
}

/// Like getAtomCached but returns 0 (the X11 "no atom" sentinel) instead of
/// erroring when the cache isn't ready. Callers guard `if (atom != 0)` before
/// issuing an X request.
pub inline fn getAtomOrZero(comptime name: []const u8) u32 {
    return getAtomCached(name) catch 0;
}

// ---------------------------------------------------------------------------
// EWMH root window advertisement

/// EWMH atoms hana declares via `_NET_SUPPORTED`. Every entry must correspond
/// to a protocol hana genuinely honours; clients use this list to decide what
/// they can rely on.
///
/// Notably fixes GLFW's "Iconification of full screen windows requires a WM
/// that supports EWMH full screen" error (Minecraft and other LWJGL games):
/// GLFW only fullscreens via `_NET_WM_STATE_FULLSCREEN` if that atom is
/// listed here; otherwise it falls back to a raw override-redirect window that
/// bypasses the WM and can't be iconified through it, so the next
/// XIconifyWindow() throws that error.
const supported_atoms = [_][]const u8{
    "_NET_SUPPORTED",
    "_NET_SUPPORTING_WM_CHECK",
    "_NET_WM_NAME",
    "_NET_WM_STATE",
    "_NET_WM_STATE_FULLSCREEN",
    "_NET_WM_STATE_ABOVE",
    "_NET_WM_STATE_STICKY",
    "_NET_WM_ALLOWED_ACTIONS",
    "_NET_WM_ACTION_CLOSE",
    "_NET_WM_ACTION_ABOVE",
    "_NET_WM_ACTION_STICK",
    "_NET_WM_PID",
    "_NET_WM_WINDOW_TYPE",
    "_NET_WM_WINDOW_TYPE_DOCK",
    "_NET_WM_STRUT_PARTIAL",
};

/// Publishes hana's EWMH conformance on the root window: per the spec a
/// conformant WM creates a small identity ("check") window, tags it and the
/// root with `_NET_SUPPORTING_WM_CHECK`, gives it a `_NET_WM_NAME`, and lists
/// every honour-able hint in `_NET_SUPPORTED`. Clients (GLFW, Qt, Chromium, ...)
/// probe this once at startup; without it they assume a bare ICCCM-only WM and
/// take more conservative, in GLFW's case broken, code paths (see
/// `supported_atoms`).
///
/// Must run once at startup, after initAtomCache() and before any client can
/// map a window.
///
/// Known gaps between `_NET_SUPPORTED` and full behaviour: document, don't
/// narrow; external tools key on the listed hints, and the list above is
/// what keeps GLFW/Qt/Chromium out of their broken fallback paths.
///
/// - The only client messages answered are `_NET_WM_STATE` with the
///   fullscreen atom (ADD/REMOVE/TOGGLE). `_NET_ACTIVE_WINDOW`,
///   `_NET_CLOSE_WINDOW`, `_NET_CURRENT_DESKTOP`, and `_NET_WM_DESKTOP`
///   requests are ignored.
/// - `_NET_ACTIVE_WINDOW` is written (root property tracks our focus) but
///   never read or requested via client message.
/// - `_NET_CLIENT_LIST`/`_NET_CLIENT_LIST_STACKING` are not maintained;
///   pagers cannot enumerate clients.
/// - `_NET_WM_STATE_HIDDEN`/`_NET_WM_STATE_DEMANDS_ATTENTION` are neither
///   advertised nor answered; minimize is internal-only (no state property).
/// - `_NET_WORKAREA` is absent; clients wanting dock-safe geometry must use
///   `_NET_STRUT_PARTIAL` feedback instead.
pub fn advertiseEwmhSupport(conn: core.Connection, screen: core.Screen, root: u32) void {
    const supporting_wm_check = getAtomCached("_NET_SUPPORTING_WM_CHECK") catch return;
    const net_wm_name = getAtomCached("_NET_WM_NAME") catch return;
    const utf8_string = getAtomCached("UTF8_STRING") catch return;
    const net_supported = getAtomCached("_NET_SUPPORTED") catch return;

    // A small, invisible identity window. Override-redirect so hana's own
    // SubstructureRedirect handling never tries to manage it as a client.
    const check_win = xcb.xcb_generate_id(conn);
    const depth: u8 = xcb.XCB_COPY_FROM_PARENT;
    const value_mask = xcb.XCB_CW_OVERRIDE_REDIRECT;
    const value_list = [_]u32{1};
    _ = xcb.xcb_create_window(
        conn,
        depth,
        check_win,
        root,
        -1,
        -1,
        1,
        1,
        0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen.root_visual,
        @intCast(value_mask),
        &value_list,
    );

    // Identity dance required by the spec: the check window points at
    // itself, and the root points at the check window. Clients compare the
    // two `_NET_SUPPORTING_WM_CHECK` values to tell a live WM from a stale
    // property a crashed WM left behind.
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, check_win, supporting_wm_check, xcb.XCB_ATOM_WINDOW, 32, 1, &check_win);
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, root, supporting_wm_check, xcb.XCB_ATOM_WINDOW, 32, 1, &check_win);

    const wm_name = "hana";
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, check_win, net_wm_name, utf8_string, 8, @intCast(wm_name.len), wm_name.ptr);

    var supported: [supported_atoms.len]xcb.xcb_atom_t = undefined;
    inline for (supported_atoms, 0..) |name, i|
        supported[i] = getAtomCached(name) catch xcb.XCB_ATOM_NONE;
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, root, net_supported, xcb.XCB_ATOM_ATOM, 32, @intCast(supported.len), &supported);
}

// ---------------------------------------------------------------------------
// Reply collection (poll-first)

/// Collects the reply for an already-fired request, trying a non-blocking
/// poll first and falling back to the typed blocking collector only when the
/// reply isn't buffered yet. One entry point for every request kind: each
/// `xcb_*_cookie_t` wraps just a sequence number, so the poll works off
/// `cookie.sequence` and the original cookie object flows to the blocking
/// call unchanged.
///
/// Poll semantics: `xcb_poll_for_reply` consumes the cookie on BOTH success
/// and error, so a plain "null means block" contract is unsound; blocking
/// on a consumed-error cookie has undefined XCB semantics. An X error seen
/// here is freed and reported as plain failure; after it, the cookie must
/// never be touched again.
///
/// `blockingReply` issues the request's blocking reply call (passing null for
/// the error out-param, exactly like every pre-absorption call site) and
/// returns the owned reply pointer or null. Typed wrappers below cast the
/// result back so callers never see `*anyopaque`.
fn collectReply(
    conn: core.Connection,
    cookie: anytype,
    comptime blockingReply: anytype,
) ?*anyopaque {
    var reply: ?*anyopaque = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(conn, cookie.sequence, &reply, &err);
    if (reply) |r| return r;
    if (err) |e| {
        std.c.free(e);
        return null;
    }
    return blockingReply(conn, cookie);
}

fn blockingPropertyReply(conn: core.Connection, cookie: xcb.xcb_get_property_cookie_t) ?*anyopaque {
    return @ptrCast(xcb.xcb_get_property_reply(conn, cookie, null));
}

fn blockingGeometryReply(conn: core.Connection, cookie: xcb.xcb_get_geometry_cookie_t) ?*anyopaque {
    return @ptrCast(xcb.xcb_get_geometry_reply(conn, cookie, null));
}

/// Property-flavored collectReply: an owned `xcb_get_property_reply_t`, or
/// null when neither the poll nor the blocking fallback produced one.
pub fn collectPropertyReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_property_cookie_t,
) ?*xcb.xcb_get_property_reply_t {
    return @ptrCast(@alignCast(collectReply(conn, cookie, blockingPropertyReply)));
}

/// Geometry-flavored collectReply: an owned `xcb_get_geometry_reply_t`, or
/// null under the same contract.
pub fn collectGeometryReply(
    conn: core.Connection,
    cookie: xcb.xcb_get_geometry_cookie_t,
) ?*xcb.xcb_get_geometry_reply_t {
    return @ptrCast(@alignCast(collectReply(conn, cookie, blockingGeometryReply)));
}

// ---------------------------------------------------------------------------
// Property fetchers

/// Fetches an 8-bit X11 window property into the caller-supplied `buffer`.
/// Returns a slice into `buffer`, or null if the property is absent, empty,
/// not 8-bit encoded, the reply's type doesn't match the requested
/// `atom_type`, or the value exceeds the buffer length.
pub fn fetchPropertyToBuffer(
    conn: core.Connection,
    window: u32,
    atom: u32,
    atom_type: u32,
    buffer: []u8,
) !?[]const u8 {
    const reply = collectPropertyReply(
        conn,
        xcb.xcb_get_property(conn, property_no_delete, window, atom, atom_type, 0, max_property_length),
    ) orelse return null;
    defer std.c.free(reply);
    const r = reply.*;
    if (r.format != 8 or r.value_len == 0 or r.type != atom_type) return null;
    if (r.value_len == max_property_length)
        debug.warn("Property atom {x} on window {x} exceeds the {}-byte fetch cap; value truncated", .{ atom, window, max_property_length });

    const len: usize = @intCast(r.value_len);
    if (len > buffer.len) return null;
    const value_ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    @memcpy(buffer[0..len], value_ptr[0..len]);
    return buffer[0..len];
}
