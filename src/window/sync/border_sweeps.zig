//! Per-batch border sweeps (moved out of protocol/borders.zig): the
//! workspace/floating recolor passes and the config-reload full apply.
//! Every border WRITE goes through this module or borders.zig's apply*
//! helpers (which this module calls); window.zig re-exports the three entry
//! points as part of its dispatch facade.
//!
//! The pure per-window decisions (visibility, color, width) stay in
//! protocol/borders.zig; the sweeps own only iteration + the occupant-table
//! build that keeps them O(store) instead of O(N^2).

const core = @import("core");
const model = @import("wm_state");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const requests = @import("requests");
const query = @import("query");
const ledger = @import("ledger");
const borders = @import("borders");

inline fn tilingActive() bool {
    return core.getState().config.tiling.enabled;
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
        const color = borders.resolveBorderColorWith(win, &occupants);
        // Same ledger dedup in both sweep variants: a window whose color is
        // unchanged (per the ledger's record) skips the XCB call outright.
        // One record has to answer this for both the sweep and the
        // reconcile -- see applyWith.
        if (ledger.markSentBorderPixelIfChanged(win, color))
            requests.setBorderPixel(core.getState().conn, win, color);
    }
}

pub fn updateWorkspaceBorders() void {
    sweepWorkspaceBorders(false);
}

pub fn updateFloatingWindowBorders() void {
    sweepWorkspaceBorders(true);
}

/// Called on config reload.
pub fn reloadBorders() void {
    var occupants: [model.max_workspaces]?model.WindowId = undefined;
    occupantsInto(&occupants);
    var snapshot: [model.store_capacity]query.Entry = undefined;
    for (query.allWindowsInto(&snapshot)) |entry| {
        borders.applyWith(core.getState().conn, entry.win, &occupants);
    }
}
