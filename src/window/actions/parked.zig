//! The parked-window actions: the minimize module parks a window
//! off-screen; restore/restoreOrdered/
//! restoreAll unpark. Each action is one model transition + one
//! sync entry. The shared transition tails (retile, focusFallback,
//! prepareAndSetFocus, the covering-occupant queries) live in
//! `actions.zig`, the hub this file imports: the two files form
//! the window layer's intentional runtime-only import cycle (the
//! same hub-and-spoke shape check-layers.sh documents for
//! core<->window).

const model_mod = @import("model");
const pipeline = @import("pipeline");
const build_options = @import("build_options");

const actions = @import("actions");
const registry = @import("registry");

const providerOf = registry.providerOf;

const callHook = registry.callHook;
const dispatchAll = registry.dispatchAll;

// hide (window park)

/// Atomicity: hide + fallback-focus + retile land under one grab.
///
/// Focus policy reads MODEL truth (`m.focused`): hiding the focused
/// window hands focus over via focusFallback, otherwise m.focused would keep
/// pointing at the hidden window (stale title segment, stale border colors
/// until the next unrelated focus event).
///
/// Hiding THE screen-covering occupant also frees the bar-hide reason: the
/// bar comes back (setBarState re-derives occupancy itself and no-ops when
/// another occupant remains or the user toggled the bar off). It runs BEFORE
/// the reconcile because the bar must have updated its screen claim (the
/// usable-area fact the reconcile reads) before placement is re-derived.
pub fn minimize(focused: ?model_mod.WindowId) void {
    const wm = providerOf(.hideWindow) orelse return;
    const win = focused orelse return;
    const m = pipeline.mut();
    const was_focused = m.focused == win;
    const fs_ws_before =
        model_mod.coveringWsOf(m, win); // Model query

    wm.hideWindow.?(m, win) catch return; // Pre-refusal (CapacityFull)

    // Hiding the current workspace's covering occupant releases its screen
    // claim; retileWithFallback bumps the core fact so the bar reacts.
    actions.retileWithFallback(m, if (fs_ws_before) |fs_ws| fs_ws.eql(m.current) else false, was_focused);
}

// restore (unpark)

/// Shared hide/close withdraw tail helper for the restore family:
/// arms the deferred bar-hide when the restore opened a fresh claim.
fn armFullscreenBarHideIfNeeded(
    m: *const model_mod.Model,
    win: model_mod.WindowId,
    had_occupant_before: bool,
) void {
    if (build_options.has_bar and !had_occupant_before and model_mod.isCoveringOn(m, win, m.current)) {
        dispatchAll(.armPendingBarHide, .{win});
    }
}

/// Restores `win` via the minimize module's `restoreWindow` hook, re-focuses it,
/// and arms the deferred bar-hide when the restore opened a fresh claim.
fn restoreTarget(m: *model_mod.Model, win: model_mod.WindowId) void {
    const had_occupant_before = actions.currentCoveringOccupant(m) != null;
    callHook(.restoreWindow, .{ m, win });
    restoreAndFocus(m, win);
    armFullscreenBarHideIfNeeded(m, win, had_occupant_before);
}

/// Restores a specific hidden window (title-bar click path).
pub fn restore(win: model_mod.WindowId) void {
    const m = pipeline.mut();
    if (!actions.isMinimizedOnAnyWs(m, win)) return;
    restoreTarget(m, win);
}

/// Slot-ordered single restore (LIFO/FIFO keybind paths).
pub fn restoreOrdered(order: model_mod.RestoreOrder) void {
    const m = pipeline.mut();
    const win = (if (providerOf(.restoreCandidateOn)) |wm|
        wm.restoreCandidateOn.?(m, m.current, order)
    else
        null) orelse return;
    restoreTarget(m, win);
}

/// Slot-ordered bulk restore of the current workspace. Focus target is
/// the most recently hidden PLAIN window (screen-covering windows replay
/// through the same reconcile's covering branch, straight back into
/// covering).
pub fn restoreAll() void {
    const m = pipeline.mut();
    const wm = providerOf(.latestHiddenOnWs) orelse return;
    const ws = m.current;
    const target = (wm.latestHiddenOnWs.?(m, ws) orelse return);
    const had_occupant_before = actions.currentCoveringOccupant(m) != null;
    callHook(.restoreOnWs, .{ m, ws });
    restoreAndFocus(m, target);
    if (actions.currentCoveringOccupant(m)) |occ|
        armFullscreenBarHideIfNeeded(m, occ, had_occupant_before);
}

/// Shared restore tail: re-focus the restored window (a no_input
/// restore never takes model focus, but the reconcile still runs so
/// the restored window is mapped and placed).
fn restoreAndFocus(m: *model_mod.Model, win: model_mod.WindowId) void {
    const prep = actions.prepareAndSetFocus(m, win, .window_spawn);
    pipeline.reconcileGrabFocus(.{ .force_restack = true }, prep, .before, null);
}
