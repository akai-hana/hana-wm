const std = @import("std");
const model = @import("model");
const utils = @import("utils");
const sync = @import("sync");
const linux = std.os.linux;

pub fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

pub fn makeModel() model.Model {
    return .{};
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
        .env = .{ .margins = .{ .gap = 8, .border = 2 }, .min_dim = 50 },
    };
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
    parks,
    category,
    record,
};

pub fn TestSink(comptime mode: SinkMode) type {
    return struct {
        const Self = @This();

        count: usize = 0,
        map: usize = 0,
        park: usize = 0,
        geom: usize = 0,
        bw: usize = 0,
        pixel: usize = 0,
        grab: usize = 0,
        total: usize = 0,
        ops: std.ArrayList(TestOp) = .empty,

        fn mapShim(self_ptr: *anyopaque, win: model.WindowId) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            switch (mode) {
                .record => self.ops.append(std.testing.allocator, .{ .map = win }) catch unreachable,
                .count => self.count += 1,
                .category => {
                    self.map += 1;
                    self.total += 1;
                },
                .parks => {},
            }
        }

        fn geomShim(self_ptr: *anyopaque, win: model.WindowId, rect: utils.Rect, stack: ?sync.Stack) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            switch (mode) {
                .record => self.ops.append(std.testing.allocator, .{ .geom = .{ .win = win, .rect = rect, .stack = stack } }) catch unreachable,
                .count => self.count += 1,
                .category => {
                    self.geom += 1;
                    self.total += 1;
                },
                .parks => {},
            }
        }

        fn bwShim(self_ptr: *anyopaque, win: model.WindowId, w: u16) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            switch (mode) {
                .record => self.ops.append(std.testing.allocator, .{ .bw = .{ .win = win, .w = w } }) catch unreachable,
                .count => self.count += 1,
                .category => {
                    self.bw += 1;
                    self.total += 1;
                },
                .parks => {},
            }
        }

        fn pixelShim(self_ptr: *anyopaque, win: model.WindowId, p: u32) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            switch (mode) {
                .record => self.ops.append(std.testing.allocator, .{ .pixel = .{ .win = win, .p = p } }) catch unreachable,
                .count => self.count += 1,
                .category => {
                    self.pixel += 1;
                    self.total += 1;
                },
                .parks => {},
            }
        }

        fn parkShim(self_ptr: *anyopaque, win: model.WindowId) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            switch (mode) {
                .record => self.ops.append(std.testing.allocator, .{ .park = win }) catch unreachable,
                .count => self.count += 1,
                .category => {
                    self.park += 1;
                    self.total += 1;
                },
                .parks => self.count += 1,
            }
        }

        fn stackShim(self_ptr: *anyopaque, win: model.WindowId, s: sync.Stack) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .record) {
                self.ops.append(std.testing.allocator, .{ .stack = .{ .win = win, .s = s } }) catch unreachable;
            }
        }

        fn ewmhShim(_: *anyopaque, _: model.WindowId, _: u32, _: u32, _: bool) void {}
        fn flushShim(_: *anyopaque) void {}
        fn grabShim(self_ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(self_ptr));
            if (mode == .category) self.grab += 1;
        }
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

        pub fn reset(self: *Self) void {
            self.* = .{};
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
