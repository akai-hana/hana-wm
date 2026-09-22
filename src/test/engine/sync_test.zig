//! Golden-sequence tests for the sync layer: a recording sink captures every
//! queued request; each scenario asserts the exact op sequence.

const std = @import("std");
const testing = std.testing;

const utils = @import("utils");
const model = @import("model");
const constants = @import("constants");

const sync = @import("sync");
const helpers = @import("helpers");
const build_options = @import("build_options");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};

const cfg_bw = helpers.cfg_bw;
const focused_pixel = helpers.focused_pixel;
const unfocused_pixel = helpers.unfocused_pixel;
const testColor = helpers.testColor;
const golden = helpers.std_golden;

const Recorder = helpers.TestSink(.record);

const Fixture = struct {
    m: model.Model,
    rec: Recorder,
    ctx: sync.Ctx,

    fn init(self: *Fixture) void {
        // setUpModel resets the minimize/fullscreen module stores, so
        // capacity/seq bookkeeping never leaks across scenarios and the
        // tests pass in any order (F-20).
        self.* = .{
            .m = helpers.setUpModel(),
            .rec = .{},
            .ctx = undefined,
        };
        sync.init();
        self.ctx = .{
            .sink = self.rec.sink(),
            .screen = helpers.std_wa,
            .workarea = helpers.std_wa,
            .cfg_bw = cfg_bw,
            .color_of = testColor,
            .env = helpers.std_env,
        };
    }

    fn deinit(self: *Fixture) void {
        self.rec.deinit();
        minimize.deinit();
        sync.init();
    }

    fn reconcile(self: *Fixture, opts: sync.ReconcileOpts) void {
        sync.reconcile(&self.m, &self.ctx, opts);
    }
};

// -- Spawn -----------------------------------------------------------------

test "spawn: first show replays map/pixel/bw/geom ABOVE; steady state delta-sends nothing" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 101);
    model.setFocus(&fx.m, 101);

    fx.reconcile(.{});

    // First send on 800x600 (gap 8 / border 2): ledger empty => "moved" =>
    // winner rides ABOVE; map precedes geometry; border width folds into the
    // geometry request.
    try fx.rec.expectLen(3);
    try fx.rec.expectMap(0, 101);
    try fx.rec.expectPixel(1, 101, focused_pixel);
    try fx.rec.expectGeomBw(2, 101, golden.single, cfg_bw, .above);

    // Steady state: delta-send elides unchanged map/pixel/bw/geom; the server
    // already holds this exact desired state (still re-computed each pass).
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(0);

    // force_restack: only the winner's raise changed, so just the geometry
    // request carrying the merged ABOVE is sent.
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });
    try fx.rec.expectLen(1);
    try fx.rec.expectGeomRect(0, 101, golden.single, .above);
}

// -- Focus color flip --------------------------------------------------------

test "focus change: delta-sends ONLY the two border pixels, no raise" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 201);
    helpers.regCur(&fx.m, 202);
    model.setFocus(&fx.m, 201);
    fx.reconcile(.{}); // baseline: 201 master (winner ABOVE), 202 stack

    model.setFocus(&fx.m, 202);
    fx.rec.clear();
    fx.reconcile(.{});

    // Delta-apply: the focus flip only changes the two border PIXELs; rect,
    // border width, and map are unchanged (elided). No raise: no motion.
    try fx.rec.expectLen(2);
    try fx.rec.expectPixel(0, 201, unfocused_pixel);
    try fx.rec.expectPixel(1, 202, focused_pixel);
}

// -- Fullscreen enter/exit ---------------------------------------------------

test "fullscreen enter: winner fullscreened (rect=screen, bw=0), others parked; exit restores" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 301);
    helpers.regCur(&fx.m, 302);
    model.setFocus(&fx.m, 301);
    fx.reconcile(.{}); // baseline tiled

    _ = fullscreen.toggleFullscreen(&fx.m, 301);
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });

    // 301: full-screen rect, bw=0, pixel=0, ABOVE (visible, not parked, so
    // only pixel/geom+bw sent). 302: ONE merged park request.
    try fx.rec.expectLen(3);
    try fx.rec.expectPixel(0, 301, 0);
    try fx.rec.expectGeomBw(1, 301, golden.fullscreen, 0, .above);
    try fx.rec.expectPark(2, 302);

    _ = fullscreen.toggleFullscreen(&fx.m, 301);
    fx.rec.clear();
    fx.reconcile(.{});

    // Exit restores width AND pixel: 301 moved off the full-screen slot =>
    // pixel+geom+bw (no map: never parked); 302 unparkers => map+geom.
    try fx.rec.expectLen(4);
    try fx.rec.expectPixel(0, 301, focused_pixel);
    try fx.rec.expectGeomBw(1, 301, golden.master, cfg_bw, .above);
    try fx.rec.expectMap(2, 302);
    try fx.rec.expectGeomRect(3, 302, golden.stack, null);
}

test "fullscreen enter keeps sibling geometry, only repositions it off-screen" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 501);
    helpers.regCur(&fx.m, 502);
    model.setFocus(&fx.m, 501);
    fx.reconcile(.{}); // baseline tiled

    // Baseline geometry (master 501 / stack 502) that the sibling must
    // preserve unchanged across the fullscreen session.
    try fx.rec.expectGeomBw(2, 501, golden.master, cfg_bw, .above);
    try fx.rec.expectGeomBw(5, 502, golden.stack, cfg_bw, null);

    _ = fullscreen.toggleFullscreen(&fx.m, 501);
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });

    // 501 owns the screen. 502 gets ONLY the merged park: its size+Y are
    // preserved (X pushed off-screen); 501 sends only its three changed attrs.
    try fx.rec.expectLen(3);
    try fx.rec.expectPixel(0, 501, 0);
    try fx.rec.expectGeomBw(1, 501, golden.fullscreen, 0, .above);
    try fx.rec.expectPark(2, 502);

    // Exiting fullscreen replays 502 at its ORIGINAL geometry — identical
    // size and position, so the sibling never visibly resizes.
    _ = fullscreen.toggleFullscreen(&fx.m, 501);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(4);
    try fx.rec.expectPixel(0, 501, focused_pixel);
    try fx.rec.expectGeomBw(1, 501, golden.master, cfg_bw, .above);
    try fx.rec.expectMap(2, 502);
    try fx.rec.expectGeomRect(3, 502, golden.stack, null);
}

// -- Park / unpark ------------------------------------------------------------

test "minimize parks every pass; restore replays original slot geometry" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 401);
    helpers.regCur(&fx.m, 402);
    model.setFocus(&fx.m, 401);
    fx.reconcile(.{}); // baseline

    try minimize.minimize(&fx.m, 402);
    // Minimizing the stack window grows 401 to full master width (moved =>
    // winner ABOVE); 402 emits ONE merged park request.
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(2);
    try fx.rec.expectGeomRect(0, 401, golden.single, .above);
    try fx.rec.expectPark(1, 402);

    // Idempotent pass while minimized: delta-sends nothing (401 unchanged,
    // 402 already parked), though every desire is still re-computed.
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(0);

    // Restore: 401 shrinks back (moved => winner ABOVE); 402 unparks with
    // map + geometry (pixel/bw preserved across the park).
    minimize.restore(&fx.m, 402);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(3);
    try fx.rec.expectGeomRect(0, 401, golden.master, .above);
    try fx.rec.expectMap(1, 402);
    try fx.rec.expectGeomRect(2, 402, golden.stack, null);
}

// -- Fullscreen -> minimize -> restore -> un-fullscreen ------------------------
// The fullscreen-prev window's saved slot must survive restore, ending fully tiled.
test "fs->min->restore->unfs retiles instead of stranding an orphan" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 601);
    helpers.regCur(&fx.m, 602);
    model.setFocus(&fx.m, 601);
    fx.reconcile(.{}); // baseline tiled: both placed

    // Enter fullscreen: 601 takes the screen (bw=0, pixel=0, ABOVE), 602
    // parks; 601 (visible, not parked) sends only pixel/geom+bw.
    _ = fullscreen.toggleFullscreen(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });
    try fx.rec.expectLen(3);
    try fx.rec.expectPixel(0, 601, 0);
    try fx.rec.expectGeomBw(1, 601, golden.fullscreen, 0, .above);
    try fx.rec.expectPark(2, 602);

    // Minimize FROM fullscreen: 601 parks (its fullscreen record is stored
    // inside prev) - the park transition emits ONE merged park request.
    // 602 - parked by the fullscreen enter - UNPARKS into the full master
    // slot as the fallback winner (m.focused is still 601, but its desire is
    // parked): unpark transition => map + geometry (raise merged: the rect
    // moved too); its pixel/bw were preserved across the park.
    try minimize.minimize(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(3);
    try fx.rec.expectPark(0, 601);
    try fx.rec.expectMap(1, 602);
    try fx.rec.expectGeomRect(2, 602, golden.single, .above);

    // Restore: straight back into fullscreen. 601 replays the
    // fullscreen branch riding its unpark transition (map + geom with .above
    // merged; bw/pixel were already 0 from before). 602 - unparked by the
    // minimize step - parks AGAIN behind the returning fullscreen occupant.
    minimize.restore(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(3);
    try fx.rec.expectMap(0, 601);
    try fx.rec.expectGeomRect(1, 601, golden.fullscreen, .above);
    try fx.rec.expectPark(2, 602);

    // THE REGRESSION GATE - leave fullscreen: 601 returns TILED at its master
    // slot, 602 unparks into its surviving stack slot.
    _ = fullscreen.toggleFullscreen(&fx.m, 601);
    fx.rec.clear();
    fx.reconcile(.{});
    try testing.expectEqual(model.WSId.fromIndex(0), model.findHome(&fx.m, 601).?);
    try fx.rec.expectLen(4);
    try fx.rec.expectPixel(0, 601, focused_pixel);
    try fx.rec.expectGeomBw(1, 601, golden.master, cfg_bw, .above);
    try fx.rec.expectMap(2, 602);
    try fx.rec.expectGeomRect(3, 602, golden.stack, null);
}

// -- Workspace switch (wire shape) -------------------------------------------

test "workspace switch: leavers park, arrivers map + place ABOVE; return unpark raises" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    try model.register(&fx.m, 501, model.WSId.fromIndex(0)); // stays here
    try model.register(&fx.m, 502, model.WSId.fromIndex(1)); // arrives with the switch
    model.setFocus(&fx.m, 501);
    fx.reconcile(.{}); // baseline: 501 placed, 502 parked

    fx.m.current = model.WSId.fromIndex(1);
    fx.rec.clear();
    fx.reconcile(.{ .force_restack = true });

    // 501 leaves: ONE merged park request. 502 arrives first-sight:
    // map -> pixel(color_of focused=501 => unfocused) -> geom+bw(ABOVE,
    // first sight counts as moved; also force_restack).
    try fx.rec.expectLen(4);
    try fx.rec.expectPark(0, 501);
    try fx.rec.expectMap(1, 502);
    try fx.rec.expectPixel(2, 502, unfocused_pixel);
    try fx.rec.expectGeomBw(3, 502, golden.single, cfg_bw, .above);

    // Switch back: 501's ledger kept its rect across the park; returning
    // winner counts as UNPARKED => ABOVE merged into the replay even though
    // the rect itself did not move. 502 parks again.
    // Delta-send elides pixel/bw: 501's focused color equals the value last
    // sent on the baseline pass, and nothing since changed it.
    fx.m.current = model.WSId.fromIndex(0);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(3);
    try fx.rec.expectMap(0, 501);
    try fx.rec.expectGeomRect(1, 501, golden.single, .above);
    try fx.rec.expectPark(2, 502);
}

// -- Multi-tag orphan resurface (ledger read #1) ------------------------------

test "all-view orphan resurfaces at last real rect; history-less orphan parks" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 701); // home ws 0
    model.setFocus(&fx.m, 701);
    fx.m.store.getPtr(701).?.mask |= model.bit(model.WSId.fromIndex(1)); // multi-tag onto ws 1
    fx.reconcile(.{}); // baseline: placed at master slot on ws 0

    // The live rect IS what we last sent (ledger read #3 feeds assertions).
    const real_rect = sync.lastRectFor(701).?;
    try testing.expectEqual(@as(i32, golden.single.x), @as(i32, real_rect.x));
    try testing.expectEqual(@as(u16, golden.single.width), real_rect.width);

    fx.m.current = model.WSId.fromIndex(1);
    fx.rec.clear();
    fx.reconcile(.{});

    // Orphan pass: ws 1's home list is empty so no placement owns 701, but
    // the mask shows it here - kept at its previous REAL geometry
    // (never parks a window with sent history). Even though it is the
    // fallback winner, the raise stays suppressed: same rect, no transition,
    // no restack (winner-raise only-on-change, ledger read #2). Delta-send:
    // the window is already mapped at that rect with that color, so there is
    // nothing to emit.
    try fx.rec.expectLen(0);
    try testing.expectEqual(real_rect, sync.lastRectFor(701).?);

    // History-less variant: registered here with mask bit for ws 1 but NEVER
    // reconciled on its home ws (nothing ever sent): first sighting as an
    // orphan must PARK, not materialize a bogus geometry.
    fx.m.current = model.WSId.fromIndex(0);
    helpers.regCur(&fx.m, 702); // home ws 0
    fx.m.store.getPtr(702).?.mask |= model.bit(model.WSId.fromIndex(1));
    // deliberately no reconcile on ws 0 => 702 has no sent history
    fx.m.current = model.WSId.fromIndex(1);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(1);
    try fx.rec.expectPark(0, 702);
    try testing.expectEqual(@as(?utils.Rect, null), sync.lastRectFor(702));
}

// -- forget() / ledger lifecycle (X ids recycle) ------------------------------

test "forget clears the sent ledger; next pass treats the window as first sight" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    helpers.regCur(&fx.m, 801);
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
    try fx.rec.expectLen(3);
    try fx.rec.expectMap(0, 801);
    try fx.rec.expectPixel(1, 801, focused_pixel);
    try fx.rec.expectGeomBw(2, 801, golden.single, cfg_bw, .above);
}

// -- Ledger index tombstone collision (hash-table probe chain) ----------------
// A tombstone bucket was mistaken for the end of the probe chain, crashing
// when a shared-home-bucket survivor was swap-removed.
test "ledger index: swap-remove across a shared home bucket does not hit tombstones" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    // x and z differ by the index capacity, so they share a home bucket;
    // y sits beside them. Reconcile inserts in ascending-id order.
    const base: model.WindowId = 1000;
    const x = base;
    const y = base + 1;
    const z = base + model.store_capacity;
    helpers.regCur(&fx.m, x);
    helpers.regCur(&fx.m, y);
    helpers.regCur(&fx.m, z);
    model.setFocus(&fx.m, x);
    fx.reconcile(.{});

    // Removing y tombstones its bucket; swap-moving z re-points its probe
    // across that tombstone (pre-fix: `unreachable` stepping over it).
    sync.forget(y);

    // Neither surviving ledger record is lost by the index surgery.
    try testing.expect(sync.sentGet(x) != null);
    try testing.expect(sync.sentGet(z) != null);
}

// Stress the id→slot index: chains of ids sharing a home bucket, removed in
// shuffle order, must stay consistent (no lost entries, no phantom entries)
// after every swap-remove + re-insert cycle.
test "ledger index: swap-remove stress keeps every surviving record findable" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    const base: model.WindowId = 2000;
    // 48 ids that map into the same 12 home buckets (mod capacity 128), so
    // every getOrPut probes through a shared chain.
    const n: usize = 48;
    var win: [n]model.WindowId = undefined;
    for (0..n) |i| win[i] = base + @as(model.WindowId, @intCast(i)) * 3;

    for (0..n) |i| {
        helpers.regCur(&fx.m, win[i]);
    }
    fx.reconcile(.{});

    var present: [n]bool = .{true} ** n;
    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();

    // Remove every window one at a time in random order; after each removal,
    // every still-present window must be findable (and nothing else).
    var remaining = n;
    while (remaining > 1) : (remaining -= 1) {
        // Random survivor to drop this round, then drop it.
        const pick = rand.intRangeAtMost(usize, 0, remaining - 1);
        var k: usize = 0;
        var drop: usize = 0;
        for (0..n) |i| {
            if (present[i]) {
                if (k == pick) {
                    drop = i;
                    break;
                }
                k += 1;
            }
        }
        present[drop] = false;
        sync.forget(win[drop]);

        var found: usize = 0;
        for (0..n) |i| {
            const e = sync.sentGet(win[i]);
            if (present[i]) {
                try testing.expect(e != null);
                try testing.expectEqual(win[i], e.?.id);
                found += 1;
            } else {
                try testing.expect(e == null);
            }
        }
        try testing.expectEqual(remaining - 1, found);
    }
}

// -- Park wire shape ----------------------------------------------------------

test "park: offscreen-X constant, ONE merged request per parked window per pass" {
    var fx: Fixture = undefined;
    fx.init();
    defer fx.deinit();

    // Production Sink.park folds X-offscreen + BELOW into ONE configure:
    // the X value is this constant, the stack half is BELOW (wire.zig).
    try testing.expectEqual(@as(i32, -30000), constants.offscreen_x_position);

    try model.register(&fx.m, 901, model.WSId.fromIndex(0));
    try model.register(&fx.m, 902, model.WSId.fromIndex(1));
    model.setFocus(&fx.m, 901);
    fx.reconcile(.{});

    // Baseline: exactly ONE park op for the parked window - never a separate
    // offscreen configure plus a stack configure.
    try fx.rec.expectLen(4);
    try fx.rec.expectMap(0, 901);
    try fx.rec.expectPixel(1, 901, focused_pixel);
    try fx.rec.expectGeomBw(2, 901, golden.single, cfg_bw, .above);
    try fx.rec.expectPark(3, 902);

    // Steady state: nothing changed since the baseline pass, so delta-send
    // elides every op (901's map/pixel/geom+bw and 902's park were all sent).
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(0);

    // Minimized windows ride the same single-op park shape. Only 901's park
    // is new: 902's park was already sent on the baseline pass.
    try minimize.minimize(&fx.m, 901);
    fx.rec.clear();
    fx.reconcile(.{});
    try fx.rec.expectLen(1);
    try fx.rec.expectPark(0, 901);
}
