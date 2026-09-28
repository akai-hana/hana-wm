//! Bar visibility decisions
//!
//! The bar visibility subsystem's POLICY half: every decision about when the
//! bar is shown/hidden -- fullscreen-occupancy reactions, workspace-scoped
//! recomputation, prompt forced-show/undo, and the shared-screen predicate
//! behind them -- lives here as pure computations over the core model.
//!
//! This partition issues NO X11 requests. The eponymous `bar.zig` imports it
//! one-way (bar -> visibility), applies a decision, and performs the
//! map/unmap + screen-claim + reconcile glue; visibility.zig never imports
//! bar.zig, so every wire token stays in the orchestrator. It also does not
//! import the pipeline: the model is a parameter, so every decision is a pure
//! function of what the caller handed in.

const build_options = @import("build_options");
const model = @import("model");

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

/// The pre-computed show/hide decision shared by the workspace-switch path
/// (`updateBarVisibilityForWorkspace`) and the fullscreen-fact reaction
/// (`applyFullscreenVisibility`): recompute the desired visibility from the
/// workspace + user level, folded with the bar's present mapped state so the
/// caller can return without touching the wire when nothing changes.
/// Why the bar wants the visibility it wants. The POLICY states the target and
/// why; COMPARING that target against the bar's currently mapped state belongs
/// to the orchestrator, because that comparison reads live window state and is
/// the thing that decides whether any wire request happens.
pub const Reason = enum {
    /// The user toggle and the current workspace both want the bar shown.
    user_and_workspace,
    /// The user turned the bar off.
    user_hidden,
    /// A fullscreen window on this workspace claims the whole screen.
    fullscreen_claims_screen,
};

pub const DesiredVisibility = struct {
    should_be_visible: bool,
    reason: Reason,
};

/// `is_visible` (the bar's mapped state) is deliberately NOT a parameter.
/// `desiredVisibility` used to take it and return `needs_change`, making one
/// function both the policy and the comparator, so the bar then early-returned
/// on a field the policy had already folded in. Asking the policy for the
/// target and reason, and letting the caller compare, is one step instead of
/// two and keeps the mapped state at the one place that can see it.
pub fn desiredVisibility(m: *const model.Model, ws: u8, is_globally_visible: bool) DesiredVisibility {
    if (is_globally_visible) {
        if (barForcedHiddenByFullscreen(m, ws)) {
            return .{ .should_be_visible = false, .reason = .fullscreen_claims_screen };
        }
        return .{ .should_be_visible = true, .reason = .user_and_workspace };
    }
    return .{ .should_be_visible = false, .reason = .user_hidden };
}

/// Decision for `dismissAfterPrompt`: whether the prompt's forced-show
/// override should be kept because the bar IS shown at its natural, freshly
/// recomputed visibility. The prompt can outlive the state that justified the
/// override (e.g. the fullscreen window closes on its own), so this is
/// recomputed from the CURRENT workspace at prompt-exit time rather than
/// trusting the decision made at activation.
pub fn keepPromptOverride(m: *const model.Model, ws: u8, is_globally_visible: bool) bool {
    return shouldBeVisible(is_globally_visible, barForcedHiddenByFullscreen(m, ws));
}
