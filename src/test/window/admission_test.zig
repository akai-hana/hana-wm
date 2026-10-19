//! Headless admission-policy tests: the class-rule map merge and the
//! WM_CLASS match are pure (buildRulesMapFrom and matchRule take the map as
//! a parameter), so neither needs an X server nor live WM state -- the
//! "testable without a server" split admission.zig documents.

const std = @import("std");
const testing = std.testing;

const admission = @import("admission");
const types = @import("types");
const model = @import("model");
const core = @import("core");
const composed = @import("composed");
const focus = @import("focus");

test "admission rules: one map holds float and workspace rules; first rule wins" {
    var map: std.StringHashMapUnmanaged(?u8) = .{};
    defer map.deinit(testing.allocator);
    const rules = [_]types.Rule{
        .{ .class_name = "Navigator", .workspace = 2, .float = false },
        // Same name again, later: must NOT overwrite the workspace target.
        .{ .class_name = "Navigator", .workspace = 5, .float = true },
        .{ .class_name = "mpv", .workspace = 0, .float = true },
        // A float rule already won for this name: must NOT become tiled.
        .{ .class_name = "mpv", .workspace = 4, .float = false },
        .{ .class_name = "Alacritty", .workspace = 7, .float = false },
    };
    admission.buildRulesMapFrom(&map, testing.allocator, &rules);

    try testing.expectEqual(@as(?u8, 2), map.get("Navigator").?);
    try testing.expectEqual(@as(?u8, 7), map.get("Alacritty").?);
    // Float rules live in the same map as a null VALUE, not as absence:
    // get() must return an outer-present / inner-null pair.
    const mpv = map.get("mpv");
    try testing.expect(mpv != null);
    try testing.expectEqual(@as(?u8, null), mpv.?);
    try testing.expectEqual(@as(usize, 3), map.count());
    try testing.expect(map.get("no-such-class") == null);
}

test "admission matchRule: class before instance, per-key outcome, no match is null" {
    var map: std.StringHashMapUnmanaged(?u8) = .{};
    defer map.deinit(testing.allocator);
    const rules = [_]types.Rule{
        .{ .class_name = "Navigator", .workspace = 1, .float = false },
        .{ .class_name = "mpv", .workspace = 0, .float = true },
    };
    admission.buildRulesMapFrom(&map, testing.allocator, &rules);

    // Class hit wins outright, even when the instance would hit another key.
    const cls = admission.matchRule(&map, "mpv", "Navigator").?;
    try testing.expectEqual(@as(?u8, 1), cls.workspace);
    try testing.expect(!cls.float);

    // Class miss falls through to the instance key.
    const inst = admission.matchRule(&map, "Navigator", "missing-class").?;
    try testing.expectEqual(@as(?u8, 1), inst.workspace);
    try testing.expect(!inst.float);

    // Empty class goes straight to the instance; float outcome is explicit.
    const flt = admission.matchRule(&map, "mpv", "").?;
    try testing.expect(flt.float);
    try testing.expectEqual(@as(?u8, null), flt.workspace);

    // Unknown in both slots: no rule at all.
    try testing.expect(admission.matchRule(&map, "x", "y") == null);
}

// P1-16: pin the primary-fifo/lifo spawn placement (the decision behind
// admission.mapRequest's reorder call). fifo = the new window takes the head
// slot (index 0); lifo = append at the tail (no reorder). Both variants and
// the empty/single-window guards are pure, so this needs no X server.
test "admission spawnPlacementTarget: fifo -> head (0), lifo -> tail (null)" {
    if (!@import("build_options").has_tiling) return;
    const contract = @import("tiling_contract");
    const tiling = @import("tiling");

    var m: model.Model = .{};
    const home = model.WSId.fromIndex(0);
    const ms_kind = tiling.layoutByName("master-stack") orelse return;
    const ms = contract.moduleOf(ms_kind) orelse return;
    const fifo_v = ms.fifo_variant orelse return;
    // The lifo variant is the one the table does NOT name as fifo.
    const lifo_v: u8 = if (fifo_v == 0) 1 else 0;

    // Seed two tiled windows so the head slot is genuinely occupied.
    try testing.expect(m.ws[home.index].tiled_order.append(10));
    try testing.expect(m.ws[home.index].tiled_order.append(11));
    try testing.expectEqual(@as(usize, 2), m.ws[home.index].tiled_order.len);

    // fifo variant active: a spawn reorders to the head slot.
    m.ws[home.index].params = .{ .kind = ms_kind, .variant_idx = fifo_v };
    try testing.expectEqual(@as(?usize, 0), admission.spawnPlacementTarget(&m, home));

    // lifo variant active: no reorder; the new window appends at the tail.
    m.ws[home.index].params = .{ .kind = ms_kind, .variant_idx = lifo_v };
    try testing.expectEqual(@as(?usize, null), admission.spawnPlacementTarget(&m, home));

    // fifo but only one window (or none): nothing to displace, no reorder.
    m.ws[home.index].params = .{ .kind = ms_kind, .variant_idx = fifo_v };
    m.ws[home.index].tiled_order.clear();
    try testing.expect(m.ws[home.index].tiled_order.append(10));
    try testing.expectEqual(@as(?usize, null), admission.spawnPlacementTarget(&m, home));
}

// ---- P1-19: the admission spine ----

const build_options = @import("build_options");
const helpers = @import("helpers");
const window_state_ops = @import("window_state_ops");
const session = @import("session");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};

// The spawn-queue match policy, extracted from findSpawnQueueWorkspace's XCB
// reply drain so the whole decision is testable without a server.

test "admission spawnQueueMatch: an exact PID hits the right entry, ambiguity is null" {
    const q = [_]admission.SpawnEntry{
        .{ .workspace = 1, .pid = 111 },
        .{ .workspace = 2, .pid = 222 },
        .{ .workspace = 3, .pid = 333 },
    };
    // Exact hit: right index, not the heuristic (the caller skips the
    // "sole entry" log for it).
    const m = admission.spawnQueueMatch(&q, 222).?;
    try testing.expectEqual(@as(usize, 1), m.index);
    try testing.expect(!m.heuristic);
    // No exact hit with several pending: ambiguous, fall back to current ws
    // rather than guessing oldest-first.
    try testing.expect(admission.spawnQueueMatch(&q, 999) == null);
    // An empty queue is the same verdict (defensive: the caller only fires
    // the cookie when it saw a non-empty queue).
    try testing.expect(admission.spawnQueueMatch(&.{}, 999) == null);
}

test "admission spawnQueueMatch: a pid-less window never exact-matches a daemon entry" {
    // Daemon entry (pid 0) beside a real one: a window WITHOUT _NET_WM_PID
    // (win_pid 0) must not claim the daemon entry by exact match -- that
    // would conflate "terminal that will fork a grandchild" with "app that
    // doesn't set the property". With two entries it is also ambiguous, so
    // the whole thing is null.
    const q = [_]admission.SpawnEntry{
        .{ .workspace = 4, .pid = 0 },
        .{ .workspace = 5, .pid = 42 },
    };
    try testing.expect(admission.spawnQueueMatch(&q, 0) == null);
    // The window that DOES report the pid claims its own entry...
    const m = admission.spawnQueueMatch(&q, 42).?;
    try testing.expectEqual(@as(usize, 1), m.index);
    try testing.expect(!m.heuristic);
    // ...and the pid-less window still cannot, even with the daemon entry
    // first (swap order would otherwise hand it index 0).
    try testing.expect(admission.spawnQueueMatch(&[_]admission.SpawnEntry{
        .{ .workspace = 4, .pid = 0 },
        .{ .workspace = 5, .pid = 42 },
    }, 0) == null);
}

test "admission spawnQueueMatch: exactly one pending entry is consumed by heuristic" {
    // The `sh -c "cmd"` grandchild case: one pending spawn, the window
    // reports a DIFFERENT (grandchild) pid -- still consumed, flagged
    // heuristic so the caller logs it as such.
    const real = [_]admission.SpawnEntry{.{ .workspace = 6, .pid = 4242 }};
    const m = admission.spawnQueueMatch(&real, 99999).?;
    try testing.expectEqual(@as(usize, 0), m.index);
    try testing.expect(m.heuristic);
    // A sole DAEMON entry is consumed by the same fallback whatever pid the
    // window reports (including none): one pending spawn has no rival to be
    // mis-routed against. This pins the current policy on purpose.
    const daemon = [_]admission.SpawnEntry{.{ .workspace = 7, .pid = 0 }};
    const d0 = admission.spawnQueueMatch(&daemon, 0).?;
    try testing.expectEqual(@as(usize, 0), d0.index);
    try testing.expect(d0.heuristic);
    const d1 = admission.spawnQueueMatch(&daemon, 1234).?;
    try testing.expectEqual(@as(usize, 0), d1.index);
    try testing.expect(d1.heuristic);
}

// window_state_ops.register / unregister: the rollback and scrub contracts
// admission relies on (both called from mapRequest / unmanage).

test "admission register: a full store refuses before any observable change" {
    var m = helpers.makeModel();
    var i: usize = 0;
    while (i < model.store_capacity) : (i += 1) {
        _ = try m.store.put(@intCast(0x1000 + i), .{
            .mask = model.bit(model.WSId.fromIndex(0)),
            .anchor = .tiled,
        });
    }
    const ws0_len = m.ws[0].tiled_order.len;
    // Refusal happens BEFORE the store write: no entry, no list append, no
    // half-registered window.
    try testing.expectError(error.CapacityFull, window_state_ops.register(&m, 0xdead, null));
    try testing.expect(!m.store.has(0xdead));
    try testing.expectEqual(model.store_capacity, m.store.len);
    try testing.expectEqual(ws0_len, m.ws[0].tiled_order.len);
}

test "admission register: a full tiled_order rolls the fresh store entry back" {
    var m = helpers.makeModel();
    // Store has room, the target list does not: pre-fill tiled_order to
    // capacity with ids that hold NO store entry.
    var i: usize = 0;
    while (i < model.max_tiled_per_ws) : (i += 1) {
        try testing.expect(m.ws[0].tiled_order.append(@intCast(0x2000 + i)));
    }
    try testing.expectEqual(@as(usize, 0), m.store.len);
    try testing.expectError(
        error.CapacityFull,
        window_state_ops.register(&m, 0xbeef, model.WSId.fromIndex(0)),
    );
    // The store.put that succeeded before the failed append must be undone:
    // a half-registered window (in the store, in no list) would make
    // findHome lie about single membership and feed a ghost to reconcile.
    try testing.expect(!m.store.has(0xbeef));
    try testing.expectEqual(@as(usize, 0), m.store.len);
    try testing.expectEqual(model.max_tiled_per_ws, m.ws[0].tiled_order.len);
}

test "admission register: the hint workspace is honored; a double register is a no-op" {
    var m = helpers.makeModel();
    try window_state_ops.register(&m, 10, model.WSId.fromIndex(2));
    try testing.expect(m.store.has(10));
    try testing.expectEqual(@as(?model.WSId, model.WSId.fromIndex(2)), m.store.get(10).?.home_ws);
    try testing.expect(m.ws[2].tiled_order.indexOfScalar(10) != null);
    try testing.expectEqual(@as(usize, 1), m.ws[2].tiled_order.len);

    // Re-register with a DIFFERENT hint: early return on store.has -- no
    // duplicate list membership, no anchor/home overwrite.
    try window_state_ops.register(&m, 10, model.WSId.fromIndex(3));
    try testing.expectEqual(@as(usize, 1), m.ws[2].tiled_order.len);
    try testing.expectEqual(@as(usize, 0), m.ws[3].tiled_order.len);
    try testing.expectEqual(@as(?model.WSId, model.WSId.fromIndex(2)), m.store.get(10).?.home_ws);
}

test "admission unregister: the whole-model scrub clears stale lists and focus" {
    var m = helpers.makeModel();
    try window_state_ops.register(&m, 10, model.WSId.fromIndex(0));
    // Plant the id where it must NOT survive: another workspace's membership
    // lists (the stale-left-behind case the whole-model scan exists for --
    // a home_ws-only removal would leave ws3 feeding a dead id to layout)
    // and the focus stack.
    try testing.expect(m.ws[3].tiled_order.append(10));
    try testing.expect(m.ws[3].focus_mru.append(10));
    try testing.expect(m.ws[0].focus_mru.append(10));
    m.focused = 10;

    window_state_ops.unregister(&m, 10);

    try testing.expect(!m.store.has(10));
    for (&m.ws) |*s| {
        try testing.expect(s.tiled_order.indexOfScalar(10) == null);
        try testing.expect(s.focus_mru.indexOfScalar(10) == null);
    }
    try testing.expectEqual(@as(?model.WindowId, null), m.focused);
}

test "admission unregister: idempotent, and unknown ids are no-ops" {
    var m = helpers.makeModel();
    try window_state_ops.register(&m, 10, null);
    window_state_ops.unregister(&m, 10);
    window_state_ops.unregister(&m, 10); // store.remove misses -> early return
    window_state_ops.unregister(&m, 999); // never registered
    try testing.expectEqual(@as(usize, 0), m.store.len);
    try testing.expectEqual(@as(?model.WindowId, null), m.focused);
}

// applyRestoredRecord: the adoption half that overwrites a fresh entry with
// the state the previous session persisted (tiled/floating anchor, mask, and
// the module-claimed ext blob).

test "admission applyRestoredRecord: a tiled record reapplies mask, keeps anchor and home" {
    var m = helpers.makeModel();
    try window_state_ops.register(&m, 21, model.WSId.fromIndex(1));
    const rec = session.WindowRecord{
        .win = 21,
        // Multi-tag mask: visibility across workspaces is mask-derived for
        // tiled windows, so the record's mask must land verbatim.
        .mask = model.bit(model.WSId.fromIndex(2)) | model.bit(model.WSId.fromIndex(4)),
        .anchor = .tiled,
    };
    admission.applyRestoredRecord(&m, 21, &rec);
    const e = m.store.get(21).?;
    try testing.expectEqual(rec.mask, e.mask);
    try testing.expect(e.anchor == .tiled);
    // tiled: register's home hint stands; membership lists are rebuilt by
    // session.applyModelLevel afterwards (F10), never by this pass.
    try testing.expectEqual(@as(?model.WSId, model.WSId.fromIndex(1)), e.home_ws);
    try testing.expect(e.presence == .present);
}

test "admission applyRestoredRecord: a floating record takes the rect and drops home_ws" {
    var m = helpers.makeModel();
    try window_state_ops.register(&m, 22, null);
    const rect = model.Rect{ .x = 10, .y = 20, .width = 300, .height = 200 };
    const rec = session.WindowRecord{
        .win = 22,
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .{ .floating = rect },
    };
    admission.applyRestoredRecord(&m, 22, &rec);
    const e = m.store.get(22).?;
    try testing.expect(e.anchor == .floating);
    try testing.expectEqual(rect, e.anchor.floating);
    // A floating window has no tiled slot -- the same detach toggleFloating
    // performs; list surgery itself belongs to applyModelLevel's rebuild.
    try testing.expectEqual(@as(?model.WSId, null), e.home_ws);
    try testing.expectEqual(rec.mask, e.mask);
}

test "admission applyRestoredRecord: a parked record's ext blob replays through the module hook" {
    if (!build_options.has_minimize) return;
    const alloc = testing.allocator;

    // Save half: park the window and marshal the owning module's blob.
    var m = helpers.makeModel(); // makeModel re-arms the minimize store
    try window_state_ops.register(&m, 23, null);
    try minimize.minimize(&m, 23);
    try testing.expect(minimize.isMinimized(&m, 23));
    const blob = minimize.serializeWindow(&m, 23, alloc).?;
    defer alloc.free(blob);

    // Adopt half: a FRESH model (the successor process's register pass made
    // the entry present+tiled) replays the record; presence must come from
    // the ext dispatch, not from the record's own presence field.
    var m2 = helpers.makeModel(); // clears the module store again (restart)
    try window_state_ops.register(&m2, 23, null);
    const rec = session.WindowRecord{
        .win = 23,
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .tiled,
        .presence = .parked,
        .ext = blob,
    };
    admission.applyRestoredRecord(&m2, 23, &rec);

    // The hook claimed the blob: record adopted, park replayed on the model.
    try testing.expect(minimize.isMinimized(&m2, 23));
    const e = m2.store.get(23).?;
    try testing.expect(e.presence == .parked);
    try testing.expectEqual(@as(?model.WSId, null), e.home_ws); // parkEntry clears home
    try testing.expect(m2.ws[0].tiled_order.indexOfScalar(23) == null); // slot dropped
}

test "admission applyRestoredRecord: presence/covering stay with applyModelLevel, not this pass" {
    var m = helpers.makeModel();
    try window_state_ops.register(&m, 24, null);
    const rec = session.WindowRecord{
        .win = 24,
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .tiled,
        .presence = .covering,
        .covering_ws = model.WSId.fromIndex(0),
    };
    admission.applyRestoredRecord(&m, 24, &rec);
    const e = m.store.get(24).?;
    // mask applies; presence deliberately does NOT: the model-authoritative
    // covering phase is session.applyModelLevel (pinned by session_test's
    // F10), and parked comes from the ext blob (previous test). Two owners,
    // two passes -- this documents the split.
    try testing.expectEqual(rec.mask, e.mask);
    try testing.expect(e.presence == .present);
    try testing.expectEqual(@as(?model.WSId, null), e.covering_ws);
}

test "admission applyRestoredRecord: an unregistered window is a no-op" {
    var m = helpers.makeModel();
    const rec = session.WindowRecord{
        .win = 777,
        .mask = model.bit(model.WSId.fromIndex(0)),
        .anchor = .tiled,
    };
    admission.applyRestoredRecord(&m, 777, &rec); // store miss -> nothing to patch
    try testing.expect(!m.store.has(777));
}

// P1-40: deinit is idempotent — a second call, or one before the first init,
// is a no-op, not a null-unwrap panic (`state.?` used to run past the first
// call's `state = null`). The warm admission cycle is also leak-checked: the
// spawn queue and rules map allocate against testing.allocator in init and
// must all come back in the FIRST deinit (the second frees nothing).
//
// The core bootstrap mirrors render_core_test exactly: dummy connection never
// dereferenced on this path (buildRulesMap reads only `config`), page
// allocator for the config box core holds for the process.
var g_screen: core.xcb.xcb_screen_t = std.mem.zeroes(core.xcb.xcb_screen_t);
var g_cfg: composed.Config = .{};

test "admission and focus deinit are idempotent" {
    core.init(undefined, &g_screen, 0, std.heap.page_allocator, &g_cfg, 96.0);

    // Warm: init allocates, first deinit frees, second must skip cleanly.
    admission.init(testing.allocator);
    admission.deinit();
    admission.deinit();

    // Cold: this headless file never runs focus.init (it needs the live
    // pieces the X fixture brings), so state is null and both calls must
    // return without unwrapping or reaching for a connection.
    focus.deinit();
    focus.deinit();
}
