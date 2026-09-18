//! X-gated integration tests for the two-phase focus protocol
//! (src/window/focus.zig): ICCCM input-model resolution against real server
//! properties, the prepare/apply split, dedup, and the clear path. Self-skips
//! on machines without an X server so `zig build test` stays green headless.

const std = @import("std");
const core = @import("core");

const model = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const fixture = @import("fixture");
const actions = @import("actions");
const window = @import("window");

fn admit(win: u32) !void {
    actions.mapRequest(win, 0, true, null); // takes its own mutable model via pipeline.mut
}

/// Admits `win` through handleMapRequest so the spawn-cursor snapshot runs
/// exactly as in production (actions.mapRequest bypasses it).
fn admitViaMapRequest(win: u32) void {
    var ev = std.mem.zeroes(core.xcb.xcb_map_request_event_t);
    ev.response_type = core.xcb.XCB_MAP_REQUEST;
    ev.window = win;
    window.handleMapRequest(&ev);
}

/// Hands handleEnterNotify a synthetic crossing event at root (x, y) for
/// `win`, as a spawned window's mapping would deliver when the cursor is
/// parked over it.
fn enterNotify(fx: *fixture.Fx, win: u32, x: i16, y: i16) void {
    var ev = std.mem.zeroes(core.xcb.xcb_enter_notify_event_t);
    ev.response_type = core.xcb.XCB_ENTER_NOTIFY;
    ev.mode = core.xcb.XCB_NOTIFY_MODE_NORMAL;
    ev.detail = core.xcb.XCB_NOTIFY_DETAIL_ANCESTOR;
    ev.event = win;
    ev.root = fx.root;
    ev.root_x = x;
    ev.root_y = y;
    window.handleEnterNotify(&ev);
}

test "focus: property-less window is passive; apply lands input focus" {
    var fx = fixture.setUp("focus_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    // Admission runs the full two-phase protocol internally: prepareFocus
    // (.window_spawn) then apply inside the reconcile grab. A property-less
    // window resolves to `.passive`, so X input focus lands on it directly.
    const win = fx.createWindow();
    try admit(win);
    fx.flush();

    try std.testing.expectEqual(win, fx.inputFocus());
    try std.testing.expectEqual(win, m.focused.?);
    try std.testing.expectEqual(win, (fx.rootActiveWindow() orelse return error.MissingActiveWindow));
    // Protocol cache and model truth must agree once the transition settled.
    try std.testing.expect(focus.protocolParityHolds());

    // Already-applied window: a repeated prepare is a pure dedup no-op.
    try std.testing.expect(focus.prepareFocus(win, .user_command, null) == .none);
}

test "focus: WM_TAKE_FOCUS window (locally_active) still lands input focus" {
    var fx = fixture.setUp("focus_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    // locally_active windows get xcb_set_input_focus (model != .globally_active)
    // plus the WM_TAKE_FOCUS protocol message.
    const win = fx.createWindow();
    fx.setWmTakeFocus(win); // properties must pre-exist the resolve
    try admit(win);
    fx.flush();

    try std.testing.expectEqual(win, fx.inputFocus());
    try std.testing.expectEqual(win, m.focused.?);
    try std.testing.expect(focus.protocolParityHolds());
    try std.testing.expect(focus.prepareFocus(win, .user_command, null) == .none);
}

test "focus: no_input window refuses focus (none transition)" {
    var fx = fixture.setUp("focus_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();

    const win = fx.createWindow();
    fx.setNoInput(win); // WM_HINTS input=False
    try admit(win);

    const t = focus.prepareFocus(win, .user_command, null);
    try std.testing.expect(t == .none);
    // A no_input window can never hold X input focus, so it must not take
    // model focus either (model focus is one store with the protocol).
    try std.testing.expect(@as(?u32, null) == m.focused); // model untouched
}

test "focus: switching to an empty workspace clears input focus to root" {
    var fx = fixture.setUp("focus_test") orelse return;
    defer fx.deinit();

    const win = fx.createWindow();
    try admit(win);
    try std.testing.expectEqual(win, fx.inputFocus());

    // switchTo(empty ws) runs prepareClearFocus + applyPendingFocus, the same
    // two-phase path a real workspace switch to an empty target uses.
    actions.switchTo(2); // ws 2 is empty: no candidate -> clear to root
    fx.flush();

    try std.testing.expectEqual(fx.root, fx.inputFocus());
    try std.testing.expect(@as(?u32, null) == focus.getFocused());
    // Both the cache and model truth are empty after the clear settled.
    try std.testing.expect(focus.protocolParityHolds());
}

test "focus: destroyed window under a mouse_click is never re-focused (liveness before dedup)" {
    var fx = fixture.setUp("focus_test") orelse return;
    defer fx.deinit();

    const win = fx.createWindow();
    try admit(win);
    fx.flush();
    try std.testing.expectEqual(win, fx.inputFocus());
    try std.testing.expect(focus.protocolParityHolds());

    // The window dies between the raise request and spawn-resolution. A
    // click-to-raise on the corpse must return .none even though it was the
    // last_applied window: the liveness guard (focus.zig prepareFocus) runs
    // BEFORE the dedup branch, so the raise side effect cannot republish
    // focus to a destroyed window.
    _ = core.xcb.xcb_destroy_window(fx.conn, win);
    fx.flush();
    try std.testing.expect(focus.prepareFocus(win, .mouse_click, null) == .none);
    try std.testing.expect(focus.protocolParityHolds());
}

test "focus: parked cursor cannot steal a fresh spawn's focus (one-shot suppression)" {
    var fx = fixture.setUp("focus_test") orelse return;
    defer fx.deinit();
    const m = pipeline.model();
    const xcb = core.xcb;

    // First window, admitted with the pointer parked at (100,100): its
    // MapRequest snapshots the spawn cursor there.
    const w1 = fx.createWindow();
    _ = xcb.xcb_warp_pointer(fx.conn, xcb.XCB_NONE, fx.root, 0, 0, 0, 0, 100, 100);
    fx.flush();
    admitViaMapRequest(w1);
    try std.testing.expectEqual(w1, m.focused.?);

    // Spawn a second window with the pointer at (200,200). The new spawn
    // snaps (200,200) and arms the .window_spawn suppression.
    const w2 = fx.createWindow();
    _ = xcb.xcb_warp_pointer(fx.conn, xcb.XCB_NONE, fx.root, 0, 0, 0, 0, 200, 200);
    fx.flush();
    admitViaMapRequest(w2);
    try std.testing.expectEqual(w2, m.focused.?);

    // The crossing the spawn's map generates lands exactly on the snapshot
    // position: it is synthetic, so it must NOT re-hover-focus w1. w2 keeps
    // both model and X focus.
    enterNotify(fx, w1, 200, 200);
    fx.flush();
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w2, fx.inputFocus());

    // The guard is one-shot: a second crossing at the same pixel is a real
    // hover and hands focus back to the window under the cursor.
    enterNotify(fx, w1, 200, 200);
    fx.flush();
    try std.testing.expectEqual(w1, m.focused.?);
    try std.testing.expect(focus.protocolParityHolds());
}
