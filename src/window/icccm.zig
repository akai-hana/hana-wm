//! ICCCM 4.1.2/4.1.7 protocol handling
//! WM_PROTOCOLS/WM_HINTS focus-property cache, the four ICCCM focus-delivery
//! modes, and WM_TAKE_FOCUS client-message dispatch. Owns its cache state:
//! window.zig calls init/deinit/evictCache through the lifecycle, and shares
//! firePropQuery/u32Values for its admission and size-hints paths.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const debug = @import("debug");
const constants = @import("constants");

// WM_HINTS constants (ICCCM 4.1.2.4)
const wm_hints_input_flag: u32 = 1 << 0;
const wm_hints_flags_field: usize = 0;
const wm_hints_input_field: usize = 1;
pub const wm_hints_long_length: u32 = 9; // flags + 8 fields

// ICCCM focus property cache: keyed by window ID, populated at map time,
// invalidated on WM_PROTOCOLS/WM_HINTS PropertyNotify and on destruction.
// Caches accepts_input (WM_HINTS.input), wm_delete (WM_DELETE_WINDOW), and
// take_focus (WM_TAKE_FOCUS in WM_PROTOCOLS). Safe because the mask-first
// map ordering guarantees PropertyNotify before any post-seed change can stale.

var cache_slots: utils.BoundedList(CacheSlot, max_window_cache) = .{};
var cache_ready: bool = false;

/// The four ICCCM focus delivery modes (4.1.7), determined by the combination of
/// WM_HINTS.input and WM_TAKE_FOCUS presence in WM_PROTOCOLS.
pub const InputModel = enum {
    no_input, // input=False, no WM_TAKE_FOCUS: window doesn't want focus
    passive, // input=True,  no WM_TAKE_FOCUS: set focus via `XSetInputFocus`
    locally_active, // input=True,  WM_TAKE_FOCUS:    set focus + send protocol
    globally_active, // input=False, WM_TAKE_FOCUS:    only send protocol
};

/// Per-window properties cached from WM_HINTS and WM_PROTOCOLS. Kept in
/// sync via PropertyNotify; take_focus is safe to cache because the mask-first
/// map ordering guarantees it cannot stale.
const CachedProps = struct {
    accepts_input: bool,
    wm_delete: bool,
    take_focus: bool,
};

// At realistic window counts (<=100 typical, <=300 extreme) a linear scan over
// u32 IDs in a flat array is cache-local and allocation-free. Windows beyond
// max_window_cache still work; they just fall through to the live X11 path.
pub const max_window_cache: usize = 512;

const CacheSlot = struct {
    id: u32,
    props: CachedProps,
};

/// Enables (window init) or disables (window deinit) the cache and drops all
/// entries. Callers must not touch the cache outside the active window.
/// deinit runs before focus/tracking teardown, whose managed-window sweeps
/// must not encounter a partially-valid cache.
pub fn reset(active: bool) void {
    cache_slots.clear();
    cache_ready = active;
}

/// Removes a window's cache entry on unmanage so a reused XID can't borrow a
/// stale focus verdict.
pub fn evictCache(win: u32) void {
    if (cache_slots.indexOfById(win)) |i| cache_slots.swapRemove(i);
}

/// Called from handleMapRequest, which fires both cookies synchronously.
/// MapRequest is a one-time event per window, not a hot path worth pipelining.
///
/// The WM_PROTOCOLS reply is scanned once for both WM_TAKE_FOCUS and
/// WM_DELETE_WINDOW, and both halves are cached (mask-first map ordering makes
/// take_focus staleness impossible, see the section comment above).
pub fn populateFocusCacheFromCookies(
    conn: core.Connection,
    win: u32,
    protocols_cookie: xcb.xcb_get_property_cookie_t,
    hints_cookie: xcb.xcb_get_property_cookie_t,
) void {
    // Scan WM_PROTOCOLS once for both protocols atoms (no second round-trip);
    // wm_delete and take_focus both get cached below.
    const protocols_result = drainWMProtocolsReply(conn, protocols_cookie);

    putCachedProps(win, .{
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
        constants.property_no_delete,
        win,
        prop,
        prop_type,
        0,
        length,
    );
}

/// Fires (but does not drain) a WM_PROTOCOLS query for `win`, so a caller can
/// pipeline it with other round trips and consume the reply later via
/// getInputModelResolvedConsume / queryWMProtocolsPropsConsume. Returns null
/// when the WM_PROTOCOLS atom is not yet interned (the caller then falls back
/// to the live query path). Fire-and-forget; the caller owns the cookie.
pub fn fireWMProtocolsQuery(
    conn: core.Connection,
    win: u32,
) ?xcb.xcb_get_property_cookie_t {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return null;
    return firePropQuery(conn, win, protocols_atom, xcb.XCB_ATOM_ATOM, constants.property_max_length);
}

/// Drains the WM_HINTS cookie and returns the ICCCM input flag. Returns true
/// when absent, when the flag is unset, or when the field is explicitly True,
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

/// Silently drops the entry when the cache is full;
/// the live-query fallback is always correct.
fn putCachedProps(win: u32, props: CachedProps) void {
    if (!cache_ready) return;
    if (!cache_slots.upsertById(.id, win, .{ .id = win, .props = props })) {
        debug.warn("Focus cache full, falling back to live queries", .{});
    }
}

/// Returns cached props without triggering a live query, or null on a miss.
/// The null case means the window's WM_HINTS/WM_PROTOCOLS have not been seen
/// since the cache seeded (or the cache is full/not ready); callers fall back
/// to a live query or a pre-fired cookie.
fn peekCachedProps(win: u32) ?CachedProps {
    if (cache_ready) {
        if (cache_slots.indexOfById(win)) |i| {
            return cache_slots.items[i].props;
        }
    }
    return null;
}

/// Returns cached props if available, otherwise queries (consuming an optional
/// pre-fired WM_PROTOCOLS cookie on a miss), caches the result, and returns it.
/// Used by the input-model resolve paths so the populate logic lives in one
/// place; a pre-fired cookie is discarded on a cache hit.
fn getOrQueryCachedProps(conn: core.Connection, win: u32, pre_protocols_cookie: ?xcb.xcb_get_property_cookie_t) CachedProps {
    if (peekCachedProps(win)) |p| {
        discardProtocolCookie(conn, pre_protocols_cookie);
        return p;
    }
    const protocols = if (pre_protocols_cookie) |ck|
        drainWMProtocolsReply(conn, ck)
    else
        queryWMProtocolsProps(conn, win);
    const props = CachedProps{
        .accepts_input = queryWMHintsAcceptsInput(conn, win),
        .wm_delete = protocols.wm_delete,
        .take_focus = protocols.take_focus,
    };
    putCachedProps(win, props);
    return props;
}

/// Resolves the ICCCM 4.1.7 focus-delivery model for `win` together with the
/// take_focus verdict, so callers can dispatch WM_TAKE_FOCUS without issuing a
/// second query. Both answers come from the focus-property cache on a hit.
pub const InputModelResolution = struct {
    model: InputModel,
    /// True when `win` advertises WM_TAKE_FOCUS.
    take_focus: bool,
};

fn resolve(props: CachedProps) InputModelResolution {
    return .{
        .model = inputModelFrom(props.take_focus, props.accepts_input),
        .take_focus = props.take_focus,
    };
}

pub fn getInputModelResolved(conn: core.Connection, win: u32) InputModelResolution {
    return resolve(getOrQueryCachedProps(conn, win, null));
}

/// Resolves the input model from the focus-property cache only, consuming a
/// caller pre-fired WM_PROTOCOLS cookie on a cache miss and DISCARDING it on a
/// hit (where the cached take_focus verdict supersedes the redundant query).
///
/// The cache is safe because the mask-first map ordering prevents staleness;
/// a miss fills it from the pre-fired cookie (or a live query when null).
pub fn getInputModelResolvedConsume(
    conn: core.Connection,
    win: u32,
    pre_protocols_cookie: ?xcb.xcb_get_property_cookie_t,
) InputModelResolution {
    return resolve(getOrQueryCachedProps(conn, win, pre_protocols_cookie));
}

/// Resolves the ICCCM 4.1.7 focus-delivery model for `win`. Both accepts_input
/// and take_focus come from the focus-property cache (live query only on a
/// genuine miss, which is rare since the cache is seeded at map time).
pub fn getInputModel(conn: core.Connection, win: u32) InputModel {
    return getInputModelResolved(conn, win).model;
}

/// Falls back to a live query only on a genuine cache miss (extremely rare).
pub fn supportsWMDeleteCached(conn: core.Connection, win: u32) bool {
    return getOrQueryCachedProps(conn, win, null).wm_delete;
}

/// True when `win`'s input-model verdict is already cached (seeded at map
/// time), i.e. a focus-prep for it will not round-trip. Lets pipeline callers
/// skip a redundant WM_PROTOCOLS pre-fire on the already-cached common case.
pub fn isInputModelCached(win: u32) bool {
    return peekCachedProps(win) != null;
}

/// The WM_PROTOCOLS and WM_TAKE_FOCUS atoms this module's focus paths share.
const FocusAtoms = struct { protocols: u32, take_focus: u32 };

/// Called by `sendWMTakeFocus` (live round-trip path) to keep the send logic in one place.
fn dispatchTakeFocusMessage(
    conn: core.Connection,
    win: u32,
    time: u32,
    at: FocusAtoms,
    proto_list: []const u32,
) void {
    for (proto_list) |atom| {
        if (atom == at.take_focus) break;
    } else return; // window does not advertise WM_TAKE_FOCUS

    sendTakeFocusEvent(conn, win, time, at);
}

/// Builds and sends the WM_TAKE_FOCUS ClientMessage. No protocol-list scan:
/// callers either scanned already or hold an authoritative answer.
fn sendTakeFocusEvent(
    conn: core.Connection,
    win: u32,
    time: u32,
    at: FocusAtoms,
) void {
    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.window = win;
    event.type = at.protocols;
    event.format = 32;
    event.data.data32[0] = at.take_focus;
    event.data.data32[1] = time;

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

/// Resolves the WM_PROTOCOLS and WM_TAKE_FOCUS atoms this module's focus paths
/// share, or null when the atom cache is not ready. The atom set is atomic
/// (one cache), so a partial failure is impossible.
fn focusAtoms() ?FocusAtoms {
    const protocols = utils.getAtomCached("WM_PROTOCOLS") catch return null;
    const take_focus = utils.getAtomCached("WM_TAKE_FOCUS") catch return null;
    return .{ .protocols = protocols, .take_focus = take_focus };
}

/// Dispatches WM_TAKE_FOCUS from an already-known advertisement bit, the one
/// returned by `getInputModelResolved` alongside the input model. Skips the
/// WM_PROTOCOLS round trip entirely; used by the grab-wrapped focus path so a
/// keyboard focus change costs one protocol query instead of two.
pub fn sendWMTakeFocusKnown(
    conn: core.Connection,
    win: u32,
    time: u32,
    advertises_take_focus: bool,
) void {
    if (!advertises_take_focus) return;
    const at = focusAtoms() orelse return;
    sendTakeFocusEvent(conn, win, time, at);
}

/// Shared body of sendWMTakeFocus and sendWMTakeFocusWithCookie: resolves the
/// WM_PROTOCOLS and WM_TAKE_FOCUS atoms, drains the WM_PROTOCOLS reply (from the
/// pre-fired `cookie` when present, else a fresh round-trip), and dispatches the
/// WM_TAKE_FOCUS ClientMessage iff `win` advertises the protocol (ICCCM 4.1.7).
/// When the cookie cannot be consumed (atom resolution fails), it is discarded
/// so the XCB queue drains.
fn dispatchTakeFocus(
    conn: core.Connection,
    win: u32,
    time: u32,
    cookie: ?xcb.xcb_get_property_cookie_t,
) void {
    const at = focusAtoms() orelse {
        discardProtocolCookie(conn, cookie);
        return;
    };

    const proto_cookie = cookie orelse (fireWMProtocolsQuery(conn, win) orelse return);
    const proto_reply = xcb.xcb_get_property_reply(conn, proto_cookie, null) orelse return;
    defer std.c.free(proto_reply);
    if (proto_reply.*.format != 32 or proto_reply.*.value_len == 0) return;
    dispatchTakeFocusMessage(
        conn,
        win,
        time,
        at,
        u32Values(proto_reply)[0..@intCast(proto_reply.*.value_len)],
    );
}

/// Sends a WM_TAKE_FOCUS client message (ICCCM 4.1.7) iff `win` advertises
/// WM_TAKE_FOCUS in WM_PROTOCOLS. Uses the cached take_focus verdict when
/// present (no round trip); only on a cache miss does it fall back to a live
/// WM_PROTOCOLS query, matching dwm's sendevent().
///
/// Fallback for callers that don't pre-fire the cookie (drainPendingConfirm).
pub fn sendWMTakeFocus(conn: core.Connection, win: u32, time: u32) void {
    if (peekCachedProps(win)) |p| {
        sendWMTakeFocusKnown(conn, win, time, p.take_focus);
        return;
    }
    dispatchTakeFocus(conn, win, time, null);
}

/// See ICCCM 4.1.7: the matrix of (accepts_input x supports_take_focus)
/// determines which focus delivery mechanism the WM must use.
fn inputModelFrom(supports_take_focus: bool, accepts_input: bool) InputModel {
    return if (supports_take_focus)
        (if (accepts_input) .locally_active else .globally_active)
    else
        (if (accepts_input) .passive else .no_input);
}

const WMProtocolsProps = struct { take_focus: bool = false, wm_delete: bool = false };

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
    var props: WMProtocolsProps = .{};
    for (u32Values(reply)[0..@intCast(reply.*.value_len)]) |atom| {
        if (atom == take_focus_atom) props.take_focus = true;
        if (atom == wm_delete_atom) props.wm_delete = true;
        if (props.take_focus and props.wm_delete) break;
    }
    return props;
}

fn queryWMProtocolsProps(conn: core.Connection, win: u32) WMProtocolsProps {
    const ck = fireWMProtocolsQuery(conn, win) orelse return .{};
    return drainWMProtocolsReply(conn, ck);
}

/// Drains a WM_PROTOCOLS reply (the pipelined cookie of
/// queryWMProtocolsPropsConsume, or the one fired by queryWMProtocolsProps
/// above) into take_focus/wm_delete. Sharing one drain keeps the pipelined
/// verdict byte-identical to the live one; the caller fired the query BEFORE
/// the pointer round trip so its reply is typically already buffered by the
/// time this is reached. A failed atom resolution (cache not ready) returns
/// early with empty props, so the reply still drains cleanly.
fn drainWMProtocolsReply(conn: core.Connection, cookie: xcb.xcb_get_property_cookie_t) WMProtocolsProps {
    const reply = xcb.xcb_get_property_reply(conn, cookie, null) orelse return .{};
    defer std.c.free(reply);
    // WM_DELETE_WINDOW resolves independently of the focus-atom cache, so a
    // client that advertises it still gets wm_delete detection during the
    // narrow startup window where focusAtoms() (and its take_focus atom) are
    // not yet available. take_focus atom 0 can never match a real client
    // atom, keeping the miss path's take_focus verdict as correct as the
    // old early-return-empty.
    const wm_delete = utils.getAtomOrZero("WM_DELETE_WINDOW");
    const at = focusAtoms() orelse
        return protocolPropsFromReply(reply, 0, wm_delete);
    return protocolPropsFromReply(reply, at.take_focus, wm_delete);
}

/// Discards a pre-fired WM_PROTOCOLS cookie without draining it. Used when a
/// pipelined cookie was fired for a candidate window that the caller ultimately
/// does not target, so it never leaks a pending reply on the stream.
pub fn discardProtocolCookie(conn: core.Connection, opt: anytype) void {
    if (opt) |ck| xcb.xcb_discard_reply(conn, ck.sequence);
}

/// Returns true when absent (assume True per ICCCM) or explicitly True.
fn queryWMHintsAcceptsInput(conn: core.Connection, win: u32) bool {
    return extractWMHintsInput(conn, xcb.xcb_get_property(
        conn,
        constants.property_no_delete,
        win,
        xcb.XCB_ATOM_WM_HINTS,
        xcb.XCB_ATOM_WM_HINTS,
        0,
        wm_hints_long_length,
    ));
}

/// Refresh one half of CachedProps after a PropertyNotify, keeping the other
/// halves from cache to avoid a redundant round-trip. When the old is not
/// cached, the affected half is queried live; this fallback costs one extra
/// XCB call per window until populateFocusCacheFromCookies seeds the cache.
///
/// A WM_PROTOCOLS notify invalidates both wm_delete and take_focus (same
/// property); a WM_HINTS notify invalidates only accepts_input.
pub fn refreshCachedPropHalf(conn: core.Connection, win: u32, atom: u32) void {
    const is_protocols = atom == utils.getAtomOrZero("WM_PROTOCOLS");
    const existing: ?CachedProps = peekCachedProps(win);

    const protocols: WMProtocolsProps = if (existing) |p|
        if (is_protocols) queryWMProtocolsProps(conn, win) else .{ .wm_delete = p.wm_delete, .take_focus = p.take_focus }
    else
        queryWMProtocolsProps(conn, win);
    const accepts_input: bool = if (existing) |p|
        if (is_protocols) p.accepts_input else queryWMHintsAcceptsInput(conn, win)
    else
        queryWMHintsAcceptsInput(conn, win);

    putCachedProps(win, .{
        .accepts_input = accepts_input,
        .wm_delete = protocols.wm_delete,
        .take_focus = protocols.take_focus,
    });
}
