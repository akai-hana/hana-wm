// Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: tiling

// Timing/instrumentation for the focus-change hot path.
//
// Question: when focus moves from window A to window B (Mod+k/Mod+j cycling,
// hover, click), how much work does the synchronous model path do, and is any
// of it redundant?
//
// Every focus change commits a server-grab reconcile (focus.applyPendingFocus +
// reconcile.run). reconcile recomputes the DESIRED state for every window each
// pass, then sends ONLY the deltas (map + borderPixel + borderWidth + geom
// changed bits) the sync ledger recorded as last-sent -- which is what this
// instrumentation quantifies as a function of window count. A reconcile that
// re-sent the full desired state every pass (the invariant reconcile_test
// pins against) was the cost center an earlier fix had to remove.
//
// The Mod+k caller shape (`focus.cycleTarget` then
// `focus.grabFocusWithDuty`) now runs the viewport snap as a duty INSIDE the
// focus transition's grab, so a cycle that scrolls the viewport is a single
// grab+reconcile instead of the old focus-then-snap two.

const std = @import("std");
const model = @import("model");
const helpers = @import("helpers");
const test_sink = @import("test_sink");
const build_options = @import("build_options");

const time = @import("time");
const ledger = @import("ledger");
const reconcile = @import("reconcile");
// Latency instrumentation only runs its full loops + timing output under
// `-Dbench`; the default suite keeps a silent smoke so `zig build
// test` never writes to stderr (the runner flags test stderr as `failed
// command:` even on success).
const bench = build_options.bench;

const nowNs = time.monotonicNs;

const makeModel = helpers.makeBareModel; // Bench: no module-store churn between iterations

const regCur = helpers.regCur;

const CountingSink = test_sink.TestSink(.category);

const colorOfFocused = helpers.colorOfFocused;

const makeCtx = helpers.makeCtx;

// Reconcile cost scaling with window count + the number of wire requests a
// single focus change issues (reconcile replays every window unconditionally).
test "latency: reconcile cost + request count at focus change" {
    inline for (.{ 1, 2, 4, 16, 50 }) |n| {
        var m = makeModel();
        for (0..n) |i| regCur(&m, @intCast(i + 1));

        ledger.init();
        defer ledger.init();

        // Warm once (a live counter seeds the ledger), then measure the CPU
        // cost of one reconcile.
        const per_pass_ns = helpers.benchReconcile(&m, if (bench) 5_000 else 1);

        // Count requests in one representative reconcile (fresh sink).
        var probe = CountingSink{};
        var probe_ctx = makeCtx(probe.sink(), colorOfFocused, helpers.std_wa);
        reconcile.run(&m, &probe_ctx, .{});

        // Steady state after the warm pass must send NOTHING: the warm
        // reconcile seeded last-sent for every window, nothing in the model
        // changed since, and reconcile never flushes or grabs itself
        // ("DO NOT FLUSH HERE. Caller owns flushing"). This is the
        // delta-elision invariant asserted at every scale -- a full-state
        // re-send (the cost center before the fix) fails here at each n.
        try std.testing.expectEqual(@as(usize, 0), probe.total);

        if (bench)
            helpers.benchLog(
                "[latency] reconcile n={d}: {d:.1} ns/pass, requests/pass={d}\n",
                .{ n, per_pass_ns, probe.total },
            );
    }
}

// Mod+k caller: `focus.grabFocusWithDuty` commits the focus protocol and the
// viewport snap in ONE grab+reconcile (the snap runs as a duty between
// applyPendingFocus and reconcile.run). Previously the cycle did a focus
// transition (first reconcile) then snapViewportToFocused (a second
// grab+reconcile whenever the viewport had to shift), plus a redundant second
// reconcile even when the focused window was already on-screen.
//
// This test quantifies the single-reconcile cost the folded path now pays, so
// the per-Mod+k compute is explicit and any regression to two reconciles shows up.
test "latency: Mod+k folded focus + viewport-snap reconcile" {
    const n = 16;
    var m = makeModel();
    for (0..n) |i| regCur(&m, @intCast(i + 1));

    ledger.init();
    defer ledger.init();

    var warm = CountingSink{};
    var warm_ctx = makeCtx(warm.sink(), colorOfFocused, helpers.std_wa);
    reconcile.run(&m, &warm_ctx, .{});

    const iters: usize = if (bench) 5_000 else 1;

    // Phase 1: the focus transition reconcile.
    var s1 = CountingSink{};
    var c1 = makeCtx(s1.sink(), colorOfFocused, helpers.std_wa);
    model.setFocus(&m, 2);
    const t0 = nowNs();
    for (0..iters) |_| {
        model.setFocus(&m, 2);
        reconcile.run(&m, &c1, .{});
    }
    const focus_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iters));

    // The focus transition's ONLY wire delta is border color: focus was null
    // before setFocus(2), so exactly window 2's pixel flips 0->1. Geometry
    // comes from layout (untouched), stacking only applies to floating
    // windows (none here), and every window was already mapped by warm.
    try std.testing.expectEqual(@as(usize, 1), s1.total);
    try std.testing.expectEqual(@as(usize, 1), s1.pixel);

    // Phase 2: a second reconcile, kept as the cost reference the folded
    // path would pay IF it regressed to two grabs per Mod+k. The folded path
    // never runs this: it reconciles once, with the snap already applied.
    var s2 = CountingSink{};
    var c2 = makeCtx(s2.sink(), colorOfFocused, helpers.std_wa);
    const t1 = nowNs();
    for (0..iters) |_| reconcile.run(&m, &c2, .{});
    const snap_ns = @as(f64, @floatFromInt(nowNs() - t1)) / @as(f64, @floatFromInt(iters));

    // The reference second reconcile must be a pure no-op. It is what the
    // folded Mod+k would pay if it regressed to two grabs, and the folded
    // path's premise is that the state is already steady after phase 1 --
    // if this ever sends anything, steady state is broken.
    try std.testing.expectEqual(@as(usize, 0), s2.total);

    if (bench)
        helpers.benchLog(
            "[latency] Mod+k n={d}: single folded reconcile={d:.1} ns (a second grab+reconcile would add {d:.1}%)\n",
            .{ n, focus_ns, @as(f64, 100.0) * snap_ns / focus_ns },
        );
}
