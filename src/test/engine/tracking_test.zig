//! Facade-vs-ledger parity tests (src/window/tracking.zig vs
//! src/core/sync/sync.zig). The tracking facade is a read-through of the
//! model; the sent ledger is the "what's on the wire" authority. After a
//! reconcile the two must agree window-for-window on the managed set, on
//! current-workspace visibility, and on parked state.
//!
//! The facade reads the process-global `pipeline` model, so the fixture
//! drives that global (`pipeline.initialized` + `pipeline.mut(&gate)`)
//! instead of a local model, and reconciles the SAME instance the facade
//! reads. The sync sink is the recorder (no live X needed; these are
//! headless and run in every `zig build test`).

const std = @import("std");
const testing = std.testing;

const model = @import("model");
const pipeline = @import("pipeline");
const tracking = @import("tracking");
const sync = @import("sync");
const helpers = @import("helpers");
const build_options = @import("build_options");
const minimize = if (build_options.has_minimize) @import("minimize") else struct {};
const fullscreen = if (build_options.has_fullscreen) @import("fullscreen") else struct {};

const cfg_bw = helpers.cfg_bw;
const testColor = helpers.testColor;

const Recorder = helpers.TestSink(.record);

/// Test-owned transition-layer gate (same pattern as the shared fixture):
/// gives the reset path a mutable handle to the pipeline global model.
var gate: pipeline.Gate = .{};

/// Re-arms the pipeline global model (which the tracking facade reads) and
/// the sync/capacity module stores, returning the mutable instance handle.
/// Then every reconcile in a test runs over `pipeline.model()` so facade and
/// ledger observe the identical state.
fn setUpModel() *model.Model {
    pipeline.initialized = true;
    const m = pipeline.mut(&gate);
    m.* = helpers.makeModel();
    helpers.testReset();
    sync.init();
    tracking.init();
    return m;
}

fn reconcile(m: *model.Model, rec: *Recorder, opts: sync.ReconcileOpts) void {
    var ctx: sync.Ctx = .{
        .sink = rec.sink(),
        .screen = helpers.std_wa,
        .workarea = helpers.std_wa,
        .cfg_bw = cfg_bw,
        .color_of = testColor,
        .env = helpers.std_env,
    };
    sync.reconcile(m, &ctx, opts);
}

fn reg(m: *model.Model, win: model.WindowId, ws_idx: u8) !void {
    try model.register(m, win, model.WSId.fromIndex(ws_idx));
}

test "facade agrees with ledger on managed set, masks, and ws visibility" {
    var m = setUpModel();
    var rec = Recorder{};
    defer rec.deinit();

    // ws0 has two tiled windows (101 focused), ws1 has one; current = ws0.
    try reg(m, 101, 0);
    try reg(m, 102, 0);
    try reg(m, 201, 1);
    model.setFocus(m, 101);

    // Ledger-first preconditions: nothing sent yet, nothing visible.
    try testing.expect(sync.lastRectFor(101) == null);

    reconcile(m, &rec, .{});

    // Managed set parity: every store window has a ledger record, and the
    // facade store count equals the ledger's (each reconcile reconciles all).
    try testing.expectEqual(@as(usize, 3), m.store.count());
    const wins = [_]model.WindowId{ 101, 102, 201 };
    for (wins) |w| {
        try testing.expect(tracking.isManaged(w));
        try testing.expect(sync.sentGet(w) != null);
    }

    // Mask parity: the facade's current-workspace test matches the model's
    // stored mask against the current workspace.
    for (wins) |w| {
        try testing.expectEqual(
            model.maskedOn(m.store.get(w).?.mask, m.current),
            tracking.isOnCurrentWorkspace(w),
        );
    }

    // Workspace visibility parity: ws0 windows are on the current workspace
    // and were placed (ledger visible); the ws1 window is parked on the wire
    // (ledger has no visible rect) and the facade agrees.
    try testing.expect(tracking.isOnCurrentWorkspace(101));
    try testing.expect(sync.lastRectFor(101) != null);
    try testing.expect(tracking.isOnCurrentWorkspace(102));
    try testing.expect(sync.lastRectFor(102) != null);
    try testing.expect(!tracking.isOnCurrentWorkspace(201));
    try testing.expect(sync.lastRectFor(201) == null);
}

test "facade tracks the workspace switch exactly like the ledger" {
    var m = setUpModel();
    var rec = Recorder{};
    defer rec.deinit();

    try reg(m, 101, 0);
    try reg(m, 201, 1);
    model.setFocus(m, 101);
    reconcile(m, &rec, .{});

    // Baseline on ws0: 101 placed, 201 parked.
    try testing.expect(sync.lastRectFor(101) != null);
    try testing.expect(sync.lastRectFor(201) == null);

    // Switch to ws1: leavers park on the wire, arrivers place; the facade
    // must flip in lockstep.
    m.current = model.WSId.fromIndex(1);
    reconcile(m, &rec, .{ .force_restack = true });

    try testing.expectEqual(@as(u8, 1), tracking.getCurrentWorkspace().?);
    try testing.expect(!tracking.isOnCurrentWorkspace(101));
    try testing.expect(sync.lastRectFor(101) == null);
    try testing.expect(tracking.isOnCurrentWorkspace(201));
    try testing.expect(sync.lastRectFor(201) != null);
}

test "minimized windows are invisible to both facade and ledger" {
    const m = setUpModel();
    var rec = Recorder{};
    defer rec.deinit();

    try reg(m, 101, 0);
    try reg(m, 102, 0);
    model.setFocus(m, 101);
    reconcile(m, &rec, .{}); // baseline: both placed

    // Minimize the stack: presence flips to .parked, reconcile parks it.
    try minimize.minimize(m, 102);
    reconcile(m, &rec, .{});

    // The window is still managed and tagged on ws0...
    try testing.expect(tracking.isManaged(102));
    try testing.expect(tracking.isOnCurrentWorkspace(102));
    // ...but not visible: facade sees the parked presence, ledger has no
    // visible rect (the park was actually sent).
    try testing.expect(sync.lastRectFor(102) == null);

    // The sibling keeps full visibility on both sides of the seam.
    try testing.expect(tracking.isOnCurrentWorkspace(101));
    try testing.expect(sync.lastRectFor(101) != null);
}

test "facade and ledger agree on presence-driven hiding (fullscreen park)" {
    const m = setUpModel();
    var rec = Recorder{};
    defer rec.deinit();

    try reg(m, 101, 0);
    try reg(m, 102, 0);
    model.setFocus(m, 101);
    reconcile(m, &rec, .{}); // baseline: both placed

    _ = fullscreen.toggleFullscreen(m, 101);
    reconcile(m, &rec, .{ .force_restack = true });

    // The covering winner owns the screen: the ledger placed it (visible
    // rect) and the facade reads it as on the current workspace. The sibling
    // stays a managed window, and the ledger parks it on the wire: the
    // covering occupant owns the screen, so no rect. Focus folding already
    // collapses the cycle pool to the occupant (focus.zig
    // collectVisibleWindows), so the model-truth read cannot leak a parked
    // window into focus recovery.
    try testing.expect(tracking.isManaged(101));
    try testing.expect(tracking.isOnCurrentWorkspace(101));
    try testing.expect(sync.lastRectFor(101) != null);
    try testing.expect(tracking.isManaged(102));
    try testing.expect(tracking.isOnCurrentWorkspace(102));
    try testing.expect(sync.lastRectFor(102) == null);
}
