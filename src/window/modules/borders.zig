//! Border policy for tiled and floating windows — an OPTIONAL window module.
//! Resolves border visibility/color/width (hiding borders for covering
//! fullscreen windows and windows behind covering occupants), applies them
//! with ledger-backed dedup, and owns the per-batch recolor sweeps.
//!
//! DELETION SEMANTICS: the registry shortens, `borders` dispatches no-op, and
//! `window.borderColorOf` falls back to constant 0 — windows keep the
//! CONFIGURED width (`core.borderWidth()`, a core config knob: geometry and
//! layout insets are coupled to it) with an uncolored pixel. Core reaches
//! this module only through the `window` facade / contract family.

const core = @import("core");
const xcb = core.xcb;

const model = @import("model");
const focus = @import("focus");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const requests = @import("requests");
const reconcile = @import("reconcile");
const query = @import("query");

/// True when `win` must render borderless because a covering (fullscreen)
/// occupant holds the workspace it actually lives on. `current` is the
/// unresolvable-workspace fallback; `has_fullscreen` (comptime) gates the
/// covering-mode reads for fullscreen-absent builds; `occupants` is the
/// precomputed per-workspace table (`model.coveringOccupants`).
pub fn isBehindCoveringWindowWith(
    m: *const model.Model,
    win: u32,
    current: model.WSId,
    comptime has_fullscreen: bool,
    occupants: []const ?model.WindowId,
) bool {
    if (!m.store.has(win)) return false;
    if (model.findHome(m, win)) |w| {
        if (w.index < occupants.len) return occupants[w.index] != null;
    }
    return has_fullscreen and current.index < occupants.len and occupants[current.index] != null;
}

/// The border-color decision for `win`: 0 for screen-covering windows,
/// focused or unfocused color otherwise, against a PRECOMPUTED occupant
/// table (built once per sweep, never per window). The SWEEPS' decision;
/// the reconcile delta uses `colorOf` below.
pub fn resolveBorderColorWith(win: u32, occupants: []const ?model.WindowId) u32 {
    if (comptime !build_options.has_tiling) return 0; // borderless: no tiled chrome
    // Covering windows render borderless via the bw=0/pixel=0 policy in
    // sync; this predicate covers callers outside reconcile.
    const m = pipeline.state();
    if (model.isCovering(m, win)) return 0;
    const cfg = &core.getState().config.tiling;
    // A window sharing a workspace with a covering occupant is hidden behind
    // it, so it must render borderless too -- otherwise the barless
    // fullscreen view leaks colored edges. Stray/unfindable windows fall back
    // to whether the CURRENT workspace has a covering occupant.
    if (isBehindCoveringWindowWith(m, win, m.current, build_options.has_fullscreen, occupants)) return 0;
    // The model is the focus source, so this cannot drift from the
    // pipeline's own pick.
    return focus.focusedBorderColor(m, win, cfg.border_focused, cfg.border_unfocused);
}

/// The reconcile delta's border-color pick (the `colorOf` contract hook).
/// Deliberately WITHOUT the covering checks `resolveBorderColorWith`
/// carries: the reconciler zeroes bw/pixel for the covering winner and for
/// parked windows itself (computeDesire's policy), so those never send this
/// value as a colored border. Reads MODEL focus; focus.zig mirrors every
/// transition into m.focused.
fn colorOf(win: model.WindowId, m: *const model.Model) u32 {
    if (comptime !build_options.has_tiling) return 0;
    const cfg = &core.getState().config.tiling;
    return focus.focusedBorderColor(m, win, cfg.border_focused, cfg.border_unfocused);
}

/// Applies the configured border width to `win`, skipping the configure when
/// the sync ledger shows that width was already sent (the ledger is the sole
/// owner of "last border width sent").
fn applyWidth(conn: core.Connection, win: u32) void {
    const w = core.borderWidth();
    if (w == 0) return;
    if (reconcile.sentGet(win)) |e| {
        if (e.bw == w) return;
    }
    const ck = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{w});
    requests.noteSequence(win, ck.sequence);
    if (build_options.has_tiling) reconcile.markSentBorderWidth(win, w);
}

/// Applies border width + color against a PRECOMPUTED occupant table for
/// sweep callers: resolving color per window would rebuild the table each
/// time (O(windows * store)); one build + apply keeps the sweep O(store).
///
/// The color dedup lives in the SENT LEDGER beside the width record, so
/// sweep and reconcile share one "has this pixel gone out" record — deriving
/// it from window_facts would let a reconcile-sent pixel go unrecorded for
/// the sweep (and vice versa).
fn applyWith(conn: core.Connection, win: u32, occupants: []const ?model.WindowId) void {
    applyWidth(conn, win);
    const c = resolveBorderColorWith(win, occupants);
    if (reconcile.markSentBorderPixelIfChanged(win, c)) requests.setBorderPixel(conn, win, c);
}

inline fn tilingActive() bool {
    return build_options.has_tiling;
}

/// Fill `buf` with the per-workspace covering-occupant table in ONE store
/// pass. Asking the covering question per window made sweeps O(N^2) in store
/// scans, so every sweep variant (and reloadBorders) builds it up-front.
fn occupantsInto(buf: *[model.max_workspaces]?model.WindowId) void {
    buf.* = @splat(null);
    model.coveringOccupants(pipeline.state(), buf);
}

/// Refresh border colors for windows on the current workspace; shared loop
/// for both sweep variants. `skip_tiled` true (updateFloatingWindowBorders)
/// skips tiled windows (configureWithHints already updated theirs; falls
/// back to a full sweep when tiling is absent). `skip_tiled` false
/// (updateWorkspaceBorders) relies on ledger dedup so the steady-state sweep
/// generates zero XCB traffic.
fn sweepWorkspaceBorders(comptime skip_tiled: bool) void {
    const cur = query.getCurrentWorkspace() orelse return;
    const cur_ws = model.WSId.fromIndex(cur);
    var occupants: [model.max_workspaces]?model.WindowId = undefined;
    occupantsInto(&occupants);
    // Caller-owned scratch: a plain buffer instead of module-level State, so
    // the sweep carries no cross-call state to reset.
    var snapshot: [model.store_capacity]query.Entry = undefined;
    for (query.allWindowsInto(&snapshot)) |entry| {
        const win = entry.win;
        if (!model.maskedOn(entry.mask, cur_ws)) continue;
        // Parked windows are invisible; recoloring them is pointless XCB
        // traffic and can race the park position (the unpark reconcile
        // re-establishes their color).
        if (entry.presence == .parked) continue;
        if (comptime skip_tiled) {
            if (build_options.has_tiling and tilingActive() and query.isTiledMode(win)) continue;
        }
        const color = resolveBorderColorWith(win, &occupants);
        if (reconcile.markSentBorderPixelIfChanged(win, color))
            requests.setBorderPixel(core.getState().conn, win, color);
    }
}

fn updateWorkspaceBorders() void {
    sweepWorkspaceBorders(false);
}

fn updateFloatingWindowBorders() void {
    sweepWorkspaceBorders(true);
}

fn reloadBorders() void {
    var occupants: [model.max_workspaces]?model.WindowId = undefined;
    occupantsInto(&occupants);
    var snapshot: [model.store_capacity]query.Entry = undefined;
    for (query.allWindowsInto(&snapshot)) |entry| {
        applyWith(core.getState().conn, entry.win, &occupants);
    }
}

/// This module's window contribution: the border-color decision plus the
/// three per-batch sweeps. No lifecycle hooks (no module state).
pub const module: @import("window_contract").WindowModule = .{
    .name = "borders",
    .borders = .{
        .colorOf = colorOf,
        .updateWorkspaceBorders = updateWorkspaceBorders,
        .updateFloatingWindowBorders = updateFloatingWindowBorders,
        .reloadBorders = reloadBorders,
    },
};
