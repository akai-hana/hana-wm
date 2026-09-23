//! Complete fullscreen feature: state transitions + read helpers + protocol hooks.
//! A self-contained plugin over the model: fullscreen state lives ENTIRELY in
//! the model (`covering_ws` is the core capture intent this module drives;
//! `presence` and `anchor` stand as recorded). There is no module-owned record
//! store — the model entry IS the record, so toggling, the workspace-caption
//! choice, the ghost state, and the read helpers collapse onto ONE authority
//! and can never drift out of lockstep. The module owns the transitions (the
//! toggle + the EWMH `_NET_WM_STATE_FULLSCREEN` advertisement) and the
//! deferred bar hide/show. Persistence needs no module blob: `anchor` and
//! `covering_ws` are carried verbatim by `persist.WindowRecord`. The core
//! never names fullscreen.
//!
//! A fullscreen window is a *ghost* while minimized: minimize parks the model
//! entry (`presence == .parked`) but leaves `covering_ws` set, so
//! `fullscreenWsOf` still reports the ws and restore re-claims the screen
//! (minimize.restore reposts `.covering`).

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const model = @import("model");
const pipeline = @import("pipeline");
const window = @import("window");
// Peers reach each other's hooks through the generated window registry,
// never by naming a sibling module: deleting a sibling only shortens the
// registry, and capabilities stay provider-agnostic.
const providerOf = window.providerOf;

/// Window configured fullscreen but awaiting ConfigureNotify confirmation.
/// Zero when none pending. Set by armPendingBarHide; cleared in
/// notifyConfigureIfPending/resetState/onWindowGone.
var g_pending_bar_hide_win: u32 = 0;

/// Window that has exited fullscreen and been retiled but awaits ConfigureNotify
/// confirming its new dimensions. Zero when none pending. Set by
/// armPendingBarShow; cleared in notifyConfigureIfPending, resetState, onWindowGone.
var g_pending_bar_show_win: u32 = 0;

// EWMH atoms for _NET_WM_STATE_FULLSCREEN, resolved from the shared atom
// cache (utils.initAtomCache) in init(). Zero (XCB_ATOM_NONE) when the cache
// was unavailable; setEwmhFullscreenState's guard already skips the write then.
var g_net_wm_state: xcb.xcb_atom_t = 0;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = 0;

// Shared reset sequence used by both init() and deinit() to keep them in sync.
fn resetState() void {
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = 0;
    g_net_wm_state = 0;
    g_net_wm_state_fullscreen = 0;
}

pub fn init() anyerror!void {
    resetState();

    // Re-resolve the EWMH fullscreen atoms from the shared atom cache rather
    // than interning them again here.
    g_net_wm_state = utils.getAtomOrZero("_NET_WM_STATE");
    g_net_wm_state_fullscreen = utils.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
}

pub fn deinit() void {
    resetState();
}

/// Toggle `win`'s fullscreen capture of the current workspace.
///
/// ON (no covering intent): sets `e.presence = .covering` plus the model's
/// `covering_ws` (the single authority on the capture target). The anchor
/// needs no snapshot: nothing mutates a covering window's anchor (floating's
/// setFloatingRect is gated on `presence != .covering`), so the base mode
/// already holds the pre-fullscreen geometry to return to.
/// OFF (intent set): clears the covering intent, returning the window to
/// `.present` with its anchor untouched.
///
/// Returns true iff a transition happened (turn on OR turn off). Returns false
/// when the entry is missing or when the window is currently minimized (gated
/// feature->feature guard). The model store's capacity is the ceiling, so no
/// separate fullscreen-store capacity check exists.
pub fn toggleFullscreen(m: *model.Model, win: model.WindowId) bool {
    if (providerOf(.isWindowHidden)) |wm| {
        if (wm.isWindowHidden.?(m, win)) return false;
    }
    const e = m.store.getPtr(win) orelse return false;
    if (e.covering_ws != null) {
        // OFF: leave fullscreen; clearing the core intent replays the
        // unchanged anchor and drops the covering presence.
        releaseCovering(m, win);
        return true;
    }
    // Covering SWITCH: claiming the screen while another window already
    // owns it on this workspace releases the previous occupant's claim
    // first. sync's occupant scan (model.coveringOccupantOnWs) elects the
    // covering winner by store order, so a stale second claim would keep
    // the OLD window covering and park the entrant — the switch could never
    // take effect. Exactly one covering intent per workspace. The release
    // is gated on the ENTERING window being able to claim this workspace
    // (present-not-parked and visible on it): a stray intent targeting a
    // ws the entrant is not on must not displace the resident owner.
    const entrant_claims_ws = e.presence != .parked and model.visibleOn(m, win, m.current);
    if (entrant_claims_ws) {
        if (model.coveringOccupantOnWs(m, m.current)) |occupant| {
            if (occupant != win) releaseCovering(m, occupant);
        }
    }
    e.presence = .covering;
    e.covering_ws = m.current; // model stays the authority on the capture target
    return true;
}

/// True when `win` holds a covering (fullscreen) capture, derived from the
/// MODEL's core `covering_ws` intent. Reports true even while the model
/// presence is parked — a minimized-from-fullscreen window keeps `covering_ws`
/// set — so the ghost state is preserved. Reading the model here keeps this
/// predicate consistent with `fullscreenWsOf` and the core
/// `coveringOccupantOnWs`, with no module record to drift out of lockstep.
pub fn isFullscreenMode(m: *const model.Model, win: model.WindowId) bool {
    const e = m.store.get(win) orelse return false;
    return e.covering_ws != null;
}

/// The workspace `win`'s covering capture anchors to, per the MODEL's core
/// `covering_ws` intent. GHOST: still reports the ws even while the model
/// presence is parked (minimized-from-fullscreen: minimize leaves
/// `covering_ws` set), so callers classifying drops/withdraw-without-destroy
/// can read the true target before teardown.
pub fn fullscreenWsOf(m: *const model.Model, win: model.WindowId) ?model.WSId {
    const e = m.store.get(win) orelse return null;
    return e.covering_ws;
}

/// Whether `win`'s covering capture targets `ws`. Unlike
/// fullscreenOccupantOnWs this does NOT consult visibility; callers use it for
/// pre-toggle classification and was-fullscreen captures. Reads the model's
/// `covering_ws` intent.
pub fn isFullscreenOnWs(m: *const model.Model, win: model.WindowId, ws: model.WSId) bool {
    const fws = fullscreenWsOf(m, win) orelse return false;
    return fws.eql(ws);
}

/// Clears `win`'s covering intent, returning the window to plain presence.
/// The anchor needs no replay: nothing mutates a covering window's anchor
/// (floating's setFloatingRect is gated on `presence != .covering`), so the
/// base mode stands as recorded. Shared by the toggle-offs and the
/// occupant-eviction path.
fn releaseCovering(m: *model.Model, win: model.WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    e.presence = .present;
    e.covering_ws = null; // release the core covering intent
}

/// The first window holding a covering capture of `ws`: presence must be
/// covering (not parked), the capture must anchor to `ws`, and the window must
/// be visible on `ws` (a stray intent whose base is tagged elsewhere never
/// counts as an occupant — sync parks such strays instead of letting them
/// claim the slot). Pure store-order AND scan over the model: the entry IS the
/// record, so there is no separate registry to scan. At most one visible
/// occupant per ws is guaranteed by sync (others parked).
/// Contrast `model.coveringOccupantOnWs` (OR: anchor-or-visibility union).
/// Routed through contract.coveringOccupantOnWs for the workspaces move/tag seam.
pub fn fullscreenOccupantOnWs(m: *const model.Model, ws: model.WSId) ?model.WindowId {
    var it = m.store.iterator();
    while (it.next()) |row| {
        const e = row.val;
        if (e.presence != .covering) continue;
        if (e.covering_ws) |cws| {
            if (!cws.eql(ws)) continue;
        } else {
            continue;
        }
        if (!model.visibleOn(m, row.key, ws)) continue;
        return row.key;
    }
    return null;
}

/// Seam for the workspaces module's move/tag slice: retargets `win`'s
/// covering intent to `ws` (a covering window stays covering; a ghost of a
/// minimized window follows the mask) by writing the MODEL's core
/// `covering_ws` — the single authority on the capture target. The caller has
/// already confirmed the destination is not occupied.
pub fn moveFullscreenTo(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    const eptr = m.store.getPtr(win) orelse return;
    if (eptr.covering_ws == null) return;
    eptr.covering_ws = ws;
}

/// Persistence needs no module blob: `anchor` and `covering_ws` are carried
/// verbatim by `persist.WindowRecord`, so there is no serialize/deserialize
/// seam here (minimize alone claims the `ext` slot for parked windows).

// ---------------------------------------------------------------------------
// Protocol hooks (EWMH advertisement + deferred bar hide/show).
// ---------------------------------------------------------------------------

// Sets or clears the EWMH _NET_WM_STATE_FULLSCREEN property on `win`. The
// actual change_property write is routed through sync's sink (the ONLY writer
// to X); the EWMH atoms stay resolved here and the write is queued inside the
// enclosing grab (reconcileUnderGrabNowFullscreen), whose ungrabAndFlush lands
// it atomically with geometry. Guards on both EWMH atoms being valid; pub for
// actions.fullscreenToggleWindow, keeping the advertisement protocol-side.
pub fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    pipeline.grabCtx().sink.setEwmhFullscreen(
        win,
        g_net_wm_state,
        g_net_wm_state_fullscreen,
        is_fullscreen,
    );
}

// The protocol-side geometry commit helpers are gone: sync.reconcile derives
// their wire traffic from the model.

/// Called from the ConfigureNotify handler in events.zig. Drives both deferred
/// bar transitions: hide on confirmed fullscreen dimensions (enter), show on
/// non-fullscreen ones (exit). Safe for every ConfigureNotify; no-ops when
/// nothing is pending or dimensions don't match.
pub fn notifyConfigureIfPending(win: u32, width: u16, height: u16) void {
    const cs = core.getState();
    const screen_w = @as(u16, @intCast(cs.screen.width_in_pixels));
    const screen_h = @as(u16, @intCast(cs.screen.height_in_pixels));

    // Deferred bar hide (enter-fullscreen path): window must report exactly
    // screen dimensions before we hide the bar. Deferred bar show (exit
    // path) must report non-fullscreen dimensions first. The else-if makes
    // the mutual exclusion explicit: both can never match for the same win.
    // In both cases we only bump core's fullscreen-occupancy fact; the bar
    // (a consumer) derives its own hide/show from that fact.
    if (g_pending_bar_hide_win == win) {
        if (width == screen_w and height == screen_h) {
            g_pending_bar_hide_win = 0;
            core.fullscreen.bump();
        }
    } else if (g_pending_bar_show_win == win) {
        if (width != screen_w or height != screen_h) resolvePendingBarShow();
    }
}

fn resolvePendingBarShow() void {
    g_pending_bar_show_win = 0;
    core.fullscreen.bump();
}

/// Arm the deferred bar-hide from the fullscreenToggle path.
pub fn armPendingBarHide(win: u32) void {
    g_pending_bar_show_win = 0;
    g_pending_bar_hide_win = win;
}

/// Arm the deferred bar-show after an exit reconcile (armed AFTER geometry
/// settles).
pub fn armPendingBarShow(win: u32) void {
    g_pending_bar_hide_win = 0;
    g_pending_bar_show_win = win;
}

/// Record cleanup on window teardown; the wire layer fires this (events /
/// unmanage) after removing the store entry. Also clears any pending deferred
/// bar op so the bar doesn't stay stuck (both show and hide cases).
pub fn onWindowGone(win: u32) void {
    if (g_pending_bar_show_win == win) resolvePendingBarShow();
    if (g_pending_bar_hide_win == win) g_pending_bar_hide_win = 0;
}

/// This module's window sub-system contribution: lifecycle + coverage seam +
/// the EWMH/bar protocol hooks.
pub const module: @import("contract").WindowModule = .{
    .init = init,
    .deinit = deinit,
    .notifyConfigureIfPending = notifyConfigureIfPending,
    .onWindowGone = onWindowGone,
    .setEwmhFullscreenState = setEwmhFullscreenState,
    .armPendingBarHide = armPendingBarHide,
    .armPendingBarShow = armPendingBarShow,
    .toggleCovering = toggleFullscreen,
    .isCoveringMode = isFullscreenMode,
    .coveringWsOf = fullscreenWsOf,
    .isCoveringOnWs = isFullscreenOnWs,
    .coveringOccupantOnWs = fullscreenOccupantOnWs,
    .moveCoveringTo = moveFullscreenTo,
};
