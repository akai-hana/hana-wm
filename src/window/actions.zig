//! Thin action wrappers: one action = one model transition + one sync entry.
//! Model state, wire requests, and focus protocol live in model, sync, and focus.

const std = @import("std");
const core = @import("core");
const constants = @import("constants");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const sync = @import("sync");
const focus = @import("focus");
const window = @import("window");
const screen = @import("screen");
const build_options = @import("build_options");
const debug = @import("debug");
const utils = @import("utils");
const window_mods = @import("window_modules").modules;

/// Registry lookup for the hook `field` (see `plugin.providerOf`), null when
/// no module binds it; canonical scan lives in window.providerOf.
const providerOf = window.providerOf;

/// Convenience: returns the current workspace's covering occupant, or null.
fn currentCoveringOccupant(m: *const model_mod.Model) ?model_mod.WindowId {
    return if (providerOf(.coveringOccupantOnWs)) |prov|
        prov.coveringOccupantOnWs.?(m, m.current)
    else
        null;
}

/// Convenience: true when `win` is the covering (fullscreen) occupant on its
/// workspace.
fn isCoveringOnWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    return if (providerOf(.isCoveringOnWs)) |wm| wm.isCoveringOnWs.?(m, win, m.current) else false;
}

/// Shared change guard for the tag/pin actions: the window must be present in
/// the model and not hidden.
fn canTagChange(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    if (m.store.get(win) == null) return false;
    return !isMinimizedOnAnyWs(m, win);
}

/// Layout registry (build-generated); the active layout is a `u8` index into
/// it, never a closed enum. Empty when the tiling subsystem is absent.
const tiling_mods = @import("plugin").tiling_mods;
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};

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
fn retileAndNotify(restack: bool, full_redraw: bool) void {
    // Bump core's fact revision for the arrange; the bar (a consumer of the
    // fact) redraws from its own poll. Core is never informed of "the bar".
    if (full_redraw) core.bumpLayout() else core.bumpWindow();
    pipeline.reconcileUnderGrabNow(if (restack) .{ .force_restack = true } else .{});
}

/// Same as retileAndNotify but commits a focus transition inside the grab.
fn retileAndNotifyWithFocus(restack: bool, full_redraw: bool, ft: focus.FocusTransition) void {
    if (full_redraw) core.bumpLayout() else core.bumpWindow();
    pipeline.reconcileUnderGrabNowWithFocus(if (restack) .{ .force_restack = true } else .{}, ft);
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
    if (providerOf(.hideWindow)) |wm| {
        const win = focused orelse return;
        const m = pipeline.model();
        const was_focused = m.focused == win;
        const fs_ws_before =
            if (providerOf(.coveringWsOf)) |prov| prov.coveringWsOf.?(m, win) else null;

        wm.hideWindow.?(m, win) catch return; // Pre-refusal (CapacityFull)

        const ft: focus.FocusTransition = if (was_focused) focusFallback(m) else .none;

        core.bumpWindow(); // hiding refreshes the title segment
        // If the hidden window was the current workspace's screen-covering
        // occupant, its removal changed occupancy: bump the core fact and let
        // the bar (a consumer) react, instead of poking it by name.
        if (fs_ws_before) |fs_ws| {
            if (fs_ws == m.current) core.bumpFullscreen();
        }

        pipeline.reconcileUnderGrabNowWithFocus(.{ .force_restack = true }, ft); // Atomicity
    }
}

/// Fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
/// Returns a FocusTransition for the caller to commit inside its server grab.
/// Model and protocol focus are updated together: the model update runs
/// before the grab, the protocol commit runs inside it.
fn focusFallback(m: *model_mod.Model) focus.FocusTransition {
    // Tier policy lives in the model layer so tests can exercise it without
    // linking the protocol side (see model.fallbackFocusCandidate).
    if (model_mod.fallbackFocusCandidate(m, m.current)) |winner| {
        model_mod.setFocus(m, winner);
        return focus.prepareFocus(winner, .tiling_operation, null);
    } else {
        model_mod.clearFocus(m);
        return focus.prepareClearFocus();
    }
}

// --------------------------------------------------------- restore (unpark)

fn isMinimizedOnAnyWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    return if (providerOf(.isWindowHidden)) |wm| wm.isWindowHidden.?(m, win) else false;
}

fn restoreAndFocus(m: *model_mod.Model, win: model_mod.WindowId) void {
    model_mod.setFocus(m, win);
    const ft = focus.prepareFocus(win, .window_spawn, null);
    pipeline.reconcileUnderGrabNowWithFocus(.{ .force_restack = true }, ft);
}

fn armFullscreenBarHideIfNeeded(
    m: *const model_mod.Model,
    win: model_mod.WindowId,
    had_occupant_before: bool,
) void {
    if (build_options.has_bar and !had_occupant_before and isCoveringOnWs(m, win)) {
        for (window_mods) |wm| if (wm.armPendingBarHide) |f| f(win);
    }
}

/// Restores `win` via the hide module's `restoreWindow` hook, re-focuses it,
/// and arms the deferred bar-hide when the restore opened a fresh claim.
fn restoreTarget(m: *model_mod.Model, win: model_mod.WindowId) void {
    const had_occupant_before = currentCoveringOccupant(m) != null;
    if (providerOf(.restoreWindow)) |wm| wm.restoreWindow.?(m, win);
    restoreAndFocus(m, win);
    armFullscreenBarHideIfNeeded(m, win, had_occupant_before);
}

/// Restores a specific hidden window (title-bar click path).
pub fn restore(win: model_mod.WindowId) void {
    const m = pipeline.model();
    if (!isMinimizedOnAnyWs(m, win)) return;
    restoreTarget(m, win);
}

/// Slot-ordered single restore (LIFO/FIFO keybind paths).
pub fn restoreOrdered(order: model_mod.RestoreOrder) void {
    const m = pipeline.model();
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
    const m = pipeline.model();
    if (providerOf(.latestHiddenOnWs)) |wm| {
        const ws = m.current;
        const target = (wm.latestHiddenOnWs.?(m, ws) orelse return);
        const had_occupant_before = currentCoveringOccupant(m) != null;
        if (providerOf(.restoreOnWs)) |rp| rp.restoreOnWs.?(m, ws);
        restoreAndFocus(m, target);
        if (currentCoveringOccupant(m)) |occ|
            armFullscreenBarHideIfNeeded(m, occ, had_occupant_before);
    }
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
/// Bar hide/show deferral and EWMH stay protocol-side (R2), driven through the
/// window_modules registry's pending machinery so events.zig's ConfigureNotify
/// handler works unchanged. The keybind path resolves the focused window at
/// the dispatch site and lands here too.
pub fn fullscreenToggleWindow(win: model_mod.WindowId) void {
    // Timing: wall-clock from action entry (keybind/EWMH resolve) to the
    // synchronous completion of the fullscreen transition INCLUDING the bar
    // hide and the ungrabAndFlush of the enclosing grab — i.e. the point at
    // which the bar is gone and the window is sized, all visible on the next
    // compositor frame. Runs in every Debug build (harness runs Debug);
    // `debug.info` is compiled out under ReleaseFast via the log level.
    const fs_t0: u64 = utils.monotonicNs();
    if (providerOf(.toggleCovering)) |wm| {
        if (!core.getState().config.fullscreen_enabled) return;
        const m = pipeline.model();
        // Never cover a window off the viewed workspace: the covering
        // record binds the current ws and would claim it while hidden.
        if (!model_mod.visibleOn(m, win, m.current)) return;

        // Classify BEFORE toggling so bar deferrals keep the occupant
        // scan in one place; both the classification and prev_fs_win need
        // the same result, saving one full store scan.
        const prev_fs_win = currentCoveringOccupant(m);
        const kind: enum { enter, exit, switch_ } = blk: {
            if (isCoveringOnWs(m, win)) break :blk .exit;
            if (prev_fs_win != null) break :blk .switch_;
            break :blk .enter;
        };

        if (!wm.toggleCovering.?(m, win)) return;

        // EWMH writes + bar arming land inside the same grab as geometry
        // (Gap 2 atomicity fix). All fire-and-forget or pure state.
        pipeline.reconcileUnderGrabNowFullscreen(
            .{ .force_restack = true },
            win,
            prev_fs_win,
            kind == .exit,
            kind == .switch_,
        );

        // Completion of the transition is synchronous: run time elapsed
        // already covers the reconcile + immediate bar hide (enter) and the
        // ungrabAndFlush, i.e. the visual-completion point.
        {
            const dt = utils.monotonicNs() - fs_t0;
            debug.info("[FSPROF] win={d} kind={s} done {d}ns", .{
                win, @tagName(kind), dt,
            });
        }
    }
}

// ------------------------------------------------- tag-move / pin / all-view

/// move_to_workspace. Model moves mask + home list + covering record in one
/// call; the reconcile's diff parks/repairs geometry globally.
pub fn moveWindowTo(win: model_mod.WindowId, ws_idx: u8) void {
    if (providerOf(.sendToWs)) |wm| {
        if (ws_idx >= constants.max_workspaces) return;

        const m = pipeline.model();
        const was_focused = m.focused == win;
        const was_fs_current = isCoveringOnWs(m, win);

        wm.sendToWs.?(m, win, ws_idx);
        if (m.store.get(win) == null) return; // unknown window: no-op

        var ft: focus.FocusTransition = .none;
        if (ws_idx != m.current) {
            if (was_focused) ft = focusFallback(m);
            // Moving the current workspace's covering window away changes the
            // workspace's covering occupancy: bump the core fact; bar reacts.
            if (was_fs_current) core.bumpFullscreen();
        }
        retileAndNotifyWithFocus(false, false, ft);
    }
}

/// toggle_tag (Mod+Alt+N). Focus is left unchanged on add (multi-tag gesture);
/// removing the CURRENT tag evicts the window and re-focuses.
pub fn tagToggle(win: model_mod.WindowId, ws_idx: u8, protect_current: bool) void {
    if (providerOf(.sendToWs) == null) return;
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.model();
    if (!canTagChange(m, win)) return;
    const e = m.store.get(win).?;

    const had_bit = e.mask & model_mod.bit(ws_idx) != 0;
    const removing_current = ws_idx == m.current;

    var ft: focus.FocusTransition = .none;
    if (had_bit) {
        if (providerOf(.removeFromWs)) |rp| {
            if (!rp.removeFromWs.?(m, win, ws_idx)) return; // last tag protected
        }
        if (removing_current and m.focused == win) ft = focusFallback(m);
    } else {
        if (providerOf(.addToWs)) |ap| ap.addToWs.?(m, win, ws_idx, protect_current);
    }

    if (removing_current or (!had_bit and ws_idx == m.current)) {
        // Visible-set changed on the shown workspace: atomic evict/map+retile.
        pipeline.reconcileUnderGrabNowWithFocus(.{}, ft);
    }
    if (!removing_current) {
        // Off-workspace change: the tag set changed; bump the fact so the
        // workspace-aware consumers redraw.
        core.bumpWindow();
    }
}

/// move_to_all_workspaces / toggle_tag_all: pinned <-> current-only.
pub fn pinToggle(win: model_mod.WindowId) void {
    if (providerOf(.togglePin) == null) return;
    const m = pipeline.model();
    if (!canTagChange(m, win)) return;
    if (providerOf(.togglePin)) |wm| wm.togglePin.?(m, win);
    retileAndNotify(false, false);
}

/// all_workspaces (Mod+5): flag flip; sync maps foreign windows on enter and
/// parks them again on exit through the ordinary diff.
pub fn allViewToggle() void {
    if (providerOf(.toggleAllView) == null) return;
    const m = pipeline.model();
    const entering = if (providerOf(.toggleAllView)) |wm| wm.toggleAllView.?(m) else false;
    var ft: focus.FocusTransition = .none;
    if (!entering and m.focused != null and !model_mod.visibleOn(m, m.focused.?, m.current)) {
        ft = focusFallback(m);
    }
    retileAndNotifyWithFocus(true, false, ft);
}

// ------------------------------------------------------------ tiling ops / drag

/// Shared tiled->floating detach (toggleFloating/detachToFloating): seeds the
/// floating anchor from LastSent geometry and drops the home-list membership.
fn detachTiledToFloating(e: *model_mod.Entry, win: model_mod.WindowId) bool {
    const r = sync.lastRectFor(win) orelse return false;
    e.anchor = .{ .floating = r };
    e.home_ws = null; // no longer in tiled_order
    return true;
}

/// toggle_floating_window. Tiled->floating seeds the rect from the window's
/// current on-screen geometry (LastSent); floating->tiled re-enters the home
/// list at the primary-column head via the ordinary tiling order.
pub fn toggleFloating(win: model_mod.WindowId) void {
    const m = pipeline.model();
    const e = m.store.getPtr(win) orelse return;
    // A window carrying a covering record keeps its anchor: the record owns
    // the screen while covering, and a ghost (parked) record must survive
    // the command so the later toggle-off restores the ORIGINAL anchor, not
    // a flipped one.
    if (providerOf(.isCoveringMode)) |wm| {
        if (wm.isCoveringMode.?(m, win)) return;
    }
    switch (e.anchor) {
        .tiled => {
            if (!detachTiledToFloating(e, win)) return;
        },
        .floating => {
            e.anchor = .tiled;
            repairStrandedHome(m, e, win);
        },
    }
    retileAndNotify(true, false);
}

/// Defense in depth (the stranded-slot bug class): repair a tiled-anchored
/// window that has no home-list entry instead of leaving it a
/// tiling-invisible window this toggle could never fix again.
fn repairStrandedHome(m: *model_mod.Model, e: *model_mod.Entry, win: model_mod.WindowId) void {
    if (model_mod.findHome(m, win) != null) return;
    if (model_mod.lowestBit(e.mask)) |h| {
        _ = m.ws[h].tiled_order.append(win);
        e.home_ws = h;
    }
}

/// Drag tick (no grab; E.6): targeted reconcile — sends ONLY the dragged
/// window's geometry (1 XCB call) instead of replaying all windows. Called
/// from the drag provider's updateDrag on every motion event.
pub fn dragRect(win: model_mod.WindowId, r: @import("utils").Rect) void {
    if (providerOf(.setFloatingRect)) |wm| {
        const m = pipeline.model();
        wm.setFloatingRect.?(m, win, r);
        pipeline.dragTick(win);
    }
}

/// First motion of a drag on a tiled window detaches it to floating at its
/// current geometry (pending-float detach + remove + retile).
pub fn detachToFloating(win: model_mod.WindowId) void {
    const m = pipeline.model();
    const e = m.store.getPtr(win) orelse return;
    if (providerOf(.isCoveringMode)) |wm| {
        if (wm.isCoveringMode.?(m, win)) return;
    }
    if (e.anchor != .tiled) return;
    if (!detachTiledToFloating(e, win)) return;
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
    for (window_mods) |m| if (m.startDrag) |f| f(win, button, x, y);
}

/// Drag end: commits any in-flight detach/rect.
pub fn stopDrag() void {
    for (window_mods) |m| if (m.stopDrag) |f| f();
}

/// Motion tick during an active drag.
pub fn updateDrag(x: i16, y: i16) void {
    for (window_mods) |m| if (m.updateDrag) |f| f(x, y);
}

/// Whether a floating drag/resize is currently in flight. In practice only
/// one module provides this hook, so the loop's first true wins.
pub fn isDragging() bool {
    for (window_mods) |m| {
        if (m.isDragging) |f| {
            if (f()) return true;
        }
    }
    return false;
}

/// Whether `win` is the current resize target (drag guard).
pub fn isResizingWindow(win: model_mod.WindowId) bool {
    for (window_mods) |m| {
        if (m.isResizingWindow) |f| {
            if (f(win)) return true;
        }
    }
    return false;
}

/// Last committed drag rect, for resize-path geometry replay. Zero rect
/// fallback when no module provides the hook, matching the old no-floating
/// default.
pub fn getDragLastRect() @import("utils").Rect {
    for (window_mods) |m| {
        if (m.getDragLastRect) |f| return f();
    }
    return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
}

/// Cancels any active drag targeting `win` (unmanage path).
pub fn cancelDragForWindow(win: model_mod.WindowId) void {
    for (window_mods) |m| if (m.cancelDragForWindow) |f| f(win);
}

pub fn cycleLayoutKind(dir: i32) void {
    const m = pipeline.model();
    cycleActiveLayout(m, dir);
    retileAndNotify(false, true);
}

/// Step the active layout within the config layout-name list (config order
/// is the cycle order, S20), reproducing the old model.cycleLayout
/// wrap-around while resetting the variant index. Defaults/overrides always
/// come from config names, so the active kind is always resolvable.
fn cycleActiveLayout(m: *model_mod.Model, dir: i32) void {
    if (!build_options.has_tiling) return;
    const cfg = &core.getState().config.tiling;
    const p = &m.ws[m.current].params;
    p.kind = tiling.cycleKind(p.kind, dir, cfg.layouts.items);
    p.variant_idx = 0;
}

pub fn stepVariantDir(dir: i32) void {
    if (!build_options.has_tiling) return;
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const n = tiling.variantCount(p.kind);
    const cur: i32 = @intCast(p.variant_idx);
    const next: i32 = @mod(cur + dir, @as(i32, @intCast(n)));
    p.variant_idx = @intCast(next);
    retileAndNotify(false, true);
}

pub fn adjustPrimaryWidthAction(delta: f32) void {
    const m = pipeline.model();
    model_mod.adjustPrimaryWidth(m, delta);
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustPrimaryCount(delta: i32) void {
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const next = @as(i32, p.primary_count) + delta;
    // Upper clamp: layouts clamp downstream per-tile, but the model
    // param itself used to drift unbounded, desyncing bar/inspect state.
    // store_capacity/4 keeps the bound proportional to the window budget.
    const max_count: i32 = @max(1, model_mod.store_capacity / 4);
    p.primary_count = @intCast(std.math.clamp(next, 1, max_count));
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustSecondaryBalance(delta: f32) void {
    const max_balance: f32 = 6.0; // secondary-column swing cap (see StackBoost.fromBalance)
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    p.secondary_balance = std.math.clamp(p.secondary_balance + delta, -max_balance, max_balance);
    pipeline.reconcileUnderGrabNow(.{});
}

/// swap_master: exchanges the focused window with the list head. focus_swap
/// variant moves focus to the displaced window BEFORE the reconcile so
/// head-focused layouts render the right window on the first pass.
pub fn swapPrimaryAction(focus_swap: bool) void {
    const m = pipeline.model();
    const list = &m.ws[m.current].tiled_order;
    if (list.items.len < 2) return;
    const displaced = list.items[0];
    model_mod.swapPrimary(m);
    var ft: focus.FocusTransition = .none;
    if (focus_swap) {
        if (m.focused != null and m.focused.? != displaced) {
            model_mod.setFocus(m, displaced);
            ft = focus.prepareFocus(displaced, .tiling_operation, null);
        }
    }
    pipeline.reconcileUnderGrabNowWithFocus(.{}, ft);
}

pub fn moveFocused(delta: i32) void {
    const m = pipeline.model();
    const win = m.focused orelse return;
    // Modulo wrap (dwm stack rotate): stepping past either edge of the home
    // list's tiled order cycles back around, matching the focus-step parity.
    model_mod.stepTiled(m, win, delta);
    pipeline.reconcileUnderGrabNow(.{});
}

/// scroll_view_left/right: one slot per step, clamped to content. The spawn
/// snap-right duty lives in preReconcileDuties (pipeline choke point).
pub fn viewportStep(dir: i32) void {
    if (!build_options.has_tiling) return;
    if (!build_options.has_bar) return;
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const sc = viewportContext(m);
    if (!sc.active) return;
    p.viewport_offset += dir * sc.slot_w;
    p.viewport_offset = std.math.clamp(p.viewport_offset, 0, sc.max_off);
    p.viewport_prev_count = @intCast(sc.tiled_count);
    pipeline.reconcileUnderGrabNow(.{});
}

/// Focus-change viewport snap: shift the viewport minimally so the focused
/// window's slot is fully on-screen. When the focused window is already fully
/// on-screen (the common case during focus cycling), the desired viewport
/// offset and tiled count are unchanged, so the reconcile is skipped entirely:
/// the focus transition's own grab-reconcile already handled borders, and an
/// unchanged viewport needs no geometry reposition. This avoids a second
/// full grab+reconcile+flush per Mod+k/Mod+j when nothing about the viewport
/// actually moved.
pub fn snapViewportToFocused() void {
    if (!build_options.has_tiling) return;
    if (!build_options.has_bar) return;
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const sc = viewportContext(m);
    if (!sc.active) return;
    const win = m.focused orelse return;

    var idx: ?usize = null;
    var n: usize = 0;
    for (m.ws[m.current].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (e.mask & model_mod.bit(m.current) == 0) continue;
        if (w == win) idx = n;
        n += 1;
    }
    const i = idx orelse return;

    const wa = screen.workArea(core.getState().screen);
    const i64_slot_w: i64 = sc.slot_w;
    const slot_left = @as(i64, @intCast(i)) * i64_slot_w - p.viewport_offset;
    const slot_right = slot_left + i64_slot_w;
    const old_offset = p.viewport_offset;
    if (slot_left < 0)
        p.viewport_offset = @intCast(@as(i64, @intCast(i)) * i64_slot_w)
    else if (slot_right > wa.width)
        p.viewport_offset = @intCast(
            @as(i64, @intCast(i)) * i64_slot_w + i64_slot_w - @as(i64, wa.width),
        );
    p.viewport_offset = std.math.clamp(p.viewport_offset, 0, sc.max_off);
    const old_count = p.viewport_prev_count;
    p.viewport_prev_count = @intCast(n);
    if (p.viewport_offset == old_offset and p.viewport_prev_count == old_count) return;
    pipeline.reconcileUnderGrabNow(.{});
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
    const p = &m.ws[m.current].params;
    const mod: ?@import("plugin").Layout =
        if (p.kind < tiling_mods.len) tiling_mods[p.kind] else null;
    const md = mod orelse return viewport_inactive;
    if (md.slotWidth == null or md.maxOffset == null) return viewport_inactive;
    const n = model_mod.tiledCountOnWs(m, m.current);
    const wa = screen.workArea(core.getState().screen);
    const slot_w = md.slotWidth.?(wa.width);
    const max_off = md.maxOffset.?(n, slot_w, wa.width);
    return .{ .active = true, .tiled_count = n, .slot_w = slot_w, .max_off = max_off };
}

// ---------------------------------------------------------- config reload

/// Seeds every workspace's model params from the CURRENT config. Shared by
/// boot-time initialization (without this the config's tiling
/// params/workspace overrides stay inert until the first explicit reload)
/// and post-reload re-seeding; mirrors the per-workspace override model:
/// per-ws layout/variant/master-count overrides, global defaults otherwise;
/// primary_width/secondary_balance are runtime-only (no config
/// representation) and reset to their defaults.
/// No reconcile: callers decide when to push state to X.
pub fn seedParamsFromConfig() void {
    if (!build_options.has_tiling) return;
    const cs = core.getState();
    const cfg = &cs.config.tiling;
    const max_ws = constants.max_workspaces;

    // Config layout names resolve to registry ids here, once per seed.
    // A name that fails to resolve (an unregistered module) must not be
    // silent: report it and the fallback used.
    const default_kind: u8 = blk: {
        if (tiling.layoutByName(cfg.layout)) |k| break :blk @intCast(k);
        debug.warn(
            "Config: layout name '{s}' did not resolve to a registered layout; " ++
                "using default layout '{s}'",
            .{ cfg.layout, tiling.moduleName(tiling.defaultKind()) },
        );
        break :blk tiling.defaultKind();
    };

    // Last override wins (loop-overwrite semantics).
    var layout_lookup: [max_ws]?usize = .{null} ** max_ws;
    for (cfg.workspace_layout_overrides.items, 0..) |o, oi| {
        if (o.workspace_idx < max_ws) layout_lookup[o.workspace_idx] = oi;
    }
    // Last-wins master-count lookup (shared rule on TilingConfig).
    const count_lookup = cfg.masterCountLookup();

    const m = pipeline.model();
    for (&m.ws, 0..) |*s, i| {
        const id: u8 = @intCast(i);
        var kind = default_kind;
        var override_variant: ?[]const u8 = null;
        if (id < max_ws) {
            if (layout_lookup[id]) |oi| {
                const o = cfg.workspace_layout_overrides.items[oi];
                if (o.layout_idx < cfg.layouts.items.len)
                    kind = @intCast(
                        tiling.layoutByName(cfg.layouts.items[o.layout_idx]) orelse blk: {
                            debug.warn(
                                "Config: workspace {} layout name '{s}' did not resolve to a " ++
                                    "registered layout; using layout '{s}'",
                                .{
                                    i,
                                    cfg.layouts.items[o.layout_idx],
                                    tiling.moduleName(default_kind),
                                },
                            );
                            break :blk default_kind;
                        },
                    );
                override_variant = o.variant;
            }
        }
        s.params.kind = kind;
        // Resolve the active variant index from the registry-driven
        // value-string: a per-workspace override when present, else the
        // per-layout variants map entry for the active module's canonical
        // name. The module's own variant_parse hook interprets the string;
        // an unparseable/unknown string warns (Stage-1 style) and uses 0.
        var value_string: ?[]const u8 = override_variant;
        const active_mod: ?@import("plugin").Layout =
            if (kind < tiling_mods.len) tiling_mods[kind] else null;
        var v_idx: u8 = 0;
        if (active_mod) |md| {
            if (value_string == null) value_string = cfg.variants.get(md.name);
            if (value_string) |vs| {
                if (md.variant_parse) |vp| {
                    if (vp(vs)) |parsed| {
                        v_idx = parsed;
                    } else if (override_variant != null) {
                        debug.warn(
                            "Config: workspace {d} layout variant '{s}' ignored — not a variant " ++
                                "of the active layout",
                            .{ i, vs },
                        );
                    } else {
                        debug.warn("Unknown {s} variants '{s}', using default", .{ md.name, vs });
                    }
                } else if (override_variant != null) {
                    debug.warn(
                        "Config: workspace {d} layout variant ignored — not a variant " ++
                            "of the active layout",
                        .{i},
                    );
                }
            }
        }
        s.params.variant_idx = v_idx;
        s.params.primary_count = if (id < max_ws)
            (count_lookup[id] orelse cfg.master_count)
        else
            cfg.master_count;
        s.params.primary_width = 0.5; // runtime-only; reset to default
        s.params.secondary_balance = 0;
    }
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
/// Kept protocol-side (R2): pointer-hover query and focus suppression reset.
/// model.current is the single store; tracking's getCurrentWorkspace is a
/// read-through facade over it.
pub fn switchTo(ws_idx: u8) void {
    const m = pipeline.model();
    if (ws_idx >= constants.max_workspaces) return;
    if (m.current == ws_idx) return;

    const t0 = utils.monotonicNs();

    // Suppression/pointer-sync state first, then the switch transition.
    const focus_mod = @import("focus");
    focus_mod.setSuppressReason(.none);
    focus_mod.cancelPointerSync();

    // All-view exit is a flag flip (emerges from visibility); temp-window
    // masks do not exist in the model.
    m.all_view_active = false;

    // model.current is the ONLY store for the current workspace; the
    // tracking/workspaces mirrors are deleted (read-through facades now).
    m.current = ws_idx;

    // Bump the window fact: the workspace indicator always changes on switch.
    // prepareClearFocus returns .none when last_applied is null (empty-to-empty
    // switch), so the focus fact alone can't guarantee a redraw; bumping the
    // window fact here makes the bar redraw at end-of-batch.
    core.bumpWindow();
    // Bar visibility follows the NEW workspace's fullscreen occupant. Apply it
    // NOW (X-free, no reconcile) so the FIRST reconcile below already reads the
    // correct screen claim / workarea for this workspace. Otherwise the bar's
    // deferred visibility update would require a SECOND reconcile on this
    // workspace, retiling Discord's geometry twice and causing a flicker.
    if (build_options.has_bar)
        @import("plugins").Surfaces.updateBarVisibilityForWorkspace(@intCast(ws_idx));
    // Bump the core fullscreen fact; the bar's reactive path in updateIfDirty
    // will no-op since the claim is already applied, but keeping the fact in
    // sync avoids any stale-revision edge.
    core.bumpFullscreen();

    const t1 = utils.monotonicNs();

    // The server grab body below is pure fire-and-forget XCB (focus
    // transition + reconcile), so no blocking wait ever freezes input while
    // the grab is held. All decision work — focus-candidate selection and
    // the FocusTransition prep — runs here, model-local or cache-backed,
    // BEFORE grabServer so a fast-following keypress is never starved by this
    // switch (the drop-safety fix).
    const cs = core.getState();

    // Keyboard-triggered switch focuses the model's tiered fallback
    // (newest-first MRU, then reversed tiled_order, then floating) — NO pointer
    // query. Querying what's under the cursor costs a synchronous round trip
    // that stalls the single-threaded event loop; a fast-following keypress
    // (Super+2 immediately after Super+1) waits behind that stall, which is
    // exactly the "quick workspace switches sometimes don't register" symptom.
    // A keyboard switch has no pointer gesture to honor, so focus is decided
    // purely from the model with zero X round trips.
    const target: ?model_mod.WindowId = model_mod.fallbackFocusCandidate(m, ws_idx);

    // Pre-fire the fallback's WM_PROTOCOLS query only on a take_focus cache
    // miss; the common path is cache-backed (see window.zig's "ICCCM focus
    // property cache" note) so nothing is wasted, and the miss case overlaps
    // the FocusTransition prep below instead of blocking inline.
    const pre_protocols_cookie = if (target) |t|
        (if (window.isInputModelCached(t)) null else window.fireWMProtocolsQuery(cs.conn, t))
    else
        null;

    const ft: focus.FocusTransition = blk: {
        if (target) |t| {
            model_mod.setFocus(m, t);
            break :blk focus_mod.prepareFocus(t, .workspace_switch, pre_protocols_cookie);
        } else {
            window.discardProtocolCookie(cs.conn, pre_protocols_cookie);
            model_mod.clearFocus(m);
            break :blk focus_mod.prepareClearFocus();
        }
    };

    const t2 = utils.monotonicNs();

    // Inline the server grab so protocol focus and geometry land atomically
    // (Gap 4 atomicity fix). Only fire-and-forget XCB runs below, so the grab
    // is held for microseconds — no blocking wait can freeze a next keypress.
    const c = pipeline.grabCtx();
    c.sink.grabServer();
    defer c.sink.ungrabAndFlush();

    focus_mod.applyPendingFocus(ft);

    // force_restack raises the bar window.
    sync.reconcile(m, c, .{ .force_restack = true });

    const t3 = utils.monotonicNs();
    debug.info("[TIMING] switchTo ws={}: model={d}us rt_prep={d}us grab_body={d}us total={d}us", .{
        ws_idx,
        @as(u64, @intCast(t1 - t0)) / 1000,
        @as(u64, @intCast(t2 - t1)) / 1000,
        @as(u64, @intCast(t3 - t2)) / 1000,
        @as(u64, @intCast(t3 - t0)) / 1000,
    });
}

// ------------------------------------------------------- spawn/map lifecycle

/// MapRequest tail. The caller's front-end (event masks, property
/// queries, size-hints cache) has already run; this registers the window in
/// the model and lets ONE reconcile do map+pixel+bw+geom(+ABOVE winner) for
/// on-current spawns. Off-current spawns park by construction; sync sends
/// their border width at first show instead of immediately (invisible either
/// way; one less request).
pub fn mapRequest(win: model_mod.WindowId, target_ws: u8, on_current: bool) void {
    const wincache = @import("wincache");

    const m = pipeline.model();
    if (m.store.has(win)) return; // double-manage guard

    // A defined refusal (store or home-list full) leaves the window
    // unmanaged.
    model_mod.register(m, win, if (on_current) null else target_ws) catch {
        std.log.warn("mapRequest: capacity full; window 0x{x} left unmanaged", .{win});
        return;
    };
    // Bridge the cached WM_NORMAL_HINTS into the model entry at registration.
    const e = m.store.getPtr(win);
    if (e) |ep| ep.size_hints = wincache.peekHints(win);
    // Primary-fifo variant spawn placement (moved out of model.register; it
    // is SPAWN policy, not membership policy): a new window takes the
    // primary-column head slot, and the previous head window drops one slot.
    {
        const home: model_mod.WSId = if (on_current) m.current else @intCast(target_ws);
        const p = &m.ws[home].params;
        // Same policy restated at the spawn site: driven by the active
        // module's fifo_variant metadata (the head slot binds variant
        // index 1).
        if (p.kind < tiling_mods.len) {
            const fv = tiling_mods[p.kind].fifo_variant;
            if (fv != null and p.variant_idx == fv.? and m.ws[home].tiled_order.len > 1)
                model_mod.reorderTiled(m, win, 0);
        }
    }
    focus.initWindowGrabs(win); // protocol-side keygrabs, both paths did this
    core.bumpWindow(); // a window was admitted

    if (!on_current) return;

    // Model focus first so the reconcile below colors/stacks with the new
    // focus. X input focus AFTER reconcile (inside the same grab): the
    // window must be mapped before xcb_set_input_focus, and the map happens
    // during reconcile. Both map+focus land under one grab (Gap 3 fix).
    model_mod.setFocus(m, win);
    const ft = focus.prepareFocus(win, .window_spawn, null);
    pipeline.reconcileUnderGrabNowWithFocusAfter(.{}, ft);
}

/// Unmanage tail: close/destroy/unmap of a managed window. Local
/// bookkeeping (covering record, caches, sub-system removes) has already
/// run; this drops the model entry and re-focuses. Inactive-workspace
/// geometry repairs ride the same global LastSent diff.
pub fn unmanage(ctx: *Ctx, win: model_mod.WindowId) void {
    const m = pipeline.model();
    // Covering and focus truth arrive via ctx: the sole caller (window.
    // unmanageWindow) removes the model entry (the workspace layer's
    // removeWindow -> unregister) BEFORE this action runs, so reading the
    // store here could never see either; closing the covering occupant never
    // restored the bar, and the withdrawn window's focus ownership was
    // unknowable.
    const was_fs_current = if (ctx.withdrawn_fullscreen_ws) |ws| ws == m.current else false;
    const was_focused = ctx.withdrawn_was_focused;

    model_mod.unregister(m, win);
    sync.forget(win); // X ids recycle; stale LastSent must not survive

    // Close fallback (parity with the hide path): when the withdrawn window
    // held focus, hand it to the previously focused window on this ws
    // (MRU newest-first -> reversed tiled_order -> floating); with no
    // candidate left, focus clears. Model update runs before the grab;
    // protocol commit runs inside the grab (Gap 1 atomicity fix).
    const ft: focus.FocusTransition = if (was_focused) focusFallback(m) else .none;

    core.bumpWindow(); // window removed; title segment drops it
    // Closing the current workspace's covering occupant releases the area:
    // bump the core fact (bar reacts, re-derives its claim before the reconcile
    // below reads the work area).
    if (was_fs_current) core.bumpFullscreen();

    pipeline.reconcileUnderGrabNowWithFocus(.{ .force_restack = true }, ft);
}
