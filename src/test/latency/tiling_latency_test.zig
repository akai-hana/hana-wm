//! Timing/instrumentation for the TILING LAYOUT OPERATION path (retile).
//!
//! Question: when a tiling action runs (layout switch, variant change, width
//! adjust, swap master, focus next/prev), how much latency does the
//! server-grab reconcile add, and how does it scale with window count?
//!
//! Every tiling op routes through actions -> pipeline.reconcileUnderGrabNow
//! -> reconcile.reconcileUnderGrab -> reconcile.run. reconcile replays the FULL
//! desired wire state for EVERY stored window (all workspaces) each reconcile,
//! then delta-sends only what changed (no-op elision). The SEND is O(changed)
//! but the COMPUTE is O(total windows), so a retile's CPU cost grows with
//! total window count even though few windows actually move.

// (28.6) Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: tiling

const std = @import("std");
const model = @import("model");
const tiling = @import("tiling");
const helpers = @import("helpers");
const test_sink = @import("test_sink");
const build_options = @import("build_options");

const time = @import("time");
// Latency instrumentation only runs its full loops + timing output under
const ledger = @import("ledger");
const reconcile = @import("reconcile");
const sink = @import("sink");
// `-Dbench`; the default suite keeps a silent smoke so `zig build
// test` never writes to stderr (the runner flags test stderr as `failed
// command:` even on success).
const bench = build_options.bench;

const WindowId = model.WindowId;

const makeModel = helpers.makeBareModel; // (28.3) bench: no module-store churn between iterations
const regCur = helpers.regCur;
const nowNs = time.monotonicNs;

const CountingSink = test_sink.TestSink(.category);

const colorOfFocused = helpers.colorOfFocused;
const makeCtx = helpers.makeCtx;

// Reconcile CPU cost + request count scaling with window count, all windows
// on ONE workspace (the realistic many-window tiling case).
test "tiling: reconcile CPU cost + request count, all-on-1-ws, 1..50 win" {
    inline for (.{ 1, 8, 20, 35, 50 }) |n| {
        var m = makeModel();
        for (0..n) |i| regCur(&m, @intCast(i + 1));
        model.setFocus(&m, 1);

        ledger.init();
        defer ledger.init();

        // Warm: seed steady-state ledger, then measure one steady-state reconcile
        // (all desire compute + ledger scans; sends mostly elided).
        const per_pass_ns = helpers.benchReconcile(&m, if (bench) 5_000 else 1);

        // What a single CHANGED reconcile costs: flip the layout kind so every
        // rect changes -> geometry requests sent for every visible window.
        var move = CountingSink{};
        var move_ctx = makeCtx(move.sink(), colorOfFocused, helpers.std_wa);
        m.ws[m.current.index].params.kind = 1;
        const t1 = nowNs();
        reconcile.run(&m, &move_ctx, .{});
        const move_ns: f64 = @floatFromInt(nowNs() - t1);

        if (bench)
            helpers.benchLog(
                "[tiling] n={d} (1ws): steady reconcile={d:.1} ns/pass, layout-change reconcile={d:.1} ns, requests on change={d} (configure={d},map={d})\n",
                // (28.2) Was `move.geom`: TestSink has no `geom` counter. The
                // configure counter is the geometry-send counter -- configure
                // is how a moved window's new rect reaches the server -- so
                // this prints the number the label always meant.
                .{ n, per_pass_ns, move_ns, move.total, move.configure, move.map },
            );
    }
}

// Same, but windows SPREAD across workspaces: total count grows but the
// current workspace has a fixed small window set. Exposes how much of a
// retile cost is attributable to OFF-workspace (parked) windows.
test "tiling: reconcile cost with windows spread across 10 ws" {
    inline for (.{ 10, 30, 50 }) |total| {
        const per_ws = total / 10 + 1;
        var m = makeModel();
        var id: WindowId = 1;
        for (0..10) |ws| {
            for (0..per_ws) |_| {
                _ = try model.register(&m, id, model.WSId.fromIndex(ws));
                id += 1;
            }
        }
        model.setFocus(&m, 1);

        ledger.init();
        defer ledger.init();

        // Warm, then measure one steady-state reconcile.
        const per_pass_ns = helpers.benchReconcile(&m, if (bench) 5_000 else 1);

        if (bench)
            helpers.benchLog(
                "[tiling] total={d} (10ws, {d}/ws): steady reconcile={d:.1} ns/pass (current ws has only {d} windows)\n",
                .{ total, per_ws, per_pass_ns, per_ws },
            );
    }
}

// Decompose a retile into: (a) layout compute over visible windows,
// (b) the full reconcile walk over ALL windows.
test "tiling: decompose layout.compute vs full reconcile walk" {
    const n = 50;
    var m = makeModel();
    for (0..n) |i| regCur(&m, @intCast(i + 1));
    model.setFocus(&m, 1);

    ledger.init();
    defer ledger.init();

    const screen: model.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    var order_buf: [128]WindowId = undefined;
    var hints_buf: [128]model.SizeHints = undefined;
    var placements: tiling.List = .{};
    var nn: usize = 0;
    for (m.ws[m.current.index].tiled_order.constSlice()) |w| {
        const e = m.store.get(w).?;
        order_buf[nn] = w;
        hints_buf[nn] = e.size_hints;
        nn += 1;
    }
    const view = tiling.View{
        .order = order_buf[0..nn],
        .params = &m.ws[m.current.index].params,
        .workarea = screen,
        .hints = .{ .order = order_buf[0..nn], .hints = hints_buf[0..nn] },
        .focused = m.focused,
        .env = helpers.std_env,
    };
    const iterations: usize = if (bench) 50_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        tiling.compute(m.ws[m.current.index].params.kind, &view, &placements);
    }
    const compute_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iterations));

    // Warm, then measure the full reconcile-walk.
    const reconcile_ns = helpers.benchReconcile(&m, if (bench) 5_000 else 1);

    if (bench)
        helpers.benchLog(
            "[tiling] n={d}: layout.compute={d:.1} ns/pass ({d:.1}% of reconcile), full reconcile walk={d:.1} ns/pass\n",
            .{ n, compute_ns, 100.0 * compute_ns / reconcile_ns, reconcile_ns },
        );
}

// A *change* reconcile (e.g. every tiling op) sends geometry for every visible
// window. Counts the XCB requests in the changed reconcile at various window
// counts, mirroring reconcileUnderGrab's grab-server -> ungrabAndFlush.
test "tiling: XCB request count on a changing retile (layout switch)" {
    inline for (.{ 1, 20, 35, 50 }) |n| {
        var m = makeModel();
        for (0..n) |i| regCur(&m, @intCast(i + 1));
        model.setFocus(&m, 1);

        ledger.init();
        defer ledger.init();

        var warm = CountingSink{};
        var warm_ctx = makeCtx(warm.sink(), colorOfFocused, helpers.std_wa);
        reconcile.run(&m, &warm_ctx, .{});

        var counting = CountingSink{};
        var ctx = makeCtx(counting.sink(), colorOfFocused, helpers.std_wa);
        m.ws[m.current.index].params.kind = 1;
        ctx.sink.grabServer();
        reconcile.run(&m, &ctx, .{});
        ctx.sink.ungrabAndFlush();

        if (bench)
            helpers.benchLog(
                "[tiling] layout switch n={d}: {d} XCB requests queued in grab (configure={d}, map={d}, park={d}, pixel={d})\n",
                // (28.2) `sink` did not exist in this scope at all -- the sink
                // here is `counting` -- and `geom`/`bw` are not TestSink
                // fields. All four placeholders are read off `counting`.
                .{ n, counting.total, counting.configure, counting.map, counting.park, counting.pixel },
            );
    }
}
