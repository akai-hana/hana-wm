//! X-gated integration tests for the two-phase focus protocol
//! (src/window/focus.zig): ICCCM input-model resolution against real server
//! properties, the prepare/apply split, dedup, and the clear path. Self-skips
//! on machines without an X server so `zig build test` stays green headless.

const std = @import("std");

const model = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const fixture = @import("fixture");
const actions = @import("actions");

fn admit(win: u32) !void {
    actions.mapRequest(win, 0, true); // takes its own mutable model via pipeline.mut
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
    try std.testing.expect(m.focused != null and m.focused.? == win);
    try std.testing.expectEqual(win, (fx.rootActiveWindow() orelse return error.MissingActiveWindow));

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
    try std.testing.expect(m.focused != null and m.focused.? == win);
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
    try std.testing.expect(m.focused != null and m.focused.? == win); // model untouched
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
}
