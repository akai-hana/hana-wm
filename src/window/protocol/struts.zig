//! Inbound EWMH struts: foreign docks claim screen edges.
//!
//! A dock (polybar, xfce4-panel, ...) declares `_NET_WM_WINDOW_TYPE_DOCK`
//! and `_NET_WM_STRUT_PARTIAL` — "I occupy N pixels of this edge". hana's
//! own bar publishes the same property outward (`bar/wire/win.zig`); this
//! module is the INBOUND half: parse what foreign docks declare and publish
//! it into core's `usable_area` ledger, so placement (tiled and floating)
//! avoids their edges exactly the way it avoids hana's own bar.
//!
//! D27 (the struts-only multi-monitor interim): one hana screen. The
//! property's partial ranges (start/end coordinates along each edge) are a
//! per-monitor refinement and are deliberately ignored — only the four edge
//! widths matter, the same reading the outbound publication makes.
//!
//! Honored only for DOCK-typed windows: `event.window` on a property change
//! and a window id at admission are client-controlled, and an arbitrary
//! client's right to shrink the whole screen's work area to nothing is not a
//! trade hana makes. A malformed or absent strut releases the window's
//! claim (a dock that withdraws its strut stops occupying the edge).
//!
//! Lifecycle: admission drains the pre-fired cookie and publishes BEFORE the
//! admitting reconcile (so a spawned dock's shrink lands with the first
//! placement); PropertyNotify re-publishes (coalesced through window.zig's
//! dirty set, like titles); unmanage releases. A publish that changes the
//! ledger returns true and the caller triggers the re-tile.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const atoms = @import("atoms");
const icccm = @import("icccm");
const usable_area = @import("usable_area");

/// The four edge widths of a strut, in pixels.
pub const Insets = struct {
    left: u16 = 0,
    right: u16 = 0,
    top: u16 = 0,
    bottom: u16 = 0,

    pub fn eql(a: Insets, b: Insets) bool {
        return a.left == b.left and a.right == b.right and a.top == b.top and a.bottom == b.bottom;
    }

    pub fn isZero(a: Insets) bool {
        return a.left == 0 and a.right == 0 and a.top == 0 and a.bottom == 0;
    }
};

/// Pure parse of a `_NET_WM_STRUT_PARTIAL` payload: 12 CARDINALs, indices
/// 0..3 the edge widths (left, right, top, bottom), 4..11 the per-monitor
/// partial ranges (ignored under D27). Null when the reply is not the EWMH
/// layout — a malformed strut is dropped, never guessed at.
pub fn parsePartial(data: []const u32) ?Insets {
    if (data.len < 12) return null;
    return .{
        .left = @intCast(data[0]),
        .right = @intCast(data[1]),
        .top = @intCast(data[2]),
        .bottom = @intCast(data[3]),
    };
}

/// Fires the two EWMH cookies this module drains: the window-type list (for
/// DOCK detection) and the strut itself. Fired with the rest of the admission
/// batch so the server processes them in parallel; null when the atom cache
/// lacks the atom (early boot / degraded init), which reads as "no dock".
pub fn fireCookies(conn: core.Connection, win: u32) Cookies {
    const type_atom = atoms.getAtomOrZero("_NET_WM_WINDOW_TYPE");
    const strut_atom = atoms.getAtomOrZero("_NET_WM_STRUT_PARTIAL");
    return .{
        .type_cookie = if (type_atom != 0)
            icccm.firePropQuery(conn, win, type_atom, xcb.XCB_ATOM_ATOM, icccm.property_max_length)
        else
            null,
        .strut_cookie = if (strut_atom != 0)
            icccm.firePropQuery(conn, win, strut_atom, xcb.XCB_ATOM_CARDINAL, 12)
        else
            null,
    };
}

pub const Cookies = struct {
    type_cookie: ?xcb.xcb_get_property_cookie_t,
    strut_cookie: ?xcb.xcb_get_property_cookie_t,
};

/// Everything fireCookies' batch extracts: whether the window is DOCK-typed
/// and, when it is, its strut insets (null = no valid strut = no claim).
pub const Drain = struct {
    is_dock: bool = false,
    strut: ?Insets = null,
};

/// Drains the cookies into (is_dock, strut). A non-dock's strut reply is
/// discarded unread (the property may legally exist on any window; honoring
/// it is what this module refuses to do).
pub fn drain(conn: core.Connection, cookies: Cookies) Drain {
    const is_dock = isDock(conn, cookies.type_cookie) orelse false;
    // Exactly one consumer per cookie: drainStrut reads (and frees) the reply
    // when the window is a dock; otherwise the reply is discarded unread (the
    // property may legally exist on any window; honoring it is what this
    // module refuses to do).
    var strut: ?Insets = null;
    if (is_dock) {
        strut = drainStrut(conn, cookies.strut_cookie);
    } else {
        icccm.discardProtocolCookie(conn, cookies.strut_cookie);
    }
    return .{ .is_dock = is_dock, .strut = strut };
}

/// Discards both cookies without parsing (adoption's attribute-gate path).
pub fn discard(conn: core.Connection, cookies: Cookies) void {
    icccm.discardProtocolCookie(conn, cookies.type_cookie);
    icccm.discardProtocolCookie(conn, cookies.strut_cookie);
}

/// True when the ATOM-list reply contains `_NET_WM_WINDOW_TYPE_DOCK`.
/// Null on a vanished window / malformed reply (treated as "not a dock" by
/// callers via `orelse false`).
fn isDock(conn: core.Connection, cookie: ?xcb.xcb_get_property_cookie_t) ?bool {
    const ck = cookie orelse return false;
    const reply = xcb.xcb_get_property_reply(conn, ck, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 32) return false;
    const dock_atom = atoms.getAtomOrZero("_NET_WM_WINDOW_TYPE_DOCK");
    if (dock_atom == 0) return false;
    const values = icccm.u32Values(reply);
    // value_len counts format-sized units (sink's _NET_WM_STATE read does the same).
    const len: usize = @intCast(reply.*.value_len);
    for (values[0..len]) |a| if (a == dock_atom) return true;
    return false;
}

fn drainStrut(conn: core.Connection, cookie: ?xcb.xcb_get_property_cookie_t) ?Insets {
    const ck = cookie orelse return null;
    const reply = xcb.xcb_get_property_reply(conn, ck, null) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 32) return null;
    const values = icccm.u32Values(reply);
    // value_len counts format-sized units (sink's _NET_WM_STATE read does the same).
    const len: usize = @intCast(reply.*.value_len);
    return parsePartial(values[0..len]);
}

/// Publishes `insets` as `win`'s dock claim (null or all-zero RELEASES).
/// Returns true when the ledger changed, so the caller can trigger a re-tile
/// only when geometry actually needs to move.
pub fn publish(win: core.WindowId, insets: ?Insets) bool {
    const new = insets orelse Insets{};
    const old: Insets = if (usable_area.dockClaimOf(win)) |c|
        .{ .left = c.left, .right = c.right, .top = c.top, .bottom = c.bottom }
    else
        .{};
    if (new.eql(old)) return false;
    _ = usable_area.setDockClaim(win, new.left, new.right, new.top, new.bottom);
    return true;
}

/// Releases `win`'s claim (unmanage). True when a claim existed; the caller
/// needs no reconcile of its own — unmanage always re-tiles.
pub fn release(win: core.WindowId) bool {
    return usable_area.releaseDockClaim(win);
}

/// PropertyNotify refresh: re-read type + strut for a managed window and
/// republish. Returns true when the ledger changed (caller re-tiles). This
/// is the coalesced dirty-set's action as well as the set-full fallback.
pub fn refresh(conn: core.Connection, win: core.WindowId) bool {
    const cookies = fireCookies(conn, win);
    const d = drain(conn, cookies);
    if (!d.is_dock) return publish(win, null);
    return publish(win, d.strut);
}
