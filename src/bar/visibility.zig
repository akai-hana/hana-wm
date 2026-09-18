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
//! bar.zig, so every wire token stays in the orchestrator.

const build_options = @import("build_options");
const model = @import("model");
const pipeline = @import("pipeline");

/// True when a fullscreen window on `ws` forces the bar hidden (shared-screen
/// reaction). Compile-time folded when the fullscreen module is absent: the
/// model read is comptime-unreachable, matching the inlined guards that used
/// to live at each decision site.
pub fn barForcedHiddenByFullscreen(ws: u8) bool {
    return if (build_options.has_fullscreen)
        model.coveringOccupantOnWs(pipeline.model(), model.WSId.fromIndex(ws)) != null
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
pub const DesiredVisibility = struct {
    should_be_visible: bool,
    needs_change: bool,
};

pub fn desiredVisibility(ws: u8, is_visible: bool, is_globally_visible: bool) DesiredVisibility {
    const should_be_visible = shouldBeVisible(
        is_globally_visible,
        barForcedHiddenByFullscreen(ws),
    );
    return .{
        .should_be_visible = should_be_visible,
        .needs_change = should_be_visible != is_visible,
    };
}

/// Decision for `dismissAfterPrompt`: whether the prompt's forced-show
/// override should be kept because the bar IS shown at its natural, freshly
/// recomputed visibility. The prompt can outlive the state that justified the
/// override (e.g. the fullscreen window closes on its own), so this is
/// recomputed from the CURRENT workspace at prompt-exit time rather than
/// trusting the decision made at activation.
pub fn keepPromptOverride(ws: u8, is_globally_visible: bool) bool {
    return shouldBeVisible(is_globally_visible, barForcedHiddenByFullscreen(ws));
}
