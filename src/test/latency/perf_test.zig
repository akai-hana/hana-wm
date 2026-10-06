//! Micro-benchmarks for model/reconcile hot paths.
//!
//! Run: zig build test -Dbench --summary all (timing goes to stdout/stderr
//! only under -Dbench; the default suite runs these as silent
//! smokes so `zig build test` stays quiet).

// (28.6) Declared here, next to the imports that make it necessary, rather than in a
// build.zig table that had to be kept in agreement with them by hand.
// build-gate: minimize, fullscreen, workspaces

const std = @import("std");
const testing = std.testing;
const model = @import("model");
const constants = @import("constants");
const build_options = @import("build_options");
const helpers = @import("helpers");
const test_sink = @import("test_sink");

const time = @import("time");
// Bench marks only run (full iterations + timing output) under `-Dbench`.
const ledger = @import("ledger");
const reconcile = @import("reconcile");
const bench = build_options.bench; // (28.2) timings -> file
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;

const makeModel = helpers.makeBareModel; // (28.3) bench: no module-store churn between iterations

const nowNs = time.monotonicNs;

const regCur = helpers.regCur;

const makeCtx = helpers.makeCtx;

/// Registers ids 1..n with home-workspace hint 0 (the fill most benchmarks use).
fn fill(m: *Model, n: u32) !void {
    for (0..n) |i| try model.register(m, @intCast(i + 1), model.WSId.fromIndex(0));
}

test "bench: findHome scan (100 wins, 10 ws)" {
    var m = makeModel();
    var win_id: WindowId = 1;
    for (0..10) |ws| {
        for (0..10) |_| {
            regCur(&m, win_id);
            // Override home to target the specific workspace
            if (win_id != 1) {
                workspaces.moveWindowToWs(&m, win_id, model.WSId.fromIndex(ws));
            }
            win_id += 1;
        }
    }

    const iterations: usize = if (bench) 10_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        for (0..10) |ws| {
            const w: WindowId = @intCast(10 * ws + 10);
            _ = model.findHome(&m, w);
        }
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 10));
    if (bench) helpers.benchLog("[bench] findHome (100 wins, 10 ws): {d:.1} ns/call\n", .{per_call_ns});

    for (0..100) |i| {
        const e = m.store.get(@intCast(i + 1)).?;
        try testing.expect(e.home_ws != null);
    }
}

test "bench: fullscreenOccupantOnWs store scan (50 wins)" {
    var m = makeModel();
    for (0..50) |i| {
        regCur(&m, @intCast(i + 1));
    }
    _ = fullscreen.toggleFullscreen(&m, 25);

    const iterations: usize = if (bench) 10_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = fullscreen.visibleCoveringOnWs(&m, model.WSId.fromIndex(0));
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    if (bench) helpers.benchLog("[bench] fullscreenOccupantOnWs (50 wins): {d:.1} ns/call\n", .{per_call_ns});
}

test "bench: coveringOccupantOnWs store scan (50 wins)" {
    var m = makeModel();
    for (0..50) |i| {
        regCur(&m, @intCast(i + 1));
    }
    _ = fullscreen.toggleFullscreen(&m, 25);

    const iterations: usize = if (bench) 10_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = model.coveringOccupantOnWs(&m, model.WSId.fromIndex(0));
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    if (bench) helpers.benchLog("[bench] coveringOccupantOnWs (50 wins): {d:.1} ns/call\n", .{per_call_ns});
}

test "bench: moveWindowToWs round-trip (50 wins)" {
    var m = makeModel();
    try fill(&m, 50);

    const iterations: usize = if (bench) 10_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        for (0..50) |i| {
            workspaces.moveWindowToWs(&m, @intCast(i + 1), model.WSId.fromIndex(1));
        }
        for (0..50) |i| {
            workspaces.moveWindowToWs(&m, @intCast(i + 1), model.WSId.fromIndex(0));
        }
    }
    const elapsed_ns = nowNs() - t0;
    const per_op_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 100));
    if (bench) helpers.benchLog("[bench] moveWindowToWs round-trip (50 wins): {d:.1} ns/op\n", .{per_op_ns});
}

test "bench: minimize/restore cycle (32 wins, max budget)" {
    var m = makeModel();
    try minimize.init();
    defer minimize.deinit();
    try fill(&m, 32);

    const iterations: usize = if (bench) 5_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        for (0..32) |i| {
            try minimize.minimize(&m, @intCast(i + 1));
        }
        for (0..32) |i| {
            minimize.restore(&m, @intCast(i + 1));
        }
    }
    const elapsed_ns = nowNs() - t0;
    const per_op_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 64));
    if (bench) helpers.benchLog("[bench] minimize/restore cycle (32 wins): {d:.1} ns/op\n", .{per_op_ns});
}

test "bench: reorderTiled (50 wins)" {
    var m = makeModel();
    try fill(&m, 50);

    const iterations: usize = if (bench) 10_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        model.reorderTiled(&m, 50, 0);
        model.reorderTiled(&m, 50, 49);
    }
    const elapsed_ns = nowNs() - t0;
    const per_op_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 2));
    if (bench) helpers.benchLog("[bench] reorderTiled (50 wins): {d:.1} ns/op\n", .{per_op_ns});
}

fn testColor(_: model.WindowId, _: *const model.Model) u32 {
    // (28.8) helpers.focused_pixel, not a literal 100. The literal was a
    // second copy of a shared constant: changing the focused pixel would have
    // left this returning the old value with no test failing, since nothing
    // compared the two.
    return helpers.focused_pixel;
}

test "bench: reconcile pass (50 windows)" {
    var m = makeModel();
    try fill(&m, 50);
    model.setFocus(&m, 25);

    var recorder = test_sink.TestSink(.none){};

    ledger.init();
    defer ledger.init();

    var ctx = makeCtx(recorder.sink(), testColor, helpers.std_wa);

    const iterations: usize = if (bench) 1_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| reconcile.run(&m, &ctx, .{});
    const elapsed_ns = nowNs() - t0;
    const per_pass_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    if (bench) helpers.benchLog("[bench] reconcile (50 wins): {d:.1} ns/pass\n", .{per_pass_ns});
}

test "bench: drag tick full reconcile vs targeted reconcileDragTick" {
    // Compares the per-motion-event latency of the drag path BEFORE (a full
    // reconcile over every window) vs AFTER (a targeted reconcileDragTick that
    // sends only the dragged window's geometry).
    var m = makeModel();
    try fill(&m, 50);
    model.setFocus(&m, 25);

    // Float window 50 so it participates in the drag fast path.
    const dragged: WindowId = 50;
    const e = m.store.getPtr(dragged).?;
    e.anchor = .{ .floating = .{ .x = 100, .y = 100, .width = 300, .height = 200 } };

    ledger.init();
    defer ledger.init();

    var recorder = test_sink.TestSink(.none){};
    var ctx = makeCtx(recorder.sink(), testColor, helpers.std_wa);

    // Warm once so the sent ledger is seeded (steady-state drag).
    reconcile.run(&m, &ctx, .{});

    const iterations: usize = if (bench) 100_000 else 1;

    // AFTER: targeted reconcileDragTick
    const t2 = nowNs();
    for (0..iterations) |_| {
        const e2 = m.store.getPtr(dragged).?;
        switch (e2.anchor) {
            .floating => |*r| {
                r.x +%= 1;
                r.y +%= 1;
            },
            .tiled => unreachable,
        }
        reconcile.reconcileDragTick(&m, recorder.sink(), dragged);
    }
    const elapsed2 = nowNs() - t2;
    const per_tick_ns = @as(f64, @floatFromInt(elapsed2)) / @as(f64, @floatFromInt(iterations));

    // BEFORE: full reconcile (what reconcileNow did on every drag tick)
    const t1 = nowNs();
    for (0..iterations) |_| {
        const e1 = m.store.getPtr(dragged).?;
        switch (e1.anchor) {
            .floating => |*r| {
                r.x +%= 1;
                r.y +%= 1;
            },
            .tiled => unreachable,
        }
        reconcile.run(&m, &ctx, .{});
    }
    const elapsed1 = nowNs() - t1;
    const per_full_ns = @as(f64, @floatFromInt(elapsed1)) / @as(f64, @floatFromInt(iterations));

    if (bench)
        helpers.benchLog(
            "[drag] full reconcile (50 wins): {d:.1} ns/tick; targeted reconcileDragTick: {d:.1} ns/tick; speedup {d:.1}x\n",
            .{ per_full_ns, per_tick_ns, per_full_ns / per_tick_ns },
        );
}

test "bench: register (50 wins, home_ws cache setup)" {
    const iterations: usize = if (bench) 10_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        var m = makeModel();
        try fill(&m, 50);
    }
    const elapsed_ns = nowNs() - t0;
    const per_reg_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 50));
    if (bench) helpers.benchLog("[bench] register (50 wins): {d:.1} ns/reg\n", .{per_reg_ns});
}

test "bench: fallbackFocusCandidate (50 wins)" {
    var m = makeModel();
    try fill(&m, 50);
    for (0..50) |i| {
        model.setFocus(&m, @intCast(i + 1));
    }

    const iterations: usize = if (bench) 10_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = model.fallbackFocusCandidate(&m, model.WSId.fromIndex(0), null);
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    if (bench) helpers.benchLog("[bench] fallbackFocusCandidate (50 wins): {d:.1} ns/call\n", .{per_call_ns});
}

test "bench: store.get linear scan (max_tiled_windows, worst case)" {
    var m = makeModel();
    const n = constants.max_tiled_windows;
    try fill(&m, n);

    const iterations: usize = if (bench) 50_000 else 1;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = m.store.get(@intCast(n));
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    if (bench) helpers.benchLog("[bench] store.get ({d} wins, worst case): {d:.1} ns/call\n", .{ n, per_call_ns });
}

test "bench: sent ledger (64 wins: cold fill + warm hit sweep)" {
    // The sync sent-ledger access pattern, isolated: reconcile touches the
    // ledger with exactly one get-or-put per window per reconcile (see reconcile.run).
    // COLD = fresh ledger first-touch (post-boot reconcile); WARM = already-seeded
    // ledger, hit-only sweep (steady-state reconcile; model.Store iterates sorted-key
    // order, so the sweep walks ascending window ids).
    ledger.init();
    defer ledger.init();

    const n: usize = 64;

    const it_cold: usize = if (bench) 20_000 else 1;
    const t0 = nowNs();
    for (0..it_cold) |_| {
        ledger.init();
        for (0..n) |i| _ = ledger.sentGetOrPut(@intCast(i + 1));
    }
    const cold_ns = nowNs() - t0;
    const per_cold_ns = @as(f64, @floatFromInt(cold_ns)) / @as(f64, @floatFromInt(it_cold * n));

    ledger.init();
    for (0..n) |i| _ = ledger.sentGetOrPut(@intCast(i + 1001));
    const it_warm: usize = if (bench) 20_000 else 1;
    const t1 = nowNs();
    for (0..it_warm) |_| {
        for (0..n) |i| _ = ledger.sentGetOrPut(@intCast(i + 1001));
    }
    const warm_ns = nowNs() - t1;
    const per_warm_ns = @as(f64, @floatFromInt(warm_ns)) / @as(f64, @floatFromInt(it_warm * n));

    if (bench)
        helpers.benchLog(
            "[bench] sent ledger ({d} wins): cold {d:.1} ns/op; warm {d:.1} ns/op ({d:.2} us/sweep)\n",
            .{ n, per_cold_ns, per_warm_ns, per_warm_ns * @as(f64, @floatFromInt(n)) / 1000.0 },
        );
}

test "bench mode records its timings to a file, not to stderr" {
    // (28.2) The test protocol rejects any stderr, which is why bench output
    // could never be printed: the one invocation that compiles bench mode
    // (`zig build test -Dbench=true`) reported failure on a passing suite.
    // This pins the replacement end to end -- a line written, and readable
    // back -- so the file path cannot silently rot into a no-op.
    if (!bench) return error.SkipZigTest;
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, ".zig-cache/bench") catch |err| {
        std.debug.print("bench dir: {s}\n", .{@errorName(err)});
        return err;
    };
    // Record the file's size BEFORE this run's append, so the assertion can be
    // bound to the bytes this run actually added -- appends accumulate across
    // process runs by design, and a stale hit from a previous run under an
    // unbounded grep would say success without the current write landing.
    const path = ".zig-cache/bench/timings.txt";
    var size_before: usize = 0;
    if (cwd.openFile(path, .{})) |f_before| {
        defer f_before.close();
        size_before = (try f_before.stat(io)).size;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    helpers.benchLog("bench-selftest {d}", .{@as(u32, 12345)});
    const bytes = cwd.readFileAlloc(io, path, testing.allocator, .limited(1 << 20)) catch |err| {
        std.debug.print("bench read: {s}\n", .{@errorName(err)});
        return err;
    };
    defer testing.allocator.free(bytes);
    const from = @min(size_before, bytes.len);
    try testing.expect(std.mem.indexOf(u8, bytes[from..], "bench-selftest 12345") != null);
}
