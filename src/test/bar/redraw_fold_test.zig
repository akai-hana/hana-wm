//! The consume-all redraw drain (`segmod.foldProbes`).
//!
//! P2-59: `foldModuleRedraw` now drains the registry INLINE (per-segment,
//! classifying each request width-stable vs width-changing), but it upholds
//! exactly the drain policy this primitive pins, and the primitive remains
//! the reference definition of that policy. The drain is the whole reason a
//! multi-module first-paint settle fits under `max_batched_redraws`: one fold
//! pass must consume EVERY pending module request, not just the first. The
//! short-circuiting `anyBoolHook` would return after the first true probe,
//! stranding each later pending request behind its own fold round -- five
//! boot segments against a four-round cap is the stall these tests exist to
//! prevent.

// Declared here, next to the import that makes it necessary, rather than in
// a build.zig table that had to be kept in agreement with them by hand.
// build-gate: bar

const std = @import("std");
const segmod = @import("segment");

/// Mutable cells standing in for module-level `consumeRedrawRequest` state
/// (Zig has no closures over locals, so probes read test-owned globals).
var pending0 = true;
var pending2 = true;

fn probe0() bool {
    const v = pending0;
    pending0 = false;
    return v;
}
fn probe2() bool {
    const v = pending2;
    pending2 = false;
    return v;
}
fn probeAlwaysPending() bool {
    return true;
}

const three = [_]?*const fn () bool{ probe0, null, probe2 };

test "one fold pass consumes every pending request, not just the first" {
    // A null in the middle and a LATER probe pending: the walk must not
    // stop before reaching the end of the list.
    pending0 = true;
    pending2 = true;
    try std.testing.expect(segmod.foldProbes(three[0..]));

    // Every pending probe was consumed by its own call in that single pass.
    // A second fold with nothing re-pended must be a no-op -- this is the
    // consume-once half, and it is what keeps a settled bar from folding
    // forever.
    try std.testing.expect(!segmod.foldProbes(three[0..]));
    try std.testing.expect(!pending0);
    try std.testing.expect(!pending2);
}

test "a fold with nothing pending reports false" {
    pending0 = false;
    pending2 = false;
    try std.testing.expect(!segmod.foldProbes(three[0..]));
}

test "a null entry is skipped, and later probes still fold" {
    // Every segment may omit the hook; the walk must step over the nulls
    // without losing a request queued behind one.
    pending0 = false;
    pending2 = true;
    try std.testing.expect(segmod.foldProbes(three[0..]));
    try std.testing.expect(!pending2);
}

test "a permanently re-requesting probe cannot silence later pending work" {
    // The runaway-module shape: probe0 answers true forever (never actually
    // consumes). A short-circuit fold would answer true and strand probe2;
    // the consume-all fold still runs probe2 and consumes it.
    pending2 = true;
    const runaway = [_]?*const fn () bool{ probeAlwaysPending, null, probe2 };
    try std.testing.expect(segmod.foldProbes(runaway[0..]));
    try std.testing.expect(!pending2);
    // The runaway itself stays pending -- the fold reports work existed; the
    // iteration cap in updateIfDirty (not silence) is what bounds it.
    try std.testing.expect(segmod.foldProbes(runaway[0..]));
}
