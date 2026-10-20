//! X request primitives: the allowlisted home for raw `xcb_*` calls, plus the
//! documented EWMH/geometry/policy requests that sit above them.
//!
//! XCB is a request/reply protocol, so
//! this is the request layer: `raiseWindow`,
//! `setBorderPixel`, the server grab pair, the poll-first reply collector, the
//! EWMH root advertisement, and the one xcb-typed geometry adapter. Atom ids
//! come from `atoms.zig`; dispatch of these requests happens in `sink.zig`,
//! which is the sanctioned seam (see dev/scripts/check-layers.sh Rules 1-2).
//! Geometry itself stays in `core/model.zig` so the pure layers never
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
const log = std.log.scoped(.requests);

// Geometry <-> wire conversions

/// P1-18: last OUTBOUND SEQUENCE per window, for type-0 error attribution.
///
/// Unchecked requests never produce a reply; their only trace is the error
/// pseudo-event (type 0) the server sends back, which carries the failed
/// request's sequence -- but nothing else in that event says WHICH window the
/// send was for unless the resource_id happens to be the window. Every send
/// site therefore records its cookie sequence here at send time (cookies are
/// assigned at queue time, so this costs no round-trip), and the type-0
/// handler maps the sequence back through `windowForSequence` to name the
/// window. Best-effort by contract: only the LAST sequence per window is
/// kept (a batched earlier failure to the same window may miss and fall back
/// to the anonymous line), and a full ledger silently drops new entries.
var last_outbound: model.Store(model.WindowId, u16, model.store_capacity) = .{};

/// Record that `win`'s most recent outbound request took sequence `seq`
/// (the cookie's full unsigned sequence; XCB cookies are `unsigned int`
/// while error events echo only the low 16 bits, so the tracker stores the
/// same `@truncate` both sides compare on).
pub fn noteSequence(win: model.WindowId, seq: u32) void {
    const seq16: u16 = @truncate(seq);
    if (last_outbound.getPtr(win)) |p| {
        p.* = seq16;
        return;
    }
    _ = last_outbound.put(win, seq16) catch return;
}

/// The sequence of the last request sent to `win`, or null when nothing has
/// been sent (or the ledger was reset). Test seam: reconcile_test-style
/// assertions record and read back.
pub fn lastSequence(win: model.WindowId) ?u16 {
    return last_outbound.get(win);
}

/// Reverse lookup for the type-0 handler: which window's last outbound
/// request carried `seq`? The first match wins (sequence space is 16-bit and
/// wraps; a collision would only mislabel diagnostics, never state).
pub fn windowForSequence(seq: u16) ?model.WindowId {
    for (last_outbound.keys[0..last_outbound.len], last_outbound.vals[0..last_outbound.len]) |w, s| {
        if (s == seq) return w;
    }
    return null;
}

/// Drop `win`'s record. X ids recycle: a stale sequence could mislabel a
/// future window's error. Called from reconcile.forget (the ledger's own
/// forget) so both stores live and die together.
pub fn forgetSequence(win: model.WindowId) void {
    _ = last_outbound.remove(win);
}

/// Test seam: process-lifetime state needs the same re-arm between tests
/// that reconcile.init gives its ledger.
pub fn resetOutboundTracking() void {
    last_outbound = .{};
}

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

pub inline fn raiseWindow(conn: Connection, win: u32) void {
    const ck = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    noteSequence(win, ck.sequence);
}

pub inline fn setBorderPixel(conn: Connection, win: u32, pixel: u32) void {
    const ck = xcb.xcb_change_window_attributes(conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{pixel});
    noteSequence(win, ck.sequence);
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

/// Releases the X server grab, then flushes. Defined here so every module can
/// share one copy; the ungrab and the flush are not separable by design, since
/// flushing a request made while grabbed is exactly what this exists to undo.
pub inline fn ungrabAndFlush(conn: Connection) void {
    _ = xcb.xcb_ungrab_server(conn);
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
/// they can rely on. ADVERTISED IMPLIES HANDLED: the list is deliberately
/// narrow, because advertising a hint whose requests hana drops sends pagers
/// and taskbars into UI whose clicks land in a warn-once-ignored branch. The
/// audit (each entry paired with the site that honours it, and the known-
/// unimplemented hints pinned as absent) lives in
/// `src/test/window/ewmh_supported_test.zig`; extending this list without a
/// handling claim there fails the suite.
///
/// Notably fixes GLFW's "Iconification of full screen windows requires a WM
/// that supports EWMH full screen" error (Minecraft and other LWJGL games):
/// GLFW only fullscreens via `_NET_WM_STATE_FULLSCREEN` if that atom is
/// listed here; otherwise it falls back to a raw override-redirect window that
/// bypasses the WM and can't be iconified through it, so the next
/// XIconifyWindow() throws that error.
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
};

// Both lists must stay in sync at compile time: a misspelt/advertised atom
// without an AtomCache field would intern XCB_ATOM_NONE (0) and silently
// claim support for nothing. Catalogue: the advertised set is a strict
// subset of the cached fields (RESOURCE_MANAGER & friends are fetched but
// never advertised, and vice versa is a compile error).
comptime {
    for (supported_atoms) |name| {
        // @hasField answers this exactly, which is the question the nested scan
        // below was reimplementing by hand -- and it is what atoms.zig already
        // uses to check this same field set. The scan also needed a raised
        // @setEvalBranchQuota because it was O(fields x atoms).
        if (!@hasField(atoms.AtomCache, name)) {
            @compileError("supported_atoms has no AtomCache field: " ++ name);
        }
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
/// The advertised set is the NARROW reading of the spec: only hints hana
/// actually implements appear above, and the complement is the honest gap
/// list. What hana does NOT implement stays off `_NET_SUPPORTED` rather than
/// documented as aspirational -- an absent atom makes pagers/clients take
/// their conservative path, while a listed-but-dropped request leaves them
/// waiting on a click that will never land:
///
/// - `_NET_WM_STATE_ABOVE`/`_NET_WM_STATE_STICKY` are preserved when WE
///   mutate `_NET_WM_STATE` (the sink's read-merge-write must not nuke a
///   client's own atoms) but neither state changes stacking or workspace
///   placement, so neither the states nor their `_NET_WM_ACTION_*` hints are
///   advertised. The bar window declaring them on itself (bar/wire/win.zig)
///   is us-as-client, unrelated to this claim.
/// - `_NET_WM_ALLOWED_ACTIONS` is never written on managed windows; the
///   per-window property and its `_NET_WM_ACTION_*` atoms stay unadvertised.
/// - `_NET_WM_WINDOW_TYPE`/`_NET_WM_WINDOW_TYPE_DOCK`/`_NET_WM_STRUT_PARTIAL`
///   are never READ for managed windows (the bar manages its own space; its
///   strut is published for external compositors, not for us to parse).
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
        defer std.c.free(err);
        // `xcb_request_check` funnels two different failures through this one
        // pointer: a server-rejected request (response_type 1, error_code a
        // protocol code -- BadAccess when another WM holds the redirect), and
        // -- when the stream DIED while the check waited for the reply --
        // a synthetic error libxcb fabricates from the connection's
        // XCB_CONN_* state (response_type 0). Only the first is "another WM";
        // mislabeling a dead server as one sends the user hunting for a
        // process that no longer exists. The has-error rule -- the same
        // predicate XSession.deinit's teardown encodes -- tells them apart,
        // and returning the connection's own error name lets the caller's
        // errdefer release the socket through the matching guarded path.
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
