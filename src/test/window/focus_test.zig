//! X-gated integration tests for the two-phase focus protocol
//! (src/window/protocol/focus.zig): ICCCM input-model resolution against real server
//! properties, the prepare/apply split, dedup, and the clear path. Self-skips
//! on machines without an X server so `zig build test` stays green headless.

// Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: tiling

const std = @import("std");
const core = @import("core");

const model = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const fixture = @import("fixture");
const actions = @import("actions");
const window = @import("window");

fn admit(win: u32) !void {
    actions.mapRequest(win, 0, true, null, null); // takes its own mutable model via pipeline.mut
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
    var fx = try fixture.setUp("focus_test");
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
    try std.testing.expect(focus.prepareFocus(win, .user_command) == .none);
}

test "focus: WM_TAKE_FOCUS window (locally_active) still lands input focus" {
    var fx = try fixture.setUp("focus_test");
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
    try std.testing.expect(focus.prepareFocus(win, .user_command) == .none);
}

test "focus: no_input window refuses focus (no_input transition)" {
    var fx = try fixture.setUp("focus_test");
    defer fx.deinit();
    const m = pipeline.model();

    const win = fx.createWindow();
    fx.setNoInput(win); // WM_HINTS input=False
    admitViaMapRequest(win); // real map path seeds the ICCCM focus cache
    const t = focus.prepareFocus(win, .user_command);
    // `.no_input`, NOT `.none`: the two are deliberately distinct so a caller
    // that mutates the model on its own can tell "this target is focus-less"
    // from "this was a dedup skip". This test asserted `.none` and so failed
    // once the split limb landed -- it had never run before, because the
    // fixture skips without an X display.
    try std.testing.expect(t == .no_input);
    // A no_input window can never hold X input focus, so it must not take
    // model focus either (model focus is one store with the protocol).
    try std.testing.expect(@as(?u32, null) == m.focused); // model untouched
}

test "focus: switching to an empty workspace clears input focus to root" {
    var fx = try fixture.setUp("focus_test");
    defer fx.deinit();

    const win = fx.createWindow();
    try admit(win);
    try std.testing.expectEqual(win, fx.inputFocus());

    // switchTo(empty workspace) runs prepareClearFocus + applyPendingFocus, the same
    // two-phase path a real workspace switch to an empty target uses.
    actions.switchTo(2); // workspace 2 is empty: no candidate -> clear to root
    fx.flush();

    try std.testing.expectEqual(fx.root, fx.inputFocus());
    try std.testing.expect(@as(?u32, null) == focus.getFocused());
    // Both the cache and model truth are empty after the clear settled.
    try std.testing.expect(focus.protocolParityHolds());
}

test "focus: destroyed window under a mouse_click is never re-focused (liveness before dedup)" {
    var fx = try fixture.setUp("focus_test");
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
    try std.testing.expect(focus.prepareFocus(win, .mouse_click) == .none);
    try std.testing.expect(focus.protocolParityHolds());
}

test "focus: switch to a workspace with a never-shown window lands input focus" {
    var fx = try fixture.setUp("focus_test");
    defer fx.deinit();
    const m = pipeline.model();

    // w1 lives on the current workspace and holds focus.
    const w1 = fx.createWindow();
    try admit(w1);
    fx.flush();
    try std.testing.expectEqual(w1, fx.inputFocus());

    // w2 is admitted on workspace 1 while workspace 0 is current: it is parked off-current
    // and never mapped (the spawn register path sends no map).
    const w2 = fx.createWindow();
    actions.mapRequest(w2, 1, false, null, null);
    fx.flush();
    try std.testing.expect(!fx.isViewable(w2));

    actions.switchTo(1);
    fx.flush();

    // The arriving window must be mapped before xcb_set_input_focus targets
    // it; otherwise the request is a BadMatch and focus stays on w1.
    try std.testing.expect(fx.isViewable(w2));
    try std.testing.expectEqual(w2, fx.inputFocus());
    try std.testing.expectEqual(w2, m.focused.?);
}

test "focus: switch lands xcb_set_input_focus on globally_active window" {
    var fx = try fixture.setUp("focus_test");
    defer fx.deinit();
    const m = pipeline.model();

    // w1 on workspace 0 holds focus.
    const w1 = fx.createWindow();
    try admit(w1);
    fx.flush();
    try std.testing.expectEqual(w1, fx.inputFocus());

    // w2 is globally_active (WM_TAKE_FOCUS advertised + WM_HINTS input=False).
    // The WM must force xcb_set_input_focus during workspace switch rather than
    // relying on WM_TAKE_FOCUS self-focus, which parked windows may ignore.
    const w2 = fx.createWindow();
    fx.setWmTakeFocus(w2);
    fx.setNoInput(w2);
    actions.mapRequest(w2, 1, false, null, null);
    fx.flush();

    actions.switchTo(1);
    fx.flush();

    try std.testing.expectEqual(w2, fx.inputFocus());
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expect(focus.protocolParityHolds());
}

// The Mod+j/k cycle must follow the arrangement on screen, not the order the
// windows were created in: after a move or a master swap the windows sit
// somewhere else, so the next cycle step has to land on the new neighbour.
// Four windows, so both mutations below are transpositions. A three-window
// swap_master can only ever produce a ROTATION of the spawn order, and a
// rotation cycles identically -- the old id-ordered pool would agree with the
// layout and hide the bug.
test "focus: cycle steps follow the tiled order after a move and a swap" {
    var fx = try fixture.setUp("focus_test");
    defer fx.deinit();
    const m = pipeline.model();

    // Created in id order, which is also the spawn order, so the pool's
    // first version (store order) is indistinguishable from the layout here.
    const w1 = fx.createWindow();
    const w2 = fx.createWindow();
    const w3 = fx.createWindow();
    const w4 = fx.createWindow();
    for ([_]u32{ w1, w2, w3, w4 }) |w| {
        try admit(w);
        fx.flush();
    }
    const order = &m.ws[m.current.index].tiled_order;
    try std.testing.expectEqualSlices(u32, &.{ w1, w2, w3, w4 }, order.constSlice());
    try std.testing.expectEqual(w4, m.focused.?);

    // Mod+Shift+j (the key dispatches to actions.moveFocused) walks the
    // focused window one slot toward the head: [w1,w2,w4,w3]. From w4 the
    // next step must be w3 (its new neighbour), where the id order would
    // have wrapped around to w1.
    actions.moveFocused(-1);
    fx.flush();
    try std.testing.expectEqualSlices(u32, &.{ w1, w2, w4, w3 }, order.constSlice());
    try std.testing.expectEqual(w3, focus.cycleTarget(.forward).?);
    try std.testing.expectEqual(w2, focus.cycleTarget(.reverse).?);

    // Mod+Tab (swap_master) exchanges the focused and previous slots: with
    // w3 then w2 focused, [w1,w2,w4,w3] becomes [w1,w3,w4,w2]. w2 now sits
    // in the LAST slot, so a forward step must wrap to w1, not step to w3
    // the way the id order would.
    focus.grabFocusWithDuty(w3, .user_command, null);
    focus.grabFocusWithDuty(w2, .user_command, null);
    fx.flush();
    actions.swapPrimaryAction(false);
    fx.flush();
    try std.testing.expectEqualSlices(u32, &.{ w1, w3, w4, w2 }, order.constSlice());
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w1, focus.cycleTarget(.forward).?);
    try std.testing.expectEqual(w4, focus.cycleTarget(.reverse).?);
}

test "focus: parked cursor cannot steal a fresh spawn's focus (sticky-at-pixel suppression)" {
    var fx = try fixture.setUp("focus_test");
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

    // The crossings the spawn's map generates land exactly on the snapshot
    // position: they are synthetic (an enter into the spawned window and the
    // return crossing into the window it displaced), so NEITHER may
    // re-hover-focus w1. w2 keeps both model and X focus.
    enterNotify(fx, w1, 200, 200);
    fx.flush();
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w2, fx.inputFocus());
    enterNotify(fx, w1, 200, 200);
    fx.flush();
    try std.testing.expectEqual(w2, m.focused.?);
    try std.testing.expectEqual(w2, fx.inputFocus());

    // The guard releases only on a genuine pointer move: a hover at a
    // different pixel is real and hands focus back to the window under it.
    _ = xcb.xcb_warp_pointer(fx.conn, xcb.XCB_NONE, fx.root, 0, 0, 0, 0, 400, 400);
    fx.flush();
    enterNotify(fx, w1, 400, 400);
    fx.flush();
    try std.testing.expectEqual(w1, m.focused.?);
    try std.testing.expect(focus.protocolParityHolds());
}

// The destroyed-window guard applies to `.user_command` too.
//
// The guard used to be `if (reason == .mouse_click and !isWindowMapped(...))`,
// with `.user_command` excluded because the focus-cycle callers had already
// confirmed visibility. floating.zig reaches
// grabFocus(win, .user_command) directly, so that reasoning did not hold
// there: a window destroyed between admission and the toggle could be focused
// and raised. The new model-side `store.has` check closes it with no round
// trip, and this is the regression test for that specific path.
//
// X-gated like the rest of this file (grabFocus takes a real server grab).
test "focus: a destroyed window cannot take focus via user_command" {
    var fx = try fixture.setUp("focus_test");
    defer fx.deinit();

    const w1 = fx.createWindow();
    try admit(w1);
    fx.flush();

    const m = pipeline.model();
    const m2 = pipeline.mut();

    // Destroy the window behind the model's back: the entry leaves the store
    // (what a DestroyNotify would do) but no event is delivered, so this is
    // the exact window a stale caller could still be holding.
    model.unregister(m2, w1);
    fx.flush();

    try std.testing.expect(!m.store.has(w1));

    // The direct `.user_command` route the guard used to let through.
    focus.grabFocus(w1, .user_command);
    fx.flush();

    try std.testing.expect(m.focused == null or m.focused.? != w1);
}
