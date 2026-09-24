//! Thin action wrappers: one action = one model transition + one sync entry.
//! Model state, wire requests, and focus protocol live in model, sync, and focus.

const std = @import("std");
const core = @import("core");
const constants = @import("constants");
const types = @import("types");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const persist = @import("persist");
const sync = @import("sync");
const focus = @import("focus");
const window = @import("window");
const screen = @import("screen");
const build_options = @import("build_options");
const debug = @import("debug");
const utils = @import("utils");
const tracking = @import("tracking");

// Private transition-layer gate for mutable model access: this module owns
// model transitions, so it declares its own capability token (see
// tracking.gate).
const gate: pipeline.Gate = .{};

/// Registry lookup for the hook `field` (see `contract.providerOf`), null when
/// no module binds it; canonical scan lives in window.providerOf.
const providerOf = window.providerOf;

const callHook = window.callHook;
const callHookBool = window.callHookBool;
const dispatchAll = window.dispatchAll;
const dispatchFirstTrue = window.dispatchFirstTrue;
const isCoveringMode = window.isCoveringMode;

/// Convenience: returns the current workspace's covering occupant via the
/// module AND hook (active covering record on ws), null without a fullscreen
/// module. Contrast the OR scan `model.coveringOccupantOnWs`.
fn currentCoveringOccupant(m: *const model_mod.Model) ?model_mod.WindowId {
    return if (providerOf(.coveringOccupantOnWs)) |prov|
        prov.coveringOccupantOnWs.?(m, m.current)
    else
        null;
}

/// Convenience: true when `win` is the covering (fullscreen) occupant on its
/// workspace.
fn isCoveringOnWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    return callHookBool(.isCoveringOnWs, .{ m, win, m.current });
}

/// Shared change guard for the tag/pin actions: the window must be present in
/// the model and not hidden.
fn canTagChange(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    if (m.store.get(win) == null) return false;
    return !isMinimizedOnAnyWs(m, win);
}

/// Layout registry (build-generated); the active layout is a `u8` index into
/// it, never a closed enum. Empty when the tiling subsystem is absent.
const surfaces = @import("surfaces").Surfaces;
const wincache = @import("wincache");
const contract = @import("contract");
const tiling_mods = contract.tiling_mods;
const tiling = @import("tiling_seam").tiling;

/// Withdrawal facts for actions.unmanage. The sole caller (window.
/// unmanageWindow) removes the model entry BEFORE the action runs, so both
/// fields are captured up front and ride the context in; every other entry
/// point reads live model truth and needs no context at all.
pub const Ctx = struct {
    /// Fullscreen workspace record of the window being withdrawn, captured
    /// by unmanageWindow BEFORE the workspace layer's removeWindow drops the
    /// model entry (after which no store query could recover it).
    withdrawn_fullscreen_ws: ?model_mod.WSId = null,
    /// Whether the withdrawn window held MODEL focus at withdrawal time,
    /// captured BEFORE removal clears m.focused. Drives the close
    /// fallback (parity with the hide path): the previous focus owner must hand
    /// over, otherwise the workspace stays unfocused until a pointer event.
    withdrawn_was_focused: bool = false,
};

/// Shared tail of the trivial flip-actions (C): bump the relevant core fact
/// and push ONE reconcile through the grab (viewport snap/clamp duties run
/// inside the pipeline choke point). Bumping a fact revision is a pure
/// counter increment with zero X traffic, so doing it before the reconcile is
/// wire-identical to doing it after. Actions whose pinned side-effect ORDER
/// differs (setBarState before the reconcile, armPendingBarHide after,
/// reconcile-only tails) keep their bespoke tails instead of growing this
/// helper flags.
const RetileOpts = struct {
    restack: bool = false,
    full_redraw: bool = false,
    with_focus: bool = false,
    bump_fullscreen: bool = false,
};

fn retile(opts: RetileOpts, ft: ?focus.FocusTransition) void {
    if (opts.full_redraw) core.layout.bump() else core.window.bump();
    if (opts.bump_fullscreen) core.fullscreen.bump();
    if (opts.with_focus) {
        // Focus lands before geometry (focus-before).
        pipeline.reconcileGrabFocus(if (opts.restack) .{ .force_restack = true } else .{}, ft.?, .before);
    } else pipeline.reconcileUnderGrabNow(if (opts.restack) .{ .force_restack = true } else .{});
}

/// Shared hide/close withdraw tail: when the withdrawn window was the
/// current workspace's covering occupant, bump the core fact so the bar (a
/// consumer) re-derives its screen claim before the reconcile reads the work
/// area; then hand focus to the fallback winner (or clear) and reconcile
/// focus + geometry under one grab.
fn retileWithFallback(m: *model_mod.Model, fs_current: bool, was_focused: bool) void {
    const ft: focus.FocusTransition = if (was_focused) focusFallback(m, .tiling_operation) else .none;
    retile(.{ .bump_fullscreen = fs_current, .restack = true, .with_focus = true }, ft);
}

// ----------------------------------------------------------- hide (window park)

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
    const m = pipeline.mut(&gate);
    const was_focused = m.focused == win;
    const fs_ws_before =
        if (providerOf(.coveringWsOf)) |prov| prov.coveringWsOf.?(m, win) else null;

    wm.hideWindow.?(m, win) catch return; // Pre-refusal (CapacityFull)

    // Hiding the current workspace's covering occupant releases its screen
    // claim; retileWithFallback bumps the core fact so the bar reacts.
    retileWithFallback(m, if (fs_ws_before) |fs_ws| fs_ws.eql(m.current) else false, was_focused);
}

/// Fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
/// Returns a FocusTransition for the caller to commit inside its server grab.
/// Model and protocol focus are updated together: the model update runs
/// before the grab, the protocol commit runs inside it. `reason` is the
/// prepareFocus reason handed to the winner (the fallback's own
/// `.tiling_operation`, or `.workspace_switch` on a workspace switch).
fn focusFallback(m: *model_mod.Model, reason: focus.Reason) focus.FocusTransition {
    // Tier policy lives in the model layer so tests can exercise it without
    // linking the protocol side (see model.fallbackFocusCandidate). A
    // no_input candidate can never hold X focus, so it is excluded and the
    // scan continues to the next focusable window; only when nothing
    // focusable remains is model focus cleared and X focus handed to root.
    var excluded: ?model_mod.WindowId = null;
    while (model_mod.fallbackFocusCandidate(m, m.current, excluded)) |winner| {
        const prep = prepareAndSetFocus(m, winner, reason);
        if (prep == .none and focus.lastRejectWasNoInput()) {
            excluded = winner;
            continue;
        }
        return prep;
    }
    // prepareClearFocus reads MODEL focus as its decision source, so it
    // runs BEFORE the model clear.
    const prep = focus.prepareClearFocus();
    model_mod.clearFocus(m);
    return prep;
}

/// Prepare BEFORE the model write: prepareFocus resolves the input model
/// (round trip) and can re-raise an already-applied window. The model write
/// is conditional on a real `.set` intent, so a no_input candidate never
/// takes model focus. Returns the transition so the caller can commit it
/// inside its own server grab.
fn prepareAndSetFocus(m: *model_mod.Model, win: model_mod.WindowId, reason: focus.Reason) focus.FocusTransition {
    const prep = focus.prepareFocus(win, reason);
    if (prep != .none) model_mod.setFocus(m, win);
    return prep;
}

// --------------------------------------------------------- restore (unpark)

fn isMinimizedOnAnyWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    return callHookBool(.isWindowHidden, .{ m, win });
}

fn restoreAndFocus(m: *model_mod.Model, win: model_mod.WindowId) void {
    // A no_input restore never takes model focus, but the reconcile still
    // runs so the restored window is mapped and placed.
    const prep = prepareAndSetFocus(m, win, .window_spawn);
    pipeline.reconcileGrabFocus(.{ .force_restack = true }, prep, .before);
}

fn armFullscreenBarHideIfNeeded(
    m: *const model_mod.Model,
    win: model_mod.WindowId,
    had_occupant_before: bool,
) void {
    if (build_options.has_bar and !had_occupant_before and isCoveringOnWs(m, win)) {
        dispatchAll(.armPendingBarHide, .{win});
    }
}

/// Restores `win` via the hide module's `restoreWindow` hook, re-focuses it,
/// and arms the deferred bar-hide when the restore opened a fresh claim.
fn restoreTarget(m: *model_mod.Model, win: model_mod.WindowId) void {
    const had_occupant_before = currentCoveringOccupant(m) != null;
    callHook(.restoreWindow, .{ m, win });
    restoreAndFocus(m, win);
    armFullscreenBarHideIfNeeded(m, win, had_occupant_before);
}

/// Restores a specific hidden window (title-bar click path).
pub fn restore(win: model_mod.WindowId) void {
    const m = pipeline.mut(&gate);
    if (!isMinimizedOnAnyWs(m, win)) return;
    restoreTarget(m, win);
}

/// Slot-ordered single restore (LIFO/FIFO keybind paths).
pub fn restoreOrdered(order: model_mod.RestoreOrder) void {
    const m = pipeline.mut(&gate);
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
    const m = pipeline.mut(&gate);
    const wm = providerOf(.latestHiddenOnWs) orelse return;
    const ws = m.current;
    const target = (wm.latestHiddenOnWs.?(m, ws) orelse return);
    const had_occupant_before = currentCoveringOccupant(m) != null;
    callHook(.restoreOnWs, .{ m, ws });
    restoreAndFocus(m, target);
    if (currentCoveringOccupant(m)) |occ|
        armFullscreenBarHideIfNeeded(m, occ, had_occupant_before);
}

// ------------------------------------------------------- covering (screen claim)

/// Covering enter/exit/switch for an arbitrary window in ONE model
/// transition + ONE reconcile.
///
/// The covering winner renders on the full screen edge-to-edge (screen rect,
/// bw=0, pixel=0, ABOVE merged); everyone else parks off-screen in the same
/// pass. Floating exit geometry replays from the base rect via the LastSent
/// diff; tiled exit re-derives placements from the tiling engine, so the pre-exit
/// "restore then re-park" request round collapses away.
///
/// Bar hide/show deferral and EWMH stay protocol-side, driven through the
/// window_modules registry's pending machinery so events.zig's ConfigureNotify
/// handler works unchanged. The keybind path resolves the focused window at
/// the dispatch site and lands here too.
pub fn fullscreenToggleWindow(win: model_mod.WindowId) void {
    // Timing: wall-clock from action entry (keybind/EWMH resolve) to the
    // synchronous completion of the fullscreen transition INCLUDING the bar
    // hide and the ungrabAndFlush of the enclosing grab — i.e. the point at
    // which the bar is gone and the window is sized, all visible on the next
    // compositor frame. Gated on `-Dprofile-key` like the other profiler
    // seams, so non-profiled builds skip the clock samples.
    const fs_t0: u64 = if (build_options.profile_key) utils.monotonicNs() else 0;
    const wm = providerOf(.toggleCovering) orelse return;
    if (!core.getState().config.fullscreen_enabled) return;
    const m = pipeline.mut(&gate);
    // Never cover a window off the viewed workspace: the covering
    // record binds the current ws and would claim it while hidden.
    if (!model_mod.visibleOn(m, win, m.current)) return;

    // Classify BEFORE toggling so bar deferrals keep the occupant
    // scan in one place; both the classification and prev_fs_win need
    // the same result, saving one full store scan.
    const prev_fs_win = currentCoveringOccupant(m);
    const kind: pipeline.FullscreenKind =
        if (isCoveringOnWs(m, win)) .exit else if (prev_fs_win != null) .switch_ else .enter;

    if (!wm.toggleCovering.?(m, win)) return;

    // EWMH writes + bar arming land inside the same grab as geometry -- all
    // fire-and-forget or pure state.
    pipeline.reconcileUnderGrabNowFullscreen(
        .{ .force_restack = true },
        win,
        prev_fs_win,
        kind,
    );

    // Deterministic fullscreen-exit reaction: the model no longer has a
    // covering occupant the moment the toggle lands, so bump the fact now.
    // The deferred bar-show arm waits for a non-fullscreen ConfigureNotify,
    // which never arrives when a window's restored anchor IS the screen size
    // (the model just restores it in place) -- the bar would stay hidden
    // until some unrelated event happened to bubble the fact.
    if (kind == .exit) core.fullscreen.bump();

    // Completion of the transition is synchronous: run time elapsed
    // already covers the reconcile + immediate bar hide (enter) and the
    // ungrabAndFlush, i.e. the visual-completion point.
    if (build_options.profile_key) {
        const dt = utils.monotonicNs() - fs_t0;
        debug.info("[FSPROF] win={d} kind={s} done {d}ns", .{
            win, @tagName(kind), dt,
        });
    }
}

// ------------------------------------------------- tag-move / pin / all-view

/// move_to_workspace. Model moves mask + home list + covering record in one
/// call; the reconcile's diff parks/repairs geometry globally.
pub fn moveWindowTo(win: model_mod.WindowId, ws_idx: u8) void {
    const wm = providerOf(.sendToWs) orelse return;
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.mut(&gate);
    const was_focused = m.focused == win;
    const was_fs_current = isCoveringOnWs(m, win);

    wm.sendToWs.?(m, win, model_mod.WSId.fromIndex(ws_idx));
    if (m.store.get(win) == null) return; // unknown window: no-op

    var ft: focus.FocusTransition = .none;
    if (ws_idx != m.current.index) {
        if (was_focused) ft = focusFallback(m, .tiling_operation);
        // Moving the current workspace's covering window away changes the
        // workspace's covering occupancy: bump the core fact; bar reacts.
        if (was_fs_current) core.fullscreen.bump();
    }
    retile(.{ .with_focus = true }, ft);
}

/// toggle_tag (Mod+Alt+N). Focus is left unchanged on add (multi-tag gesture);
/// removing the CURRENT tag evicts the window and re-focuses.
pub fn tagToggle(win: model_mod.WindowId, ws_idx: u8, protect_current: bool) void {
    // Guard on the two hooks this action actually dispatches: with neither
    // bound there is nothing to toggle (and no reconcile to trigger).
    const add_prov = providerOf(.addToWs);
    const rem_prov = providerOf(.removeFromWs);
    if (add_prov == null and rem_prov == null) return;
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.mut(&gate);
    if (!canTagChange(m, win)) return;
    const e = m.store.get(win).?;

    const had_bit = model_mod.taggedOn(e, model_mod.WSId.fromIndex(ws_idx));
    const removing_current = ws_idx == m.current.index;

    var ft: focus.FocusTransition = .none;
    if (had_bit) {
        if (rem_prov) |rp| {
            if (!rp.removeFromWs.?(m, win, model_mod.WSId.fromIndex(ws_idx))) return; // last tag protected
        }
        if (removing_current and m.focused == win) ft = focusFallback(m, .tiling_operation);
    } else {
        if (add_prov) |ap| ap.addToWs.?(m, win, model_mod.WSId.fromIndex(ws_idx), protect_current);
    }

    if (removing_current or (!had_bit and ws_idx == m.current.index)) {
        // Visible-set changed on the shown workspace: atomic evict/map+retile.
        pipeline.reconcileGrabFocus(.{}, ft, .before);
    }
    if (!removing_current) {
        // Off-workspace change: the tag set changed; bump the fact so the
        // workspace-aware consumers redraw.
        core.window.bump();
    }
}

/// move_to_all_workspaces / toggle_tag_all: pinned <-> current-only.
pub fn pinToggle(win: model_mod.WindowId) void {
    const wm = providerOf(.togglePin) orelse return;
    const m = pipeline.mut(&gate);
    if (!canTagChange(m, win)) return;
    wm.togglePin.?(m, win);
    retile(.{}, null);
}

/// all_workspaces (Mod+5): flag flip; sync maps foreign windows on enter and
/// parks them again on exit through the ordinary diff.
pub fn allViewToggle() void {
    const wm = providerOf(.toggleAllView) orelse return;
    const m = pipeline.mut(&gate);
    const entering = wm.toggleAllView.?(m);
    var ft: focus.FocusTransition = .none;
    if (!entering and m.focused != null and !model_mod.visibleOn(m, m.focused.?, m.current)) {
        ft = focusFallback(m, .tiling_operation);
    }
    retile(.{ .restack = true, .with_focus = true }, ft);
}

// ------------------------------------------------------------ tiling ops / drag

/// Shared tiled->floating detach (toggleFloating/detachToFloating): seeds the
/// floating anchor from LastSent geometry and drops the home-list membership.
fn detachTiledToFloating(m: *model_mod.Model, e: *model_mod.Entry, win: model_mod.WindowId) bool {
    const r = sync.lastRectFor(win) orelse return false;
    if (e.home_ws) |home| model_mod.removeValue(&m.ws[home.index].tiled_order, win);
    e.anchor = .{ .floating = r };
    e.home_ws = null; // no longer in tiled_order
    return true;
}

/// toggle_floating_window. Tiled->floating seeds the rect from the window's
/// current on-screen geometry (LastSent); floating->tiled re-enters the home
/// list at the primary-column head via the ordinary tiling order.
pub fn toggleFloating(win: model_mod.WindowId) void {
    const m = pipeline.mut(&gate);
    const e = m.store.getPtr(win) orelse return;
    // A window carrying a covering record keeps its anchor: the record owns
    // the screen while covering, and a ghost (parked) record must survive
    // the command so the later toggle-off restores the ORIGINAL anchor, not
    // a flipped one.
    if (isCoveringMode(m, win)) return;
    switch (e.anchor) {
        .tiled => {
            if (!detachTiledToFloating(m, e, win)) return;
        },
        .floating => {
            e.anchor = .tiled;
            repairStrandedHome(m, e, win);
        },
    }
    retile(.{ .restack = true }, null);
}

/// Defense in depth (the stranded-slot bug class): repair a tiled-anchored
/// window that has no home-list entry instead of leaving it a
/// tiling-invisible window this toggle could never fix again.
fn repairStrandedHome(m: *model_mod.Model, e: *model_mod.Entry, win: model_mod.WindowId) void {
    if (model_mod.findHome(m, win) != null) return;
    if (model_mod.lowestBit(e.mask)) |h| {
        _ = m.ws[h.index].tiled_order.append(win);
        e.home_ws = h;
    }
}

/// Drag tick (no grab; E.6): targeted reconcile — sends ONLY the dragged
/// window's geometry (1 XCB call) instead of replaying all windows. Called
/// from the drag provider's updateDrag on every motion event.
pub fn dragRect(win: model_mod.WindowId, r: utils.Rect) void {
    const wm = providerOf(.setFloatingRect) orelse return;
    const m = pipeline.mut(&gate);
    wm.setFloatingRect.?(m, win, r);
    pipeline.dragTick(win);
}

/// First motion of a drag on a tiled window detaches it to floating at its
/// current geometry (pending-float detach + remove + retile).
pub fn detachToFloating(win: model_mod.WindowId) void {
    const m = pipeline.mut(&gate);
    const e = m.store.getPtr(win) orelse return;
    if (isCoveringMode(m, win)) return;
    if (e.anchor != .tiled) return;
    if (!detachTiledToFloating(m, e, win)) return;
    pipeline.reconcileUnderGrabNow(.{});
}

// ------------------------------------ floating drag commands (registry loops)
//
// Uniform dispatch loops over the compiled-in sub-system set: a module that
// provides the hook runs it, and a tree without the module simply has no
// provider, so the loop no-ops; dropping a module file (and its entire
// subtree) leaves zero residue here.

/// Pointer-press drag begin.
pub fn startDrag(win: model_mod.WindowId, button: u8, x: i16, y: i16) void {
    dispatchAll(.startDrag, .{ win, button, x, y });
}

/// Drag end: commits any in-flight detach/rect.
pub fn stopDrag() void {
    dispatchAll(.stopDrag, .{});
}

/// Motion tick during an active drag.
pub fn updateDrag(x: i16, y: i16) void {
    dispatchAll(.updateDrag, .{ x, y });
}

/// Whether a floating drag/resize is currently in flight. In practice only
/// one module provides this hook, so the loop's first true wins.
pub fn isDragging() bool {
    return dispatchFirstTrue(.isDragging, .{});
}

/// Whether `win` is the current resize target (drag guard).
pub fn isResizingWindow(win: model_mod.WindowId) bool {
    return dispatchFirstTrue(.isResizingWindow, .{win});
}

/// Last committed drag rect, for resize-path geometry replay. Zero rect
/// fallback when no module provides the hook, matching the old no-floating
/// default.
pub fn getDragLastRect() utils.Rect {
    const zero = utils.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const wm = providerOf(.getDragLastRect) orelse return zero;
    return wm.getDragLastRect.?();
}

/// Cancels any active drag targeting `win` (unmanage path).
pub fn cancelDragForWindow(win: model_mod.WindowId) void {
    dispatchAll(.cancelDragForWindow, .{win});
}

pub fn cycleLayoutKind(dir: i32) void {
    const m = pipeline.mut(&gate);
    cycleActiveLayout(m, dir);
    retile(.{ .full_redraw = true }, null);
}

/// Step the active layout within the config layout-name list (config order
/// is the cycle order), reproducing the old model.cycleLayout
/// wrap-around while resetting the variant index. Defaults/overrides always
/// come from config names, so the active kind is always resolvable.
fn cycleActiveLayout(m: *model_mod.Model, dir: i32) void {
    if (!build_options.has_tiling) return;
    const cfg = &core.getState().config.tiling;
    const p = &m.ws[m.current.index].params;
    p.kind = tiling.cycleKind(p.kind, dir, cfg.layouts.items);
    p.variant_idx = 0;
}

pub fn stepVariantDir(dir: i32) void {
    if (!build_options.has_tiling) return;
    const m = pipeline.mut(&gate);
    const p = &m.ws[m.current.index].params;
    const n = tiling.variantCount(p.kind);
    p.variant_idx = @intCast(utils.wrapIndex(p.variant_idx, dir, n));
    retile(.{ .full_redraw = true }, null);
}

pub fn adjustPrimaryWidthAction(delta: f32) void {
    const m = pipeline.mut(&gate);
    model_mod.adjustPrimaryWidth(m, delta);
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustPrimaryCount(delta: i32) void {
    // Primary-column capacity: a sane handful of slots, capped at a quarter
    // of the managed-window ceiling so one workspace can't statically claim
    // the store.
    const max_primary_count = model_mod.store_capacity / 4;
    const m = pipeline.mut(&gate);
    const p = &m.ws[m.current.index].params;
    p.primary_count = @intCast(std.math.clamp(@as(i32, p.primary_count) + delta, 1, @max(1, max_primary_count)));
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustSecondaryBalance(delta: f32) void {
    const m = pipeline.mut(&gate);
    const p = &m.ws[m.current.index].params;
    p.secondary_balance = std.math.clamp(p.secondary_balance + delta, -constants.max_primary_swing, constants.max_primary_swing);
    pipeline.reconcileUnderGrabNow(.{});
}

/// swap_master: exchanges the focused window's tiled slot with the previously
/// focused window's (focus MRU), not the list head -- a slot in the middle of
/// a 3+ window workspace still swaps the pair the user expects. focus_swap
/// variant moves focus to the previously focused window BEFORE the reconcile
/// so the swapped-in window is focused on the first pass.
pub fn swapPrimaryAction(focus_swap: bool) void {
    const m = pipeline.mut(&gate);
    const focused = m.focused orelse return;
    const mru = m.ws[m.current.index].focus_mru.constSlice();
    if (mru.len < 2 or mru[1] == focused) return;
    const displaced = mru[1];
    model_mod.swapFocusedWithPrevious(m);
    var ft: focus.FocusTransition = .none;
    if (focus_swap) {
        // A no_input displaced window must not take model focus.
        ft = prepareAndSetFocus(m, displaced, .tiling_operation);
    }
    pipeline.reconcileGrabFocus(.{}, ft, .before);
}

pub fn moveFocused(delta: i32) void {
    const m = pipeline.mut(&gate);
    const win = m.focused orelse return;
    // Modulo wrap (dwm stack rotate): stepping past either edge of the home
    // list's tiled order cycles back around, matching the focus-step parity.
    model_mod.stepTiled(m, win, delta);
    pipeline.reconcileUnderGrabNow(.{});
}

/// Clamp an updated viewport offset to the layout's content span and stamp
/// the tiled-count snapshot the prefetch expects after a step.
fn commitViewport(p: *model_mod.LayoutParams, sc: ViewportContext, offset: i64, count: usize) void {
    p.viewport_offset = @intCast(std.math.clamp(offset, 0, sc.max_off));
    p.viewport_prev_count = @intCast(count);
}

/// scroll_view_left/right: one slot per step, clamped to content. The spawn
/// snap-right duty lives in preReconcileDuties (pipeline choke point).
pub fn viewportStep(dir: i32) void {
    const vp = activeViewport() orelse return;
    const p = vp.p;
    const sc = vp.sc;
    commitViewport(p, sc, p.viewport_offset + dir * sc.slot_w, sc.tiled_count);
    pipeline.reconcileUnderGrabNow(.{});
}

/// Focus-change viewport snap: shift the viewport minimally so the focused
/// window's slot is fully on-screen. Pure model/param mutation (no grab, no
/// reconcile); returns whether the offset or tiled count actually changed.
/// When the focused window is already fully on-screen (the common case during
/// focus cycling) both are unchanged and the caller can skip all geometry
/// work. The focus-cycle path runs this as a duty INSIDE the focus transition's
/// grab, so a Mod+k/Mod+j that scrolls the viewport still lands focus + geometry
/// in one grab+reconcile rather than two.
fn snapViewportParamsToFocused() bool {
    const vp = activeViewport() orelse return false;
    const m = vp.m;
    const p = vp.p;
    const sc = vp.sc;
    const win = m.focused orelse return false;

    var idx: ?usize = null;
    var n: usize = 0;
    for (m.ws[m.current.index].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (!model_mod.taggedOn(e, m.current)) continue;
        if (w == win) idx = n;
        n += 1;
    }
    const i = idx orelse return false;

    const wa = screen.workArea(core.getState().screen);
    const i64_slot_w: i64 = sc.slot_w;
    const slot_left = @as(i64, @intCast(i)) * i64_slot_w - p.viewport_offset;
    const slot_right = slot_left + i64_slot_w;
    const old_offset = p.viewport_offset;
    const snapped = if (slot_left < 0)
        @as(i64, @intCast(i)) * i64_slot_w
    else if (slot_right > wa.width)
        @as(i64, @intCast(i)) * i64_slot_w + i64_slot_w - @as(i64, wa.width)
    else
        p.viewport_offset;
    const old_count = p.viewport_prev_count;
    commitViewport(p, sc, snapped, n);
    return p.viewport_offset != old_offset or p.viewport_prev_count != old_count;
}

/// Focus-cycle duty (see focus.grabFocusWithDuty): recompute the viewport for
/// the freshly focused window and let the enclosing reconcile pick it up.
/// Signature is void to match the pipeline duty pointer; the change signal is
/// not needed because the transition's reconcile always runs.
pub fn snapViewportFocusedDuty() void {
    _ = snapViewportParamsToFocused();
}

const ViewportContext = struct {
    active: bool,
    tiled_count: usize,
    slot_w: i32,
    max_off: i32,
};

const viewport_inactive: ViewportContext =
    .{ .active = false, .tiled_count = 0, .slot_w = 0, .max_off = 0 };

/// Viewport context for the active layout, resolved through the layout
/// metadata: a layout "has a viewport" iff it registers the slotWidth/
/// maxOffset hooks. Returns inactive for layouts without a viewport or an
/// out-of-range kind.
fn viewportContext(m: *const model_mod.Model) ViewportContext {
    if (!build_options.has_tiling) return viewport_inactive;
    const p = &m.ws[m.current.index].params;
    const mod: ?contract.Layout =
        if (p.kind < tiling_mods.len) tiling_mods[p.kind] else null;
    const md = mod orelse return viewport_inactive;
    if (md.slotWidth == null or md.maxOffset == null) return viewport_inactive;
    const n = model_mod.tiledCountOnWs(m, m.current);
    const wa = screen.workArea(core.getState().screen);
    const slot_w = md.slotWidth.?(wa.width);
    const max_off = md.maxOffset.?(n, slot_w, wa.width);
    return .{ .active = true, .tiled_count = n, .slot_w = slot_w, .max_off = max_off };
}

fn activeViewport() ?struct {
    m: *model_mod.Model,
    p: *model_mod.LayoutParams,
    sc: ViewportContext,
} {
    if (!build_options.has_tiling) return null;
    if (!build_options.has_bar) return null;
    const m = pipeline.mut(&gate);
    const p = &m.ws[m.current.index].params;
    const sc = viewportContext(m);
    if (!sc.active) return null;
    return .{ .m = m, .p = p, .sc = sc };
}

// ---------------------------------------------------------- config reload

/// Boot/restore seam: replay a persisted session's model level onto the
/// live model. Sole authorized user is main.zig's re-exec restore path
/// (persist.loadToGlobal + window.adoptRootWindows have already run);
/// routing through this transition keeps the mutable handle out of boot code
/// and inside the window layer. No reconcile: the caller reconciles once,
/// placing every adopted window exactly as it was.
pub fn applyRestoredLevel() void {
    persist.applyModelLevel(pipeline.mut(&gate));
}

/// Per-workspace seed overrides resolved from `cfg` (built via the shared
/// last-wins lookup rules on TilingConfig). The one labeled bundle driving
/// per-workspace param seeding here (the separate workspaces override store
/// was dead and is gone, C12).
const SeedOverrides = struct {
    /// Override index into `cfg.workspace_layout_overrides` per ws, or null.
    layout: [constants.max_workspaces]?usize,
    /// Master-count override per ws, or null (global default applies).
    master_count: [constants.max_workspaces]?u8,
};

fn seedLookups(cfg: *const types.TilingConfig) SeedOverrides {
    return .{
        .layout = cfg.workspaceLayoutLookup(),
        .master_count = cfg.masterCountLookup(),
    };
}

/// Seeds every workspace's model params from the CURRENT config. Shared by
/// boot-time initialization (without this the config's tiling
/// params/workspace overrides stay inert until the first explicit reload)
/// and post-reload re-seeding; mirrors the per-workspace override model:
/// per-ws layout/variant/master-count overrides, global defaults otherwise;
/// primary_width/secondary_balance are runtime-only (no config
/// representation) and reset to their defaults.
/// No reconcile: callers decide when to push state to X.
///
/// The stamping loop lives in model.applyConfigReload (whose viewport-preserve
/// invariant gets its production caller here); this fn supplies the template.
pub fn seedParamsFromConfig() void {
    if (!build_options.has_tiling) return;
    const cs = core.getState();
    const cfg = &cs.config.tiling;

    // Config layout names resolve to registry ids here, once per seed;
    // unresolvable names fall back loudly to the default.
    const default_kind: u8 = tiling.layoutKindFallingBack(cfg.layout, 0);
    const lookups = seedLookups(cfg);

    const m = pipeline.mut(&gate);
    // Global default template, stamped across every workspace by
    // applyConfigReload (preserves viewport runtime state). Per-workspace
    // overrides are re-stamped in the pass below.
    model_mod.applyConfigReload(m, .{
        .kind = default_kind,
        .variant_idx = resolveVariant(cfg, default_kind, null),
        .primary_count = cfg.master_count,
        .primary_width = 0.5, // runtime-only; reset to the model default (LayoutParams.primary_width)
        .secondary_balance = 0,
    });

    for (&m.ws, 0..) |*s, i| {
        const id: u8 = @intCast(i);
        if (lookups.layout[id]) |oi| {
            const o = cfg.workspace_layout_overrides.items[oi];
            const kind = if (o.layout_idx < cfg.layouts.items.len)
                tiling.layoutKindFallingBack(
                    cfg.layouts.items[o.layout_idx],
                    default_kind,
                )
            else
                default_kind;
            s.params.kind = kind;
            // A layout override always carries the variant override through,
            // even when its layout_idx resolved out of range (the override
            // string still applies to the active kind).
            s.params.variant_idx = resolveVariant(cfg, kind, o.variant);
        }
        if (lookups.master_count[id]) |mc| s.params.primary_count = mc;
    }
}

/// Resolve the active variant index for `kind` from the registry-driven
/// value-string: `override_variant` when present, else the per-layout
/// variants map entry for the active module's canonical name. The module's
/// own variant_parse hook interprets the string; an unparseable/unknown
/// string warns (Stage-1 style) and uses 0.
fn resolveVariant(
    cfg: *const types.TilingConfig,
    kind: u8,
    override_variant: ?[]const u8,
) u8 {
    var value_string: ?[]const u8 = override_variant;
    const active_mod: ?contract.Layout =
        if (kind < tiling_mods.len) tiling_mods[kind] else null;
    var v_idx: u8 = 0;
    if (active_mod) |md| {
        if (value_string == null) value_string = cfg.variants.get(md.name);
        if (value_string) |vs| {
            if (md.variant_parse) |vp| {
                v_idx = vp(vs) orelse blk: {
                    if (override_variant != null)
                        debug.warn("Config: workspace layout variant '{s}' ignored — not a variant of the active layout", .{vs})
                    else
                        debug.warn("Unknown {s} variants '{s}', using default", .{ md.name, vs });
                    break :blk 0;
                };
            } else if (override_variant != null) {
                debug.warn("Config: workspace layout variant ignored — not a variant of the active layout", .{});
            }
        }
    }
    return v_idx;
}

pub fn applyConfigReload() void {
    seedParamsFromConfig();
    pipeline.reconcileUnderGrabNow(.{});
}

// ---------------------------------------------------------- workspace switch

/// Workspace switch. One model transition + one reconcile; the LastSent
/// diff parks leavers once and maps+places arrivers (see sync_test's switch
/// scenario).
///
/// Kept protocol-side: pointer-hover query and focus suppression reset.
/// model.current is the single store; tracking's getCurrentWorkspace is a
/// read-through facade over it.
///
/// Geometry-before-focus: the reconcile maps the arriving window before
/// applyPendingFocus targets it — the arriving window may have been spawned
/// off-current and never mapped, so an earlier focus-before-reconcile ordering
/// produced a BadMatch that left X focus on the old workspace's window.
pub fn switchTo(ws_idx: u8) void {
    const m = pipeline.mut(&gate);
    if (ws_idx >= constants.max_workspaces) return;
    if (m.current.index == ws_idx) return;

    const t0: u64 = if (build_options.profile_key) utils.monotonicNs() else 0;

    // Suppression reset, then the switch transition.
    focus.setSuppressReason(.none);

    // All-view exit is a flag flip (emerges from visibility); temp-window
    // masks do not exist in the model.
    m.all_view_active = false;

    // model.current is the ONLY store for the current workspace; the
    // tracking/workspaces mirrors are deleted (read-through facades now).
    m.current = model_mod.WSId.fromIndex(ws_idx);

    // Bump the window fact: the workspace indicator always changes on switch.
    // prepareClearFocus returns .none when last_applied is null (empty-to-empty
    // switch), so the focus fact alone can't guarantee a redraw; bumping the
    // window fact here makes the bar redraw at end-of-batch.
    core.window.bump();
    // Bar visibility follows the NEW workspace's fullscreen occupant. Apply it
    // NOW (X-free, no reconcile) so the FIRST reconcile below already reads the
    // correct screen claim / workarea for this workspace. Otherwise the bar's
    // deferred visibility update would require a SECOND reconcile on this
    // workspace, retiling Discord's geometry twice and causing a flicker.
    if (build_options.has_bar)
        surfaces.updateBarVisibilityForWorkspace(ws_idx);
    // Bump the core fullscreen fact only when the target workspace actually
    // carries a covering occupant: the bar's reactive path derives its claim
    // from the fact, so spuriously bumping it on every switch would churn a
    // bar-redraw for workspaces with no fullscreen window (the claim for the
    // new ws was already applied by updateBarVisibilityForWorkspace above).
    // OR scan (not the module AND hook): any covering entry, anchored or
    // merely visible on ws, owns the screen here.
    if (model_mod.coveringOccupantOnWs(m, m.current) != null) core.fullscreen.bump();

    const t1: u64 = if (build_options.profile_key) utils.monotonicNs() else 0;

    // The server grab body below is pure fire-and-forget XCB (focus
    // transition + reconcile), so no blocking wait ever freezes input while
    // the grab is held. All decision work — focus-candidate selection and
    // the FocusTransition prep — runs here, model-local or cache-backed,
    // BEFORE grabServer so a fast-following keypress is never starved by this
    // switch (the drop-safety fix).

    // Keyboard-triggered switch focuses the model's tiered fallback
    // (newest-first MRU, then reversed tiled_order, then floating) — NO pointer
    // query. Querying what's under the cursor costs a synchronous round trip
    // that stalls the single-threaded event loop; a fast-following keypress
    // (Super+2 immediately after Super+1) waits behind that stall, which is
    // exactly the "quick workspace switches sometimes don't register" symptom.
    // A keyboard switch has no pointer gesture to honor, so focus is decided
    // purely from the model with zero X round trips.
    const ft: focus.FocusTransition = focusFallback(m, .workspace_switch);

    const t2: u64 = if (build_options.profile_key) utils.monotonicNs() else 0;

    // Reconcile + focus under one server grab, atomically, via the pipeline
    // seam (grabCtx/reconcile/applyPendingFocus/ungrabAndFlush consolidated).
    // Only fire-and-forget XCB runs inside the grab, so it is held for
    // microseconds — no blocking wait can freeze a next keypress.
    //
    // Geometry-before-focus (FocusOrder.after): the arriving window may have
    // been spawned off-current and never mapped (the spawn path registers but
    // defers the map to the first reconcile).  Firing xcb_set_input_focus on
    // an unmapped window is a BadMatch that leaves X focus on the old
    // workspace's window.  The .after order maps the arriving window before
    // applyPendingFocus targets it, in the same flush.
    pipeline.reconcileGrabFocus(.{ .force_restack = true }, ft, .after);

    if (build_options.profile_key) {
        const t3 = utils.monotonicNs();
        debug.info("[TIMING] switchTo ws={}: model={d}us rt_prep={d}us grab_body={d}us total={d}us", .{
            ws_idx,
            @as(u64, @intCast(t1 - t0)) / 1000,
            @as(u64, @intCast(t2 - t1)) / 1000,
            @as(u64, @intCast(t3 - t2)) / 1000,
            @as(u64, @intCast(t3 - t0)) / 1000,
        });
    }
}

// ------------------------------------------------------- spawn/map lifecycle

/// MapRequest tail. The caller's front-end (event masks, property
/// queries, size-hints cache) has already run; this registers the window in
/// the model and lets ONE reconcile do map+pixel+bw+geom(+ABOVE winner) for
/// on-current spawns. Off-current spawns park by construction; sync sends
/// their border width at first show instead of immediately (invisible either
/// way; one less request).
///
/// `float_rect` admits the window already floating: the entry is registered
/// tiled (core membership is tiled-only) and then immediately detached to the
/// given rect with no home-list membership, mirroring detachTiledToFloating's
/// anchor/home_ws state. The reconcile tail then sizes it floating in one
/// pass, so a float-rule spawn never flashes a tiled slot.
pub fn mapRequest(win: model_mod.WindowId, target_ws: u8, on_current: bool, float_rect: ?utils.Rect) void {
    const m = pipeline.mut(&gate);
    if (m.store.has(win)) return; // double-manage guard

    // A defined refusal (store or home-list full) leaves the window
    // unmanaged.
    model_mod.register(m, win, if (on_current) null else model_mod.WSId.fromIndex(target_ws)) catch {
        debug.warn("mapRequest: capacity full; window 0x{x} left unmanaged", .{win});
        return;
    };
    // Bridge the cached WM_NORMAL_HINTS into the model entry at registration.
    const e = m.store.getPtr(win);
    if (e) |ep| ep.size_hints = wincache.peekHints(win);

    // Float-rule admission: detach the entry from its tiled slot before the
    // fifo placement runs (which assumes a home slot, nonsensical for a
    // floating window). The anchor/home_ws state mirrors toggleFloating's
    // detach, and the reconcile tail applies the rect in the same pass.
    if (float_rect) |rect| {
        if (e) |ep| {
            if (ep.home_ws) |home| model_mod.removeValue(&m.ws[home.index].tiled_order, win);
            ep.anchor = .{ .floating = rect };
            ep.home_ws = null;
        }
    } else {
        // Primary-fifo variant spawn placement (moved out of model.register;
        // it is SPAWN policy, not membership policy): a new window takes the
        // primary-column head slot, and the previous head window drops one
        // slot.
        {
            // Clamp the requested home workspace so a misconfigured target
            // can't index past the ws array in ReleaseFast (defense in depth;
            // the MapRequest front-end already resolves/clamps the target).
            const home: model_mod.WSId = if (on_current)
                m.current
            else
                window.clampToValidWorkspace(target_ws, model_mod.WSId.fromIndex(m.current.index));
            const p = &m.ws[home.index].params;
            // Same policy restated at the spawn site: driven by the active
            // module's fifo_variant metadata (the head slot binds variant
            // index 1).
            if (p.kind < tiling_mods.len) {
                const fv = tiling_mods[p.kind].fifo_variant;
                if (fv) |v| {
                    if (p.variant_idx == v and m.ws[home.index].tiled_order.len > 1)
                        model_mod.reorderTiled(m, win, 0);
                }
            }
        }
    }
    focus.initWindowGrabs(win); // protocol-side keygrabs, both paths did this
    core.window.bump(); // a window was admitted

    if (!on_current) return;

    // Focus prep before the model write (same rule as focusFallback): a
    // spawned no_input window must never take model focus -- its focus
    // protocol can't land, so marking it focused would leave borders and
    // stacking claiming a focus X will never deliver. X input focus lands
    // AFTER the reconcile, inside the same grab: the window must be mapped
    // before xcb_set_input_focus, so both map+focus land under one grab.
    const ft = prepareAndSetFocus(m, win, .window_spawn);
    pipeline.reconcileGrabFocus(.{}, ft, .after);
}

/// Unmanage tail: close/destroy/unmap of a managed window. Local
/// bookkeeping (covering record, caches, sub-system removes) has already
/// run; this drops the model entry and re-focuses. Inactive-workspace
/// geometry repairs ride the same global LastSent diff.
pub fn unmanage(ctx: *Ctx, win: model_mod.WindowId) void {
    const m = pipeline.mut(&gate);
    // Covering and focus truth arrive via ctx: the sole caller (window.
    // unmanageWindow) removes the model entry (the workspace layer's
    // removeWindow -> unregister) BEFORE this action runs, so reading the
    // store here could never see either; closing the covering occupant never
    // restored the bar, and the withdrawn window's focus ownership was
    // unknowable.
    const was_fs_current = if (ctx.withdrawn_fullscreen_ws) |ws| ws.eql(m.current) else false;
    const was_focused = ctx.withdrawn_was_focused;

    model_mod.unregister(m, win);
    sync.forget(win); // X ids recycle; stale LastSent must not survive

    // Closing the current workspace's covering occupant releases the area;
    // retileWithFallback bumps the core fact so the bar reacts.
    retileWithFallback(m, was_fs_current, was_focused);
}
