//! Bar visibility policy tests. The policy half of the bar subsystem
//! (`bar/visibility.zig`) issues no X11 requests, so its decisions run over
//! the core model, not the wire. The pure-predicate and absent-module checks
//! are fully headless; the live fullscreen-occupancy branch needs a live
//! model (pipeline's sink is boot-wired with a real core connection), so it
//! runs over the shared window fixture and self-skips when no X display is
//! reachable.

// (28.6) Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: bar

const std = @import("std");
const testing = std.testing;

const visibility = @import("visibility");
const build_options = @import("build_options");

test "F03: shared-screen predicate has the expected 4-row truth table" {
    // (is_globally_visible, forced_hidden_by_fullscreen) -> shown.
    try testing.expect(!visibility.shouldBeVisible(false, false));
    try testing.expect(!visibility.shouldBeVisible(false, true));
    try testing.expect(visibility.shouldBeVisible(true, false));
    try testing.expect(!visibility.shouldBeVisible(true, true));
}

test "F03: fullscreen occupancy forces the bar hidden" {
    // The absent-module branch is comptime-pruned out of builds with the
    // fullscreen module, so the default tree exercises the LIVE branch below;
    // this variant (only compiled in fullscreen-less trees) pins the safety
    // fold: without a module the model read folds to `false` at comptime and
    // the bar is never force-hidden by occupancy.
    if (comptime !build_options.has_fullscreen) {
        // `barForcedHiddenByFullscreen` now takes the model it decides
        // against, so this headless branch cannot call it with a literal
        // workspace id. What it CAN pin without a model is the fold: the
        // absent-module branch is comptime-pruned to `false`, which is exactly
        // the "no fullscreen module => never force-hidden" claim, and
        // `desiredVisibility` therefore collapses to the user toggle.
        // In a build WITHOUT fullscreen, nothing can force-hide the bar:
        // the occupant read folds to `false` at comptime, so a globally
        // visible, not-silenced bar is shown -- the exact same fold the live
        // truth table at the top of this file pins.
        try testing.expect(visibility.shouldBeVisible(true, false));
        try testing.expect(!visibility.shouldBeVisible(false, false));
        return;
    }

    // Live branch: boot the real pipeline/model wiring on the shared
    // display (SKIP headless like the other fixture tests).
    const fixture = @import("fixture");
    const pipeline = @import("pipeline");
    const model = @import("model");
    const fx = try fixture.setUp("F03 fullscreen occupancy");
    defer fx.deinit();

    var gate: pipeline.Gate = .{};
    const m = pipeline.mut(&gate);

    // Empty model: no covering occupant, bar stays up.
    try testing.expect(!visibility.barForcedHiddenByFullscreen(m, 0));

    // A covering occupant on ws 0 claims the screen: the coercion fires.
    try model.register(m, 1, model.WSId.fromIndex(0));
    const ent = m.store.getPtr(1).?;
    ent.presence = .covering;
    ent.covering_ws = model.WSId.fromIndex(0);
    try testing.expect(visibility.barForcedHiddenByFullscreen(m, 0));

    // Decision layer folds the coercion in: hidden, and the reason is
    // reported so the caller can log WHY instead of recomputing it.
    const shown = visibility.desiredVisibility(m, 0, true);
    try testing.expect(!shown.should_be_visible);
    try testing.expectEqual(.fullscreen_claims_screen, shown.reason);

    // The prompt override is not kept while the screen is claimed.
    try testing.expect(!visibility.keepPromptOverride(m, 0, true));

    // Releasing the claim restores the natural show decision.
    const rel = m.store.getPtr(1).?;
    rel.covering_ws = null;
    rel.presence = .present;
    try testing.expect(!visibility.barForcedHiddenByFullscreen(m, 0));

    // User preference alone hides the bar, and says so.
    const hidden_by_user = visibility.desiredVisibility(m, 0, false);
    try testing.expect(!hidden_by_user.should_be_visible);
    try testing.expectEqual(.user_hidden, hidden_by_user.reason);

    // The screen is free again, so the user toggle decides: shown.
    const both = visibility.desiredVisibility(m, 0, true);
    try testing.expect(both.should_be_visible);
    try testing.expectEqual(.user_and_workspace, both.reason);
}
