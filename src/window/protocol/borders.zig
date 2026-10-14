//! Shared border helpers for tiled and floating windows.
//! Resolves border visibility, color, and width (hiding borders for covering/
//! fullscreen windows and windows behind covering occupants), and applies them
//! atomically with ledger-backed deduplication to avoid redundant XCB configure
//! requests.

const core = @import("core");
const xcb = core.xcb;
const model = @import("model");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const wincache = @import("wincache");
const requests = @import("requests");
const window = @import("window");

const ledger = @import("ledger");
/// Pure covering-occupant borderless rule: true when `win` must render
/// borderless because a covering (fullscreen) occupant holds the workspace it
/// actually lives on. `current` is the current workspace for the
/// unresolvable-workspace fallback; `has_fullscreen` (comptime) gates the
/// covering-mode reads for fullscreen-absent builds; `occupants` is the
/// precomputed per-workspace table (see `model.coveringOccupants`).
/// (Occupant query family: pure-scan `model.coveringOccupantOnWs`, its
/// batch form `model.coveringOccupants`, module's record-backed
/// `fullscreen.visibleCoveringOnWs`, actions' routed hook
/// `currentCoveringOccupant`.)
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
pub fn resolveBorderColorWith(win: u32, occupants: []const ?model.WindowId) u32 {
    // Covering windows render borderless via the bw=0/pixel=0 policy in
    // sync; this predicate covers callers outside reconcile.
    const m = pipeline.model();
    if (window.isCoveringMode(m, win)) return 0;
    const cfg = &core.getState().config.tiling;
    // A window that shares a workspace with a covering (fullscreen) occupant
    // is hidden behind it, so it must render borderless too -- otherwise the
    // barless fullscreen view leaks colored edges. This resolves the member's
    // real workspace from its covering state or (re)place home; a stray or
    // unfindable window falls back to whether the CURRENT workspace has a
    // covering occupant.
    if (isBehindCoveringWindowWith(m, win, m.current, build_options.has_fullscreen, occupants)) return 0;
    // The model is the focus source, so this cannot drift from the
    // pipeline's own pick (which used to be a second copy of this ternary).
    return model.focusedBorderColor(m, win, cfg.border_focused, cfg.border_unfocused);
}

/// Applies the configured border width to `win`, skipping the configure when
/// the sync ledger shows that exact width is already the last one sent.
/// (The ledger is the sole "last border width sent" owner; wincache
/// no longer mirrors it.)
pub fn applyWidth(conn: core.Connection, win: u32) void {
    const w = core.borderWidth();
    if (w == 0) return;
    if (ledger.sentGet(win)) |e| {
        if (e.bw == w) return;
    }
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{w});
    if (build_options.has_tiling) ledger.markSentBorderWidth(win, w);
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
/// wincache entry instead is what let a pixel sent by the reconcile go
/// unrecorded for the sweep (and vice versa).
pub fn applyWith(conn: core.Connection, win: u32, occupants: []const ?model.WindowId) void {
    applyWidth(conn, win);
    const c = resolveBorderColorWith(win, occupants);
    if (ledger.markSentBorderPixelIfChanged(win, c)) requests.setBorderPixel(conn, win, c);
}
