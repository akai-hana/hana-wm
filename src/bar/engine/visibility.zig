//! Bar visibility policy: show/hide decisions as pure functions over the
//! core model. No X11 requests, no imports of pipeline/state/render. The
//! wire half (apply*, present/dismiss, reconcile) lives in `bar.zig`; host
//! state in `state.zig`.

const build_options = @import("build_options");
const model = @import("model");

/// True when a fullscreen window on `ws` forces the bar hidden. Folded away
/// at compile time when the fullscreen module is absent. The model is passed
/// in, never reached through pipeline, so a decision can't be computed
/// against a model other than the one its caller will act on.
pub fn barForcedHiddenByFullscreen(m: *const model.Model, ws: u8) bool {
    return if (build_options.has_fullscreen)
        model.coveringOccupantOn(m, model.WSId.fromIndex(ws), .anchored_or_visible) != null
    else
        false;
}

/// The bar is shown only when the user wants it visible AND no fullscreen
/// window claims the screen.
pub fn shouldBeVisible(is_globally_visible: bool, forced_hidden_by_fullscreen: bool) bool {
    return !forced_hidden_by_fullscreen and is_globally_visible;
}

/// Why the bar wants the visibility it wants.
pub const Reason = enum {
    /// User toggle and current workspace both want it shown.
    user_and_workspace,
    /// The user turned the bar off.
    user_hidden,
    /// A fullscreen window claims the whole screen.
    fullscreen_claims_screen,
};

const DesiredVisibility = struct {
    should_be_visible: bool,
    reason: Reason,
};

/// Target visibility + reason, shared by the workspace-switch path and the
/// fullscreen-fact reaction. POLICY states the target; comparing it against
/// the bar's currently mapped state belongs to the orchestrator (that
/// comparison reads live window state and decides whether wire happens).
///
/// `is_visible` is deliberately NOT a parameter: keeping the mapped state at
/// the one place that can see it stops the policy from early-returning on a
/// field its caller must still compare.
pub fn desiredVisibility(m: *const model.Model, ws: u8, is_globally_visible: bool) DesiredVisibility {
    // Skip the model walk when the user toggle already hides the bar:
    // `user_hidden` wins by definition, so a fullscreen reason would never
    // be consumed.
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

/// For `dismissAfterPrompt`: keep the forced-show override only if the bar
/// IS shown at freshly recomputed visibility. The prompt can outlive the
/// state that justified the override (fullscreen window closes on its own),
/// so this recomputes at prompt-exit time rather than trusting the decision
/// made at activation.
pub fn keepPromptOverride(m: *const model.Model, ws: u8, is_globally_visible: bool) bool {
    return desiredVisibility(m, ws, is_globally_visible).should_be_visible;
}
