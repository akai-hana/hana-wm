//! Micro-benchmarks for model/sync hot paths.
//!
//! Run: zig build test --summary all (these are test blocks, so they run
//! alongside correctness tests). Check stderr for timing output.

const std = @import("std");
const testing = std.testing;
const model = @import("model");
const constants = @import("constants");
const utils = @import("utils");
const sync = @import("sync");
const linux = std.os.linux;
const build_options = @import("build_options");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};
const workspaces = if (build_options.has_workspaces) @import("workspaces") else struct {};

const Model = model.Model;
const WindowId = model.WindowId;
const WSId = model.WSId;

fn makeModel() Model {
    return .{};
}

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

fn regCur(m: *Model, win: WindowId) void {
    model.register(m, win, null) catch unreachable;
}

test "bench: findHome scan (100 wins, 10 ws)" {
    var m = makeModel();
    var win_id: WindowId = 1;
    for (0..10) |ws| {
        for (0..10) |_| {
            regCur(&m, win_id);
            // Override home to target the specific workspace
            if (win_id != 1) {
                workspaces.moveWindowToWs(&m, win_id, @intCast(ws));
            }
            win_id += 1;
        }
    }

    const iterations: usize = 10_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        for (0..10) |ws| {
            const w: WindowId = @intCast(10 * ws + 10);
            _ = model.findHome(&m, w);
        }
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 10));
    std.debug.print("[bench] findHome (100 wins, 10 ws): {d:.1} ns/call\n", .{per_call_ns});

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

    const iterations: usize = 10_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = fullscreen.fullscreenOccupantOnWs(&m, 0);
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    std.debug.print("[bench] fullscreenOccupantOnWs (50 wins): {d:.1} ns/call\n", .{per_call_ns});
}

test "bench: moveWindowToWs round-trip (50 wins)" {
    var m = makeModel();
    for (0..50) |i| {
        model.register(&m, @intCast(i + 1), 0) catch unreachable;
    }

    const iterations: usize = 10_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        for (0..50) |i| {
            workspaces.moveWindowToWs(&m, @intCast(i + 1), 1);
        }
        for (0..50) |i| {
            workspaces.moveWindowToWs(&m, @intCast(i + 1), 0);
        }
    }
    const elapsed_ns = nowNs() - t0;
    const per_op_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 100));
    std.debug.print("[bench] moveWindowToWs round-trip (50 wins): {d:.1} ns/op\n", .{per_op_ns});
}

test "bench: minimize/restore cycle (32 wins, max budget)" {
    var m = makeModel();
    try minimize.init();
    defer minimize.deinit();
    for (0..32) |i| {
        model.register(&m, @intCast(i + 1), 0) catch unreachable;
    }

    const iterations: usize = 5_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        for (0..32) |i| {
            minimize.minimize(&m, @intCast(i + 1)) catch unreachable;
        }
        for (0..32) |i| {
            minimize.restore(&m, @intCast(i + 1));
        }
    }
    const elapsed_ns = nowNs() - t0;
    const per_op_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 64));
    std.debug.print("[bench] minimize/restore cycle (32 wins): {d:.1} ns/op\n", .{per_op_ns});
}

test "bench: reorderTiled (50 wins)" {
    var m = makeModel();
    for (0..50) |i| {
        model.register(&m, @intCast(i + 1), 0) catch unreachable;
    }

    const iterations: usize = 10_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        model.reorderTiled(&m, 50, 0);
        model.reorderTiled(&m, 50, 49);
    }
    const elapsed_ns = nowNs() - t0;
    const per_op_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 2));
    std.debug.print("[bench] reorderTiled (50 wins): {d:.1} ns/op\n", .{per_op_ns});
}

const BenchRecorder = struct {
    count: usize = 0,

    fn mapShim(_: *anyopaque, _: model.WindowId) void {}
    fn geomShim(_: *anyopaque, _: model.WindowId, _: utils.Rect, _: ?sync.Stack) void {}
    fn bwShim(_: *anyopaque, _: model.WindowId, _: u16) void {}
    fn pixelShim(_: *anyopaque, _: model.WindowId, _: u32) void {}
    fn parkShim(self_ptr: *anyopaque, _: model.WindowId) void {
        const self: *BenchRecorder = @ptrCast(@alignCast(self_ptr));
        self.count += 1;
    }
    fn stackShim(_: *anyopaque, _: model.WindowId, _: sync.Stack) void {}
    fn ewmhShim(_: *anyopaque, _: model.WindowId, _: u32, _: u32, _: bool) void {}
    fn flushShim(_: *anyopaque) void {}
    fn grabShim(_: *anyopaque) void {}
    fn ungrabShim(_: *anyopaque) void {}

    fn sink(self: *BenchRecorder) sync.Sink {
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

fn testColor(_: model.WindowId, _: *const model.Model) u32 {
    return 100;
}

test "bench: reconcile pass (50 windows)" {
    var m = makeModel();
    for (0..50) |i| {
        model.register(&m, @intCast(i + 1), 0) catch unreachable;
    }
    model.setFocus(&m, 25);

    var recorder = BenchRecorder{};
    const screen: utils.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };

    sync.init();
    defer sync.deinit();

    var ctx: sync.Ctx = .{
        .sink = recorder.sink(),
        .screen = screen,
        .workarea = screen,
        .cfg_bw = 2,
        .color_of = testColor,
        .env = .{ .margins = .{ .gap = 8, .border = 2 }, .min_dim = 50 },
    };

    const iterations: usize = 1_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        recorder.count = 0;
        sync.reconcile(&m, &ctx, .{});
    }
    const elapsed_ns = nowNs() - t0;
    const per_pass_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    std.debug.print("[bench] reconcile (50 wins): {d:.1} ns/pass\n", .{per_pass_ns});
}

test "bench: register (50 wins, home_ws cache setup)" {
    const iterations: usize = 10_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        var m = makeModel();
        for (0..50) |i| {
            model.register(&m, @intCast(i + 1), 0) catch unreachable;
        }
    }
    const elapsed_ns = nowNs() - t0;
    const per_reg_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations * 50));
    std.debug.print("[bench] register (50 wins): {d:.1} ns/reg\n", .{per_reg_ns});
}

test "bench: fallbackFocusCandidate (50 wins)" {
    var m = makeModel();
    for (0..50) |i| {
        model.register(&m, @intCast(i + 1), 0) catch unreachable;
    }
    for (0..50) |i| {
        model.setFocus(&m, @intCast(i + 1));
    }

    const iterations: usize = 10_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = model.fallbackFocusCandidate(&m, 0);
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    std.debug.print("[bench] fallbackFocusCandidate (50 wins): {d:.1} ns/call\n", .{per_call_ns});
}

test "bench: store.get linear scan (max_tiled_windows, worst case)" {
    var m = makeModel();
    const n = constants.Limits.max_tiled_windows;
    for (0..n) |i| {
        model.register(&m, @intCast(i + 1), 0) catch unreachable;
    }

    const iterations: usize = 50_000;
    const t0 = nowNs();
    for (0..iterations) |_| {
        _ = m.store.get(@intCast(n));
    }
    const elapsed_ns = nowNs() - t0;
    const per_call_ns = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(iterations));
    std.debug.print("[bench] store.get ({d} wins, worst case): {d:.1} ns/call\n", .{ n, per_call_ns });
}
