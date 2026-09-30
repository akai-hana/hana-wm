const std = @import("std");
const model = @import("model");
const build_options = @import("build_options");

const time = @import("time");
/// Standard 800x600 test geometry (screen == workarea), shared by the sync
const reconcile = @import("reconcile");
const sinkmod = @import("sink");
/// and tiling fixtures so no caller threads it through every init.
pub const std_wa: model.Rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

/// Deterministically re-arms the process-global module stores (minimize,
/// fullscreen) that back the model transitions, so a test's first assertions
/// never depend on which earlier tests left records behind ("pass in any
/// order"). Both modules' init()/deinit() are idempotent resets (they
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
    // (28.3) floating's drag state was never re-armed. It is a process-global
    // like the other two, and a left-active drag is not a cosmetic leak:
    // `startDrag` early-returns while `g_state.drag.active`, so one test that
    // did not end its drag silently disables dragging for every test after it.
    if (build_options.has_floating) {
        @import("floating").resetState();
    }
}

/// The ONE fixture entry: a fresh model on deterministically re-armed
/// process-global module stores. (28.3)
///
/// There used to be two entry points with different guarantees -- `makeModel`
/// (bare) and `setUpModel` (reset first) -- and nothing in the type system said
/// which one a given test needed. Worse, `model_test` had locally aliased
/// `const makeModel = helpers.setUpModel`, so a reader scanning that file saw
/// `makeModel()` and reasonably assumed no reset happened. Reset is now the
/// default, so the bare path is the one you must ask for by name.
pub fn makeModel() model.Model {
    testReset();
    return .{};
}

/// A fresh model with the module stores left ALONE. (28.3)
///
/// Only for the latency files, and the reason is measurement hygiene rather
/// than correctness: `testReset` frees and re-allocates the module stores, and
/// doing that between bench iterations churns the allocator and the cache
/// lines the next timed region is about to read, which is exactly the noise a
/// latency benchmark exists to avoid. Correctness tests must use `makeModel`.
pub fn makeBareModel() model.Model {
    return .{};
}

pub fn regCur(m: *model.Model, win: model.WindowId) void {
    model.register(m, win, null) catch unreachable;
}

pub fn colorOfFocused(win: model.WindowId, m: *const model.Model) u32 {
    return if (m.focused == win) 1 else 0;
}

/// Shared golden-sequence border-pixel convention: the sync and tracking
/// fixtures assert these exact focused/unfocused values, so they live here
/// as the single source instead of a per-file duplicate.
pub const focused_pixel: u32 = 100;
pub const unfocused_pixel: u32 = 200;

/// Configured border width the sync fixture sends on the wire (cfg_bw).
pub const cfg_bw: u16 = 2;

/// Golden-sequence border-color callback: bright border when focused, dim
/// otherwise. Shared by the sync/tracking fixtures (latency benches use the
/// cheaper colorOfFocused instead).
pub fn testColor(win: model.WindowId, m: *const model.Model) u32 {
    return if (m.focused == win) focused_pixel else unfocused_pixel;
}

pub fn makeCtx(
    sink: sinkmod.Sink,
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    screen: model.Rect,
) reconcile.Ctx {
    return .{
        .sink = sink,
        .screen = screen,
        .workarea = screen,
        .color_of = color_of,
        .env = std_env,
    };
}

/// Warms the sync ledger with one steady-state reconcile, then times `iterations`
/// reconciles and returns nanoseconds per reconcile. Shared by the latency
/// benchmarks (the identical warm+bench pattern in the latency tests).
pub fn benchReconcile(m: *model.Model, iterations: usize) f64 {
    var warm = TestSink(.count){};
    var warm_ctx = makeCtx(warm.sink(), colorOfFocused, std_wa);
    reconcile.run(m, &warm_ctx, .{});
    var bench = TestSink(.count){};
    var bench_ctx = makeCtx(bench.sink(), colorOfFocused, std_wa);
    const t0 = time.monotonicNs();
    for (0..iterations) |_| reconcile.run(m, &bench_ctx, .{});
    return @as(f64, @floatFromInt(time.monotonicNs() - t0)) / @as(f64, @floatFromInt(iterations));
}

pub const TestOp = union(enum) {
    map: model.WindowId,
    configure: struct {
        win: model.WindowId,
        rect: ?model.Rect,
        bw: ?u16,
        stack: ?sinkmod.Stack,
    },
    pixel: struct { win: model.WindowId, p: u32 },
    park: model.WindowId,
    stack: struct { win: model.WindowId, s: sinkmod.Stack },
    /// (28.1) The four ops that used to be silent shims. Recording them is what
    /// makes the fullscreen EWMH transition assertable at all: fullscreen.zig
    /// asserts nothing observable about set_state_atom otherwise, because the
    /// test sink swallowed every call.
    ewmh_fullscreen: struct { win: model.WindowId, state_atom: u32, atom: u32, add: bool },
    flush,
    grab_server,
    ungrab_and_flush,
};

pub const SinkMode = enum {
    count,
    category,
    record,
    none,
};

/// Standard test margin/min_dim tuning shared by the sync/tiling fixtures.
pub const std_env: @FieldType(reconcile.Ctx, "env") = .{
    .margins = .{ .gap = 8, .border = 2 },
    .min_dim = 50,
};

/// Canonical config-order layout cycle used by the model, tiling, and window
/// fixtures. Single source of truth so the test layouts list can't drift from
/// the config's accepted set (src/config/config.zig canonical layout names).
pub const std_layout_names = [_][]const u8{ "master", "monocle", "grid", "fibonacci", "leaf", "scroll" };

/// Golden master-layout rects on the standard 800x600 fixture (gap 8 /
/// border 2, default 50/50 split), derived from the shared constants instead
/// of magic literals: any resize of std_wa/std_env propagates to every golden
/// assertion. Formulas mirror tiling/modules/master.zig (totalInset,
/// stackSeamMargin) and the sync/tiling tests rely on exactly this geometry.
pub const std_golden = struct {
    const gap: u16 = std_env.margins.gap; // 8
    const border: u16 = std_env.margins.border; // 2
    /// Outer gap both sides + both borders (master.zig totalInset).
    const total_inset: u16 = gap *| 2 +| border *| 2; // 20
    /// Half-gap toward the stack + row pitch (master.zig stackSeamMargin).
    const seam: u16 = gap / 2 +| (gap +| border *| 2); // 16
    const inner_h: u16 = std_wa.height -| total_inset; // 580
    const split_w: u16 = std_wa.width / 2; // round(800 * 0.5) = 400

    /// Single window filling the master pane.
    pub const single = model.Rect{
        .x = @intCast(gap),
        .y = @intCast(gap),
        .width = std_wa.width -| total_inset,
        .height = inner_h,
    };
    /// Master pane of a two-window 50/50 split.
    pub const master = model.Rect{
        .x = @intCast(gap),
        .y = @intCast(gap),
        .width = split_w -| seam,
        .height = inner_h,
    };
    /// Stack pane of a two-window 50/50 split: origin = master_w, then a
    /// half-gap step; the stack column shrinks by the same seam.
    pub const stack = model.Rect{
        .x = @intCast(split_w +| gap / 2),
        .y = @intCast(gap),
        .width = split_w -| seam,
        .height = inner_h,
    };
    /// Fullscreen rect: the entire work area.
    pub const fullscreen = std_wa;
};

pub fn TestSink(comptime mode: SinkMode) type {
    return struct {
        const Self = @This();

        count: usize = 0,
        map: usize = 0,
        park: usize = 0,
        configure: usize = 0,
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

        // The three configure shapes (geom, geom+border, border-only) are one
        // recorded op now, because at the sink they are one request. Asserting
        // on `.geom` / `.geom_bw` / `.bw` separately would be asserting on an
        // encoding the production shim no longer has.
        fn configureShim(self_ptr: *anyopaque, win: model.WindowId, c: sinkmod.Configure) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.configure, .{ .configure = .{ .win = win, .rect = c.rect, .bw = c.bw, .stack = c.stack } });
        }

        fn pixelShim(self_ptr: *anyopaque, win: model.WindowId, p: u32) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.pixel, .{ .pixel = .{ .win = win, .p = p } });
        }

        fn parkShim(self_ptr: *anyopaque, win: model.WindowId) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.park, .{ .park = win });
        }

        fn stackShim(self_ptr: *anyopaque, win: model.WindowId, s: sinkmod.Stack) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .record) {
                self.ops.append(std.testing.allocator, .{ .stack = .{ .win = win, .s = s } }) catch unreachable;
            }
        }

        fn ewmhShim(
            self_ptr: *anyopaque,
            win: model.WindowId,
            state_atom: u32,
            atom: u32,
            add: bool,
        ) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .record) {
                self.ops.append(
                    std.testing.allocator,
                    .{ .ewmh_fullscreen = .{
                        .win = win,
                        .state_atom = state_atom,
                        .atom = atom,
                        .add = add,
                    } },
                ) catch @panic("test sink: out of memory recording op");
            }
        }

        fn flushShim(self_ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .record) {
                self.ops.append(std.testing.allocator, .flush) catch @panic("test sink: out of memory recording op");
            }
        }

        fn grabShim(self_ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .record) {
                self.ops.append(std.testing.allocator, .grab_server) catch @panic("test sink: out of memory recording op");
            }
        }

        fn ungrabShim(self_ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .record) {
                self.ops.append(std.testing.allocator, .ungrab_and_flush) catch @panic("test sink: out of memory recording op");
            }
        }

        pub fn sink(self: *Self) sinkmod.Sink {
            return .{
                .ptr = self,
                .vt = &.{
                    .map = mapShim,
                    .configure = configureShim,
                    .border_pixel = pixelShim,
                    .park = parkShim,
                    .stack_only = stackShim,
                    .set_state_atom = ewmhShim,
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

        /// Shared tail: the stack mode on op `i`, or its absence.
        fn expectStack(self: *const Self, i: usize, stack: ?sinkmod.Stack) !void {
            const op = self.ops.items[i];
            if (stack) |s| {
                try std.testing.expect(op.configure.stack != null);
                try std.testing.expectEqual(s, op.configure.stack.?);
            } else {
                try std.testing.expect(op.configure.stack == null);
            }
        }

        pub fn expectGeom(
            self: *const Self,
            i: usize,
            win: model.WindowId,
            x: i32,
            y: i32,
            w: u16,
            h: u16,
            stack: ?sinkmod.Stack,
        ) !void {
            comptime if (mode != .record) @compileError("expectGeom requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .configure);
            const c = op.configure;
            try std.testing.expectEqual(win, c.win);
            try std.testing.expect(c.rect != null);
            try std.testing.expectEqual(x, @as(i32, c.rect.?.x));
            try std.testing.expectEqual(y, @as(i32, c.rect.?.y));
            try std.testing.expectEqual(w, c.rect.?.width);
            try std.testing.expectEqual(h, c.rect.?.height);
            // `bw` is deliberately NOT asserted null: geometry and border width
            // are now one request, so a switch that changes both sends one
            // configure carrying both, and this helper only promises the
            // geometry half. `expectBw` is the helper that pins exclusivity.
            try self.expectStack(i, stack);
        }

        pub fn expectGeomRect(
            self: *const Self,
            i: usize,
            win: model.WindowId,
            rect: model.Rect,
            stack: ?sinkmod.Stack,
        ) !void {
            comptime if (mode != .record) @compileError("expectGeomRect requires record mode");
            try self.expectGeom(i, win, rect.x, rect.y, rect.width, rect.height, stack);
        }

        /// Asserts op `i` is the MERGED geometry+border-width request.
        pub fn expectGeomBw(
            self: *const Self,
            i: usize,
            win: model.WindowId,
            rect: model.Rect,
            bw: u16,
            stack: ?sinkmod.Stack,
        ) !void {
            comptime if (mode != .record) @compileError("expectGeomBw requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .configure);
            const c = op.configure;
            try std.testing.expectEqual(win, c.win);
            try std.testing.expect(c.rect != null);
            try std.testing.expectEqual(rect.x, c.rect.?.x);
            try std.testing.expectEqual(rect.y, c.rect.?.y);
            try std.testing.expectEqual(rect.width, c.rect.?.width);
            try std.testing.expectEqual(rect.height, c.rect.?.height);
            try std.testing.expect(c.bw != null);
            try std.testing.expectEqual(bw, c.bw.?);
            try self.expectStack(i, stack);
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
            try std.testing.expect(op == .configure);
            // A border-width-only configure must stay border-width-only: the
            // merged slot could trivially have started dragging a rect along,
            // and a spurious X|Y|W|H on a window whose geometry the WM did not
            // recompute is a real (if small) correctness regression.
            try std.testing.expect(op.configure.bw != null);
            try std.testing.expectEqual(w, op.configure.bw.?);
            try std.testing.expect(op.configure.rect == null);
            try std.testing.expect(op.configure.stack == null);
            try std.testing.expectEqual(win, op.configure.win);
        }

        pub fn expectMap(self: *const Self, i: usize, win: model.WindowId) !void {
            comptime if (mode != .record) @compileError("expectMap requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .map);
            try std.testing.expectEqual(win, op.map);
        }

        /// Asserts op `i` is a `set_state_atom` fullscreen transition. (28.1)
        pub fn expectEwmhFullscreen(
            self: *const Self,
            i: usize,
            win: model.WindowId,
            atom: u32,
            add: bool,
        ) !void {
            comptime if (mode != .record) @compileError("expectEwmhFullscreen requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .ewmh_fullscreen);
            try std.testing.expectEqual(win, op.ewmh_fullscreen.win);
            try std.testing.expectEqual(atom, op.ewmh_fullscreen.atom);
            try std.testing.expectEqual(add, op.ewmh_fullscreen.add);
        }

        /// Asserts op `i` is a bare `flush`. (28.1)
        pub fn expectFlush(self: *const Self, i: usize) !void {
            comptime if (mode != .record) @compileError("expectFlush requires record mode");
            try std.testing.expect(self.ops.items[i] == .flush);
        }

        /// Asserts op `i` is a `grab_server`. (28.1)
        pub fn expectGrab(self: *const Self, i: usize) !void {
            comptime if (mode != .record) @compileError("expectGrab requires record mode");
            try std.testing.expect(self.ops.items[i] == .grab_server);
        }

        /// Asserts op `i` is an `ungrab_and_flush`. (28.1)
        pub fn expectUngrab(self: *const Self, i: usize) !void {
            comptime if (mode != .record) @compileError("expectUngrab requires record mode");
            try std.testing.expect(self.ops.items[i] == .ungrab_and_flush);
        }

        pub fn expectPark(self: *const Self, i: usize, win: model.WindowId) !void {
            comptime if (mode != .record) @compileError("expectPark requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .park);
            try std.testing.expectEqual(win, op.park);
        }
    };
}

// --- 28.2: bench timings go to a FILE, not to stderr ---

/// Appends one bench timing line to `.zig-cache/bench/timings.txt`.
///
/// Why a file and not `std.debug.print`: the Zig test protocol treats any
/// stderr output as a failed command, so the printed numbers made
/// `zig build test -Dbench=true` -- the only way to compile bench mode -- exit
/// non-zero on a fully passing suite. The documented invocation was therefore
/// guaranteed to report failure, and the two bench-only `std.debug.print`
/// sites had in fact gone stale enough to no longer compile (they read fields
/// the test sink does not have, and one referenced a `sink` that was not in
/// scope), which is exactly what happens to a code path nothing can run.
///
/// Writing here instead keeps the numbers, keeps the exit green, and makes the
/// output land somewhere a reader looks for it. Best-effort by design: a
/// timing that cannot be recorded must not fail a test, so every error here is
/// swallowed, exactly as the `note`/`flush` instrumentation is.
/// The one open handle for the timings file, opened on first use.
///
/// (28.2) It has to be ONE handle, not one per call: `createFile` has no
/// append mode, so every fresh handle starts writing at offset 0 and each
/// record overwrote the head of the last one -- which showed up as timings
/// truncated to their own tails ("...=130 (configure=50,map=40)" with the
/// label and the numbers before it gone). Holding the handle for the run makes
/// the position advance naturally, and the test runner executes a binary's
/// tests sequentially, so there is no concurrent writer.
///
/// The handle is intentionally never closed: this is a short-lived test
/// process, and a close would need a teardown hook the test protocol does not
/// offer. One fd at process exit is not worth a shutdown path.
var bench_file: ?std.Io.File = null;

pub fn benchLog(comptime fmt: []const u8, args: anytype) void {
    const io = std.testing.io;
    if (bench_file == null) {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, ".zig-cache/bench") catch return;
        bench_file = cwd.createFile(io, ".zig-cache/bench/timings.txt", .{
            .truncate = false,
            .permissions = @enumFromInt(0o644),
        }) catch return;
    }
    // Append a newline only if the caller's format does not already end in
    // one -- the bench formats all do, and adding another left a blank line
    // between every record.
    var buf: [512]u8 = undefined;
    const with_nl = comptime if (std.mem.endsWith(u8, fmt, "\n")) fmt else fmt ++ "\n";
    const line = std.fmt.bufPrint(&buf, with_nl, args) catch return;
    bench_file.?.writeStreamingAll(io, line) catch return;
}
