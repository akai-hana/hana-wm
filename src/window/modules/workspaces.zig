//! Workspace state transitions over the window model: tag membership, moves,
//! pin and all-view toggles. A window's membership IS its tag mask plus its
//! workspace's `tiled_order`, so a move is one mask write plus two list
//! edits. The only cross-module rule is covering intent: a move or a removed
//! tag retargets a covering window to the new workspace, or drops it to
//! de-fullscreen when that destination already has an owner (dispatched
//! through the registry, so `fullscreen` is never named here).
//!
//! The module also owns the WORKSPACE COMMANDS (switch, move, tag, pin,
//! all-view): each is one model transition plus one reconcile entry, bound
//! as a `module` hook so the core reaches it through the registry. Deleting
//! this file drops the commands along with the state — which is why this
//! file may import `pipeline`/`focus`/`core` (the "pure model edits" claim
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

    // Only a window that holds a tiled seat has a list to move between;
    // floating and parked windows just retag.
    const home = model.findHome(m, win);
    const relist = if (home) |h| !h.eql(ws) else false;

    // Refuse-before-mutate: full destination list cancels the move.
    if (relist and m.ws[ws.index].tiled_order.len >= model.max_tiled_per_ws) return;

    transferFullscreenOnMove(m, win, ws);
    e.mask = model.bit(ws);
    if (relist) {
        model.removeValue(&m.ws[home.?.index].tiled_order, win);
        _ = m.ws[ws.index].tiled_order.append(win);
    }
}

/// Move `win`'s covering intent to `dest`, or drop it when a resident
/// occupant there swallows the transfer.
///
/// The demote direction is EXPLICIT: `toggleCovering` is a two-edged verb
/// whose correctness depends on a guard the caller has already proved — that
/// `win` really is covering. If that proof were ever lost, a "demote"
/// silently becomes a fullscreen ENTRY, and the failure is a window jumping
/// to screen-covering, not a no-op. `releaseCovering` only goes one way, so
/// the wrong-direction mistake is unrepresentable.
fn retargetOrDropFullscreen(m: *model.Model, win: model.WindowId, dest: model.WSId) void {
    // Screen-owner question: the AND rule, straight from the model.
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
    // covering" false while the model still holds the intent (and session
    // restore persists it).
    const fws = model.coveringWsOf(m, win) orelse return;
    if (fws.eql(ws)) return;
    retargetOrDropFullscreen(m, win, ws);
}

/// Remove tag `ws`; the last remaining tag is protected (returns false).
/// Fullscreen on the removed workspace transfers to the lowest remaining
/// bit, or drops into de-fullscreen when that destination is occupied.
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
    // has to move to a surviving tag (or the seat drops and reconcile parks
    // the unplaced window). Leaving it would inflate the old list's len and
    // feed capacity refusals while the window never returns to a layout.
    if (model.findHome(m, win)) |hw| {
        if (hw.eql(ws)) {
            model.removeValue(&m.ws[hw.index].tiled_order, win);
            if (e.anchor == .tiled) {
                if (model.lowestBit(e.mask)) |h| _ = m.ws[h.index].tiled_order.append(win);
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

/// Workspace commands: one model transition + one reconcile entry each,
/// living beside the state they write. The core reaches them through the
/// `module` hooks, so a tree without this file compiles with no binder.
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
        // A covering window moved ONTO the current workspace: it gained a
        // screen-claiming occupant, so bump the fullscreen fact and re-apply
        // the bar's visibility (switchWorkspace handles arrival on a switch;
        // this move path must handle it too). Without this the bar stays
        // mapped over the new cover.
        surfaces.updateBarVisibilityForWorkspace(ws_idx);
        core.fullscreen.bump();
    }
    reconcile_tails.retile(.{ .mode = .focus }, ft);
}

/// toggle_tag (Mod+Alt+N). Focus is left unchanged on add (multi-tag
/// gesture); removing the CURRENT tag evicts the window and re-focuses.
pub fn toggleTag(win: model.WindowId, ws_idx: u8, protect_current: bool) void {
    // Guard on the two hooks this command dispatches: with neither bound
    // there is nothing to toggle (and no reconcile to trigger).
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

/// all_workspaces (Mod+5): flag flip; the reconciler maps foreign windows
/// on enter and parks them again on exit through the ordinary diff.
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

/// Workspace switch: one model transition + one reconcile; the LastSent diff
/// parks leavers once and maps+places arrivers. Kept protocol-side for the
/// pointer-hover query and focus suppression reset; `model.current` is the
/// single store (query's getCurrentWorkspace is a read-through facade).
pub fn switchWorkspace(ws_idx: u8) void {
    const m = pipeline.mut();
    if (!core.isValidWorkspaceIndex(ws_idx)) return;
    // No-op only when the view is already exactly this workspace (no
    // all-view to exit). In all-view the current index may already equal the
    // target: hitting the tag must still exit the all-view flag.
    if (m.current.index == ws_idx and !m.all_view_active) return;

    const t0: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // Suppression reset, then the switch transition.
    focus.setSuppressReason(.none);

    // All-view exit is a flag flip (emerges from visibility).
    m.all_view_active = false;

    // model.current is the ONLY store for the current workspace; the layout
    // params are per-workspace too, so the outgoing kind/variant are
    // captured HERE, before the flip.
    const leaving_kind = m.ws[m.current.index].params.kind;
    const leaving_variant = m.ws[m.current.index].params.variant_idx;
    m.current = model.WSId.fromIndex(ws_idx);

    // Bump the window fact: the workspace indicator always changes on
    // switch. prepareClearFocus returns .none for an empty-to-empty switch,
    // so the focus fact alone can't guarantee a redraw.
    core.window.bump();
    // The window fact repaints only the frame-declaring segments (title,
    // tags): the layout/variants indicators render the ACTIVE workspace's
    // kind/variant, which that fact does not carry. The layout fact means
    // "the kind or variants changed"; bump it ONLY when the switch changed
    // what they render (an identical switch must not churn a redraw).
    const entering = m.ws[ws_idx].params;
    if (leaving_kind != entering.kind or leaving_variant != entering.variant_idx)
        core.layout.bump();
    // Bar visibility follows the NEW workspace's fullscreen occupant. Apply
    // it NOW (X-free, no reconcile) so the first reconcile already reads the
    // correct screen claim / workarea — otherwise a deferred update would
    // need a SECOND reconcile, retiling geometry twice and flickering. No
    // `has_bar` guard: the hook is a no-op with no surface module.
    surfaces.updateBarVisibilityForWorkspace(ws_idx);
    // Bump the core fullscreen fact only when the target workspace carries
    // a covering occupant: spuriously bumping on every switch churns a bar
    // redraw (the claim was already applied above). OR rule (not the AND
    // screen-owner rule): any covering entry, anchored or merely visible on
    // the current workspace, owns the screen here.
    if (model.coveringOccupantOn(m, m.current, .anchored_or_visible) != null) core.fullscreen.bump();

    const t1: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // The server grab wraps pure fire-and-forget XCB, so no blocking wait
    // can freeze input while it is held. All decision work (focus-candidate
    // selection, FocusTransition prep) runs BEFORE grabServer so a
    // fast-following keypress is never starved.

    // Keyboard-triggered switch focuses the model's tiered fallback
    // (newest-first MRU, then reversed tiled_order, then floating) — NO
    // pointer query: a synchronous round trip stalls the single-threaded
    // event loop, and a fast-following keypress waits behind that stall
    // ("quick workspace switches sometimes don't register"). A keyboard
    // switch has no pointer gesture to honor, so focus is decided purely
    // from the model.
    const ft: focus.FocusTransition = focus.focusFallback(m, .workspace_switch);

    const t2: u64 = if (build_options.profile_key) core.monotonicNs() else 0;

    // Reconcile + focus under one server grab. Geometry-before-focus
    // (FocusOrder.after): the arriving window may have been spawned
    // off-current and never mapped (the spawn path registers but defers the
    // map to the first reconcile). Firing xcb_set_input_focus on an unmapped
    // window is a BadMatch that leaves X focus on the old workspace's
    // window; `.after` maps the arriving window before applyPendingFocus
    // targets it, in the same flush.
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

/// This module's window contribution: pure model transitions + the workspace
/// commands; lifecycle is the query facade's init and model state lives in
/// the model.
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
