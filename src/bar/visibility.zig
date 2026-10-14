//! Bar visibility policy: every decision about when the bar is shown/
//! hidden (fullscreen-occupancy reactions, workspace-scoped recomputation,
//! prompt forced-show/undo, the shared-screen predicate) as pure
//! computations over the core model. The model is a parameter, so every
//! decision is a pure function of what the caller handed in; this file
//! issues NO X11 requests, imports no pipeline, and holds no state.
//!
//! The wire half -- the apply* family plus the prompt's present/dismiss
//! pair that turn those decisions into X11 map/unmap + screen-claim writes
//! and the reconcile that reacts to a claim change -- lives in `bar.zig`
//! with the rest of the bar's X traffic (see the check-layers.sh Rule-1
//! allowlist entry).
//!
//! (History: formerly split into `visibility.zig` + `visibility_glue.zig`,
//! merged back 2026-10-09 as one "bar visibility" unit, then split again
//! in Phase 3 of the bar refactor when the glue moved home to `bar.zig`.
//! The host state (`State`, `gBar`) lives in `state.zig` and the draw
//! submission in `render.zig`; neither is imported by this file.)

const build_options = @import("build_options");
const model = @import("wm_state");

// ---------------------------------------------------------------------------
// Policy (pure): decisions over the model, no wire.
// ---------------------------------------------------------------------------

/// True when a fullscreen window on `ws` forces the bar hidden (shared-screen
/// reaction). Compile-time folded when the fullscreen module is absent: the
/// model read is comptime-unreachable, matching the inlined guards that used
/// to live at each decision site.
/// `m` is the model the decision is made AGAINST, passed in rather than
/// reached for through pipeline. visibility.zig no longer imports the pipeline
/// at all, so a decision can no longer be computed against a model that is not
/// the one its caller is about to act on -- the two used to be reached
/// independently, and the bar's own comment noted the dependency was the only
/// thing keeping the partition honest.
pub fn barForcedHiddenByFullscreen(m: *const model.Model, ws: u8) bool {
    return if (build_options.has_fullscreen)
        model.coveringOccupantOnWs(m, model.WSId.fromIndex(ws)) != null
    else
        false;
}

/// The core shared-screen predicate: the bar is shown only when the user
/// wants it visible AND no fullscreen window on the workspace claims the
/// screen (fullscreen coverage and the user toggle both keep it hidden).
pub fn shouldBeVisible(is_globally_visible: bool, forced_hidden_by_fullscreen: bool) bool {
    return !forced_hidden_by_fullscreen and is_globally_visible;
}

/// Why the bar wants the visibility it wants.
pub const Reason = enum {
    /// The user toggle and the current workspace both want the bar shown.
    user_and_workspace,
    /// The user turned the bar off.
    user_hidden,
    /// A fullscreen window on this workspace claims the whole screen.
    fullscreen_claims_screen,
};

const DesiredVisibility = struct {
    should_be_visible: bool,
    reason: Reason,
};

/// The pre-computed show/hide decision shared by the workspace-switch path
/// (`updateBarVisibilityForWorkspace`) and the fullscreen-fact reaction
/// (`applyFullscreenVisibility`): recompute the desired visibility from the
/// workspace + user level. The POLICY states the target and why; COMPARING
/// that target against the bar's currently mapped state belongs to the
/// orchestrator, because that comparison reads live window state and is
/// the thing that decides whether any wire request happens.
///
/// `is_visible` (the bar's mapped state) is deliberately NOT a parameter.
/// `desiredVisibility` used to take it and return `needs_change`, making one
/// function both the policy and the comparator, so the bar then early-returned
/// on a field the policy had already folded in. Asking the policy for the
/// target and reason, and letting the caller compare, is one step instead of
/// two and keeps the mapped state at the one place that can see it.
pub fn desiredVisibility(m: *const model.Model, ws: u8, is_globally_visible: bool) DesiredVisibility {
    // Short-circuit the model walk when the user toggle already hides the bar:
    // `shouldBeVisible` ignores `forced_hidden` on that row of its truth table,
    // so reading the fullscreen occupant there could only produce a reason the
    // caller never asks for (user_hidden wins by definition).
    const forced_hidden = is_globally_visible and barForcedHiddenByFullscreen(m, ws);
    return .{
        .should_be_visible = shouldBeVisible(is_globally_visible, forced_hidden),
        .reason = if (!is_globally_visible)
            Reason.user_hidden
        else if (forced_hidden)
            Reason.fullscreen_claims_screen
        else
            Reason.user_and_workspace,
    };
}

/// Decision for `dismissAfterPrompt`: whether the prompt's forced-show
/// override should be kept because the bar IS shown at its natural, freshly
/// recomputed visibility. The prompt can outlive the state that justified the
/// override (e.g. the fullscreen window closes on its own), so this is
/// recomputed from the CURRENT workspace at prompt-exit time rather than
/// trusting the decision made at activation. One decision function, not a
/// second hand-rolled fold of the same two inputs.
pub fn keepPromptOverride(m: *const model.Model, ws: u8, is_globally_visible: bool) bool {
    return desiredVisibility(m, ws, is_globally_visible).should_be_visible;
}
