//! Bar visibility policy tests (F-03). The policy half of the bar subsystem
//! (`bar/visibility.zig`) issues no X11 requests, so its decisions run over
//! the core model, not the wire. The pure-predicate and absent-module checks
//! are fully headless; the live fullscreen-occupancy branch needs a live
//! model (pipeline's sink is boot-wired with a real core connection), so it
//! runs over the shared window fixture and self-skips when no X display is
//! reachable.

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
        try testing.expect(!visibility.barForcedHiddenByFullscreen(0));

        const shown = visibility.desiredVisibility(0, true, true);
        try testing.expect(shown.should_be_visible);
        try testing.expect(!shown.needs_change);

        const hidden_by_user = visibility.desiredVisibility(0, true, false);
        try testing.expect(!hidden_by_user.should_be_visible);
        try testing.expect(hidden_by_user.needs_change);

        const already_hidden = visibility.desiredVisibility(0, false, false);
        try testing.expect(!already_hidden.should_be_visible);
        try testing.expect(!already_hidden.needs_change);

        try testing.expect(visibility.keepPromptOverride(0, true));
        try testing.expect(!visibility.keepPromptOverride(0, false));
        return;
    }

    // Live branch: boot the real core/pipeline/model wiring on the shared
    // display (SKIP headless like the other fixture tests).
    const fixture = @import("fixture");
    const pipeline = @import("pipeline");
    const model = @import("model");
    const fx = fixture.setUp("F03 fullscreen occupancy") orelse return;
    defer fx.deinit();

    var gate: pipeline.Gate = .{};
    const m = pipeline.mut(&gate);

    // Empty model: no covering occupant, bar stays up.
    try testing.expect(!visibility.barForcedHiddenByFullscreen(0));

    // A covering occupant on ws 0 claims the screen: the coercion fires.
    model.register(m, 1, model.WSId.fromIndex(0)) catch unreachable;
    const ent = m.store.getPtr(1).?;
    ent.presence = .covering;
    ent.covering_ws = model.WSId.fromIndex(0);
    try testing.expect(visibility.barForcedHiddenByFullscreen(0));

    // Decision layer folds the coercion in: marked hidden, needs change.
    const shown = visibility.desiredVisibility(0, true, true);
    try testing.expect(!shown.should_be_visible);
    try testing.expect(shown.needs_change);

    // The prompt override is not kept while the screen is claimed.
    try testing.expect(!visibility.keepPromptOverride(0, true));

    // Releasing the claim restores the natural show decision.
    const rel = m.store.getPtr(1).?;
    rel.covering_ws = null;
    rel.presence = .present;
    try testing.expect(!visibility.barForcedHiddenByFullscreen(0));
    const hidden_by_user = visibility.desiredVisibility(0, true, false);
    try testing.expect(!hidden_by_user.should_be_visible);
    try testing.expect(hidden_by_user.needs_change);

    const already_hidden = visibility.desiredVisibility(0, false, false);
    try testing.expect(!already_hidden.should_be_visible);
    try testing.expect(!already_hidden.needs_change);
}
