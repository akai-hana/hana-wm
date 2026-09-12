//! Bar visibility policy tests (F-03). The policy half of the bar subsystem
//! (`bar/visibility.zig`) issues no X11 requests, so its pure decisions run
//! headless. The fullscreen-fact branch reads the core model (only live after
//! `pipeline.init`/real X), so that half is covered by the X-gated paths;
//! this suite pins the no-fullscreen fold instead -- the exact property that
//! must hold so an absent fullscreen module can never leave the bar stuck
//! hidden.

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

test "F03: without a fullscreen module every decision folds coercion off" {
    // In a tree without the fullscreen module the model read folds to
    // `false` at comptime: the bar is never force-hidden by occupancy. This
    // is the safety property the test pins -- no display needed, because the
    // model access is pruned, not merely skipped.
    if (build_options.has_fullscreen) return error.SkipZigTest;

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
}
