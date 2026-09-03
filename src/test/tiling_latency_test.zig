//! Timing/instrumentation for the TILING LAYOUT OPERATION path (retile).
//!
//! Question: when a tiling action runs (layout switch, variant change, width
//! adjust, swap master, focus next/prev), how much latency does the 
//! server-grab reconcile add, and how does it scale with window count?
//!
//! Every tiling op routes through actions -> pipeline.reconcileUnderGrabNow
//! -> sync.reconcileUnderGrab -> sync.reconcile. reconcile replays the FULL
//! desired wire state for EVERY stored window (all workspaces) each pass,
//! then delta-sends only what changed (no-op elision). The SEND is O(changed)
//! but the COMPUTE is O(total windows), so a retile's CPU cost grows with
//! total window count even though few windows actually move.

const std = @import("std");
const model = @import("model");
const utils = @import("utils");
const sync = @import("sync");
const tiling = @import("tiling");
const linux = std.os.linux;

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn makeModel() Model {
    return .{};
}

fn regCur(m: *Model, win: WindowId) void {
    model.register(m, win, null) catch unreachable;
}

const CountingSink = struct {
    map: usize = 0,
    park: usize = 0,
    geom: usize = 0,
    bw: usize = 0,
    pixel: usize = 0,
    total: usize = 0,
    grab: usize = 0,

    fn mapShim(self_ptr: *anyopaque, _: model.WindowId) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.map += 1;
        s.total += 1;
    }
    fn geomShim(self_ptr: *anyopaque, _: model.WindowId, _: utils.Rect, _: ?sync.Stack) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.geom += 1;
        s.total += 1;
    }
    fn bwShim(self_ptr: *anyopaque, _: model.WindowId, _: u16) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.bw += 1;
        s.total += 1;
    }
    fn pixelShim(self_ptr: *anyopaque, _: model.WindowId, _: u32) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.pixel += 1;
        s.total += 1;
    }
    fn parkShim(self_ptr: *anyopaque, _: model.WindowId) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.park += 1;
        s.total += 1;
    }
    fn stackShim(_: *anyopaque, _: model.WindowId, _: sync.Stack) void {}
    fn ewmhShim(_: *anyopaque, _: model.WindowId, _: u32, _: u32, _: bool) void {}
    fn flushShim(_: *anyopaque) void {}
    fn grabShim(self_ptr: *anyopaque) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.grab += 1;
    }
    fn ungrabShim(_: *anyopaque) void {}

    fn reset(self: *CountingSink) void {
        self.* = .{};
    }

    fn sink(self: *CountingSink) sync.Sink {
        return .{
            .ptr = self,
            .vt = &.{
                .map = mapShim,
                .geom = geomShim,
                .border_width = bwShim,
                .border_pixel = pixelShim,
                .park = parkShim,
                .stack_only = stackShim,
                .set_ewmh_fullscreen = ewmhShim,
                .flush = flushShim,
                .grab_server = grabShim,
                .ungrab_and_flush = ungrabShim,
            },
        };
    }
};

fn colorOfFocused(win: WindowId, m: *const Model) u32 {
    return if (m.focused == win) 1 else 0;
}

fn makeCtx(sink: *CountingSink) sync.Ctx {
    const screen: utils.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    return .{
        .sink = sink.sink(),
        .screen = screen,
        .workarea = screen,
        .cfg_bw = 2,
        .color_of = colorOfFocused,
        .env = .{ .margins = .{ .gap = 8, .border = 2 }, .min_dim = 50 },
    };
}

// Reconcile CPU cost + request count scaling with window count, all windows
// on ONE workspace (the realistic many-window tiling case).
test "tiling: reconcile CPU cost + request count, all-on-1-ws, 1..50 win" {
    inline for (.{ 1, 8, 20, 35, 50 }) |n| {
        var m = makeModel();
        for (0..n) |i| regCur(&m, @intCast(i + 1));
        model.setFocus(&m, 1);

        sync.init();
        defer sync.deinit();

        // Warm: seed steady-state ledger (delta-send from here on).
        var warm = CountingSink{};
        var warm_ctx = makeCtx(&warm);
        sync.reconcile(&m, &warm_ctx, .{});

        // CPU cost of one steady-state reconcile pass (all desire compute +
        // ledger scans; sends mostly elided by delta-send).
        var bench = CountingSink{};
        var bench_ctx = makeCtx(&bench);
        const iterations: usize = 5_000;
        const t0 = nowNs();
        for (0..iterations) |_| sync.reconcile(&m, &bench_ctx, .{});
        const per_pass_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iterations));

        // What a single CHANGED pass costs: flip the layout kind so every
        // rect changes -> geometry requests sent for every visible window.
        var move = CountingSink{};
        var move_ctx = makeCtx(&move);
        m.ws[m.current].params.kind = 1;
        const t1 = nowNs();
        sync.reconcile(&m, &move_ctx, .{});
        const move_ns: f64 = @floatFromInt(nowNs() - t1);

        std.debug.print(
            "[tiling] n={d} (1ws): steady reconcile={d:.1} ns/pass, layout-change reconcile={d:.1} ns, requests on change={d} (geom={d},map={d})\n",
            .{ n, per_pass_ns, move_ns, move.total, move.geom, move.map },
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
                _ = model.register(&m, id, @intCast(ws)) catch unreachable;
                id += 1;
            }
        }
        model.setFocus(&m, 1);

        sync.init();
        defer sync.deinit();

        var warm = CountingSink{};
        var warm_ctx = makeCtx(&warm);
        sync.reconcile(&m, &warm_ctx, .{});

        var bench = CountingSink{};
        var bench_ctx = makeCtx(&bench);
        const iterations: usize = 5_000;
        const t0 = nowNs();
        for (0..iterations) |_| sync.reconcile(&m, &bench_ctx, .{});
        const per_pass_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iterations));

        std.debug.print(
            "[tiling] total={d} (10ws, {d}/ws): steady reconcile={d:.1} ns/pass (current ws has only {d} windows)\n",
            .{ total, per_ws, per_pass_ns, per_ws },
        );
    }
}

// Decompose a retile pass into: (a) layout compute over visible windows,
// (b) the full reconcile walk over ALL windows.
test "tiling: decompose layout.compute vs full reconcile walk" {
    const n = 50;
    var m = makeModel();
    for (0..n) |i| regCur(&m, @intCast(i + 1));
    model.setFocus(&m, 1);

    sync.init();
    defer sync.deinit();

    const screen: utils.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    var order_buf: [128]WindowId = undefined;
    var hints_buf: [128]model.SizeHints = undefined;
    var placements: tiling.List = .{};
    var nn: usize = 0;
    for (m.ws[m.current].tiled_order.constSlice()) |w| {
        const e = m.store.get(w).?;
        order_buf[nn] = w;
        hints_buf[nn] = e.size_hints;
        nn += 1;
    }
    const hv = tiling.HintsView{ .order = order_buf[0..nn], .hints = hints_buf[0..nn] };
    const view = tiling.View{
        .order = order_buf[0..nn],
        .params = &m.ws[m.current].params,
        .workarea = screen,
        .hints = &hv,
        .focused = m.focused,
        .env = .{ .margins = .{ .gap = 8, .border = 2 }, .min_dim = 50 },
    };
    const iterations: usize = 50_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        tiling.compute(m.ws[m.current].params.kind, view, &placements);
    }
    const compute_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iterations));

    var warm = CountingSink{};
    var warm_ctx = makeCtx(&warm);
    sync.reconcile(&m, &warm_ctx, .{});
    var bench = CountingSink{};
    var bench_ctx = makeCtx(&bench);
    const t1 = nowNs();
    const iters2: usize = 5_000;
    for (0..iters2) |_| sync.reconcile(&m, &bench_ctx, .{});
    const reconcile_ns = @as(f64, @floatFromInt(nowNs() - t1)) / @as(f64, @floatFromInt(iters2));

    std.debug.print(
        "[tiling] n={d}: layout.compute={d:.1} ns/pass ({d:.1}% of reconcile), full reconcile walk={d:.1} ns/pass\n",
        .{ n, compute_ns, 100.0 * compute_ns / reconcile_ns, reconcile_ns },
    );
}

// A *change* pass (e.g. every tiling op) sends geometry for every visible
// window. Counts the XCB requests in the changed pass at various window
// counts, mirroring reconcileUnderGrab's grab-server -> ungrabAndFlush.
test "tiling: XCB request count on a changing retile (layout switch)" {
    inline for (.{ 1, 20, 35, 50 }) |n| {
        var m = makeModel();
        for (0..n) |i| regCur(&m, @intCast(i + 1));
        model.setFocus(&m, 1);

        sync.init();
        defer sync.deinit();

        var warm = CountingSink{};
        var warm_ctx = makeCtx(&warm);
        sync.reconcile(&m, &warm_ctx, .{});

        var sink = CountingSink{};
        var ctx = makeCtx(&sink);
        m.ws[m.current].params.kind = 1;
        ctx.sink.grabServer();
        sync.reconcile(&m, &ctx, .{});
        ctx.sink.ungrabAndFlush();

        std.debug.print(
            "[tiling] layout switch n={d}: {d} XCB requests queued in grab (geom={d}, map={d}, park={d}, bw={d}, pixel={d})\n",
            .{ n, sink.total, sink.geom, sink.map, sink.park, sink.bw, sink.pixel },
        );
    }
}
