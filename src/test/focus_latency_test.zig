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
const utils = @import("utils");
const sync = @import("sync");
const linux = std.os.linux;

const Model = model.Model;
const WindowId = model.WindowId;

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
    count: usize = 0,

    fn mapShim(self_ptr: *anyopaque, _: model.WindowId) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.count += 1;
    }
    fn geomShim(self_ptr: *anyopaque, _: model.WindowId, _: utils.Rect, _: ?sync.Stack) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.count += 1;
    }
    fn bwShim(self_ptr: *anyopaque, _: model.WindowId, _: u16) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.count += 1;
    }
    fn pixelShim(self_ptr: *anyopaque, _: model.WindowId, _: u32) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.count += 1;
    }
    fn parkShim(self_ptr: *anyopaque, _: model.WindowId) void {
        const s: *CountingSink = @ptrCast(@alignCast(self_ptr));
        s.count += 1;
    }
    fn stackShim(_: *anyopaque, _: model.WindowId, _: sync.Stack) void {}
    fn ewmhShim(_: *anyopaque, _: model.WindowId, _: u32, _: u32, _: bool) void {}
    fn flushShim(_: *anyopaque) void {}
    fn grabShim(_: *anyopaque) void {}
    fn ungrabShim(_: *anyopaque) void {}

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

// Reconcile cost scaling with window count + the number of wire requests a
// single focus change issues (reconcile replays every window unconditionally).
test "latency: reconcile cost + request count at focus change" {
    inline for (.{ 1, 2, 4, 16, 50 }) |n| {
        var m = makeModel();
        for (0..n) |i| regCur(&m, @intCast(i + 1));

        sync.init();
        defer sync.deinit();

        // Steady-state pass with a live counter (populates the ledger once).
        var warm = CountingSink{};
        var warm_ctx = makeCtx(&warm);
        sync.reconcile(&m, &warm_ctx, .{});

        // Measure CPU cost of one reconcile pass.
        var bench = CountingSink{};
        var bench_ctx = makeCtx(&bench);
        const iterations: usize = 5_000;
        const t0 = nowNs();
        for (0..iterations) |_| sync.reconcile(&m, &bench_ctx, .{});
        const per_pass_ns = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, @floatFromInt(iterations));

        // Count requests in one representative pass (fresh sink).
        var probe = CountingSink{};
        var probe_ctx = makeCtx(&probe);
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

    const warm = CountingSink{};
    var warm_ctx = makeCtx(@constCast(&warm));
    sync.reconcile(&m, &warm_ctx, .{});

    const iters: usize = 5_000;

    // Phase 1: the focus transition reconcile.
    var s1 = CountingSink{};
    var c1 = makeCtx(&s1);
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
    var c2 = makeCtx(&s2);
    const t1 = nowNs();
    for (0..iters) |_| sync.reconcile(&m, &c2, .{});
    const snap_ns = @as(f64, @floatFromInt(nowNs() - t1)) / @as(f64, @floatFromInt(iters));

    std.debug.print(
        "[latency] Mod+k n={d}: focus reconcile={d:.1} ns, redundant snap reconcile={d:.1} ns (snap would add {d:.1}% on top; now skipped when viewport unchanged)\n",
        .{ n, focus_ns, snap_ns, @as(f64, 100.0) * snap_ns / focus_ns },
    );
}
