//! The workspace actions: move_to_workspace, tag/pin
//! toggles, all-view, and the workspace switch. Each
//! action is one model transition + one sync entry. The
//! shared transition tails (retile, focusFallback) and
//! the minimized query live in `actions.zig`, the hub
//! this file imports: the two files form the window
//! layer's intentional runtime-only import cycle (the
//! same hub-and-spoke shape check-layers.sh documents
//! for core<->window).

const core = @import("core");
const constants = @import("constants");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const build_options = @import("build_options");
const surfaces = @import("surfaces").Surfaces;
const time = @import("time");
const log = @import("log");

const actions = @import("actions");
const gate = actions.gate;

/// Registry lookup for the hook `field` (see `contract.providerOf`), null when
/// no module binds it; canonical scan lives in window.providerOf.
const providerOf = actions.providerOf;

/// Shared change guard for the tag/pin actions: the window must be present in
/// the model and not hidden.
fn canTagChange(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    if (m.store.get(win) == null) return false;
    return !actions.isMinimizedOnAnyWs(m, win);
}

// tag-move / pin / all-view

/// move_to_workspace. Model moves mask + home list + covering record in one
/// call; the reconcile's diff parks/repairs geometry globally.
pub fn moveWindowTo(win: model_mod.WindowId, ws_idx: u8) void {
    const wm = providerOf(.sendToWs) orelse return;
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.mut(&gate);
    const was_focused = m.focused == win;
    const was_fs_current = actions.isCoveringOnWs(m, win);

    wm.sendToWs.?(m, win, model_mod.WSId.fromIndex(ws_idx));
    if (m.store.get(win) == null) return; // unknown window: no-op

    var ft: focus.FocusTransition = .none;
    if (ws_idx != m.current.index) {
        if (was_focused) {
            ft = actions.focusFallback(m, .tiling_operation);
        }
        // Moving the current workspace's covering window away changes the
        // workspace's covering occupancy: bump the core fact; bar reacts.
        if (was_fs_current) core.fullscreen.bump();
    }
    actions.retile(.{ .mode = .focus }, ft);
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
        if (removing_current and m.focused == win) {
            ft = actions.focusFallback(m, .tiling_operation);
        }
    } else {
        if (add_prov) |ap| ap.addToWs.?(m, win, model_mod.WSId.fromIndex(ws_idx), protect_current);
    }

    if (removing_current or (!had_bit and ws_idx == m.current.index)) {
        // Visible-set changed on the shown workspace: atomic evict/map+retile.
        pipeline.reconcileGrabFocus(.{}, ft, .before, null);
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
    actions.retile(.{}, null);
}

/// all_workspaces (Mod+5): flag flip; sync maps foreign windows on enter and
/// parks them again on exit through the ordinary diff.
pub fn allViewToggle() void {
    const wm = providerOf(.toggleAllView) orelse return;
    const m = pipeline.mut(&gate);
    const entering = wm.toggleAllView.?(m);
    var ft: focus.FocusTransition = .none;
    if (!entering and m.focused != null and !model_mod.visibleOn(m, m.focused.?, m.current)) {
        ft = actions.focusFallback(m, .tiling_operation);
    }
    actions.retile(.{ .mode = .focus_restack }, ft);
}

// workspace switch

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
    // No-op only when the view is already exactly this workspace (no all-view
    // to exit). In all-view the current index may already equal the target:
    // hitting the tag must still exit the all-view flag, returning the view to
    // that one workspace.
    if (m.current.index == ws_idx and !m.all_view_active) return;

    const t0: u64 = if (build_options.profile_key) time.monotonicNs() else 0;

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
    // No `has_bar` guard: the hook is a no-op with no surface module.
    surfaces.updateBarVisibilityForWorkspace(ws_idx);
    // Bump the core fullscreen fact only when the target workspace actually
    // carries a covering occupant: the bar's reactive path derives its claim
    // from the fact, so spuriously bumping it on every switch would churn a
    // bar-redraw for workspaces with no fullscreen window (the claim for the
    // new ws was already applied by updateBarVisibilityForWorkspace above).
    // OR scan (not the module AND hook): any covering entry, anchored or
    // merely visible on ws, owns the screen here.
    if (model_mod.coveringOccupantOnWs(m, m.current) != null) core.fullscreen.bump();

    const t1: u64 = if (build_options.profile_key) time.monotonicNs() else 0;

    // The server grab (pipeline.withServerGrab, not a local bracket) wraps
    // pure fire-and-forget XCB (focus transition + reconcile), so no blocking
    // wait ever freezes input while the grab is held. All decision work —
    // focus-candidate selection and the FocusTransition prep — runs here,
    // model-local or cache-backed,
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
    const ft: focus.FocusTransition = actions.focusFallback(m, .workspace_switch);

    const t2: u64 = if (build_options.profile_key) time.monotonicNs() else 0;

    // Reconcile + focus under one server grab, atomically, via the pipeline
    // seam (grabCtx/reconcile/applyPendingFocus/ungrabAndFlush consolidated).
    // Only fire-and-forget XCB runs inside the grab, so it is held for
    // microseconds—no blocking wait can freeze a next keypress.
    //
    // Geometry-before-focus (FocusOrder.after): the arriving window may have
    // been spawned off-current and never mapped (the spawn path registers but
    // defers the map to the first reconcile).  Firing xcb_set_input_focus on
    // an unmapped window is a BadMatch that leaves X focus on the old
    // workspace's window.  The .after order maps the arriving window before
    // applyPendingFocus targets it, in the same flush.
    pipeline.reconcileGrabFocus(.{ .force_restack = true }, ft, .after, null);

    if (build_options.profile_key) {
        const t3 = time.monotonicNs();
        log.info("[TIMING] switchTo ws={}: model={d}us rt_prep={d}us grab_body={d}us total={d}us", .{
            ws_idx,
            @as(u64, @intCast(t1 - t0)) / 1000,
            @as(u64, @intCast(t2 - t1)) / 1000,
            @as(u64, @intCast(t3 - t2)) / 1000,
            @as(u64, @intCast(t3 - t0)) / 1000,
        });
    }
}
