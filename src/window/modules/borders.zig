//! Border policy for tiled and floating windows — an OPTIONAL window module
//! (P2-47; moved from `protocol/borders.zig` + `sync/border_sweeps.zig`).
//! Resolves border visibility, color, and width (hiding borders for covering/
//! fullscreen windows and windows behind covering occupants), applies them
//! with ledger-backed deduplication to avoid redundant XCB configure requests,
//! and owns the per-batch sweeps that recolor live windows.
//!
//! DELETION SEMANTICS (the modularity matrix deletes this file): the registry
//! shortens, every dispatch through the `borders` family no-ops, and
//! `window.borderColorOf` falls back to a constant 0 — windows keep the
//! CONFIGURED width (`ctx.env.margins.border` / `core.borderWidth()`, which
//! stays a core config knob: geometry and layout insets are coupled to it)
//! with an uncolored (black) pixel. No other file names this module; core
//! reaches it only through the `window` facade / the contract family.

const core = @import("core");
const xcb = core.xcb;

const model = @import("model");
const focus = @import("focus");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const requests = @import("requests");
const reconcile = @import("reconcile");
const query = @import("query");

/// Pure covering-occupant borderless rule: true when `win` must render
/// borderless because a covering (fullscreen) occupant holds the workspace it
/// actually lives on. `current` is the current workspace for the
/// unresolvable-workspace fallback; `has_fullscreen` (comptime) gates the
/// covering-mode reads for fullscreen-absent builds; `occupants` is the
/// precomputed per-workspace table (see `model.coveringOccupants` — the
/// batch form of `model.coveringOccupantOn(..., .anchored_or_visible)`).
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
/// focused or unfocused color otherwise, resolved against a PRECOMPUTED
/// occupant table (see `model.coveringOccupants` — every caller sweeps
/// windows, so the table is built once per sweep, never per window).
/// The SWEEPS' color decision; the reconcile delta uses `colorOf` below.
pub fn resolveBorderColorWith(win: u32, occupants: []const ?model.WindowId) u32 {
    if (comptime !build_options.has_tiling) return 0; // borderless: no tiled chrome
    // Covering windows render borderless via the bw=0/pixel=0 policy in
    // sync; this predicate covers callers outside reconcile.
    const m = pipeline.state();
    if (model.isCovering(m, win)) return 0;
    const cfg = &core.getState().config.tiling;
    // A window that shares a workspace with a covering (fullscreen) occupant
    // is hidden behind it, so it must render borderless too -- otherwise the
    // barless fullscreen view leaks colored edges. This resolves the member's
    // real workspace from its covering state or (re)place home; a stray or
    // unfindable window falls back to whether the CURRENT workspace has a
    // covering occupant.
    if (isBehindCoveringWindowWith(m, win, m.current, build_options.has_fullscreen, occupants)) return 0;
    // The model is the focus source, so this cannot drift from the
    // pipeline's own pick.
    return focus.focusedBorderColor(m, win, cfg.border_focused, cfg.border_unfocused);
}

/// The reconcile delta's border-color pick (the `colorOf` contract hook;
/// formerly `pipeline.colorOf`). Deliberately WITHOUT the covering checks
/// `resolveBorderColorWith` carries: the reconciler zeroes bw/pixel for the
/// covering winner and for parked windows itself (computeDesire's policy),
/// so those windows never send this value as a colored border. Fullscreen
/// windows get bw=0/pixel=0 through that branch policy instead. Reads MODEL
/// focus; focus.zig mirrors every transition into m.focused, so this is the
/// same single source of truth.
fn colorOf(win: model.WindowId, m: *const model.Model) u32 {
    if (comptime !build_options.has_tiling) return 0;
    const cfg = &core.getState().config.tiling;
    return focus.focusedBorderColor(m, win, cfg.border_focused, cfg.border_unfocused);
}

/// Applies the configured border width to `win`, skipping the configure when
/// the sync ledger shows that exact width is already the last one sent.
/// (The ledger is the sole "last border width sent" owner.)
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

/// Applies border width + color to `win` against a PRECOMPUTED occupant table,
/// for callers sweeping many windows (the reload sweep): resolving the color
/// per window would rebuild the table each time, making the sweep
/// O(windows * store). One build (model.coveringOccupants) + applyWidth +
/// resolveBorderColorWith keeps it at O(store) total.
///
/// The color dedup lives in the SENT LEDGER, beside the width record and
/// the reconcile's own `need_pixel` check, so the sweep and the reconcile derive
/// "has this pixel already gone out" from one record. Deriving it from the
/// window_facts entry instead would let a pixel sent by the reconcile go
/// unrecorded for the sweep (and vice versa).
fn applyWith(conn: core.Connection, win: u32, occupants: []const ?model.WindowId) void {
    applyWidth(conn, win);
    const c = resolveBorderColorWith(win, occupants);
    if (reconcile.markSentBorderPixelIfChanged(win, c)) requests.setBorderPixel(conn, win, c);
}

inline fn tilingActive() bool {
    return build_options.has_tiling;
}

/// Fill `buf` with the per-workspace covering-occupant table in ONE store
/// pass. Every per-window color decision asks "does this window's workspace
/// have a covering occupant"; asking per window made the sweep O(N^2) in
/// store scans, so both sweep variants (and reloadBorders) build it once
/// up-front.
fn occupantsInto(buf: *[model.max_workspaces]?model.WindowId) void {
    buf.* = @splat(null);
    model.coveringOccupants(pipeline.state(), buf);
}

/// Refresh border colors for all windows on the current workspace. Shared
/// iteration loop for workspace border sweeps:
///
/// - `skip_tiled` true (updateFloatingWindowBorders): skip tiled windows,
///   `configureWithHints` already updated their borders via get_border_color;
///   when tiling is absent or disabled it falls back to a full sweep because
///   there are no tiled windows to skip.
/// - `skip_tiled` false (updateWorkspaceBorders): dedup via the sent ledger
///   (markSentBorderPixelIfChanged), so the steady-state focused-window
///   sweep generates zero XCB traffic.
fn sweepWorkspaceBorders(comptime skip_tiled: bool) void {
    const cur = query.getCurrentWorkspace() orelse return;
    const cur_ws = model.WSId.fromIndex(cur);
    var occupants: [model.max_workspaces]?model.WindowId = undefined;
    occupantsInto(&occupants);
    // Caller-owned scratch (the diag.zig pattern): the store walk fills a
    // plain buffer instead of module-level State, so the sweep carries no
    // cross-call state to reset.
    var snapshot: [model.store_capacity]query.Entry = undefined;
    for (query.allWindowsInto(&snapshot)) |entry| {
        const win = entry.win;
        if (!model.maskedOn(entry.mask, cur_ws)) continue;
        // Parked (offscreen/minimized) windows are invisible; recoloring
        // them is pointless XCB traffic and can race the park position. The
        // unpark reconcile re-establishes their border color.
        if (entry.presence == .parked) continue;
        if (comptime skip_tiled) {
            if (build_options.has_tiling and tilingActive() and query.isTiledMode(win)) continue;
        }
        const color = resolveBorderColorWith(win, &occupants);
        // Same ledger dedup in both sweep variants: a window whose color is
        // unchanged (per the ledger's record) skips the XCB call outright.
        // One record has to answer this for both the sweep and the
        // reconcile -- see applyWith.
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

/// Called on config reload.
fn reloadBorders() void {
    var occupants: [model.max_workspaces]?model.WindowId = undefined;
    occupantsInto(&occupants);
    var snapshot: [model.store_capacity]query.Entry = undefined;
    for (query.allWindowsInto(&snapshot)) |entry| {
        applyWith(core.getState().conn, entry.win, &occupants);
    }
}

/// This module's window sub-system contribution: the border-color decision
/// plus the three per-batch sweeps. No lifecycle hooks (no module state).
pub const module: @import("window_contract").WindowModule = .{
    .name = "borders",
    .borders = .{
        .colorOf = colorOf,
        .updateWorkspaceBorders = updateWorkspaceBorders,
        .updateFloatingWindowBorders = updateFloatingWindowBorders,
        .reloadBorders = reloadBorders,
    },
};
