//! Workspace state transitions over the window model: tag membership, moves,
//! pin and all-view toggles. Pure model edits, no state of its own -- a
//! window's membership IS its tag mask plus its workspace's `tiled_order`,
//! so a move is one mask write plus two list edits. The only cross-module
//! rule is covering intent: a move or a removed tag retargets a covering
//! window to the new workspace, or drops it to de-fullscreen when that
//! destination already has an owner (dispatched through the registry, so
//! `fullscreen` is never named here). Workspace count and per-workspace
//! config overrides are owned elsewhere (query latches the count;
//! config/model_config.zig seeds the params).
//!
//! The module also owns the WORKSPACE COMMANDS (switch, move, tag, pin,
//! all-view): each is one model transition plus one reconcile entry, and
//! each binds a hook on `module` so the core reaches it through the
//! registry instead of importing this file by name. Deleting this file
//! drops the commands along with the state. That is why this file may
//! import `pipeline`/`focus`/`core` (the "pure model edits" claim above
//! covers the model transitions, not the commands layered on them).

const std = @import("std");
const core = @import("core");
const model = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const surfaces = @import("surfaces").Surfaces;
const build_options = @import("build_options");
const log = std.log.scoped(.workspaces);
const registry = @import("registry");
const reconcile_tails = @import("reconcile_tails");
const covering = registry.covering;
const wsf = registry.workspaces;

/// Model-only workspace assignment; the production switch path is
/// `switchWorkspace` below (one model transition + one reconcile).
pub fn switchTo(m: *model.Model, ws: model.WSId) void {
    m.current = ws;
}

pub fn moveWindowToWs(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    const e = m.store.getPtr(win) orelse return;
    if (!ws.isValid()) return; // bad target: indexing m.ws[ws] below would OOB (ReleaseFast)
    if (model.isPinned(e.*)) return; // pinned stays everywhere-visible

    // Refuse-before-mutate: full destination list cancels the move.
    const to_new_ws = if (e.home_ws) |hw| !hw.eql(ws) else true;
    if (e.home_ws != null and to_new_ws and m.ws[ws.index].tiled_order.len >= model.max_tiled_per_ws) return;

    transferFullscreenOnMove(m, win, ws);
    e.mask = model.bit(ws);
    if (e.home_ws) |old_h| {
        if (to_new_ws) {
            // Only a tiled-anchor window lives in a tiled_order. A floating-
            // anchored window can carry a stale home_ws (register seeds it),
            // but appending it there would make a layout seat it cannot fill.
            if (e.anchor == .tiled) {
                model.removeValue(&m.ws[old_h.index].tiled_order, win);
                _ = m.ws[ws.index].tiled_order.append(win);
            }
            e.home_ws = ws;
        }
    }
}

/// Move `win`'s covering intent to `dest`, or drop it when a resident occupant
/// there swallows the transfer.
///
/// The demote direction is EXPLICIT. `toggleCovering` is a two-edged verb
/// whose correctness depends entirely on a guard the caller has already
/// proved -- `win` really is covering. If that proof were ever lost (a
/// reordered check, a new caller, a provider that reports covering
/// differently) a "demote" silently becomes a fullscreen ENTRY, and the
/// failure is a window jumping to screen-covering, not a no-op.
/// `releaseCovering` only goes one way, so the wrong-direction mistake is
/// unrepresentable.
fn retargetOrDropFullscreen(m: *model.Model, win: model.WindowId, dest: model.WSId) void {
    // Screen-owner question: the AND rule, straight from the model (P2-51
    // consolidated the old contract hook into model.coveringOccupantOn).
    const occupant = model.coveringOccupantOn(m, dest, .anchored_and_visible);
    if (occupant != null and occupant != win) {
        if (covering.providerOf(.releaseCovering)) |wm| {
            wm.covering.releaseCovering.?(m, win);
        }
        return; // a resident owner swallows the transfer
    }
    if (covering.providerOf(.moveCoveringTo)) |wm| {
        wm.covering.moveCoveringTo.?(m, win, dest);
    }
}

/// Fullscreen record follows the move; a destination owner drops the mover
/// into de-fullscreen rather than clobbering the resident. Ghost records
/// (minimized-from-fullscreen) move their workspace too, following the
/// parked mask.
fn transferFullscreenOnMove(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    // Model query, not a peer-module dispatch: a dispatch returns null when
    // no covering module is bound, which would answer "is this window
    // covering" false in such a build -- while the model still holds the
    // intent, and session.zig restores it across a session restart.
    const fws = model.coveringWsOf(m, win) orelse return;
    if (fws.eql(ws)) return;
    retargetOrDropFullscreen(m, win, ws);
}

/// Remove tag `ws`; the last remaining tag is protected (returns false).
/// Fullscreen on the removed workspace transfers to the lowest remaining bit,
/// or drops into de-fullscreen when that destination is occupied.
pub fn tagRemove(m: *model.Model, win: model.WindowId, ws: model.WSId) bool {
    const e = m.store.getPtr(win) orelse return false;
    if (@popCount(e.mask) <= 1) return false;
    if (!model.taggedOn(e.*, ws)) return false; // tag wasn't set: true no-op
    e.mask &= ~model.bit(ws);
    // Model query (see transferFullscreenOnMove).
    if (model.isCoveringOn(m, win, ws)) {
        const dest = model.lowestBit(e.mask) orelse unreachable;
        retargetOrDropFullscreen(m, win, dest);
    }
    // Removing the home tag must not strand the seat: the window can no
    // longer be placed on its old home workspace, so its tiled_order entry
    // and home cache have to move to a surviving tag (or the seat drops and
    // reconcile parks the unplaced window). Leaving it would inflate the old
    // list's len and feed capacity refusals while the window itself never
    // returns to a layout.
    if (e.home_ws) |hw| {
        if (hw.eql(ws)) {
            model.removeValue(&m.ws[hw.index].tiled_order, win);
            e.home_ws = null;
            if (e.anchor == .tiled) {
                if (model.lowestBit(e.mask)) |h| {
                    if (m.ws[h.index].tiled_order.append(win)) {
                        e.home_ws = h;
                    }
                }
            }
        }
    }
    return true;
}

pub fn tagAdd(m: *model.Model, win: model.WindowId, ws: model.WSId, protect_current: bool) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask |= model.bit(ws);
    if (protect_current) e.mask |= model.bit(m.current);
}

pub fn pinToggle(m: *model.Model, win: model.WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask = if (model.isPinned(e.*)) model.bit(m.current) else model.ALL_MASK;
}

pub fn allViewToggle(m: *model.Model) bool {
    m.all_view_active = !m.all_view_active;
    return m.all_view_active;
}

/// Workspace commands: one model transition + one reconcile entry each, living
/// beside the state they write. The core reaches them through the
/// `switchWorkspace`/`moveToWorkspace`/`toggleTag`/`pinWindow`/`allWorkspaces`
/// hooks on `module`, so a tree without this file compiles with no binder
/// rather than a dangling import.
/// Shared change guard for the tag/pin commands: the window must be present
/// in the model and not hidden.
fn canTagChange(m: *const model.Model, win: model.WindowId) bool {
    if (m.store.get(win) == null) return false;
    return !registry.isMinimizedOnAnyWs(m, win);
}

/// move_to_workspace. Model moves mask + home list + covering record in one
/// call; the reconcile's diff parks/repairs geometry globally.
pub fn moveToWorkspace(win: model.WindowId, ws_idx: u8) void {
    const wm = wsf.providerOf(.sendToWs) orelse {
        log.warn("move_to_workspace: no sendToWs provider bound", .{});
        return;
    };
    if (!core.isValidWorkspaceIndex(ws_idx)) return;

    const m = pipeline.mut();
    const was_focused = m.focused == win;
    const was_fs_current = model.isCoveringOn(m, win, m.current);

    wm.workspaces.sendToWs.?(m, win, model.WSId.fromIndex(ws_idx));
    if (m.store.get(win) == null) return; // unknown window: no-op

    var ft: focus.FocusTransition = .none;
    if (ws_idx != m.current.index) {
        if (was_focused) {
            ft = focus.focusFallback(m, .tiling_operation);
        }
        // Moving the current workspace's covering window away changes the
        // workspace's covering occupancy: bump the core fact; bar reacts.
        if (was_fs_current) core.fullscreen.bump();
    } else if (!was_fs_current and model.isCoveringOn(m, win, m.current)) {
        // A covering window moved ONTO the current workspace: current gained
        // a screen-claiming occupant, so bump the core fullscreen fact and
        // re-apply the bar's visibility for the new occupant. Without this, a
        // tag-move of a fullscreen window onto the active workspace leaves the
        // bar mapped over the new cover (switchWorkspace handles arrival on a
        // switch; this move path must handle it too).
        surfaces.updateBarVisibilityForWorkspace(ws_idx);
        core.fullscreen.bump();
    }
    reconcile_tails.retile(.{ .mode = .focus }, ft);
}

/// toggle_tag (Mod+Alt+N). Focus is left unchanged on add (multi-tag gesture);
/// removing the CURRENT tag evicts the window and re-focuses.
pub fn toggleTag(win: model.WindowId, ws_idx: u8, protect_current: bool) void {
    // Guard on the two hooks this command actually dispatches: with neither
    // bound there is nothing to toggle (and no reconcile to trigger).
    const add_prov = wsf.providerOf(.addToWs);
    const rem_prov = wsf.providerOf(.removeFromWs);
    if (add_prov == null and rem_prov == null) {
        log.warn("toggle_tag: no addToWs/removeFromWs provider bound", .{});
        return;
    }
    if (!core.isValidWorkspaceIndex(ws_idx)) return;

    const m = pipeline.mut();
    if (!canTagChange(m, win)) return;
    const e = m.store.get(win).?;

    const had_bit = model.taggedOn(e, model.WSId.fromIndex(ws_idx));
    const removing_current = ws_idx == m.current.index;

    var ft: focus.FocusTransition = .none;
    if (had_bit) {
        if (rem_prov) |rp| {
            if (!rp.workspaces.removeFromWs.?(m, win, model.WSId.fromIndex(ws_idx))) return; // last tag protected
        }
        if (removing_current and m.focused == win) {
            ft = focus.focusFallback(m, .tiling_operation);
        }
    } else {
        if (add_prov) |ap| ap.workspaces.addToWs.?(m, win, model.WSId.fromIndex(ws_idx), protect_current);
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
pub fn pinWindow(win: model.WindowId) void {
    const wm = wsf.providerOf(.togglePin) orelse {
        log.warn("pin_window: no togglePin provider bound", .{});
        return;
    };
    const m = pipeline.mut();
    if (!canTagChange(m, win)) return;
    wm.workspaces.togglePin.?(m, win);
    reconcile_tails.retile(.{}, null);
}

/// all_workspaces (Mod+5): flag flip; the reconciler maps foreign windows on
/// enter and parks them again on exit through the ordinary diff.
pub fn allWorkspaces() void {
    const wm = wsf.providerOf(.toggleAllView) orelse {
        log.warn("all_workspaces: no toggleAllView provider bound", .{});
        return;
    };
    const m = pipeline.mut();
    const entering = wm.workspaces.toggleAllView.?(m);
    var ft: focus.FocusTransition = .none;
    if (!entering and m.focused != null and !model.visibleOn(m, m.focused.?, m.current)) {
        ft = focus.focusFallback(m, .tiling_operation);
    }
    reconcile_tails.retile(.{ .mode = .focus_restack }, ft);
}

// workspace switch

/// Workspace switch. One model transition + one reconcile; the LastSent
/// diff parks leavers once and maps+places arrivers (see reconcile_test's
/// switch scenario).
///
/// Kept protocol-side: pointer-hover query and focus suppression reset.
/// model.current is the single store; query's getCurrentWorkspace is a
/// read-through facade over it.
///
/// Geometry-before-focus: the reconcile maps the arriving window before
/// applyPendingFocus targets it — the arriving window may have been spawned
/// off-current and never mapped, so an earlier focus-before-reconcile
/// ordering produced a BadMatch that left X focus on the old workspace's
/// window.
pub fn switchWorkspace(ws_idx: u8) void {
    const m = pipeline.mut();
    if (!core.isValidWorkspaceIndex(ws_idx)) return;
    // No-op only when the view is already exactly this workspace (no all-view
    // to exit). In all-view the current index may already equal the target:
    // hitting the tag must still exit the all-view flag, returning the view to
    // that one workspace.
    if (m.current.index == ws_idx and !m.all_view_active) return;

    const t0: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // Suppression reset, then the switch transition.
    focus.setSuppressReason(.none);

    // All-view exit is a flag flip (emerges from visibility); temp-window
    // masks do not exist in the model.
    m.all_view_active = false;

    // model.current is the ONLY store for the current workspace; the other
    // layers read through it. The layout params are per-workspace too, so the
    // outgoing workspace's kind/variant are captured HERE, before the flip --
    // they are what the layout and variants segments were last drawn from.
    const leaving_kind = m.ws[m.current.index].params.kind;
    const leaving_variant = m.ws[m.current.index].params.variant_idx;
    m.current = model.WSId.fromIndex(ws_idx);

    // Bump the window fact: the workspace indicator always changes on switch.
    // prepareClearFocus returns .none when last_applied is null (empty-to-empty
    // switch), so the focus fact alone can't guarantee a redraw; bumping the
    // window fact here makes the bar redraw at end-of-batch.
    core.window.bump();
    // The window fact repaints only the frame-declaring segments (title, tags):
    // the layout/variants indicators render the ACTIVE workspace's per-workspace
    // kind/variant, which that fact does not carry -- without this they stayed
    // stale on a switch until an unrelated segment's redraw request happened to
    // repaint the row. The layout fact is the revision that means "the kind or
    // variants changed" (a full redraw, the same tail cycle_layout/cycle_variants
    // take), so bump it ONLY when the switch actually changed what they render:
    // an identical switch must not churn a redraw, a differing one must not wait.
    const entering = m.ws[ws_idx].params;
    if (leaving_kind != entering.kind or leaving_variant != entering.variant_idx)
        core.layout.bump();
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
    // new workspace was already applied by updateBarVisibilityForWorkspace
    // above). OR rule (not the AND screen-owner rule): any covering entry,
    // anchored or merely visible on the current workspace, owns the screen
    // here.
    if (model.coveringOccupantOn(m, m.current, .anchored_or_visible) != null) core.fullscreen.bump();

    const t1: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // The server grab (pipeline's grabScoped token, not a local bracket) wraps
    // pure fire-and-forget XCB (focus transition + reconcile), so no blocking
    // wait ever freezes input while the grab is held. All decision work —
    // focus-candidate selection and the FocusTransition prep — runs here,
    // model-local or cache-backed,
    // BEFORE grabServer so a fast-following keypress is never starved by this
    // switch.

    // Keyboard-triggered switch focuses the model's tiered fallback
    // (newest-first MRU, then reversed tiled_order, then floating) — NO
    // pointer query. Querying what's under the cursor costs a synchronous
    // round trip that stalls the single-threaded event loop; a fast-following
    // keypress (Super+2 immediately after Super+1) waits behind that stall,
    // which is exactly the "quick workspace switches sometimes don't register"
    // symptom. A keyboard switch has no pointer gesture to honor, so focus is
    // decided purely from the model with zero X round trips.
    const ft: focus.FocusTransition = focus.focusFallback(m, .workspace_switch);

    const t2: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // Reconcile + focus under one server grab, atomically, via the pipeline's
    // grab path (grabCtx/reconcile/applyPendingFocus/ungrabAndFlush
    // consolidated). Only fire-and-forget XCB runs inside the grab, so it is
    // held for microseconds—no blocking wait can freeze a next keypress.
    //
    // Geometry-before-focus (FocusOrder.after): the arriving window may have
    // been spawned off-current and never mapped (the spawn path registers but
    // defers the map to the first reconcile).  Firing xcb_set_input_focus on
    // an unmapped window is a BadMatch that leaves X focus on the old
    // workspace's window.  The .after order maps the arriving window before
    // applyPendingFocus targets it, in the same flush.
    pipeline.reconcileGrabFocus(.{ .force_restack = true }, ft, .after, null);

    if (build_options.profile_key) {
        const t3 = core.monotonicNs();
        log.info("[TIMING] switchTo ws={}: model={d}us rt_prep={d}us grab_body={d}us total={d}us", .{
            ws_idx,
            @as(u64, @intCast(t1 - t0)) / 1000,
            @as(u64, @intCast(t2 - t1)) / 1000,
            @as(u64, @intCast(t3 - t2)) / 1000,
            @as(u64, @intCast(t3 - t0)) / 1000,
        });
    }
}

/// This module's window sub-system contribution: pure model transitions;
/// lifecycle is handled by the query facade's init (count latch) and
/// model state lives in the model.
pub const module: @import("window_contract").WindowModule = .{
    .name = "workspaces",
    .workspaces = .{
        .sendToWs = moveWindowToWs,
        .addToWs = tagAdd,
        .removeFromWs = tagRemove,
        .togglePin = pinToggle,
        .toggleAllView = allViewToggle,
    },
    .command = .{
        .switchWorkspace = switchWorkspace,
        .moveToWorkspace = moveToWorkspace,
        .toggleTag = toggleTag,
        .pinWindow = pinWindow,
        .allWorkspaces = allWorkspaces,
    },
};
