//! Golden-sequence tests for the sync layer.
//! A recording sink captures every queued request; each scenario asserts the
//! EXACT op sequence under UNCONDITIONAL APPLY: every reconcile pass replays
//! park/map/pixel/bw/geometry for every stored window (X configure/map
//! requests are idempotent, so full replay is drift-proof by construction).
//! Parks are ONE merged request per parked window per pass; map precedes
//! geometry so a first-show/unparking client exposes at its final rect.
//! The winner rides .above ONLY when its geometry moved, when it unparked,
//! or under restack pressure - derived from the sent ledger ({rect,
//! has_rect, parked}), never remembered separately; the ledger is otherwise
//! write-only bookkeeping.

const std = @import("std");
const testing = std.testing;

const utils = @import("utils");
const model = @import("model");
const constants = @import("constants");

const sync = @import("sync");
const build_options = @import("build_options");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};

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
            .m = .{},
            .rec = .{},
            .ctx = undefined,
        };
        sync.init();
        // Reset the minimize module's static store so capacity/seq bookkeeping
        // never leaks across scenarios (sync drives it via minimize.minimize).
        minimize.init() catch unreachable;
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
        self.rec.deinit();
        minimize.deinit();
        sync.deinit();
    }

    fn reconcile(self: *Fixture, opts: sync.ReconcileOpts) void {
        sync.reconcile(&self.m, &self.ctx, opts);
    }
};

// -- Spawn -----------------------------------------------------------------

test "spawn: first show replays map/pixel/bw/geom ABOVE; steady state re-sends without raising" {
    var fx: Fixture = undefined;
    fx.init(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .x = 0, .y = 0, .width = 800, .height = 600 });
    defer fx.deinit();

    model.register(&fx.m, 101, null) catch unreachable;
    model.setFocus(&fx.m, 101);

    fx.reconcile(.{});

    // Master layout single window on 800x600 with gap 8 / border 2.
    // First send: ledger holds nothing => "moved" => winner rides ABOVE.
    // map precedes geometry so the client exposes at its final rect.
    try fx.rec.expectLen(4);
    try fx.rec.expectMap(0, 101);
    try fx.rec.expectPixel(1, 101, focused_pixel);
    try fx.rec.expectBw(2, 101, cfg_bw);
    try fx.rec.expectGeom(3, 101, 8, 8, 780, 580, .above);

    // Steady state: UNCONDITIONAL replay - same configure every pass, but
    // NO raise: the winner did not move, did not unpark, no restack pressure
    // (raising on mere presence re-creates a crossing-event storm).
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(4);
    try fx.rec.expectMap(0, 101);
    try fx.rec.expectPixel(1, 101, focused_pixel);
    try fx.rec.expectBw(2, 101, cfg_bw);
    try fx.rec.expectGeom(3, 101, 8, 8, 780, 580, null);

    // force_restack: replay carries the explicit winner raise again.
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });
    try fx.rec.expectLen(4);
    try fx.rec.expectMap(0, 101);
    try fx.rec.expectPixel(1, 101, focused_pixel);
    try fx.rec.expectBw(2, 101, cfg_bw);
    try fx.rec.expectGeom(3, 101, 8, 8, 780, 580, .above);
}

// -- Focus color flip --------------------------------------------------------

test "focus change: both windows fully replayed, only pixels differ, no raise" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 201, null) catch unreachable;
    model.register(&fx.m, 202, null) catch unreachable;
    model.setFocus(&fx.m, 201);
    fx.reconcile(.{}); // baseline: 201 master (winner ABOVE), 202 stack

    model.setFocus(&fx.m, 202);
    fx.rec.clear();
    fx.reconcile(.{});

    // Unconditional apply: BOTH windows replay all four requests in store
    // order; only the two pixels differ from last pass. No raise on either
    // window: no motion, no transitions, no restack.
    try fx.rec.expectLen(8);
    try fx.rec.expectMap(0, 201);
    try fx.rec.expectPixel(1, 201, unfocused_pixel);
    try fx.rec.expectBw(2, 201, cfg_bw);
    try fx.rec.expectGeom(3, 201, 8, 8, 384, 580, null);
    try fx.rec.expectMap(4, 202);
    try fx.rec.expectPixel(5, 202, focused_pixel);
    try fx.rec.expectBw(6, 202, cfg_bw);
    try fx.rec.expectGeom(7, 202, 404, 8, 384, 580, null);
}

// -- Fullscreen enter/exit ---------------------------------------------------

test "fullscreen enter: winner fullscreened (rect=screen, bw=0), others parked; exit restores" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 301, null) catch unreachable;
    model.register(&fx.m, 302, null) catch unreachable;
    model.setFocus(&fx.m, 301);
    fx.reconcile(.{}); // baseline tiled

    _ = fullscreen.toggleFullscreen(&fx.m, 301);
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });

    // 301: fullscreen branch -> full-screen rect, bw=0, pixel=0, ABOVE
    // (force_restack). 302: ONE merged park request.
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 301);
    try fx.rec.expectPixel(1, 301, 0);
    try fx.rec.expectBw(2, 301, 0);
    try fx.rec.expectGeom(3, 301, 0, 0, 800, 600, .above);
    try fx.rec.expectPark(4, 302);

    _ = fullscreen.toggleFullscreen(&fx.m, 301);
    fx.rec.clear();
    fx.reconcile(.{});

    // Exit restores width AND pixel. 301: moved off the
    // screen-sized fullscreen slot => winner raise merged. 302: unparked =>
    // map + appearance + geometry replay at its surviving slot (stack null:
    // not moved, not the winner).
    try fx.rec.expectLen(8);
    try fx.rec.expectMap(0, 301);
    try fx.rec.expectPixel(1, 301, focused_pixel);
    try fx.rec.expectBw(2, 301, cfg_bw);
    try fx.rec.expectGeom(3, 301, 8, 8, 384, 580, .above);
    try fx.rec.expectMap(4, 302);
    try fx.rec.expectPixel(5, 302, unfocused_pixel);
    try fx.rec.expectBw(6, 302, cfg_bw);
    try fx.rec.expectGeom(7, 302, 404, 8, 384, 580, null);
}

// -- Park / unpark ------------------------------------------------------------

test "minimize parks every pass; restore replays original slot geometry" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 401, null) catch unreachable;
    model.register(&fx.m, 402, null) catch unreachable;
    model.setFocus(&fx.m, 401);
    fx.reconcile(.{}); // baseline

    minimize.minimize(&fx.m, 402) catch unreachable;
    // Minimizing the stack window also grows 401 to full master width
    // (moved => winner ABOVE); 402 emits ONE merged park request.
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 401);
    try fx.rec.expectPixel(1, 401, focused_pixel);
    try fx.rec.expectBw(2, 401, cfg_bw);
    try fx.rec.expectGeom(3, 401, 8, 8, 780, 580, .above);
    try fx.rec.expectPark(4, 402);

    // Idempotent pass while minimized: 401 replays unchanged (no raise),
    // 402's park REPLAYS too (unconditional apply; a park request is just an
    // idempotent configure, so re-sending it is safe and repairs drift).
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 401);
    try fx.rec.expectPixel(1, 401, focused_pixel);
    try fx.rec.expectBw(2, 401, cfg_bw);
    try fx.rec.expectGeom(3, 401, 8, 8, 780, 580, null);
    try fx.rec.expectPark(4, 402);

    // Restore: 401 shrinks back (moved => winner ABOVE); 402 unparks: map +
    // appearance + geometry at its surviving slot rect (not winner, rect did
    // not move => no raise, stack null).
    minimize.restore(&fx.m, 402);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(8);
    try fx.rec.expectMap(0, 401);
    try fx.rec.expectPixel(1, 401, focused_pixel);
    try fx.rec.expectBw(2, 401, cfg_bw);
    try fx.rec.expectGeom(3, 401, 8, 8, 384, 580, .above);
    try fx.rec.expectMap(4, 402);
    try fx.rec.expectPixel(5, 402, unfocused_pixel);
    try fx.rec.expectBw(6, 402, cfg_bw);
    try fx.rec.expectGeom(7, 402, 404, 8, 384, 580, null);
}

// -- Fullscreen -> minimize -> restore -> un-fullscreen (user bug report) ----
//
// The model used to DROP the fullscreen-prev window's saved slot on restore,
// so the final exit-fullscreen left it base-tiled but home-less: sync's
// orphan branch kept it at its stale screen-sized geometry while the
// remaining window retook master - an untileable, engine-invisible window.
// With the slot re-added, the same sequence must end fully tiled.
test "fs->min->restore->unfs retiles instead of stranding an orphan" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 601, null) catch unreachable;
    model.register(&fx.m, 602, null) catch unreachable;
    model.setFocus(&fx.m, 601);
    fx.reconcile(.{}); // baseline tiled: both placed

    // Enter fullscreen: 601 takes the screen (rect=screen, bw=0, pixel=0,
    // ABOVE under force_restack), 602 parks.
    _ = fullscreen.toggleFullscreen(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 601);
    try fx.rec.expectPixel(1, 601, 0);
    try fx.rec.expectBw(2, 601, 0);
    try fx.rec.expectGeom(3, 601, 0, 0, 800, 600, .above);
    try fx.rec.expectPark(4, 602);

    // Minimize FROM fullscreen: 601 parks (its fullscreen record is stored
    // inside prev) - parked windows emit ONLY the one merged park request.
    // 602 - parked by the fullscreen enter - UNPARKS into the full master
    // slot as the fallback winner (m.focused is still 601, but its desire is
    // parked): unpark transition => map+appearance+geometry replay, raise
    // merged (the rect moved too).
    try minimize.minimize(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(5);
    try fx.rec.expectPark(0, 601);
    try fx.rec.expectMap(1, 602);
    try fx.rec.expectPixel(2, 602, unfocused_pixel);
    try fx.rec.expectBw(3, 602, cfg_bw);
    try fx.rec.expectGeom(4, 602, 8, 8, 780, 580, .above);

    // Restore: straight back into fullscreen. 601 replays the
    // fullscreen branch riding its unpark transition (.above); 602 -
    // unparked by the minimize step - parks AGAIN behind the returning
    // fullscreen occupant.
    minimize.restore(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 601);
    try fx.rec.expectPixel(1, 601, 0);
    try fx.rec.expectBw(2, 601, 0);
    try fx.rec.expectGeom(3, 601, 0, 0, 800, 600, .above);
    try fx.rec.expectPark(4, 602);

    // THE REGRESSION GATE - leave fullscreen. 601 must come back TILED at
    // its master slot (384x580 @ 8,8, winner ABOVE: moved off the screen
    // rect). 602 unparks into its surviving stack slot with the full
    // map+appearance+geometry replay (stack null: not the winner).
    // Pre-fix this emitted NO geometry for 601 at all: the orphan branch
    // kept the stale 800x600 fullscreen rect while 602 wrongly kept the
    // full-width master rect - an engine-invisible, untileable window.
    _ = fullscreen.toggleFullscreen(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{});
    try testing.expectEqual(@as(model.WSId, 0), model.findHome(&fx.m, 601).?);
    try fx.rec.expectLen(8);
    try fx.rec.expectMap(0, 601);
    try fx.rec.expectPixel(1, 601, focused_pixel);
    try fx.rec.expectBw(2, 601, cfg_bw);
    try fx.rec.expectGeom(3, 601, 8, 8, 384, 580, .above);
    try fx.rec.expectMap(4, 602);
    try fx.rec.expectPixel(5, 602, unfocused_pixel);
    try fx.rec.expectBw(6, 602, cfg_bw);
    try fx.rec.expectGeom(7, 602, 404, 8, 384, 580, null);
}

// -- Workspace switch (wire shape) -------------------------------------------

test "workspace switch: leavers park, arrivers map + place ABOVE; return unpark raises" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 501, 0) catch unreachable; // stays here
    model.register(&fx.m, 502, 1) catch unreachable; // arrives with the switch
    model.setFocus(&fx.m, 501);
    fx.reconcile(.{}); // baseline: 501 placed, 502 parked

    fx.m.current = 1;
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });

    // 501 leaves: ONE merged park request. 502 arrives first-sight:
    // map -> pixel(color_of focused=501 => unfocused) -> bw -> geom(ABOVE,
    // first sight counts as moved; also force_restack).
    try fx.rec.expectLen(5);
    try fx.rec.expectPark(0, 501);
    try fx.rec.expectMap(1, 502);
    try fx.rec.expectPixel(2, 502, unfocused_pixel);
    try fx.rec.expectBw(3, 502, cfg_bw);
    try fx.rec.expectGeom(4, 502, 8, 8, 780, 580, .above);

    // Switch back: 501's ledger kept its rect across the park; returning
    // winner counts as UNPARKED => ABOVE merged into the replay even though
    // the rect itself did not move. 502 parks again.
    fx.m.current = 0;
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 501);
    try fx.rec.expectPixel(1, 501, focused_pixel);
    try fx.rec.expectBw(2, 501, cfg_bw);
    try fx.rec.expectGeom(3, 501, 8, 8, 780, 580, .above);
    try fx.rec.expectPark(4, 502);
}

// -- Multi-tag orphan resurface (ledger read #1) ------------------------------

test "all-view orphan resurfaces at last real rect; history-less orphan parks" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 701, null) catch unreachable; // home ws 0
    model.setFocus(&fx.m, 701);
    fx.m.store.getPtr(701).?.mask |= model.bit(1); // multi-tag onto ws 1
    fx.reconcile(.{}); // baseline: placed at master slot on ws 0

    // The live rect IS what we last sent (ledger read #3 feeds assertions).
    const real_rect = sync.lastRectFor(701).?;
    try testing.expectEqual(@as(i32, 8), @as(i32, real_rect.x));
    try testing.expectEqual(@as(u16, 780), real_rect.width);

    fx.m.current = 1;
    fx.rec.clear();
    fx.reconcile(.{});

    // Orphan pass: ws 1's home list is empty so no placement owns 701, but
    // the mask shows it here - kept at its previous REAL geometry
    // (never parks a window with sent history). Even though it is the
    // fallback winner, the raise stays suppressed: same rect, no transition,
    // no restack (winner-raise only-on-change, ledger read #2).
    try fx.rec.expectLen(4);
    try fx.rec.expectMap(0, 701);
    try fx.rec.expectPixel(1, 701, focused_pixel);
    try fx.rec.expectBw(2, 701, cfg_bw);
    try fx.rec.expectGeom(3, 701, 8, 8, 780, 580, null);
    try testing.expectEqual(real_rect, sync.lastRectFor(701).?);

    // History-less variant: registered here with mask bit for ws 1 but NEVER
    // reconciled on its home ws (nothing ever sent): first sighting as an
    // orphan must PARK, not materialize a bogus geometry.
    fx.m.current = 0;
    model.register(&fx.m, 702, null) catch unreachable; // home ws 0
    fx.m.store.getPtr(702).?.mask |= model.bit(1);
    // deliberately no reconcile on ws 0 => 702 has no sent history
    fx.m.current = 1;
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 701);
    try fx.rec.expectPixel(1, 701, focused_pixel);
    try fx.rec.expectBw(2, 701, cfg_bw);
    try fx.rec.expectGeom(3, 701, 8, 8, 780, 580, null);
    try fx.rec.expectPark(4, 702);
    try testing.expectEqual(@as(?utils.Rect, null), sync.lastRectFor(702));
}

// -- forget() / ledger lifecycle (X ids recycle) ------------------------------

test "forget clears the sent ledger; next pass treats the window as first sight" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    model.register(&fx.m, 801, null) catch unreachable;
    model.setFocus(&fx.m, 801);
    fx.reconcile(.{});
    try testing.expect(sync.lastRectFor(801) != null);

    // truthRect prefers the floating anchor once the model says floating
    // (ledger read #3 contract: actions' detach base).
    const float_rect: utils.Rect = .{ .x = 42, .y = 43, .width = 300, .height = 200 };
    fx.m.store.getPtr(801).?.anchor = .{ .floating = float_rect };
    try testing.expectEqual(@as(?utils.Rect, float_rect), sync.truthRect(&fx.m, 801));
    fx.m.store.getPtr(801).?.anchor = .tiled;

    sync.forget(801);
    try testing.expectEqual(@as(?utils.Rect, null), sync.lastRectFor(801));

    // Ledger gone => first_send => moved => winner raise replays exactly
    // like first sight. This is why stale records MUST die with unmanage:
    // a recycled X id would otherwise inherit the previous incarnation's
    // geometry through the orphan keep-last branch.
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(4);
    try fx.rec.expectMap(0, 801);
    try fx.rec.expectPixel(1, 801, focused_pixel);
    try fx.rec.expectBw(2, 801, cfg_bw);
    try fx.rec.expectGeom(3, 801, 8, 8, 780, 580, .above);
}

// -- Park wire shape ----------------------------------------------------------

test "park: offscreen-X constant, ONE merged request per parked window per pass" {
    var fx: Fixture = undefined;
    fx.init(stdScreen(), stdWa());
    defer fx.deinit();

    // Production Sink.park folds X-offscreen + BELOW into ONE configure:
    // the X value is this constant, the stack half is BELOW (wire.zig).
    try testing.expectEqual(@as(i32, -30000), constants.offscreen_x_position);

    model.register(&fx.m, 901, 0) catch unreachable;
    model.register(&fx.m, 902, 1) catch unreachable;
    model.setFocus(&fx.m, 901);
    fx.reconcile(.{});

    // Baseline: exactly ONE park op for the parked window - never a separate
    // offscreen configure plus a stack configure.
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 901);
    try fx.rec.expectPixel(1, 901, focused_pixel);
    try fx.rec.expectBw(2, 901, cfg_bw);
    try fx.rec.expectGeom(3, 901, 8, 8, 780, 580, .above);
    try fx.rec.expectPark(4, 902);

    // Parks replay every pass (idempotent configure), still one op each.
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(5);
    try fx.rec.expectMap(0, 901);
    try fx.rec.expectPixel(1, 901, focused_pixel);
    try fx.rec.expectBw(2, 901, cfg_bw);
    try fx.rec.expectGeom(3, 901, 8, 8, 780, 580, null);
    try fx.rec.expectPark(4, 902);

    // Minimized windows ride the same single-op park shape.
    minimize.minimize(&fx.m, 901) catch unreachable;
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(2);
    try fx.rec.expectPark(0, 901);
    try fx.rec.expectPark(1, 902);
}
