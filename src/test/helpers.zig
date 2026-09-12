const std = @import("std");
const model = @import("model");
const utils = @import("utils");
const sync = @import("sync");
const build_options = @import("build_options");

/// Standard 800x600 test geometry (screen == workarea), shared by the sync
/// and tiling fixtures so no caller threads it through every init.
pub const std_wa: utils.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

pub fn makeModel() model.Model {
    return .{};
}

/// Deterministically re-arms the process-global module stores (minimize,
/// fullscreen) that back the model transitions, so a test's first assertions
/// never depend on which earlier tests left records behind ("pass in any
/// order", F-20). Both modules' init()/deinit() are idempotent resets (they
/// only clear their static stores), so calling this redundantly is harmless.
/// No-ops for modules absent from this build.
pub fn testReset() void {
    if (build_options.has_minimize) {
        @import("minimize").deinit();
        @import("minimize").init() catch unreachable;
    }
    if (build_options.has_fullscreen) {
        @import("fullscreen").deinit();
        @import("fullscreen").init() catch unreachable;
    }
}

/// Fresh model on deterministically reset module stores. The canonical
/// fixture entry for state-machine tests that touch module-backed transitions
/// (minimize/fullscreen): frees them from a shared static store seeded by an
/// unrelated earlier test.
pub fn setUpModel() model.Model {
    testReset();
    return makeModel();
}

pub fn regCur(m: *model.Model, win: model.WindowId) void {
    model.register(m, win, null) catch unreachable;
}

pub fn colorOfFocused(win: model.WindowId, m: *const model.Model) u32 {
    return if (m.focused == win) 1 else 0;
}

pub fn makeCtx(
    sink: sync.Sink,
    color_of: *const fn (model.WindowId, *const model.Model) u32,
) sync.Ctx {
    const screen: utils.Rect = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 };
    return .{
        .sink = sink,
        .screen = screen,
        .workarea = screen,
        .cfg_bw = 2,
        .color_of = color_of,
        .env = std_env,
    };
}

/// Warms the sync ledger with one steady-state pass, then times `iterations`
/// reconcile passes and returns nanoseconds per pass. Shared by the latency
/// benchmarks (the identical warm+bench pattern in the latency tests).
pub fn benchReconcile(m: *model.Model, iterations: usize) f64 {
    var warm = TestSink(.count){};
    var warm_ctx = makeCtx(warm.sink(), colorOfFocused);
    sync.reconcile(m, &warm_ctx, .{});
    var bench = TestSink(.count){};
    var bench_ctx = makeCtx(bench.sink(), colorOfFocused);
    const t0 = utils.monotonicNs();
    for (0..iterations) |_| sync.reconcile(m, &bench_ctx, .{});
    return @as(f64, @floatFromInt(utils.monotonicNs() - t0)) / @as(f64, @floatFromInt(iterations));
}

pub const TestOp = union(enum) {
    map: model.WindowId,
    geom: struct { win: model.WindowId, rect: utils.Rect, stack: ?sync.Stack },
    bw: struct { win: model.WindowId, w: u16 },
    pixel: struct { win: model.WindowId, p: u32 },
    park: model.WindowId,
    stack: struct { win: model.WindowId, s: sync.Stack },
};

pub const SinkMode = enum {
    count,
    category,
    record,
    none,
};

/// Standard test margin/min_dim tuning shared by the sync/tiling fixtures.
pub const std_env: @FieldType(sync.Ctx, "env") = .{
    .margins = .{ .gap = 8, .border = 2 },
    .min_dim = 50,
};

/// Default config-order layout cycle, used by the model and tiling tests.
pub const std_layout_names = [_][]const u8{ "master", "monocle", "grid", "fibonacci" };

pub fn TestSink(comptime mode: SinkMode) type {
    return struct {
        const Self = @This();

        count: usize = 0,
        map: usize = 0,
        park: usize = 0,
        geom: usize = 0,
        bw: usize = 0,
        pixel: usize = 0,
        total: usize = 0,
        ops: std.ArrayList(TestOp) = .empty,

        fn bump(self: *Self, comptime tag: std.meta.Tag(TestOp), payload: TestOp) void {
            switch (mode) {
                .record => self.ops.append(std.testing.allocator, payload) catch unreachable,
                .count => self.count += 1,
                .category => {
                    @field(self, @tagName(tag)) += 1;
                    self.total += 1;
                },
                .none => {},
            }
        }

        fn mapShim(self_ptr: *anyopaque, win: model.WindowId) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.map, .{ .map = win });
        }

        fn geomShim(self_ptr: *anyopaque, win: model.WindowId, rect: utils.Rect, stack: ?sync.Stack) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.geom, .{ .geom = .{ .win = win, .rect = rect, .stack = stack } });
        }

        fn bwShim(self_ptr: *anyopaque, win: model.WindowId, w: u16) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.bw, .{ .bw = .{ .win = win, .w = w } });
        }

        fn pixelShim(self_ptr: *anyopaque, win: model.WindowId, p: u32) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.pixel, .{ .pixel = .{ .win = win, .p = p } });
        }

        fn parkShim(self_ptr: *anyopaque, win: model.WindowId) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.park, .{ .park = win });
        }

        fn stackShim(self_ptr: *anyopaque, win: model.WindowId, s: sync.Stack) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .record) {
                self.ops.append(std.testing.allocator, .{ .stack = .{ .win = win, .s = s } }) catch unreachable;
            }
        }

        fn ewmhShim(_: *anyopaque, _: model.WindowId, _: u32, _: u32, _: bool) void {}
        fn flushShim(_: *anyopaque) void {}
        fn grabShim(_: *anyopaque) void {}
        fn ungrabShim(_: *anyopaque) void {}

        pub fn sink(self: *Self) sync.Sink {
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

        pub fn clear(self: *Self) void {
            if (mode == .record) self.ops.clearRetainingCapacity();
        }

        pub fn deinit(self: *Self) void {
            if (mode == .record) self.ops.deinit(std.testing.allocator);
        }

        pub fn expectLen(self: *const Self, n: usize) !void {
            comptime if (mode != .record) @compileError("expectLen requires record mode");
            try std.testing.expectEqual(n, self.ops.items.len);
        }

        pub fn expectGeom(
            self: *const Self,
            i: usize,
            win: model.WindowId,
            x: i32,
            y: i32,
            w: u16,
            h: u16,
            stack: ?sync.Stack,
        ) !void {
            comptime if (mode != .record) @compileError("expectGeom requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .geom);
            try std.testing.expectEqual(win, op.geom.win);
            try std.testing.expectEqual(x, @as(i32, op.geom.rect.x));
            try std.testing.expectEqual(y, @as(i32, op.geom.rect.y));
            try std.testing.expectEqual(w, op.geom.rect.width);
            try std.testing.expectEqual(h, op.geom.rect.height);
            if (stack) |s| {
                try std.testing.expect(op.geom.stack != null);
                try std.testing.expectEqual(s, op.geom.stack.?);
            } else {
                try std.testing.expect(op.geom.stack == null);
            }
        }

        pub fn expectPixel(self: *const Self, i: usize, win: model.WindowId, p: u32) !void {
            comptime if (mode != .record) @compileError("expectPixel requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .pixel);
            try std.testing.expectEqual(win, op.pixel.win);
            try std.testing.expectEqual(p, op.pixel.p);
        }

        pub fn expectBw(self: *const Self, i: usize, win: model.WindowId, w: u16) !void {
            comptime if (mode != .record) @compileError("expectBw requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .bw);
            try std.testing.expectEqual(win, op.bw.win);
            try std.testing.expectEqual(w, op.bw.w);
        }

        pub fn expectMap(self: *const Self, i: usize, win: model.WindowId) !void {
            comptime if (mode != .record) @compileError("expectMap requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .map);
            try std.testing.expectEqual(win, op.map);
        }

        pub fn expectPark(self: *const Self, i: usize, win: model.WindowId) !void {
            comptime if (mode != .record) @compileError("expectPark requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .park);
            try std.testing.expectEqual(win, op.park);
        }
    };
}
