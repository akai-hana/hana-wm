// Timing/instrumentation for the focus-change hot path.
//
// Question: when focus moves from window A to window B (Mod+k/Mod+j cycling,
// hover, click), how much work does the synchronous model path do, and is any
// of it redundant?
//
// Every focus change commits a server-grab reconcile (focus.applyPendingFocus +
// sync.reconcile). reconcile replays the FULL desired wire state for EVERY
// window each pass (map + borderPixel + borderWidth + geom), which this
// instrumentation quantifies as a function of window count.
//
// It also reproduces the Mod+k caller shape (`focusNext` then
// `snapViewportToFocused`), which today performs TWO back-to-back
// server-grab reconciles even when the focused window is already on-screen and
// the viewport offset is unchanged.

const std = @import("std");
const model = @import("model");
const sync = @import("sync");
const utils = @import("utils");
const helpers = @import("helpers");

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
        defer sync.deinit();

        // Warm once (a live counter seeds the ledger), then measure the CPU
        // cost of one reconcile pass.
        const per_pass_ns = helpers.benchReconcile(&m, 5_000);

        // Count requests in one representative pass (fresh sink).
        var probe = CountingSink{};
        var probe_ctx = makeCtx(probe.sink(), colorOfFocused);
        sync.reconcile(&m, &probe_ctx, .{});

        std.debug.print(
            "[latency] reconcile n={d}: {d:.1} ns/pass, requests/pass={d}\n",
            .{ n, per_pass_ns, probe.count },
        );
    }
}

// Mod+k caller: focusNext runs a focus-transition reconcile (borders + focus
// protocol), then snapViewportToFocused reconciles AGAIN when the viewport
// offset must shift. When the focused window is already fully on-screen the
// offset is unchanged, so the snap reconcile is pure redundant work -- it
// sends zero XCB requests (delta-apply) but still burns a full O(N) compute
// pass plus a grab+flush. Confirmed by actions.snapViewportToFocused,
// which now SKIPS the reconcile when the offset and tiled count are unchanged.
//
// This test quantifies both phases (the focus pass and the redundant snap
// pass) so the before-cost of the redundant second pass is explicit.
test "latency: Mod+k focus + redundant viewport-snap reconcile" {
    const n = 16;
    var m = makeModel();
    for (0..n) |i| regCur(&m, @intCast(i + 1));

    sync.init();
    defer sync.deinit();

    var warm = CountingSink{};
    var warm_ctx = makeCtx(warm.sink(), colorOfFocused);
    sync.reconcile(&m, &warm_ctx, .{});

    const iters: usize = 5_000;

    // Phase 1: the focus transition reconcile.
    var s1 = CountingSink{};
    var c1 = makeCtx(s1.sink(), colorOfFocused);
    model.setFocus(&m, 2);
    const t0 = nowNs();
    for (0..iters) |_| {
        model.setFocus(&m, 2);
        sync.reconcile(&m, &c1, .{});
    }
    const focus_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iters));

    // Phase 2: the (previously redundant) snapViewportToFocused reconcile when
    // offset is unchanged. This is what produced the second grab+reconcile per
    // Mod+k; with the snap-skip optimization the real path returns early here,
    // so the redundant pass is zeroed out for the on-screen common case.
    var s2 = CountingSink{};
    var c2 = makeCtx(s2.sink(), colorOfFocused);
    const t1 = nowNs();
    for (0..iters) |_| sync.reconcile(&m, &c2, .{});
    const snap_ns = @as(f64, @floatFromInt(nowNs() - t1)) / @as(f64, @floatFromInt(iters));

    std.debug.print(
        "[latency] Mod+k n={d}: focus reconcile={d:.1} ns, redundant snap reconcile={d:.1} ns (snap would add {d:.1}% on top; now skipped when viewport unchanged)\n",
        .{ n, focus_ns, snap_ns, @as(f64, 100.0) * snap_ns / focus_ns },
    );
}
