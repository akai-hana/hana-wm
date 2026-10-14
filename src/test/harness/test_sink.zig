//! The recording test sink: the `Sink` vtable double the
//! sync/query/tiling fixtures assert through. Modes
//! count/category/record/none; the recording mode implements
//! the full vtable and the `expect*` assertion family, so a
//! fixture asserts on the ops the reconciler ISSUED (the ops
//! are the wire contract, not an oracle re-running the
//! engine). Extracted from helpers.zig (the shared test
//! vocabulary) so the sink framework — its vtable and its
//! assertion DSL — lives apart from the fixtures/goldens/bench
//! plumbing that share that file. Counting modes are
//! category/record/none: `category` (per-op fields + `total`)
//! supersedes the old flat `count`, which could not answer any
//! breakdown question.

const std = @import("std");
const model = @import("model");
const sinkmod = @import("sink");

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
    /// The four ops that used to be silent shims. Recording them is what
    /// makes the fullscreen EWMH transition assertable at all: fullscreen.zig
    /// asserts nothing observable about set_state_atom otherwise, because the
    /// test sink swallowed every call.
    ewmh_fullscreen: struct { win: model.WindowId, state_atom: u32, atom: u32, add: bool },
    flush,
    grab_server,
    ungrab_and_flush,
};

pub const SinkMode = enum {
    category,
    record,
    none,
};

pub fn TestSink(comptime mode: SinkMode) type {
    return struct {
        const Self = @This();

        map: usize = 0,
        park: usize = 0,
        configure: usize = 0,
        pixel: usize = 0,
        stack: usize = 0,
        ewmh_fullscreen: usize = 0,
        flush: usize = 0,
        grab_server: usize = 0,
        ungrab_and_flush: usize = 0,
        total: usize = 0,
        ops: std.ArrayList(TestOp) = .empty,

        /// The ONE counting/recording funnel every shim goes through, so all
        /// ops count in category mode, all ops record in record mode, and
        /// there is exactly one OOM policy (a test-sink append failing is a
        /// test-harness bug worth a named panic, not an unreachables).
        fn bump(self: *Self, comptime tag: std.meta.Tag(TestOp), payload: TestOp) void {
            switch (mode) {
                .record => self.ops.append(std.testing.allocator, payload) catch @panic("test sink: out of memory recording op"),
                .category => {
                    @field(self, @tagName(tag)) += 1;
                    self.total += 1;
                },
                .none => {},
            }
        }

        /// The three unit-payload shims (flush/grab/ungrab): one comptime
        /// factory instead of three copy-pasted bodies.
        fn unitShim(comptime t: std.meta.Tag(TestOp)) fn (*anyopaque) void {
            return struct {
                fn shim(self_ptr: *anyopaque) void {
                    const self: *Self = @ptrCast(@alignCast(self_ptr));
                    self.bump(t, @unionInit(TestOp, @tagName(t), {}));
                }
            }.shim;
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
            self.bump(.stack, .{ .stack = .{ .win = win, .s = s } });
        }

        fn ewmhShim(
            self_ptr: *anyopaque,
            win: model.WindowId,
            state_atom: u32,
            atom: u32,
            add: bool,
        ) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            self.bump(.ewmh_fullscreen, .{ .ewmh_fullscreen = .{
                .win = win,
                .state_atom = state_atom,
                .atom = atom,
                .add = add,
            } });
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
                    .flush = unitShim(.flush),
                    .grab_server = unitShim(.grab_server),
                    .ungrab_and_flush = unitShim(.ungrab_and_flush),
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
            // geometry half.
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

        pub fn expectMap(self: *const Self, i: usize, win: model.WindowId) !void {
            comptime if (mode != .record) @compileError("expectMap requires record mode");
            const op = self.ops.items[i];
            try std.testing.expect(op == .map);
            try std.testing.expectEqual(win, op.map);
        }

        /// Asserts op `i` is a `set_state_atom` fullscreen transition.
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

        /// Asserts op `i` is a bare `flush`.
        pub fn expectFlush(self: *const Self, i: usize) !void {
            comptime if (mode != .record) @compileError("expectFlush requires record mode");
            try std.testing.expect(self.ops.items[i] == .flush);
        }

        /// Asserts op `i` is a `grab_server`.
        pub fn expectGrab(self: *const Self, i: usize) !void {
            comptime if (mode != .record) @compileError("expectGrab requires record mode");
            try std.testing.expect(self.ops.items[i] == .grab_server);
        }

        /// Asserts op `i` is an `ungrab_and_flush`.
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
