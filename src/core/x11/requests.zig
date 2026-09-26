//! X request primitives: the allowlisted home for raw `xcb_*` calls, plus the
//! documented EWMH/geometry/policy requests that sit above them.
//!
//! Split out of the former `wire` module. XCB is a request/reply protocol, so
//! this is the request layer: `configureWindow`, `raiseWindow`,
//! `setBorderPixel`, the server grab pair, the poll-first reply collector, the
//! EWMH root advertisement, and the one xcb-typed geometry adapter. Atom ids
//! come from `atoms.zig`; dispatch of these requests happens in `sink.zig`,
//! which is the sanctioned seam (see dev/scripts/check-layers.sh Rules 1-2).
//! Geometry itself stays in `architecture/model.zig` so the pure layers never
//! import this file.

const std = @import("std");

// Imported from the leaf xcb hub (pure @cImport) rather than from `core`, so
// this layer stays a DAG root: `core` re-exports these decls upward, and
// reaching back into it here would close the loop.
const xcbmod = @import("xcb");
const xcb = xcbmod.xcb;
const Connection = xcbmod.Connection;
const Screen = xcbmod.Screen;

const atoms = @import("atoms");
const model = @import("model");
const masks = @import("masks");
const log = @import("log");

// Geometry <-> wire conversions

/// Builds a model.Rect from a get_geometry reply. Deliberately on the xcb side of
/// the boundary so `model.Rect` itself stays xcb-free and the pure layers can
/// hold one; the wire border_width feeds the model.Rect's border_width.
pub inline fn rectFromXcb(reply: *const xcb.xcb_get_geometry_reply_t) model.Rect {
    return .{
        .x = reply.x,
        .y = reply.y,
        .width = reply.width,
        .height = reply.height,
        .border_width = reply.border_width,
    };
}

// Configure/raise/park primitives

/// Moves and resizes `win`, optionally merging a stack mode and/or a border
/// width into the same request (XCB consumes value slots by mask bit; the
/// extra slots are ignored when their mask bits are clear). Merging the
/// border width here collapses what would otherwise be a second configure
/// request per window on a workspace switch.
pub fn configureWindow(
    conn: Connection,
    win: u32,
    rect: model.Rect,
    stack_mode: ?u32,
    border_width: ?u16,
) void {
    var mask: u16 = xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT;
    var values = [_]u32{
        model.toXcbCoord(rect.x),
        model.toXcbCoord(rect.y),
        rect.width,
        rect.height,
        0, // border_width slot
        0, // stack_mode slot
    };
    if (border_width) |bw| {
        mask |= xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;
        values[4] = bw;
    }
    if (stack_mode) |sm| {
        mask |= xcb.XCB_CONFIG_WINDOW_STACK_MODE;
        values[5] = sm;
    }
    _ = xcb.xcb_configure_window(conn, win, mask, &values);
}

pub inline fn raiseWindow(conn: Connection, win: u32) void {
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub inline fn setBorderPixel(conn: Connection, win: u32, pixel: u32) void {
    _ = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{pixel});
}

// X server grab state
//
// The grab body runs on the main WM thread; grabServer/ungrabServer bracket
// every reconcile batch so the queued request run reaches the server
// atomically (zero-round-trip rule).

/// Always pair with ungrabAndFlush().
pub inline fn grabServer(conn: Connection) void {
    _ = xcb.xcb_grab_server(conn);
}

/// Releases the X server grab without flushing pending requests.
inline fn ungrabServer(conn: Connection) void {
    _ = xcb.xcb_ungrab_server(conn);
}

/// Defined here so every module can share one copy.
pub inline fn ungrabAndFlush(conn: Connection) void {
    ungrabServer(conn);
    _ = xcb.xcb_flush(conn);
}

/// Fires a replace-mode xcb_change_property for `value` typed `[]const T`.
/// `atom_type` is the X11 type atom; the format byte is derived from `T` (8
/// for u8, 32 for xcb_atom_t/u32). No-op when `value` is empty.
inline fn changeProperty(
    conn: Connection,
    win: u32,
    atom: u32,
    comptime T: type,
    atom_type: u32,
    value: []const T,
) void {
    if (value.len == 0) return;
    _ = xcb.xcb_change_property(
        conn,
        xcb.XCB_PROP_MODE_REPLACE,
        win,
        atom,
        atom_type,
        @intCast(8 * @sizeOf(T)),
        @intCast(value.len),
        value.ptr,
    );
}

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

// Both lists must stay in sync at compile time: a misspelt/advertised atom
// without an AtomCache field would intern XCB_ATOM_NONE (0) and silently
// claim support for nothing. Catalogue: the advertised set is a strict
// subset of the cached fields (RESOURCE_MANAGER & friends are fetched but
// never advertised, and vice versa is a compile error).
comptime {
    @setEvalBranchQuota(100000);
    const fields = std.meta.fields(atoms.AtomCache);
    for (supported_atoms) |name| {
        var found = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, name)) found = true;
        }
        if (!found) @compileError("supported_atoms has no AtomCache field: " ++ name);
    }
}

/// Publishes hana's EWMH conformance on the root window: per the spec a
/// conformant WM creates a small identity ("check") window, tags it and the
/// root with `_NET_SUPPORTING_WM_CHECK`, gives it a `_NET_WM_NAME`, and lists
/// every honour-able hint in `_NET_SUPPORTED`. Clients (GLFW, Qt, Chromium, ...)
/// probe this once at startup; without it they assume a bare ICCCM-only WM and
/// take more conservative, in GLFW's case broken, code paths (see
/// `supported_atoms`).
///
/// Must run once at startup, after atoms.initAtomCache() and before any client
/// can map a window.
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
/// Claim SubstructureRedirectMask on the root window, which is what makes this
/// process the window manager. The X server rejects the claim if another WM
/// already holds it, so a failure here is the "another WM is running" case --
/// distinct from a broken connection and worth telling apart from it.
/// Lives here with the other wire primitives so the composition root does not
/// need its own xcb include.
pub fn claimWindowManagerRole(conn: Connection, root: u32) !void {
    const cookie = xcb.xcb_change_window_attributes_checked(
        conn,
        root,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{masks.EventMasks.root_window},
    );
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        log.err(
            "Another window manager is already running (error_code={d}, type={d})",
            .{ err.*.error_code, err.*.response_type },
        );
        std.c.free(err);
        return error.AnotherWMRunning;
    }
}

/// Flush the request queue. The one raw call left in the composition root,
/// wrapped here so main needs no xcb include of its own.
pub fn flush(conn: Connection) void {
    _ = xcb.xcb_flush(conn);
}

pub fn advertiseEwmhSupport(conn: Connection, screen: Screen, root: u32) void {
    const supporting_wm_check = atoms.getAtomCached("_NET_SUPPORTING_WM_CHECK") orelse return;
    const net_wm_name = atoms.getAtomCached("_NET_WM_NAME") orelse return;
    const utf8_string = atoms.getAtomCached("UTF8_STRING") orelse return;
    const net_supported = atoms.getAtomCached("_NET_SUPPORTED") orelse return;

    // A small, invisible identity window. Override-redirect so hana's own
    // SubstructureRedirect handling never tries to manage it as a client.
    const check_win = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_window(conn, xcb.XCB_COPY_FROM_PARENT, check_win, root, -1, -1, 1, 1, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, @intCast(xcb.XCB_CW_OVERRIDE_REDIRECT), &[_]u32{1});

    // Identity dance required by the spec: the check window points at
    // itself, and the root points at the check window. Clients compare the
    // two `_NET_SUPPORTING_WM_CHECK` values to tell a live WM from a stale
    // property a crashed WM left behind.
    changeProperty(conn, check_win, supporting_wm_check, xcb.xcb_atom_t, xcb.XCB_ATOM_WINDOW, &[_]xcb.xcb_atom_t{check_win});
    changeProperty(conn, root, supporting_wm_check, xcb.xcb_atom_t, xcb.XCB_ATOM_WINDOW, &[_]xcb.xcb_atom_t{check_win});

    const wm_name = "hana";
    changeProperty(conn, check_win, net_wm_name, u8, utf8_string, wm_name);

    var supported: [supported_atoms.len]xcb.xcb_atom_t = undefined;
    inline for (supported_atoms, 0..) |name, i|
        supported[i] = atoms.getAtomCached(name) orelse xcb.XCB_ATOM_NONE;
    changeProperty(conn, root, net_supported, xcb.xcb_atom_t, xcb.XCB_ATOM_ATOM, &supported);
}

// Reply collection (poll-first)

/// Collects the reply for an already-fired get_property request, trying a
/// non-blocking poll first and falling back to the typed blocking collector
/// only when the reply isn't buffered yet. `xcb_get_property_cookie_t` wraps
/// just a sequence number, so the poll works off `cookie.sequence` and the
/// original cookie object flows to the blocking call unchanged.
///
/// Poll semantics: `xcb_poll_for_reply` consumes the cookie on BOTH success
/// and error, so a plain "null means block" contract is unsound; blocking
/// on a consumed-error cookie has undefined XCB semantics. An X error seen
/// here is freed and reported as plain failure; after it, the cookie must
/// never be touched again.
pub fn collectPropertyReply(conn: Connection, cookie: xcb.xcb_get_property_cookie_t) ?*xcb.xcb_get_property_reply_t {
    var reply: ?*xcb.xcb_get_property_reply_t = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(conn, cookie.sequence, @ptrCast(&reply), &err);
    if (reply) |r| return r;
    if (err) |e| {
        std.c.free(e);
        return null;
    }
    return xcb.xcb_get_property_reply(conn, cookie, null);
}
