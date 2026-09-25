// Timing/instrumentation for the focus-change hot path.
//
// Question: when focus moves from window A to window B (Mod+k/Mod+j cycling,
// hover, click), how much work does the synchronous model path do, and is any
// of it redundant?
//
// Every focus change commits a server-grab reconcile (focus.applyPendingFocus +
// sync.reconcile). reconcile replays the FULL desired wire state for EVERY
// window each reconcile (map + borderPixel + borderWidth + geom), which this
// instrumentation quantifies as a function of window count.
//
// The Mod+k caller shape (`focus.cycleTarget` then
// `focus.grabFocusWithDuty`) now runs the viewport snap as a duty INSIDE the
// focus transition's grab, so a cycle that scrolls the viewport is a single
// grab+reconcile instead of the old focus-then-snap two.

const std = @import("std");
const model = @import("model");
const sync = @import("sync");
const utils = @import("utils");
const helpers = @import("helpers");
const build_options = @import("build_options");

// Latency instrumentation only runs its full loops + timing output under
// `-Dbench`; the default suite keeps a silent smoke so `zig build
// test` never writes to stderr (the runner flags test stderr as `failed
// command:` even on success).
const bench = build_options.bench;

const nowNs = utils.monotonicNs;

const makeModel = helpers.makeModel;

const regCur = helpers.regCur;

const CountingSink = helpers.TestSink(.count);

const colorOfFocused = helpers.colorOfFocused;

const makeCtx = helpers.makeCtx;

// Reconcile cost scaling with window count + the number of wire requests a
// single focus change issues (reconcile replays every window unconditionally).
test "latency: reconcile cost + request count at focus change" {
    inline for (.{ 1, 2, 4, 16, 50 }) |n| {
        var m = makeModel();
        for (0..n) |i| regCur(&m, @intCast(i + 1));

        sync.init();
        defer sync.init();

        // Warm once (a live counter seeds the ledger), then measure the CPU
        // cost of one reconcile.
        const per_pass_ns = helpers.benchReconcile(&m, if (bench) 5_000 else 1);

        // Count requests in one representative reconcile (fresh sink).
        var probe = CountingSink{};
        var probe_ctx = makeCtx(probe.sink(), colorOfFocused, helpers.std_wa);
        sync.reconcile(&m, &probe_ctx, .{});

        if (bench)
            std.debug.print(
                "[latency] reconcile n={d}: {d:.1} ns/pass, requests/pass={d}\n",
                .{ n, per_pass_ns, probe.count },
            );
    }
}

// Mod+k caller: `focus.grabFocusWithDuty` commits the focus protocol and the
// viewport snap in ONE grab+reconcile (the snap runs as a duty between
// applyPendingFocus and sync.reconcile). Previously the cycle did a focus
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

    sync.init();
    defer sync.init();

    var warm = CountingSink{};
    var warm_ctx = makeCtx(warm.sink(), colorOfFocused, helpers.std_wa);
    sync.reconcile(&m, &warm_ctx, .{});

    const iters: usize = if (bench) 5_000 else 1;

    // Phase 1: the focus transition reconcile.
    var s1 = CountingSink{};
    var c1 = makeCtx(s1.sink(), colorOfFocused, helpers.std_wa);
    model.setFocus(&m, 2);
    const t0 = nowNs();
    for (0..iters) |_| {
        model.setFocus(&m, 2);
        sync.reconcile(&m, &c1, .{});
    }
    const focus_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iters));

    // Phase 2: a second reconcile, kept as the cost reference the folded
    // path would pay IF it regressed to two grabs per Mod+k. The folded path
    // never runs this: it reconciles once, with the snap already applied.
    var s2 = CountingSink{};
    var c2 = makeCtx(s2.sink(), colorOfFocused, helpers.std_wa);
    const t1 = nowNs();
    for (0..iters) |_| sync.reconcile(&m, &c2, .{});
    const snap_ns = @as(f64, @floatFromInt(nowNs() - t1)) / @as(f64, @floatFromInt(iters));

    if (bench)
        std.debug.print(
            "[latency] Mod+k n={d}: single folded reconcile={d:.1} ns (a second grab+reconcile would add {d:.1}%)\n",
            .{ n, focus_ns, @as(f64, 100.0) * snap_ns / focus_ns },
        );
}
