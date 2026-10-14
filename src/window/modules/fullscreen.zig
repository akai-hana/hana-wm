//! Fullscreen (covering) window management.
//!
//! Owns fullscreen transitions and protocol: toggles a window between present
//! and covering using `model.covering_ws` as the single source of truth,
//! advertises `_NET_WM_STATE_FULLSCREEN` via EWMH, and coordinates deferred bar
//! hide/show on ConfigureNotify. A minimized covering window remains a ghost
//! (retains `covering_ws`) so restore reclaims the screen.

const core = @import("core");
const xcb = core.xcb;
const model = @import("model");
const pipeline = @import("pipeline");
const window = @import("window");
// Peers reach each other's hooks through the generated window registry,
const atoms = @import("atoms");
// never by naming a sibling module: deleting a sibling only shortens the
// registry, and capabilities stay provider-agnostic.

/// One window's pending bar intent. Public because it is `PendingBarTable`'s
/// element type: a private element would leak through `take`'s signature.
pub const PendingBar = struct {
    win: u32,
    hide: bool,
};

/// Windows awaiting ConfigureNotify confirmation of a deferred bar transition:
/// enter (hide the bar) or exit (show it). The two intents are mutually
/// exclusive PER WINDOW (arming one clears the other for that window), so one
/// entry per window carries both.
///
/// PER WINDOW, not one slot (12.7). A single optional slot meant arming a
/// second window's intent silently DISCARDED the first: that window's
/// ConfigureNotify then found nothing pending, never bumped the fact, and its
/// bar state stayed whatever the second window decided -- a hide that never
/// hides, or a show that never shows, with nothing in the log. A covering
/// transition is in flight for at most one window per workspace, so a handful
/// of entries is ample.
///
/// AT THE BOUND: the new arm takes the last slot, so the window that held that
/// slot loses its transition. That is a real (if far-out-of-range) loss, and
/// it is why `max` is 8 rather than 2: the single-slot bug dropped a transition
/// on the SECOND concurrent arm, and 8 keeps the practical path at zero loss.
/// The bound is a memory ceiling, not a silent-drop budget.
pub const PendingBarTable = struct {
    pub const max = 8;
    entries: [max]PendingBar = undefined,
    len: usize = 0,

    /// Upsert `win`'s intent, replacing any existing entry for it.
    pub fn arm(self: *PendingBarTable, win: u32, hide: bool) void {
        for (self.entries[0..self.len], 0..) |e, i| {
            if (e.win != win) continue;
            self.entries[i] = .{ .win = win, .hide = hide };
            return;
        }
        if (self.len == max) {
            // Refuse to grow (len is the memory ceiling). Reuse the last
            // slot, whose previous holder loses its transition -- see the
            // AT THE BOUND note on the type.
            self.entries[max - 1] = .{ .win = win, .hide = hide };
            return;
        }
        self.entries[self.len] = .{ .win = win, .hide = hide };
        self.len += 1;
    }

    /// Remove and return `win`'s pending intent, or null when it has none.
    pub fn take(self: *PendingBarTable, win: u32) ?PendingBar {
        for (self.entries[0..self.len], 0..) |e, i| {
            if (e.win != win) continue;
            const found = e;
            self.entries[i] = self.entries[self.len - 1];
            self.len -= 1;
            return found;
        }
        return null;
    }

    /// Read an entry WITHOUT consuming it, for a decision that may not be
    /// decidable yet. Consuming an intent that could not be evaluated drops it
    /// on the floor -- see notifyConfigureIfPending.
    pub fn peek(self: *const PendingBarTable, win: u32) ?PendingBar {
        for (self.entries[0..self.len]) |e| {
            if (e.win == win) return e;
        }
        return null;
    }

    pub fn clear(self: *PendingBarTable) void {
        self.len = 0;
    }
};

var g_pending_bars: PendingBarTable = .{};

// EWMH atoms for _NET_WM_STATE_FULLSCREEN, resolved from the shared atom
// cache (atoms.initAtomCache) in init(). Zero (XCB_ATOM_NONE) when the cache
// was unavailable; setEwmhFullscreenState's guard already skips the write then.
var g_net_wm_state: xcb.xcb_atom_t = 0;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = 0;

// Shared reset sequence used by both init() and deinit() to keep them in sync.
fn resetState() void {
    g_pending_bars.clear();
    g_net_wm_state = 0;
    g_net_wm_state_fullscreen = 0;
}

pub fn init() anyerror!void {
    resetState();

    // Re-resolve the EWMH fullscreen atoms from the shared atom cache rather
    // than interning them again here.
    g_net_wm_state = atoms.getAtomOrZero("_NET_WM_STATE");
    g_net_wm_state_fullscreen = atoms.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
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
    if (window.callHookBool(.isWindowHidden, .{ m, win })) return false;
    const e = m.store.getPtr(win) orelse return false;
    if (e.covering_ws != null) {
        // OFF: leave fullscreen; clearing the core intent replays the
        // unchanged anchor and drops the covering presence.
        releaseCovering(m, win);
        return true;
    }
    // Covering SWITCH: a resident occupant of this ws yields first
    // (sync's store-order scan, model.coveringOccupantOnWs). The release
    // is gated on the entrant being able to claim this ws (present and
    // visible here): a stray intent elsewhere never displaces the owner.
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

// 12.4: `isFullscreenMode`, `fullscreenWsOf` and `isFullscreenOnWs` are GONE.
// Each was a private copy of a model read (`covering_ws`), reached through a
// contract dispatch that resolves to null when no covering module is bound --
// so "is this window covering" was false in a build without one, and became
// a per-provider answer for a per-field fact. The queries are `model.isCovering`,
// `model.coveringWsOf` and `model.isCoveringOn`; they carry the same GHOST
// semantics these had (a minimized-from-covering window keeps `covering_ws`
// set and still reports its workspace).

/// Clears `win`'s covering intent, returning the window to plain presence.
/// The anchor needs no replay: nothing mutates a covering window's anchor
/// (floating's setFloatingRect is gated on `presence != .covering`), so the
/// base mode stands as recorded. Shared by the toggle-offs and the
/// occupant-eviction path.
/// One-way covering release (12.8): clears the intent and the covering
/// presence, and does nothing at all if `win` is not covering.
///
/// `toggleCovering` reaches this same body, but only after proving the window
/// IS covering. A peer that means "demote" (the workspaces move/tag seam) must
/// not have to re-derive that proof to use a two-edged verb safely, so this is
/// the entry that cannot turn a demote into a fullscreen entry.
pub fn releaseCovering(m: *model.Model, win: model.WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    // Preserve a parked ghost's presence: a minimized covering window holds its
    // covering intent while `.parked` (the ghost semantics), and clearing that
    // intent must NOT resurrect it to `.present` -- minimize's record table
    // still claims it, so a `.present` ghost is an orphaned window that
    // reconcile keeps parked but nothing else bookkeeping matches. Demoting a
    // `.covering` (present) window drops it to `.present`; a minimized ghost
    // stays `.parked` with only its intent released.
    e.presence = if (e.presence == .parked) .parked else .present;
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
/// Routed through contract.visibleCoveringOnWs for the workspaces move/tag seam.
pub fn visibleCoveringOnWs(m: *const model.Model, ws: model.WSId) ?model.WindowId {
    var it = m.store.iterator();
    while (it.next()) |row| {
        const e = row.val;
        if (e.presence != .covering) continue;
        const cws = e.covering_ws orelse continue;
        if (!cws.eql(ws)) continue;
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

// Protocol hooks (EWMH advertisement + deferred bar hide/show).

// Sets or clears the EWMH _NET_WM_STATE_FULLSCREEN property on `win`. The
// actual change_property write is routed through sync's sink (the ONLY writer
// to X); the EWMH atoms stay resolved here and the write is queued inside the
// enclosing grab (reconcileUnderGrabNowFullscreen), whose ungrabAndFlush lands
// it atomically with geometry. Guards on both EWMH atoms being valid; pub for
// actions.fullscreenToggleWindow, keeping the advertisement protocol-side.
pub fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    // currentCtx, NOT a fresh ctx: this hook runs inside the fullscreen
    // operation's grab, and the doc says so. Asking for a new ctx here (the
    // old grabCtx) rebuilt `.workarea`/`.bar_win` mid-grab and re-ran the
    // pre-reconcile duties after geometry had already been applied, so the
    // model and the server could disagree before the single ungrabAndFlush.
    pipeline.currentCtx().sink.setStateAtom(
        win,
        g_net_wm_state,
        g_net_wm_state_fullscreen,
        is_fullscreen,
    );
}

// The protocol-side geometry commit helpers are gone: reconcile.run derives
// their wire traffic from the model.

/// Called from the ConfigureNotify handler in events.zig. Drives both deferred
/// bar transitions: hide on confirmed fullscreen dimensions (enter), show on
/// non-fullscreen ones (exit). Safe for every ConfigureNotify; no-ops when
/// nothing is pending or dimensions don't match.
pub fn notifyConfigureIfPending(win: u32, width: u16, height: u16) void {
    // PEEK, not take. A ConfigureNotify that cannot yet decide the question
    // must LEAVE the intent armed: a client sends a burst of ConfigureNotify
    // around a state change, and the first one can land before either side
    // settled -- non-screen dimensions while the model still says the window
    // covers, or screen dimensions while the model has not caught up. Taking
    // the entry on that first report silently dropped the transition, so the
    // bar never moved and stayed wrong until the next fullscreen toggle.
    // Taking it only once a decision fires keeps "deferred" meaning deferred.
    // The entry is per-window and onWindowGone clears it at teardown, so an
    // intent that never resolves cannot outlive its window.
    const pending = g_pending_bars.peek(win) orelse return;

    const cs = core.getState();
    const screen_w = @as(u16, @intCast(cs.screen.width_in_pixels));
    const screen_h = @as(u16, @intCast(cs.screen.height_in_pixels));

    // The ConfigureNotify DIMENSIONS are the confirmation that the server has
    // caught up, but the decision itself is MODEL TRUTH (12.7): the bar
    // follows `presence == .covering`, not "the numbers went back to normal".
    // Inferring hide/show from the dimensions is what let the bar re-show
    // while the model still recorded a covering occupant (a client that
    // reports screen-sized geometry after being told to leave fullscreen) --
    // the bar would come back over a covering window and stay.
    const m = pipeline.model();
    const covering = if (m.store.get(win)) |e| e.presence == .covering else false;

    if (pending.hide) {
        // Enter: the window must have REPORTED screen dimensions, and the
        // model must agree it is covering.
        if (width == screen_w and height == screen_h and covering) {
            _ = g_pending_bars.take(win);
            core.fullscreen.bump();
        }
    } else if (width != screen_w or height != screen_h) {
        // Exit: the window has reported non-fullscreen dimensions. Bump only
        // when the model agrees nothing here is covering; if a DIFFERENT window
        // still covers, the bar must stay hidden, and that is the model's
        // answer rather than this window's geometry.
        if (!covering) {
            _ = g_pending_bars.take(win);
            core.fullscreen.bump();
        }
    }
}

/// Arm the deferred bar-hide from the fullscreenToggle path.
pub fn armPendingBarHide(win: u32) void {
    g_pending_bars.arm(win, true);
}

/// Arm the deferred bar-show after an exit reconcile (armed AFTER geometry
/// settles).
pub fn armPendingBarShow(win: u32) void {
    g_pending_bars.arm(win, false);
}

/// Resolve `win`'s pending bar intent WITHOUT waiting for its confirmation,
/// for a caller that has already answered the question itself.
///
/// The exit toggle is that caller: the model loses its covering occupant the
/// moment the toggle lands, so it bumps the fact directly and the deferred
/// show can only ever re-publish the state that bump just published -- one
/// redundant repaint of an identical bar, every time fullscreen is left. The
/// toggle already decided, so it takes the intent here rather than leaving it
/// armed for a ConfigureNotify to decide the same question a second time.
///
/// No bump of its own: the caller is bumping because its own state changed,
/// and this only retires the intent that would have bumped for it. Taking a
/// pending HIDE here is equally correct -- a window that left fullscreen can
/// never still satisfy the hide's confirmation, so the intent was already
/// unreachable and dropping it is the same answer the hide path would give.
pub fn resolvePendingBarNow(win: u32) void {
    _ = g_pending_bars.take(win);
}

/// Record cleanup on window teardown; the wire layer fires this (events /
/// unmanage) after removing the store entry. Also clears any pending deferred
/// bar op so the bar doesn't stay stuck (both show and hide cases).
pub fn onWindowGone(win: u32) void {
    const pending = g_pending_bars.take(win) orelse return;
    // A pending HIDE just dies with the window. A pending SHOW must still
    // bump: the window is gone, so the bar has to be re-derived, and the
    // model's covering scan will now come back empty. Note the entry is
    // already taken, so there is nothing left to clear.
    if (!pending.hide) core.fullscreen.bump();
}

/// This module's window sub-system contribution: lifecycle + coverage seam +
/// the EWMH/bar protocol hooks.
pub const module: @import("contract").WindowModule = .{
    .name = "fullscreen",
    .init = init,
    .deinit = deinit,
    .notifyConfigureIfPending = notifyConfigureIfPending,
    .onWindowGone = onWindowGone,
    .setEwmhFullscreenState = setEwmhFullscreenState,
    .armPendingBarHide = armPendingBarHide,
    .armPendingBarShow = armPendingBarShow,
    .resolvePendingBarNow = resolvePendingBarNow,
    .toggleCovering = toggleFullscreen,
    .visibleCoveringOnWs = visibleCoveringOnWs,
    .releaseCovering = releaseCovering,
    .moveCoveringTo = moveFullscreenTo,
};
