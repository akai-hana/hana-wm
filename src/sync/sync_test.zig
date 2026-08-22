//! Golden-sequence tests for the sync layer (WP3 step 2).
//! A recording sink captures every queued request; each scenario asserts the
//! EXACT op sequence against §7.4 steps and the BC gates.

const std = @import("std");
const testing = std.testing;

const utils = @import("utils");
const model = @import("model");

const sync = @import("sync");

const gap = 8;
const border = 2;
const cfg_bw = 2;
const focused_pixel: u32 = 100;
const unfocused_pixel: u32 = 200;

fn testColor(win: model.WindowId, m: *const model.Model) u32 {
    return if (m.focused == win) focused_pixel else unfocused_pixel;
}

fn stdScreen() utils.Rect {
    return .{ .x = 0, .y = 0, .width = 800, .height = 600 };
}

fn stdWa() utils.Rect {
    return .{ .x = 0, .y = 0, .width = 800, .height = 600 };
}

const Op = union(enum) {
    map: model.WindowId,
    geom: struct { win: model.WindowId, rect: utils.Rect, stack: ?sync.Stack },
    bw: struct { win: model.WindowId, w: u16 },
    pixel: struct { win: model.WindowId, p: u32 },
    park: model.WindowId,
    stack: struct { win: model.WindowId, s: sync.Stack },
};

const Recorder = struct {
    ops: std.ArrayList(Op) = .empty,

    fn deinit(self: *Recorder) void {
        self.ops.deinit(testing.allocator);
    }

    fn clear(self: *Recorder) void {
        self.ops.clearRetainingCapacity();
    }

    // -- Sink vtable shims ------------------------------------------------
    fn mapShim(ptr: *anyopaque, win: model.WindowId) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.ops.append(testing.allocator, .{ .map = win }) catch unreachable;
    }
    fn geomShim(ptr: *anyopaque, win: model.WindowId, rect: utils.Rect, stack: ?sync.Stack) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.ops.append(testing.allocator, .{ .geom = .{ .win = win, .rect = rect, .stack = stack } }) catch unreachable;
    }
    fn bwShim(ptr: *anyopaque, win: model.WindowId, w: u16) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.ops.append(testing.allocator, .{ .bw = .{ .win = win, .w = w } }) catch unreachable;
    }
    fn pixelShim(ptr: *anyopaque, win: model.WindowId, p: u32) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.ops.append(testing.allocator, .{ .pixel = .{ .win = win, .p = p } }) catch unreachable;
    }
    fn parkShim(ptr: *anyopaque, win: model.WindowId) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.ops.append(testing.allocator, .{ .park = win }) catch unreachable;
    }
    fn stackShim(ptr: *anyopaque, win: model.WindowId, s: sync.Stack) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        self.ops.append(testing.allocator, .{ .stack = .{ .win = win, .s = s } }) catch unreachable;
    }
    fn flushShim(_: *anyopaque) void {}
    fn grabShim(_: *anyopaque) void {}
    fn ungrabShim(_: *anyopaque) void {}

    fn sink(self: *Recorder) sync.Sink {
        return .{ .ptr = self, .vt = &.{ .map = mapShim, .geom = geomShim, .border_width = bwShim, .border_pixel = pixelShim, .park = parkShim, .stack_only = stackShim, .flush = flushShim, .grab_server = grabShim, .ungrab_and_flush = ungrabShim } };
    }
    // ---------------------------------------------------------------------

    fn expectLen(self: *const Recorder, n: usize) !void {
        try testing.expectEqual(n, self.ops.items.len);
    }

    fn expectGeom(self: *const Recorder, i: usize, win: model.WindowId, x: i32, y: i32, w: u16, h: u16, stack: ?sync.Stack) !void {
        const op = self.ops.items[i];
        try testing.expect(op == .geom);
        try testing.expectEqual(win, op.geom.win);
        try testing.expectEqual(x, @as(i32, op.geom.rect.x));
        try testing.expectEqual(y, @as(i32, op.geom.rect.y));
        try testing.expectEqual(w, op.geom.rect.width);
        try testing.expectEqual(h, op.geom.rect.height);
        if (stack) |s| {
            try testing.expect(op.geom.stack != null);
            try testing.expectEqual(s, op.geom.stack.?);
        } else {
            try testing.expect(op.geom.stack == null);
        }
    }

    fn expectPixel(self: *const Recorder, i: usize, win: model.WindowId, p: u32) !void {
        const op = self.ops.items[i];
        try testing.expect(op == .pixel);
        try testing.expectEqual(win, op.pixel.win);
        try testing.expectEqual(p, op.pixel.p);
    }

    fn expectBw(self: *const Recorder, i: usize, win: model.WindowId, w: u16) !void {
        const op = self.ops.items[i];
        try testing.expect(op == .bw);
        try testing.expectEqual(win, op.bw.win);
        try testing.expectEqual(w, op.bw.w);
    }

    fn expectMap(self: *const Recorder, i: usize, win: model.WindowId) !void {
        const op = self.ops.items[i];
        try testing.expect(op == .map);
        try testing.expectEqual(win, op.map);
    }

    fn expectPark(self: *const Recorder, i: usize, win: model.WindowId) !void {
        const op = self.ops.items[i];
        try testing.expect(op == .park);
        try testing.expectEqual(win, op.park);
    }
};

const Fixture = struct {
    m: model.Model,
    rec: Recorder,
    ctx: sync.Ctx,

    fn init(self: *Fixture, screen: utils.Rect, workarea: utils.Rect) void {
        self.* = .{
            .m = .{ .gpa = testing.allocator },
            .rec = .{},
            .ctx = undefined,
        };
        sync.init(testing.allocator);
        self.ctx = .{
            .sink = self.rec.sink(),
            .screen = screen,
            .workarea = workarea,
            .cfg_bw = cfg_bw,
            .color_of = testColor,
            .env = .{ .margins = .{ .gap = gap, .border = border }, .min_dim = 50 },
        };
    }

    fn deinit(self: *Fixture) void {
        for (&self.m.ws) |*s| {
            s.tiled_order.deinit(self.m.gpa);
            s.focus_mru.deinit(self.m.gpa);
        }
        self.rec.deinit();
        sync.deinit();
    }

    fn reconcile(self: *Fixture, opts: sync.ReconcileOpts) void {
        sync.reconcile(&self.m, &self.ctx, opts);
    }
};

// -- Spawn -----------------------------------------------------------------

test "spawn: first-sight full sequence pixel -> bw -> geom(+ABOVE winner); idempotent re-run" {
    var fx: Fixture = undefined;
    fx.init(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .x = 0, .y = 0, .width = 800, .height = 600 });
    defer fx.deinit();

    model.register(&fx.m, 101, null);
    model.setFocus(&fx.m, 101);

    fx.reconcile(.{});

    // Master layout single window on 800x600 with gap 8 / border 2.
    // First sight also maps (mapped=false until proven; harmless no-op when
    // the window is already mapped server-side).
    try fx.rec.expectLen(4);
    try fx.rec.expectMap(0, 101);
    try fx.rec.expectPixel(1, 101, focused_pixel);
    try fx.rec.expectBw(2, 101, cfg_bw);
    try fx.rec.expectGeom(3, 101, 8, 8, 780, 580, .above);

    // Unchanged state => zero deltas on the next batch (step 6 diff-only).
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(0);
}

// -- Focus color flip --------------------------------------------------------

test "focus change: color-only diffs, no geometry, no border width" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 201, null);
    model.register(&fx.m, 202, null);
    model.setFocus(&fx.m, 201);
    fx.reconcile(.{}); // establish baseline

    model.setFocus(&fx.m, 202);
    fx.rec.clear();
    fx.reconcile(.{});

    // Store order 201 then 202; only pixels move. Winner (202) gets no
    // standalone raise without force_restack (scheduling table: focus change
    // is the scheduled color-only class).
    try fx.rec.expectLen(2);
    try fx.rec.expectPixel(0, 201, unfocused_pixel);
    try fx.rec.expectPixel(1, 202, focused_pixel);
}

// -- Fullscreen enter/exit ---------------------------------------------------

test "fullscreen enter: winner fullscreened, others parked; exit restores" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 301, null);
    model.register(&fx.m, 302, null);
    model.setFocus(&fx.m, 301);
    fx.reconcile(.{}); // baseline tiled

    _ = model.toggleFullscreen(&fx.m, 301);
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });

    // 301: fullscreen branch -> full-screen rect, bw=0, pixel=0, ABOVE merged.
    // 302: parked transition -> ONE merged park request.
    // Order follows store seq with per-window pixel -> bw -> geometry.
    try fx.rec.expectLen(4);
    try fx.rec.expectPixel(0, 301, 0);
    try fx.rec.expectBw(1, 301, 0);
    try fx.rec.expectGeom(2, 301, 0, 0, 800, 600, .above);
    try fx.rec.expectPark(3, 302);

    // Exit restores width AND pixel (BC14 hard gate); 302 unparks with a
    // full replay (unpark transitions always resend geometry).
    _ = model.toggleFullscreen(&fx.m, 301);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(6);
    try fx.rec.expectPixel(0, 301, focused_pixel);
    try fx.rec.expectBw(1, 301, cfg_bw);
    try fx.rec.expectGeom(2, 301, 8, 8, 384, 580, .above);
    try fx.rec.expectPixel(3, 302, unfocused_pixel);
    try fx.rec.expectBw(4, 302, cfg_bw);
    try fx.rec.expectGeom(5, 302, 404, 8, 384, 580, null);
}

// -- Park / unpark ------------------------------------------------------------

test "minimize parks; restore replays original slot geometry" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 401, null);
    model.register(&fx.m, 402, null);
    model.setFocus(&fx.m, 401);
    fx.reconcile(.{}); // baseline

    model.minimize(&fx.m, 402) catch unreachable;
    // Minimizing the stack window also grows 401 to full master width:
    // [geom(401, winner ABOVE), park(402)] in store-seq order.
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(2);
    try fx.rec.expectGeom(0, 401, 8, 8, 780, 580, .above);
    try fx.rec.expectPark(1, 402);

    // Already parked: no repeat request.
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(0);

    // Restore: 401 shrinks back; 402's unpark transition forces a full
    // pixel -> bw -> geometry replay to its original slot.
    model.restore(&fx.m, 402);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(4);
    try fx.rec.expectGeom(0, 401, 8, 8, 384, 580, .above);
    try fx.rec.expectPixel(1, 402, unfocused_pixel);
    try fx.rec.expectBw(2, 402, cfg_bw);
    try fx.rec.expectGeom(3, 402, 404, 8, 384, 580, null);
}

// -- Workspace switch (train c wire shape) -----------------------------------

test "workspace switch: leavers park once, arrivers map + place; return trip diffs" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 501, 0); // stays here
    model.register(&fx.m, 502, 1); // arrives with the switch
    model.setFocus(&fx.m, 501);
    fx.reconcile(.{}); // baseline: only 501 visible
    fx.rec.clear();

    fx.m.current = 1;
    fx.reconcile(.{ .force_restack = true });

    // 501 leaves: ONE merged park request. 502 arrives: map -> pixel -> bw ->
    // geom(+ABOVE winner). Store-seq order puts 501 first.
    // 502 is the only non-parked desire => fallback winner => ABOVE merged;
    // its pixel uses color_of(m.focused=501) => unfocused.
    try fx.rec.expectLen(5);
    try fx.rec.expectPark(0, 501);
    try fx.rec.expectMap(1, 502);
    try fx.rec.expectPixel(2, 502, unfocused_pixel);
    try fx.rec.expectBw(3, 502, cfg_bw);
    try fx.rec.expectGeom(4, 502, 8, 8, 780, 580, .above);

    // Switch back: 501 unparks with full replay (focused => ABOVE merged),
    // 502 parks. No map either way (both already mapped).
    fx.m.current = 0;
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(4);
    try fx.rec.expectPixel(0, 501, focused_pixel);
    try fx.rec.expectBw(1, 501, cfg_bw);
    try fx.rec.expectGeom(2, 501, 8, 8, 780, 580, .above);
    try fx.rec.expectPark(3, 502);
}
