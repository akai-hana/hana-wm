//! Tests for the EWMH ClientMessage entry point (`window.handleClientMessage`),
//! the path a BROWSER's native fullscreen takes.
//!
//! WHY A SEPARATE FILE
//!   The regression guarded here is not reachable through the keybind path: the
//!   keybinding (Mod+F) and the EWMH message are different callers of the same
//!   transition, and only the message one had ever been broken. `Mod+F`
//!   working while the browser's own fullscreen button did nothing is exactly
//!   this asymmetry -- the model path is fine and the EVENT path is not, so a
//!   test that drives `fullscreen.fullscreenSetWindow` (as pipeline_test does)
//!   cannot see the bug at all. Every test below goes through the real
//!   handler with a synthesized `xcb_client_message_event_t`.
//!
//! WHAT IS PINNED
//!   The `_NET_WM_FULLSCREEN_REQUEST` and `_NET_WM_STATE` branches must each
//!   reach the covering transition for a managed window, must treat the
//!   message's action code as a SET (`data32[0]`) rather than a toggle, and
//!   must not consume an unmanaged window's request in a way that leaves the
//!   once-per-process warning latched against later legitimate requests.
//!   The `_NET_CLOSE_WINDOW` / `_NET_CURRENT_DESKTOP` / `_NET_WM_DESKTOP`
//!   pager messages (P1-08: advertised, so they must actually work) must
//!   reach the shared ICCCM close path, the switchWorkspace hook, and the
//!   moveToWorkspace hook respectively, with their guards: no close of an
//!   unmanaged window, no workspace index hana doesn't have.
//!   The `_NET_SUPPORTED` root property must round-trip the advertised list
//!   exactly (the behavioural audit of that list is the display-free
//!   ewmh_supported_test).

const std = @import("std");
const core = @import("core");
const model = @import("model");
const pipeline = @import("pipeline");
const window = @import("window");
const atoms = @import("atoms");
const requests = @import("requests");
const fixture = @import("fixture");
const xcb = core.xcb;

/// Builds the ClientMessage a browser sends for native fullscreen.
///
/// Layout per EWMH: `window` = the target window, `message_type` = the atom,
/// `format` = 32, and the payload in `data32`. `_NET_WM_FULLSCREEN_REQUEST`
/// puts the intended END STATE in data32[0] (1 enter, 0 leave); browsers also
/// set data32[1] to 2 ("application"), which hana ignores.
fn fullscreenRequest(win: u32, enter: bool) xcb.xcb_client_message_event_t {
    var ev: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    ev.format = 32;
    ev.window = win;
    ev.response_type = xcb.XCB_CLIENT_MESSAGE;
    ev.type = atoms.getAtomOrZero("_NET_WM_FULLSCREEN_REQUEST");
    ev.data.data32[0] = @intFromBool(enter);
    ev.data.data32[1] = 2; // source indication: application
    return ev;
}

/// The `_NET_WM_STATE` variant Firefox/Zen use: data32[0] is the action
/// (0 remove, 1 add, 2 toggle) and data32[1] carries the target atom.
fn wmStateRequest(win: u32, action: u32) xcb.xcb_client_message_event_t {
    var ev: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    ev.format = 32;
    ev.window = win;
    ev.response_type = xcb.XCB_CLIENT_MESSAGE;
    ev.type = atoms.getAtomOrZero("_NET_WM_STATE");
    ev.data.data32[0] = action;
    ev.data.data32[1] = atoms.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
    ev.data.data32[2] = 0; // second state atom: none requested
    // EWMH carries the source indication (1 = application, 2 = pager) in
    // data32[3], not data32[2]. The handler does not read it yet, but the
    // fixture message must be shaped the way EWMH says clients send it.
    ev.data.data32[3] = 1;
    return ev;
}

fn covering(m: *const model.Model) ?u32 {
    return model.coveringOccupantOnWs(m, m.current);
}

fn admit(win: u32) void {
    window.mapRequest(win, 0, true, null, null);
}

test "EWMH: a browser's fullscreen REQUEST covers the window" {
    // The regression itself: Mod+F (a keybinding) reaches the model path and
    // works; this ClientMessage is the same request in EWMH form, and dropping
    // it leaves the player windowed.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    admit(w1);
    admit(w2);
    fx.flush();
    try std.testing.expect(covering(m) == null);

    var ev = fullscreenRequest(w2, true);
    window.handleClientMessage(&ev);
    fx.flush();

    try std.testing.expectEqual(w2, covering(m) orelse return error.NoOccupant);
    try std.testing.expectEqual(.covering, (m.store.get(w2) orelse return error.UnknownWindow).presence);
}

test "EWMH: fullscreen REQUEST is a SET, so a redundant enter is a no-op" {
    // A browser re-asserts fullscreen on the window it already believes is
    // fullscreen (tab switch, player re-attach). Feeding that to a toggle
    // kicks the window back OUT -- the user sees fullscreen flash and revert.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    admit(w1);
    admit(w2);
    fx.flush();

    var enter = fullscreenRequest(w2, true);
    window.handleClientMessage(&enter);
    fx.flush();
    try std.testing.expectEqual(w2, covering(m) orelse return error.NoOccupant);

    // The redundant re-assert the browser actually produces.
    window.handleClientMessage(&enter);
    fx.flush();
    try std.testing.expectEqual(w2, covering(m) orelse return error.NoOccupant);

    // And an explicit leave still leaves.
    var leave = fullscreenRequest(w2, false);
    window.handleClientMessage(&leave);
    fx.flush();
    try std.testing.expect(covering(m) == null);
}

test "EWMH: _NET_WM_STATE add/remove reaches the same transition" {
    // Firefox and Zen use the _NET_WM_STATE form for native fullscreen, not
    // _NET_WM_FULLSCREEN_REQUEST. Both must work; this is the branch that
    // carries the action code in data32[0].
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    admit(w1);
    admit(w2);
    fx.flush();

    const ewmh_add: u32 = 1;
    var add = wmStateRequest(w2, ewmh_add);
    window.handleClientMessage(&add);
    fx.flush();
    try std.testing.expectEqual(w2, covering(m) orelse return error.NoOccupant);

    const ewmh_remove: u32 = 0;
    var remove = wmStateRequest(w2, ewmh_remove);
    window.handleClientMessage(&remove);
    fx.flush();
    try std.testing.expect(covering(m) == null);
}

test "EWMH: _NET_WM_STATE toggle flips, matching the action code's meaning" {
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    admit(w1);
    fx.flush();
    try std.testing.expect(covering(m) == null);

    const ewmh_toggle: u32 = 2;
    var on = wmStateRequest(w1, ewmh_toggle);
    window.handleClientMessage(&on);
    fx.flush();
    try std.testing.expectEqual(w1, covering(m) orelse return error.NoOccupant);

    window.handleClientMessage(&on);
    fx.flush();
    try std.testing.expect(covering(m) == null);
}

test "EWMH: an unmanaged window's request is ignored, not honoured" {
    // The security-shaped half of the branch: a ClientMessage naming a window
    // hana does not manage must not cover anything.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const managed = fx.createWindow();
    admit(managed);
    fx.flush();

    // Never admitted: not in the query table.
    const stranger = fx.createWindow();

    var ev = fullscreenRequest(stranger, true);
    window.handleClientMessage(&ev);
    fx.flush();
    try std.testing.expect(covering(m) == null);

    // And the managed window is still honoured afterwards: the once-per-
    // process warning must not latch in a way that swallows later requests.
    var ok = fullscreenRequest(managed, true);
    window.handleClientMessage(&ok);
    fx.flush();
    try std.testing.expectEqual(managed, covering(m) orelse return error.NoOccupant);
}

test "EWMH: a non-32-format ClientMessage is ignored" {
    // data32 is only meaningful at format 32; reading it otherwise is reading
    // a different union member entirely.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    admit(w1);
    fx.flush();

    var ev = fullscreenRequest(w1, true);
    ev.format = 8;
    window.handleClientMessage(&ev);
    fx.flush();
    try std.testing.expect(covering(m) == null);
}

test "EWMH: _NET_ACTIVE_WINDOW is reported as unimplemented, not acted on" {
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    admit(w1);
    admit(w2);
    fx.flush();
    const focused_before = m.focused;

    var ev: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    ev.format = 32;
    ev.window = w1;
    ev.response_type = xcb.XCB_CLIENT_MESSAGE;
    ev.type = atoms.getAtomOrZero("_NET_ACTIVE_WINDOW");
    ev.data.data32[0] = 2; // source: pager
    window.handleClientMessage(&ev);
    fx.flush();

    // Unimplemented activation must not move focus as a side effect.
    try std.testing.expectEqual(focused_before, m.focused);
    try std.testing.expect(covering(m) == null);
}

test "EWMH: an unknown action code on a fullscreen REQUEST is dropped" {
    // data32[0] outside {0,1} is undefined; guessing would mean entering or
    // leaving fullscreen on a client that asked for neither.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    admit(w1);
    fx.flush();

    var ev = fullscreenRequest(w1, true);
    ev.data.data32[0] = 99;
    window.handleClientMessage(&ev);
    fx.flush();
    try std.testing.expect(covering(m) == null);
}

test "EWMH: a _NET_WM_STATE request naming another atom changes nothing" {
    // The state branch must not fire on e.g. _NET_WM_STATE_ABOVE.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    admit(w1);
    fx.flush();

    var ev: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    ev.format = 32;
    ev.window = w1;
    ev.response_type = xcb.XCB_CLIENT_MESSAGE;
    ev.type = atoms.getAtomOrZero("_NET_WM_STATE");
    ev.data.data32[0] = 1; // add
    ev.data.data32[1] = atoms.getAtomOrZero("_NET_WM_STATE_ABOVE");
    window.handleClientMessage(&ev);
    fx.flush();

    try std.testing.expect(covering(m) == null);
    try std.testing.expectEqual(model.Presence.present, (m.store.get(w1) orelse return error.UnknownWindow).presence);
}

test "EWMH: _NET_SUPPORTED on the root round-trips the advertised list" {
    // The publish path main takes at startup, then a client-style read of the
    // property: what the root ends up holding is EXACTLY supported_atoms, one
    // interned (non-NONE) atom per entry, no truncation. The behavioural half
    // of the audit -- every advertised atom is handled, unimplemented hints
    // stay absent -- is the display-free ewmh_supported_test; this guards the
    // wiring between that list and the wire.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const st = core.getState();
    requests.advertiseEwmhSupport(st.conn, st.screen, st.root);
    fx.flush();

    const net_supported = atoms.getAtomOrZero("_NET_SUPPORTED");
    try std.testing.expect(net_supported != xcb.XCB_ATOM_NONE);
    const reply = xcb.xcb_get_property_reply(
        st.conn,
        xcb.xcb_get_property(st.conn, 0, st.root, net_supported, xcb.XCB_ATOM_ATOM, 0, 64),
        null,
    ) orelse return error.NoPropertyReply;
    defer std.c.free(reply);

    try std.testing.expectEqual(@as(u8, 32), reply.*.format);
    const n: usize = @intCast(@divTrunc(xcb.xcb_get_property_value_length(reply), 4));
    try std.testing.expectEqual(@as(usize, requests.supported_atoms.len), n);
    const values: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    inline for (requests.supported_atoms, 0..) |name, i| {
        const interned = atoms.getAtomOrZero(name);
        try std.testing.expect(interned != xcb.XCB_ATOM_NONE);
        try std.testing.expectEqual(interned, values[i]);
    }
}

/// The shape of a pager ClientMessage with a single-index payload (the
/// close/switch-desktop/move-desktop family). EWMH delivers these to the
/// root; the window field names the TARGET for _NET_CLOSE_WINDOW and
/// _NET_WM_DESKTOP, and is the root for _NET_CURRENT_DESKTOP.
fn pagerRequest(win: u32, comptime atom_name: []const u8) xcb.xcb_client_message_event_t {
    var ev: xcb.xcb_client_message_event_t = std.mem.zeroes(xcb.xcb_client_message_event_t);
    ev.format = 32;
    ev.window = win;
    ev.response_type = xcb.XCB_CLIENT_MESSAGE;
    ev.type = atoms.getAtomOrZero(atom_name);
    return ev;
}

test "EWMH: _NET_CLOSE_WINDOW sends WM_DELETE to a protocol-aware client" {
    // The pager's close BUTTON (a taskbar X) must not force-destroy a client
    // that follows ICCCM: the request goes as WM_DELETE_WINDOW, exactly like
    // the close_window keybind, and the window survives until the client
    // decides otherwise. Asserted by reading the fixture connection's own
    // queue for the outgoing client message -- the same connection created
    // the window, so a send_event to it lands here.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();

    const polite = fx.createWindow();
    fx.setWmTakeFocus(polite); // WM_PROTOCOLS = [WM_TAKE_FOCUS, WM_DELETE_WINDOW]
    admit(polite);
    fx.flush();
    try std.testing.expect(fx.geometry(polite) != null);

    var ev = pagerRequest(polite, "_NET_CLOSE_WINDOW");
    window.handleClientMessage(&ev);
    fx.flush();

    // Deletion REQUEST, not a destroy: the server still has the window.
    try std.testing.expect(fx.geometry(polite) != null);

    // Round trip so the server has processed (and queued to us) the send,
    // then drain the queue looking for the outgoing ICCCM message. Bit 7 is
    // the SendEvent flag the server sets on every sent event.
    const sync = fx.inputFocus();
    _ = sync;
    const wm_protocols = atoms.getAtomOrZero("WM_PROTOCOLS");
    const wm_delete = atoms.getAtomOrZero("WM_DELETE_WINDOW");
    var saw_delete = false;
    while (xcb.xcb_poll_for_event(fx.conn)) |raw| {
        defer std.c.free(raw);
        if (raw.*.response_type & 0x7F != xcb.XCB_CLIENT_MESSAGE) continue;
        const cm: *const xcb.xcb_client_message_event_t = @ptrCast(@alignCast(raw));
        if (cm.window == polite and
            cm.type == wm_protocols and
            cm.data.data32[0] == wm_delete)
        {
            saw_delete = true;
        }
    }
    try std.testing.expect(saw_delete);
}

test "EWMH: _NET_CLOSE_WINDOW destroys a protocol-less client, never an unmanaged one" {
    // The fallback half: a client with no WM_DELETE_WINDOW cannot be asked
    // politely, so closeViaProtocol destroys it -- the same last resort the
    // keybind takes. And the guard half: event.window is spoofable content
    // of the message, so an id hana doesn't manage must not be touched.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();

    const rude = fx.createWindow(); // no WM_PROTOCOLS -> destroy fallback
    admit(rude);
    const stranger = fx.createWindow(); // never admitted
    fx.flush();
    try std.testing.expect(fx.geometry(stranger) != null);

    var probe = pagerRequest(stranger, "_NET_CLOSE_WINDOW");
    window.handleClientMessage(&probe);
    fx.flush();
    // Unmanaged: not destroyed.
    try std.testing.expect(fx.geometry(stranger) != null);

    var ev = pagerRequest(rude, "_NET_CLOSE_WINDOW");
    window.handleClientMessage(&ev);
    fx.flush();
    try std.testing.expect(fx.geometry(rude) == null);
}

test "EWMH: _NET_CURRENT_DESKTOP switches workspace; an unknown desktop is dropped" {
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();
    try std.testing.expectEqual(@as(u8, 0), m.current.index);

    var ev = pagerRequest(fx.root, "_NET_CURRENT_DESKTOP");
    ev.data.data32[0] = 2;
    window.handleClientMessage(&ev);
    fx.flush();
    try std.testing.expectEqual(@as(u8, 2), m.current.index);

    // data32[0] beyond the configured workspace count: dropped, not clamped
    // or wrapped -- the pager asked for something this hana doesn't have.
    ev.data.data32[0] = 99;
    window.handleClientMessage(&ev);
    fx.flush();
    try std.testing.expectEqual(@as(u8, 2), m.current.index);
}

test "EWMH: _NET_WM_DESKTOP moves a managed window; guards drop the rest" {
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.state();

    const w1 = fx.createWindow();
    admit(w1);
    fx.flush();
    const before = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(model.taggedOn(before, model.WSId.fromIndex(0)));

    var ev = pagerRequest(w1, "_NET_WM_DESKTOP");
    ev.data.data32[0] = 3;
    window.handleClientMessage(&ev);
    fx.flush();
    const after = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(model.taggedOn(after, model.WSId.fromIndex(3)));
    try std.testing.expect(!model.taggedOn(after, model.WSId.fromIndex(0)));

    // Unknown target: dropped, window keeps its current workspace.
    ev.data.data32[0] = 99;
    window.handleClientMessage(&ev);
    fx.flush();
    const still = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(model.taggedOn(still, model.WSId.fromIndex(3)));

    // 0xFFFFFFFF ("all workspaces") has no per-window meaning in hana's
    // model (all-view is a global mode), so it must not clear the tag either.
    ev.data.data32[0] = 0xFFFFFFFF;
    window.handleClientMessage(&ev);
    fx.flush();
    const sticky = m.store.get(w1) orelse return error.UnknownWindow;
    try std.testing.expect(model.taggedOn(sticky, model.WSId.fromIndex(3)));

    // Unmanaged target: the hook is never called, nothing enters the store.
    const stranger = fx.createWindow();
    var probe = pagerRequest(stranger, "_NET_WM_DESKTOP");
    probe.data.data32[0] = 3;
    window.handleClientMessage(&probe);
    fx.flush();
    try std.testing.expect(m.store.get(stranger) == null);
}
