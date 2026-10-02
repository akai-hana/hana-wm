//! Tests for the EWMH ClientMessage entry point (`window.handleClientMessage`),
//! the path a BROWSER's native fullscreen takes.
//!
//! WHY A SEPARATE FILE
//!   The regression guarded here is not reachable through `actions`: the
//!   keybind (Mod+F) and the EWMH message are different callers of the same
//!   transition, and only the message one had ever been broken. `Mod+F`
//!   working while the browser's own fullscreen button did nothing is exactly
//!   this asymmetry -- the model path is fine and the EVENT path is not, so a
//!   test that drives `actions.fullscreenSetWindow` (as pipeline_test does)
//!   cannot see the bug at all. Every test below goes through the real
//!   handler with a synthesized `xcb_client_message_event_t`.
//!
//! WHAT IS PINNED
//!   The `_NET_WM_FULLSCREEN_REQUEST` and `_NET_WM_STATE` branches must each
//!   reach the covering transition for a managed window, must treat the
//!   message's action code as a SET (`data32[0]`) rather than a toggle, and
//!   must not consume an unmanaged window's request in a way that leaves the
//!   once-per-process warning latched against later legitimate requests.

const std = @import("std");
const core = @import("core");
const model = @import("model");
const pipeline = @import("pipeline");
const actions = @import("actions");
const window = @import("window");
const atoms = @import("atoms");
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
    ev.data.data32[2] = 0; // "normal" source
    return ev;
}

fn covering(m: *const model.Model) ?u32 {
    return model.coveringOccupantOnWs(m, m.current);
}

fn admit(win: u32) void {
    actions.mapRequest(win, 0, true, null);
}

test "EWMH: a browser's fullscreen REQUEST covers the window" {
    // The regression itself. Mod+F (a keybind -> actions) works, so the model
    // path is healthy; the browser button arrives as this ClientMessage and
    // used to be dropped, leaving the player windowed.
    var fx = try fixture.setUp("ewmh_test");
    defer fx.deinit();
    const m = pipeline.model();

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
    const m = pipeline.model();

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
    const m = pipeline.model();

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
    const m = pipeline.model();

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
    const m = pipeline.model();

    const managed = fx.createWindow();
    admit(managed);
    fx.flush();

    // Never admitted: not in the tracking table.
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
    const m = pipeline.model();

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
    const m = pipeline.model();

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
    const m = pipeline.model();

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
    const m = pipeline.model();

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
