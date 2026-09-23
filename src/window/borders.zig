//! Shared border helpers.
//! Resolves border color and width and applies them atomically across tiled and floating paths.

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const model = @import("model");
const focus = @import("focus");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const sync = @import("sync");
const wincache = @import("wincache");
const window = @import("window");

/// Pure focused/unfocused pixel pick: 0 for screen-covering windows,
/// focused or unfocused color otherwise. Headless-testable.
pub fn borderColorOf(focused: bool, focused_px: u32, unfocused_px: u32) u32 {
    return if (focused) focused_px else unfocused_px;
}

/// Pure covering-occupant borderless rule: true when `win` must render
/// borderless because a covering (fullscreen) occupant holds the workspace it
/// actually lives on. `current` is the current workspace for the
/// unresolvable-workspace fallback; `has_fullscreen` (comptime) gates the
/// covering-mode reads for fullscreen-absent builds.
/// (Occupant query family: pure-scan `model.coveringOccupantOnWs`, module's
/// record-backed `fullscreen.fullscreenOccupantOnWs`, actions' routed hook
/// `currentCoveringOccupant`.)
pub fn isBehindCoveringWindow(
    m: *const model.Model,
    win: u32,
    current: model.WSId,
    comptime has_fullscreen: bool,
) bool {
    // Only windows present in the store take part in the rule.
    if (!m.store.has(win)) return false;
    if (model.findHome(m, win)) |w| return model.coveringOccupantOnWs(m, w) != null;
    return has_fullscreen and model.coveringOccupantOnWs(m, current) != null;
}

/// Returns the border color for `win`: 0 for screen-covering windows,
/// focused or unfocused color otherwise.
pub fn resolveBorderColor(win: u32) u32 {
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
    if (isBehindCoveringWindow(m, win, m.current, build_options.has_fullscreen)) return 0;
    return borderColorOf(focus.getFocused() == win, cfg.border_focused, cfg.border_unfocused);
}

/// Returns the effective border width for tiled windows.
pub fn width() u16 {
    return core.borderWidth();
}

/// Applies the configured border width to `win`, skipping the configure when
/// the sync ledger shows that exact width is already the last one sent.
/// (The ledger is the sole "last border width sent" owner; wincache
/// no longer mirrors it.)
pub fn applyWidth(conn: core.Connection, win: u32) void {
    const w = width();
    if (w == 0) return;
    if (sync.sentGet(win)) |e| {
        if (e.bw == w) return;
    }
    _ = xcb.xcb_configure_window(conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{w});
    if (build_options.has_tiling) sync.markSentBorderWidth(win, w);
}

/// Applies both border width and color to `win`. Color goes through the
/// layout-cache dedup so repeated sweeps don't spam ChangeWindowAttributes;
/// that dedup always records the sent/verified color, keeping the cache
/// truthful across forced values applied outside it (fullscreen's pixel 0)
/// so the next real color change is never stale-skipped. When tiling state
/// is unavailable, the send is unconditional.
pub fn apply(conn: core.Connection, win: u32) void {
    applyWidth(conn, win);
    const c = resolveBorderColor(win);
    if (build_options.has_tiling) {
        if (wincache.sendBorderColorIfChanged(win, c)) return;
    }
    utils.setBorderPixel(conn, win, c);
}
