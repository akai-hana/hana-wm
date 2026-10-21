//! X request primitives: the allowlisted home for raw `xcb_*` calls, plus the
//! EWMH/geometry/policy requests that sit above them -- `raiseWindow`,
//! `setBorderPixel`, the server grab pair, the poll-first reply collector, the
//! EWMH root advertisement, and the one xcb-typed geometry adapter. Atom ids
//! come from `atoms.zig`; dispatch happens in `sink.zig`, the sanctioned seam
//! (dev/scripts/check-layers.sh Rules 1-2). Geometry itself stays in
//! `core/model.zig` so the pure layers never import this file.

const std = @import("std");

// Imported from the leaf xcb hub rather than `core`, so this layer stays a
// DAG root (`core` re-exports these decls upward; reaching back would close
// the loop).
const xcbmod = @import("xcb");
const xcb = xcbmod.xcb;
const Connection = xcbmod.Connection;
const Screen = xcbmod.Screen;

const atoms = @import("atoms");
const model = @import("model");
const masks = @import("masks");
const log = std.log.scoped(.requests);

// Geometry <-> wire conversions

/// Last OUTBOUND SEQUENCE per window, for type-0 error attribution. Unchecked
/// requests never produce a reply, so their only trace is the error
/// pseudo-event (type 0), which carries the failed request's sequence but,
/// unless resource_id happens to be the window, nothing naming WHICH window
/// the send was for. Every send site records its cookie sequence here at send
/// time. Best-effort by contract:
/// only the LAST sequence per window is kept (a batched earlier failure may
/// miss and fall back to the anonymous line), and a full ledger drops new
/// entries silently.
var last_outbound: model.Store(model.WindowId, u16, model.store_capacity) = .{};

/// Record that `win`'s most recent outbound request took sequence `seq`. XCB
/// cookies are `unsigned int` while error events echo only the low 16 bits,
/// so the tracker stores the same `@truncate` both sides compare on.
pub fn noteSequence(win: model.WindowId, seq: u32) void {
    const seq16: u16 = @truncate(seq);
    if (last_outbound.getPtr(win)) |p| {
        p.* = seq16;
        return;
    }
    _ = last_outbound.put(win, seq16) catch return;
}

/// The sequence of the last request sent to `win`, or null when nothing has
/// been sent (or the ledger was reset). Test seam.
pub fn lastSequence(win: model.WindowId) ?u16 {
    return last_outbound.get(win);
}

/// Reverse lookup for the type-0 handler: which window's last outbound
/// request carried `seq`? First match wins -- the sequence space is 16-bit and
/// wraps, so a collision can only mislabel diagnostics, never state.
pub fn windowForSequence(seq: u16) ?model.WindowId {
    for (last_outbound.keys[0..last_outbound.len], last_outbound.vals[0..last_outbound.len]) |w, s| {
        if (s == seq) return w;
    }
    return null;
}

/// Drop `win`'s record. X ids recycle: a stale sequence could mislabel a
/// future window's error. Called from reconcile.forget so both stores live and
/// die together.
pub fn forgetSequence(win: model.WindowId) void {
    _ = last_outbound.remove(win);
}

/// Test seam: re-arm between tests, like reconcile.init for its ledger.
pub fn resetOutboundTracking() void {
    last_outbound = .{};
}

/// Builds a model.Rect from a get_geometry reply. Deliberately on the xcb
/// side of the boundary so `model.Rect` stays xcb-free for the pure layers.
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

pub inline fn raiseWindow(conn: Connection, win: u32) void {
    const ck = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    noteSequence(win, ck.sequence);
}

pub inline fn setBorderPixel(conn: Connection, win: u32, pixel: u32) void {
    const ck = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{pixel});
    noteSequence(win, ck.sequence);
}

// X server grab state: grabServer/ungrabServer bracket every reconcile batch
// so the queued request run reaches the server atomically (zero-round-trip
// rule). The grab body runs on the main WM thread only.

/// Always pair with ungrabAndFlush().
pub inline fn grabServer(conn: Connection) void {
    _ = xcb.xcb_grab_server(conn);
}

/// Releases the grab, then flushes. Ungrab and flush are not separable by
/// design: flushing a request made while grabbed is what this exists to undo.
pub inline fn ungrabAndFlush(conn: Connection) void {
    _ = xcb.xcb_ungrab_server(conn);
    _ = xcb.xcb_flush(conn);
}

/// Fires a replace-mode xcb_change_property for `value` typed `[]const T`.
/// The format byte is derived from `T` (8 for u8, 32 for u32/atom). No-op
/// when `value` is empty.
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
/// to a protocol hana genuinely honours; clients decide what they can rely on
/// from this list. ADVERTISED IMPLIES HANDLED: a hint whose requests hana drops
/// sends pagers/taskbars into UI whose clicks land in a warn-once-ignored
/// branch, so the list stays narrow.
///
/// `_NET_WM_STATE_FULLSCREEN` here is what fixes GLFW's "Iconification of full
/// screen windows requires a WM that supports EWMH full screen" error
/// (Minecraft/LWJGL): without the listing GLFW falls back to a raw
/// override-redirect window the WM never manages, and XIconifyWindow() fails.
pub const supported_atoms = [_][]const u8{
    "_NET_SUPPORTED",
    "_NET_SUPPORTING_WM_CHECK",
    "_NET_WM_NAME",
    "_NET_WM_STATE",
    "_NET_WM_STATE_FULLSCREEN",
    "_NET_WM_PID",
    "_NET_CLOSE_WINDOW",
    "_NET_CURRENT_DESKTOP",
    "_NET_WM_DESKTOP",
    "_NET_ACTIVE_WINDOW",
    "_NET_WM_WINDOW_TYPE_DOCK",
    "_NET_WM_STRUT_PARTIAL",
};

// Both lists must stay in sync at compile time: an advertised atom with no
// AtomCache field would intern XCB_ATOM_NONE (0) and silently claim support
// for nothing (the advertised set is a strict subset of the cached fields).
comptime {
    for (supported_atoms) |name| {
        // @hasField is exactly the question (and the same check atoms.zig uses
        // on this field set).
        if (!@hasField(atoms.AtomCache, name)) {
            @compileError("supported_atoms has no AtomCache field: " ++ name);
        }
    }
}

/// Publishes hana's EWMH conformance on the root window: per the spec a
/// conformant WM creates a small identity ("check") window, tags it and the
/// root with `_NET_SUPPORTING_WM_CHECK`, gives it a `_NET_WM_NAME`, and lists
/// every honour-able hint in `_NET_SUPPORTED`. Clients probe this once at
/// startup; without it they assume a bare ICCCM-only WM and take conservative,
/// in GLFW's case broken, code paths. Must run once at startup, after
/// atoms.initAtomCache() and before any client can map a window.
///
/// The advertised set is the NARROW reading of the spec: what hana does NOT
/// implement stays off `_NET_SUPPORTED` rather than documented as aspirational
/// -- an absent atom makes clients take their conservative path, while a
/// listed-but-dropped request leaves them waiting on a click that never lands.
/// The honest gap list, one line each:
/// - `_NET_WM_STATE_ABOVE`/`_STICKY`: preserved through our read-merge-write
///   but they change nothing we act on, so neither the states nor their
///   `_NET_WM_ACTION_*` hints are advertised.
/// - `_NET_WM_ALLOWED_ACTIONS`: never written on managed windows.
/// - The generic `_NET_WM_WINDOW_TYPE`: only the DOCK member is read, for
///   float+strut handling; the atom and other members stay unadvertised.
/// - `_NET_CLIENT_LIST`/`_STACKING`: not maintained, so pagers cannot
///   enumerate clients. `_NET_WM_STATE_HIDDEN`/`_DEMANDS_ATTENTION`: neither
///   advertised nor answered (minimize is internal-only).
/// - `_NET_WORKAREA`: absent; dock-safe geometry comes from
///   `_NET_WM_STRUT_PARTIAL` instead (honored: protocol/struts.zig).
///
/// Claim SubstructureRedirectMask on the root window, which is what makes this
/// process the window manager. The server rejects the claim if another WM
/// already holds it, so a failure here is the "another WM is running" case --
/// distinct from a broken connection.
pub fn claimWindowManagerRole(conn: Connection, root: u32) !void {
    const cookie = xcb.xcb_change_window_attributes_checked(
        conn,
        root,
        xcb.XCB_CW_EVENT_MASK,
        &[_]u32{masks.EventMasks.root_window},
    );
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        defer std.c.free(err);
        // `xcb_request_check` funnels two failures through this one pointer:
        // a server-rejected request (response_type 1, BadAccess when another
        // WM holds the redirect), and -- when the stream DIED while the check
        // waited -- a synthetic error libxcb fabricates from the XCB_CONN_*
        // state (response_type 0). Only the first is "another WM";
        // mislabeling a dead server as one sends the user hunting a process
        // that no longer exists.
        if (xcb.xcb_connection_has_error(conn) != 0) {
            log.err("X11 connection failed while claiming the WM role (stream error_code={d})", .{err.*.error_code});
            return error.X11ConnectionFailed;
        }
        log.err(
            "Another window manager is already running (error_code={d}, type={d})",
            .{ err.*.error_code, err.*.response_type },
        );
        return error.AnotherWMRunning;
    }
}

/// Flush the request queue. Wrapped here so main needs no xcb include of its
/// own.
pub fn flush(conn: Connection) void {
    _ = xcb.xcb_flush(conn);
}

pub fn advertiseEwmhSupport(conn: Connection, screen: Screen, root: u32) void {
    const supporting_wm_check = atoms.getAtomCached("_NET_SUPPORTING_WM_CHECK") orelse return;
    const net_wm_name = atoms.getAtomCached("_NET_WM_NAME") orelse return;
    const utf8_string = atoms.getAtomCached("UTF8_STRING") orelse return;
    const net_supported = atoms.getAtomCached("_NET_SUPPORTED") orelse return;

    // A small, invisible identity window. Override-redirect so hana's own
    // SubstructureRedirect handling never manages it as a client.
    const check_win = xcb.xcb_generate_id(conn);
    _ = xcb.xcb_create_window(conn, xcb.XCB_COPY_FROM_PARENT, check_win, root, -1, -1, 1, 1, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual, @intCast(xcb.XCB_CW_OVERRIDE_REDIRECT), &[_]u32{1});

    // Identity dance required by the spec: the check window points at itself,
    // the root at the check window. Clients compare the two values to tell a
    // live WM from a stale property a crashed WM left behind.
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

/// Collects the reply for an already-fired get_property request, polling
/// non-blockingly first and falling back to the typed blocking collector only
/// when the reply isn't buffered yet.
///
/// Poll semantics: `xcb_poll_for_reply` consumes the cookie on BOTH success
/// and error, so a plain "null means block" is unsound -- blocking on a
/// consumed-error cookie has undefined XCB semantics. An X error seen here is
/// freed and reported as plain failure; the cookie must never be touched again.
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
