//! ICCCM focus protocol support (WM_HINTS and WM_PROTOCOLS): the X11
//! queries, the admission-cookie drain that seeds the focus-property cache,
//! and the WM_DELETE_WINDOW verdict path. The per-window verdict cache, the
//! four ICCCM 4.1.7 focus-delivery modes, WM_TAKE_FOCUS dispatch, and the
//! PropertyNotify half-refresh live in focus.zig (the cache's owner); this
//! module fills the cache through focus.put. Also shares
//! firePropQuery/u32Values for its admission and size-hints paths.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const log = std.log.scoped(.icccm);
/// Maximum 32-bit words to request when fetching a window property (256 =
/// 1 KiB, sufficient for all fixed-size properties the WM reads).
pub const property_max_length: u32 = 256;
/// Value for the `delete` argument to xcb_get_property that leaves the property intact.
pub const property_no_delete: u8 = 0;

const atoms = @import("atoms");
const focus = @import("focus");
// WM_HINTS constants (ICCCM 4.1.2.4)
const wm_hints_input_flag: u32 = 1 << 0;
const wm_hints_flags_field: usize = 0;
const wm_hints_input_field: usize = 1;
pub const wm_hints_long_length: u32 = 9; // flags + 8 fields

/// Shared admission drain: the MapRequest and boot-adoption routes fire
/// their admission cookies up-front and land here (via
/// admission.drainAdmissionCookies) to consume the focus-relevant pair. The
/// WM_PROTOCOLS reply is drained through the same protocolPropsFromReply
/// path as the live query, so the pipelined verdict is byte-identical; both
/// halves are cached.
pub fn populateFocusCacheFromCookies(
    conn: core.Connection,
    win: u32,
    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie: xcb.xcb_get_property_cookie_t,
) void {
    // Scan WM_PROTOCOLS once for both atoms (no second round-trip).
    const protocols_result = drainWMProtocolsReply(conn, protocols_cookie);

    focus.put(win, .{
        .accepts_input = extractWMHintsInput(conn, hints_cookie),
        .wm_delete = protocols_result.wm_delete,
        .take_focus = protocols_result.take_focus,
    });
}

/// Shared low-level property-query fire used by the WM_* queries in this
/// module and by window.zig's admission-cookie batch.
pub fn firePropQuery(conn: core.Connection, win: u32, prop: u32, comptime prop_type: u32, comptime length: u32) xcb.xcb_get_property_cookie_t {
    return xcb.xcb_get_property(
        conn,
        property_no_delete,
        win,
        prop,
        prop_type,
        0,
        length,
    );
}

/// Fires (but does not drain) a WM_PROTOCOLS query for `win`, so a caller
/// can pipeline it with other round trips and drain later via
/// queryWMProtocolsProps. Null when the WM_PROTOCOLS atom is not yet
/// interned (the caller then falls back to the live query path).
pub fn fireWMProtocolsQuery(
    conn: core.Connection,
    win: u32,
) ?xcb.xcb_get_property_cookie_t {
    const protocols_atom = atoms.getAtomCached("WM_PROTOCOLS") orelse return null;
    return firePropQuery(conn, win, protocols_atom, xcb.XCB_ATOM_ATOM, property_max_length);
}

/// Drains the WM_HINTS cookie and returns the ICCCM input flag. True when
/// absent, when the flag is unset, or when the field is explicitly True,
/// matching ICCCM 4.1.2.4 defaults.
fn extractWMHintsInput(
    conn: core.Connection,
    hints_cookie: xcb.xcb_get_property_cookie_t,
) bool {
    const r = xcb.xcb_get_property_reply(conn, hints_cookie, null) orelse return true;
    defer std.c.free(r);
    if (r.*.format != 32 or r.*.value_len < 1) return true;
    const hints = u32Values(r);
    const input_flag_set = (hints[wm_hints_flags_field] & wm_hints_input_flag) != 0;
    const has_input_field = r.*.value_len > @as(u32, wm_hints_input_field);
    if (!input_flag_set or !has_input_field) return true;
    return hints[wm_hints_input_field] != 0;
}

/// Returns cached props if available, otherwise queries, caches, and
/// returns. Blocking only on a miss; used by the non-hot ICCCM paths
/// (supportsWMDeleteCached / window close) that genuinely need the verdict.
fn getOrQueryCachedProps(conn: core.Connection, win: u32) focus.CachedProps {
    if (focus.peek(win)) |p| return p;
    const protocols = queryWMProtocolsProps(conn, win);
    const result: focus.CachedProps = .{
        .accepts_input = queryWMHintsAcceptsInput(conn, win),
        .wm_delete = protocols.wm_delete,
        .take_focus = protocols.take_focus,
    };
    focus.put(win, result);
    return result;
}

/// Cached WM_DELETE_WINDOW verdict, live-queried only on a genuine miss
/// (rare: the cache is seeded at map time).
pub fn supportsWMDeleteCached(conn: core.Connection, win: u32) bool {
    return getOrQueryCachedProps(conn, win).wm_delete;
}

/// ICCCM §4.1.2.7 close: the WM_DELETE_WINDOW client message (timestamp in
/// data32[1] per §4.1.2.7), falling back to xcb_destroy_window for clients
/// that don't advertise the protocol. The ONE close path: the close_window
/// keybind (dispatch.zig) and EWMH's _NET_CLOSE_WINDOW (client_events.zig)
/// both land here, so "close" cannot mean two different things depending on
/// who asked.
pub fn closeViaProtocol(win: u32) void {
    const conn = core.getState().conn;
    if (supportsWMDeleteCached(conn, win)) blk: {
        const protocols_atom = atoms.getAtomCached("WM_PROTOCOLS") orelse break :blk;
        const delete_atom = atoms.getAtomCached("WM_DELETE_WINDOW") orelse break :blk;

        var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
        event.response_type = xcb.XCB_CLIENT_MESSAGE;
        event.format = 32;
        event.window = win;
        event.type = protocols_atom;
        event.data.data32[0] = delete_atom;
        event.data.data32[1] = focus.getLastEventTime();

        _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
        return;
    }
    _ = xcb.xcb_destroy_window(conn, win);
}

pub const WMProtocolsProps = struct { take_focus: bool = false, wm_delete: bool = false };

/// Alignment-cast to the u32 value array of a format-32 get_property reply.
/// Shared with window.zig's size-hints parsing.
pub fn u32Values(r: *xcb.xcb_get_property_reply_t) [*]const u32 {
    return @ptrCast(@alignCast(xcb.xcb_get_property_value(r)));
}

/// Shared by queryWMProtocolsProps (live query) and populateFocusCacheFromCookies
/// (cookie path); the caller owns `reply`'s memory.
fn protocolPropsFromReply(
    reply: *xcb.xcb_get_property_reply_t,
    take_focus_atom: u32,
    wm_delete_atom: u32,
) WMProtocolsProps {
    if (reply.*.format != 32 or reply.*.value_len == 0) return .{};
    var found: WMProtocolsProps = .{};
    for (u32Values(reply)[0..@intCast(reply.*.value_len)]) |atom| {
        if (atom == take_focus_atom) found.take_focus = true;
        if (atom == wm_delete_atom) found.wm_delete = true;
        if (found.take_focus and found.wm_delete) break;
    }
    return found;
}

pub fn queryWMProtocolsProps(conn: core.Connection, win: u32) WMProtocolsProps {
    const ck = fireWMProtocolsQuery(conn, win) orelse return .{};
    return drainWMProtocolsReply(conn, ck);
}

/// Drains a WM_PROTOCOLS reply (the cookie fired by queryWMProtocolsProps
/// or the admission path) into take_focus/wm_delete. Sharing one drain keeps
/// the pipelined verdict byte-identical to the live one; a failed atom
/// resolution returns early with empty props so the reply still drains
/// cleanly.
fn drainWMProtocolsReply(conn: core.Connection, cookie: xcb.xcb_get_property_cookie_t) WMProtocolsProps {
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return .{};
    defer std.c.free(reply);
    // WM_DELETE_WINDOW resolves independently of the focus-atom cache, so a
    // client that advertises it still gets wm_delete detection during the
    // narrow startup window where take_focus is not yet available. take_focus
    // atom 0 can never match a real client atom, so the miss path stays
    // correct.
    const wm_delete = atoms.getAtomOrZero("WM_DELETE_WINDOW");
    const at = focusAtomsOrNil() orelse
        return protocolPropsFromReply(reply, 0, wm_delete);
    return protocolPropsFromReply(reply, at.take_focus, wm_delete);
}

/// The WM_PROTOCOLS/WM_TAKE_FOCUS atom pair drainWMProtocolsReply needs,
/// resolved through focus's atom helper (the same cache the WM_TAKE_FOCUS
/// sender uses), or null when the atom cache is not ready.
fn focusAtomsOrNil() ?struct { take_focus: u32 } {
    const take_focus = atoms.getAtomCached("WM_TAKE_FOCUS") orelse return null;
    return .{ .take_focus = take_focus };
}

/// Discards a pre-fired WM_PROTOCOLS cookie without draining it, so a
/// candidate the caller ultimately rejects never leaks a pending reply on
/// the stream.
pub fn discardProtocolCookie(conn: core.Connection, opt: anytype) void {
    if (opt) |ck| xcb.xcb_discard_reply(conn, ck.sequence);
}

/// Returns true when absent (assume True per ICCCM) or explicitly True.
pub fn queryWMHintsAcceptsInput(conn: core.Connection, win: u32) bool {
    return extractWMHintsInput(conn, firePropQuery(conn, win, xcb.XCB_ATOM_WM_HINTS, xcb.XCB_ATOM_WM_HINTS, wm_hints_long_length));
}
