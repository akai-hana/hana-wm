//! The action hub: the shared transition tails every
//! action group reconciles through (retile,
//! retileWithFallback, focusFallback,
//! prepareAndSetFocus), the registry seams, and the
//! re-export surface. The five action groups
//! (parked/geometry/layout_params/ws/manage) live in
//! their own files; `actions.*` stays the single
//! import surface for keybind/events, so those
//! importers are untouched by the split. Each group
//! file imports this hub for the shared tails: the
//! files form the window layer's intentional
//! runtime-only import cycle (the same hub-and-spoke
//! shape check-layers.sh documents for core<->window).

const core = @import("core");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const window = @import("window");

const parked = @import("parked");
const layout_params = @import("layout_params");
const ws = @import("ws");
const manage = @import("manage");
const geometry = @import("geometry");

pub const providerOf = window.providerOf;

pub const callHook = window.callHook;
pub const callHookBool = window.callHookBool;
pub const dispatchAll = window.dispatchAll;
pub const dispatchFirstTrue = window.dispatchFirstTrue;
pub const isCoveringMode = window.isCoveringMode;

/// Convenience: returns the current workspace's covering occupant via the
/// module AND hook (active covering record on ws), null without a fullscreen
/// module. Contrast the OR scan `model.coveringOccupantOnWs`.
pub fn currentCoveringOccupant(m: *const model_mod.Model) ?model_mod.WindowId {
    return if (providerOf(.visibleCoveringOnWs)) |prov|
        prov.visibleCoveringOnWs.?(m, m.current)
    else
        null;
}

/// Convenience: true when `win` is the covering (fullscreen) occupant on its
/// workspace.
pub fn isCoveringOnWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    return model_mod.isCoveringOn(m, win, m.current); // Model query
}

// Re-exports: the five action groups live in their own files
// (parked/geometry/layout_params/ws/manage); `actions.*` stays the
// single import surface for keybind/events, so those importers
// are untouched by the split.
pub const minimize = parked.minimize;
pub const restore = parked.restore;
pub const restoreOrdered = parked.restoreOrdered;
pub const restoreAll = parked.restoreAll;
pub const cycleLayoutKind = layout_params.cycleLayoutKind;
pub const stepVariantDir = layout_params.stepVariantDir;
pub const adjustPrimaryWidthAction = layout_params.adjustPrimaryWidthAction;
pub const adjustPrimaryCount = layout_params.adjustPrimaryCount;
pub const adjustSecondaryBalance = layout_params.adjustSecondaryBalance;
pub const swapPrimaryAction = layout_params.swapPrimaryAction;
pub const seedParamsFromConfig = layout_params.seedParamsFromConfig;
pub const applyConfigReload = layout_params.applyConfigReload;
pub const moveWindowTo = ws.moveWindowTo;
pub const tagToggle = ws.tagToggle;
pub const pinToggle = ws.pinToggle;
pub const allViewToggle = ws.allViewToggle;
pub const switchTo = ws.switchTo;
pub const fullscreenToggleWindow = manage.fullscreenToggleWindow;
pub const fullscreenSetWindow = manage.fullscreenSetWindow;
pub const mapRequest = manage.mapRequest;
pub const focusAfterGeometry = manage.focusAfterGeometry;
pub const unmanage = manage.unmanage;
pub const toggleFloating = geometry.toggleFloating;
pub const dragRect = geometry.dragRect;
pub const detachToFloating = geometry.detachToFloating;
pub const startDrag = geometry.startDrag;
pub const stopDrag = geometry.stopDrag;
pub const updateDrag = geometry.updateDrag;
pub const isDragging = geometry.isDragging;
pub const isResizingWindow = geometry.isResizingWindow;
pub const getDragLastRect = geometry.getDragLastRect;
pub const cancelDragForWindow = geometry.cancelDragForWindow;
pub const moveFocused = geometry.moveFocused;
pub const viewportStep = geometry.viewportStep;
pub const snapViewportFocusedDuty = geometry.snapViewportFocusedDuty;

/// The four reconcile shapes a tiling action can ask for, as ONE axis.
///
/// This was a four-bool bag (`restack` / `full_redraw` / `with_focus` /
/// `bump_fullscreen`) resolved by a three-way if-chain, which let a caller name
/// a combination that meant nothing -- `with_focus` with no focus transition to
/// apply, or `restack` silently ignored on the plain path -- and made the
/// dispatch unreadable without re-deriving the truth table. All four reachable
/// combinations are enumerated here instead, so the compiler rejects the
/// impossible ones and a reader sees the dispatch without reading the chain.
const RetileMode = enum {
    /// reconcileGrab: no focus, no restack.
    plain,
    /// reconcileGrab with force_restack: restack a window that is not taking focus.
    restack,
    /// reconcileGrabFocus: move focus, geometry only.
    focus,
    /// reconcileGrabFocus with force_restack: focus and restack together.
    focus_restack,
};

/// The two flags genuinely orthogonal to the reconcile shape: which geometry
/// fact to bump, and whether the fullscreen fact changes here.
const RetileOpts = struct {
    mode: RetileMode = .plain,
    full_redraw: bool = false,
    bump_fullscreen: bool = false,
};

/// The one fact-bump + reconcile entry for a tiling action.
///
/// Each mode names which facts IT bumps. The plain and restack modes
/// deliberately do NOT bump the window fact here: both reconcile through
/// `pipeline.reconcileGrab`, which owns that bump, so the actions
/// that route through them get the invariant without having to remember
/// it, and this one cannot double-bump on the way there. The focus variants
/// reconcile through `pipeline.reconcileGrabFocus`, which does not bump, so
/// those still bump the window fact here. That is the whole asymmetry, and
/// it is the one line of the function that looks surprising on purpose.
///
/// A fact bump is a counter increment with no X traffic, so doing it before
/// the reconcile is wire-identical to doing it after; actions with a pinned
/// side-effect ORDER keep their own tails instead of routing through here.
pub fn retile(opts: RetileOpts, ft: ?focus.FocusTransition) void {
    // `full_redraw` selects WHICH geometry fact to bump; without it only the
    // focus modes still bump the window fact themselves (their reconcile
    // entry does not), and plain/restack leave it entirely to reconcileGrab.
    if (opts.full_redraw) core.layout.bump() else if (opts.mode == .focus or opts.mode == .focus_restack) core.window.bump();
    if (opts.bump_fullscreen) core.fullscreen.bump();

    switch (opts.mode) {
        .plain => pipeline.reconcileGrab(.{}),
        .restack => pipeline.reconcileGrab(.{ .force_restack = true }),
        // Focus lands before geometry (focus-before). A null transition for a
        // focus mode used to @panic via ft.?; treat it as the no-op transition
        // instead, so a caller that forgets the FocusTransition degrades to a
        // plain focus-mode retile rather than a crash.
        .focus => pipeline.reconcileGrabFocus(.{}, ft orelse .none, .before, null),
        .focus_restack => pipeline.reconcileGrabFocus(.{ .force_restack = true }, ft orelse .none, .before, null),
    }
}

/// Shared hide/close withdraw tail: when the withdrawn window was the
/// current workspace's covering occupant, bump the core fact so the bar (a
/// consumer) re-derives its screen claim before the reconcile reads the work
/// area; then hand focus to the fallback winner (or clear) and reconcile
/// focus + geometry under one grab.
pub fn retileWithFallback(m: *model_mod.Model, fs_current: bool, was_focused: bool) void {
    const ft: focus.FocusTransition = if (was_focused) focusFallback(m, .tiling_operation) else .none;
    retile(.{ .mode = .focus_restack, .bump_fullscreen = fs_current }, ft);
}

/// Fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
/// Returns a FocusTransition for the caller to commit inside its server grab.
/// Model and protocol focus are updated together: the model update runs
/// before the grab, the protocol commit runs inside it. `reason` is the
/// prepareFocus reason handed to the winner (the fallback's own
/// `.tiling_operation`, or `.workspace_switch` on a workspace switch).
pub fn focusFallback(m: *model_mod.Model, reason: focus.Reason) focus.FocusTransition {
    // Tier policy lives in the model layer so tests can exercise it without
    // linking the protocol side (see model.fallbackFocusCandidate). A
    // no_input candidate can never hold X focus, so it is excluded and the
    // scan continues to the next focusable window; only when nothing
    // focusable remains is model focus cleared and X focus handed to root.
    var excluded: ?model_mod.WindowId = null;
    while (model_mod.fallbackFocusCandidate(m, m.current, excluded)) |winner| {
        const prep = prepareAndSetFocus(m, winner, reason);
        if (prep == .no_input) {
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
pub fn prepareAndSetFocus(m: *model_mod.Model, win: model_mod.WindowId, reason: focus.Reason) focus.FocusTransition {
    const prep = focus.prepareFocus(win, reason);
    // `yieldsModelFocus`, not `!= .none`: `.no_input` is a refusal, not a
    // dedup, so the old test let a no_input window take model focus and
    // contradicted the rule written directly above this function.
    if (focus.yieldsModelFocus(prep)) model_mod.setFocus(m, win);
    return prep;
}

// restore (unpark)

pub fn isMinimizedOnAnyWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    return callHookBool(.isWindowHidden, .{ m, win });
}
