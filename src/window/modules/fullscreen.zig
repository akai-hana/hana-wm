//! Fullscreen (covering) window management: toggles a window between present
//! and covering using `model.covering_ws` as the single source of truth,
//! advertises `_NET_WM_STATE_FULLSCREEN` via EWMH, and coordinates deferred
//! bar hide/show on ConfigureNotify. A minimized covering window stays a
//! ghost (retains `covering_ws`) so restore reclaims the screen.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const model = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const build_options = @import("build_options");
const log = std.log.scoped(.fullscreen);
const registry = @import("registry");
const surfaces = @import("surfaces").Surfaces;
const window_mods = @import("window_modules").modules;
const atoms = @import("atoms");

// Peers reach each other's hooks through the generated window registry,
// never by naming a sibling module (deleting a sibling only shortens the
// registry).

/// One window's pending bar intent. Public: `PendingBarTable`'s element type
/// (a private element would leak through `take`'s signature).
pub const PendingBar = struct {
    win: u32,
    hide: bool,
};

/// Windows awaiting ConfigureNotify confirmation of a deferred bar
/// transition (enter = hide, exit = show); mutually exclusive per window, so
/// one entry carries both.
///
/// PER WINDOW, not one slot: with a single slot, arming a second window's
/// intent silently DISCARDS the first -- its ConfigureNotify finds nothing
/// pending and its bar state stays wrong with nothing in the log. A covering
/// transition is in flight for at most one window per workspace, so a
/// handful of entries is ample.
///
/// AT THE BOUND the new arm takes the last slot (the prior holder loses its
/// transition) -- hence `max` = 8, not 2: the bound is a memory ceiling, not
/// a silent-drop budget.
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
            // Refuse to grow (len is the memory ceiling); reuse the last
            // slot, whose prior holder loses its transition.
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

    /// Read WITHOUT consuming: consuming an intent that cannot be evaluated
    /// yet would drop it on the floor.
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

// EWMH atoms resolved from the shared atom cache in init(). Zero when the
// cache was unavailable; setEwmhFullscreenState's guard skips the write then.
var g_net_wm_state: xcb.xcb_atom_t = 0;
var g_net_wm_state_fullscreen: xcb.xcb_atom_t = 0;

fn resetState() void {
    g_pending_bars.clear();
    g_net_wm_state = 0;
    g_net_wm_state_fullscreen = 0;
}

pub fn init() anyerror!void {
    resetState();

    // Resolve the EWMH fullscreen atoms from the shared cache, not a fresh
    // intern.
    g_net_wm_state = atoms.getAtomOrZero("_NET_WM_STATE");
    g_net_wm_state_fullscreen = atoms.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
}

pub fn deinit() void {
    resetState();
}

/// Toggle `win`'s fullscreen capture of the current workspace.
///
/// ON: sets `presence = .covering` plus the model's `covering_ws` (the single
/// authority on the capture target). The anchor needs no snapshot: nothing
/// mutates a covering window's anchor (setFloatingRect is gated on
/// `presence != .covering`), so the base mode already holds the
/// pre-fullscreen geometry. OFF: clears the intent, returning the window to
/// `.present` with its anchor untouched.
///
/// True iff a transition happened; false when the entry is missing or the
/// window is minimized (feature->feature guard).
pub fn toggleFullscreen(m: *model.Model, win: model.WindowId) bool {
    if (registry.hide.callHookBool(.isWindowHidden, .{ m, win })) return false;
    const e = m.store.getPtr(win) orelse return false;
    if (e.covering_ws != null) {
        // OFF: clearing the core intent replays the unchanged anchor and
        // drops the covering presence.
        releaseCovering(m, win);
        return true;
    }
    // Covering SWITCH: a resident occupant yields first (store-order scan).
    // The release is gated on the entrant being able to claim this
    // workspace (present and visible here): a stray intent elsewhere never
    // displaces the owner.
    const entrant_claims_ws = e.presence != .parked and model.visibleOn(m, win, m.current);
    if (entrant_claims_ws) {
        if (model.coveringOccupantOn(m, m.current, .anchored_or_visible)) |occupant| {
            if (occupant != win) releaseCovering(m, occupant);
        }
    }
    e.presence = .covering;
    e.covering_ws = m.current; // model stays the authority on the capture target
    return true;
}

/// Clears `win`'s covering intent and presence (no-op if not covering). The
/// anchor needs no replay (nothing mutates a covering window's anchor), so
/// the base mode stands as recorded.
///
/// This is the one-way entry for peers that mean "demote" (workspaces
/// move/tag): `toggleCovering` only reaches this body after proving the
/// window IS covering, and a demote must not turn into a fullscreen entry if
/// that proof is ever lost.
pub fn releaseCovering(m: *model.Model, win: model.WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    // Preserve a parked ghost's presence: minimize's record table still
    // claims a minimized covering window, so a `.present` ghost would be
    // orphaned (reconcile keeps it parked but no bookkeeping matches). A
    // `.covering` window drops to `.present`; a ghost stays `.parked` with
    // only its intent released.
    e.presence = if (e.presence == .parked) .parked else .present;
    e.covering_ws = null; // release the core covering intent
}

/// Retargets `win`'s covering intent to `ws` (a covering window stays
/// covering; a ghost follows the mask) by writing the model's `covering_ws` —
/// the single authority on the capture target. The caller has already
/// confirmed the destination is not occupied.
pub fn moveFullscreenTo(m: *model.Model, win: model.WindowId, ws: model.WSId) void {
    const eptr = m.store.getPtr(win) orelse return;
    if (eptr.covering_ws == null) return;
    eptr.covering_ws = ws;
}

/// Persistence needs no module blob: `anchor` and `covering_ws` ride
/// `session.WindowRecord` verbatim (minimize alone claims the `ext` slot).

// Protocol hooks (EWMH advertisement + deferred bar hide/show).

// Sets or clears the EWMH _NET_WM_STATE_FULLSCREEN property on `win`. The
// change_property write routes through sync's sink (the ONLY writer to X)
// inside the enclosing grab, whose ungrabAndFlush lands it atomically with
// geometry.
pub fn setEwmhFullscreenState(win: u32, is_fullscreen: bool) void {
    if (g_net_wm_state == xcb.XCB_ATOM_NONE or g_net_wm_state_fullscreen == xcb.XCB_ATOM_NONE) return;
    // currentCtx, NOT a fresh ctx: a fresh one would rebuild
    // `.workarea`/`.bar_win` mid-grab and re-run pre-reconcile duties after
    // geometry was applied, so model and server could disagree before
    // ungrabAndFlush.
    pipeline.currentCtx().sink.setStateAtom(
        win,
        g_net_wm_state,
        g_net_wm_state_fullscreen,
        is_fullscreen,
    );
}

// Protocol-side geometry commits are derived by reconcile.run from the model.

/// Called from events.zig's ConfigureNotify handler. Drives both deferred
/// bar transitions (hide on confirmed fullscreen dimensions, show on
/// non-fullscreen ones). No-ops when nothing is pending or dimensions
/// don't match.
pub fn notifyConfigureIfPending(win: u32, width: u16, height: u16) void {
    // PEEK, not take: a ConfigureNotify that cannot yet decide must LEAVE
    // the intent armed. Clients burst ConfigureNotify around a state change,
    // and the first can land before either side settled -- taking it then
    // silently dropped the transition and the bar stayed wrong until the next
    // toggle. Taking only once a decision fires keeps "deferred" meaning
    // deferred; onWindowGone clears any intent at teardown.
    const pending = g_pending_bars.peek(win) orelse return;

    const cs = core.getState();
    const screen_w = @as(u16, @intCast(cs.screen.width_in_pixels));
    const screen_h = @as(u16, @intCast(cs.screen.height_in_pixels));

    // The ConfigureNotify DIMENSIONS confirm the server caught up, but the
    // decision is MODEL TRUTH: the bar follows `presence == .covering`.
    // Inferring from dimensions alone let the bar re-show over a window the
    // model still recorded as covering.
    const m = pipeline.state();
    const covering = if (m.store.get(win)) |e| e.presence == .covering else false;

    if (pending.hide) {
        // Enter: the window must have REPORTED screen dimensions, and the
        // model must agree it is covering.
        if (width == screen_w and height == screen_h and covering) {
            _ = g_pending_bars.take(win);
            core.fullscreen.bump();
        }
    } else if (width != screen_w or height != screen_h) {
        // Exit: reported non-fullscreen dimensions. If a DIFFERENT window
        // still covers, the bar stays hidden -- the model's answer, not this
        // window's geometry.
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

/// Resolve `win`'s pending bar intent WITHOUT waiting for confirmation, for
/// a caller that already answered the question itself (the exit toggle: the
/// deferred show could only re-publish what its own bump just published -- a
/// redundant repaint every time fullscreen is left).
///
/// No bump of its own; taking a pending HIDE is equally correct (a window
/// that left fullscreen can never satisfy the hide's confirmation, so the
/// intent was already unreachable).
pub fn resolvePendingBarNow(win: u32) void {
    _ = g_pending_bars.take(win);
}

/// Record cleanup on window teardown (wire layer fires this after removing
/// the store entry); clears any pending deferred bar op so the bar cannot
/// stay stuck.
pub fn onWindowGone(win: u32) void {
    const pending = g_pending_bars.take(win) orelse return;
    // A pending HIDE dies with the window; a pending SHOW must still bump
    // -- the bar has to be re-derived and the covering scan now comes back
    // empty.
    if (!pending.hide) core.fullscreen.bump();
}

/// Covering commands: the enter/exit/switch transition in ONE model
/// transition + ONE reconcile. The covering winner renders edge-to-edge
/// (screen rect, bw=0, pixel=0, ABOVE merged); everyone else parks
/// off-screen in the same transition. Floating exit replays from the base
/// rect via the LastSent diff; tiled exit re-derives from the tiling engine,
/// collapsing the pre-exit "restore then re-park" round.
///
/// Classification for the atomic grab path: a named kind instead of a
/// bool-pair so enter/exit/switch_ can't be passed inconsistently.
const FullscreenKind = enum { enter, exit, switch_ };

/// Covering toggle for an arbitrary window.
pub fn fullscreenToggleWindow(win: model.WindowId) void {
    fullscreenSetWindow(win, null);
}

/// The same transition with an explicit target state, for EWMH requests that
/// are a SET rather than a toggle. `_NET_WM_FULLSCREEN_REQUEST` carries the
/// end state in data32[0]; feeding it to a toggle inverts the request
/// (pressing F twice, or Firefox re-asserting fullscreen, would drop the
/// window OUT). `want` is null for the keybind and `_NET_WM_STATE` toggle
/// paths, which genuinely mean "flip".
pub fn fullscreenSetWindow(win: model.WindowId, want: ?bool) void {
    // Timing: action entry to synchronous transition completion INCLUDING
    // bar hide and the enclosing ungrabAndFlush — the point at which the bar
    // is gone and the window is sized. Gated on `-Dprofile-key`.
    const fs_t0: u64 = if (build_options.profile_key) core.monotonicNs() else 0;
    const m = pipeline.mut();
    // Never cover a window off the viewed workspace: the covering
    // record binds the current workspace and would claim it while hidden.
    if (!model.visibleOn(m, win, m.current)) return;

    // Classify BEFORE toggling: classification and prev_fs_win share one
    // occupant scan.
    const prev_fs_win = model.coveringOccupantOn(m, m.current, .anchored_and_visible);
    const is_fs = model.isCoveringOn(m, win, m.current);
    // An explicit request matching the current state is a no-op: without
    // this guard a redundant request would flip the window the wrong way.
    if (want) |target| if (target == is_fs) return;
    const kind: FullscreenKind =
        if (is_fs) .exit else if (prev_fs_win != null) .switch_ else .enter;
    const was_focused = m.focused == win;

    // Direct call, not covering.providerOf(.toggleCovering): this module
    // binds toggleCovering unconditionally (single-binder), so the registry
    // lookup only ever re-found this file's own fn.
    if (!toggleFullscreen(m, win)) return;

    // Focus the covering winner unless it already owns focus or the toggle
    // turned fullscreen OFF: a covering window owns the screen and must own
    // keyboard focus (EWMH requests can arrive for an unfocused window; a
    // switch can raise a window the pointer is not over). Model write before
    // reconcile; X focus inside the same grab after the reconcile
    // maps/raises the entrant. `.none` for a no_input entrant.
    var ft: focus.FocusTransition = .none;
    if (kind != .exit and !was_focused) ft = focus.prepareAndSetFocus(m, win, .user_command);

    // Atomic transition: reconcile, focus handoff, EWMH writes and bar
    // hide/show all land inside the same server grab, so geometry, stacking,
    // input focus and the bar's claim can never be observed half-applied.
    // `ft` is the optional focus transition (`.none` for
    // exit/already-focused): applied AFTER the reconcile so the entrant is
    // mapped+raised before xcb_set_input_focus targets it (the mapRequest
    // ordering rule).
    {
        const g = pipeline.grabScoped();
        defer g.deinit();
        g.reconcileNow(.{ .force_restack = true });
        focus.applyPendingFocus(ft);
        // EWMH advertisement inside the grab: clear for whoever left
        // fullscreen, set for entrant (fire-and-forget change_property). Not
        // registry.dispatchAll: that passes ONE argument set to every binder,
        // and this needs two calls with different arguments (clear the
        // previous winner, then set this one) plus a kind condition.
        for (window_mods) |wm_mod| {
            if (wm_mod.setEwmhFullscreenState) |hook| {
                if (kind == .switch_) {
                    if (prev_fs_win) |old| hook(old, false);
                }
                hook(win, kind != .exit);
            }
        }
        // Bar hide/show inside the grab, no separate grab/reconcile cycle.
        // ENTER: unmap the bar immediately -- the fullscreen client is
        // already mapped+raised+screen-sized, so it covers the bar before the
        // unmap lands. EXIT: arm the deferred show, confirmed by the client's
        // ConfigureNotify.
        if (kind != .exit) {
            // Immediate bar unmap when fullscreen claims the usable area.
            surfaces.hideBarForFullscreen();
        } else {
            // Exit: deferred bar show.
            if (m.focused) |w| {
                registry.dispatchAll(.armPendingBarShow, .{w});
            }
        }
    }

    // Deterministic exit reaction: the model loses its covering occupant the
    // moment the toggle lands, so bump the fact now. The deferred show alone
    // is not enough -- it waits for a non-fullscreen ConfigureNotify, which
    // never arrives when the restored anchor IS the screen size. Resolving
    // the arm here keeps this bump the ONLY one (no second answer republishing
    // an identical bar).
    if (kind == .exit) {
        registry.dispatchAll(.resolvePendingBarNow, .{win});
        core.fullscreen.bump();
    }

    // Completion is synchronous: elapsed time already covers the reconcile,
    // the immediate bar hide, and the ungrabAndFlush.
    if (build_options.profile_key) {
        const dt = core.monotonicNs() - fs_t0;
        log.info("[FSPROF] win={d} kind={s} done {d}ns", .{
            win, @tagName(kind), dt,
        });
    }
}

/// This module's window contribution: lifecycle + coverage hooks + the
/// EWMH/bar protocol hooks.
pub const module: @import("window_contract").WindowModule = .{
    .name = "fullscreen",
    .init = init,
    .deinit = deinit,
    .notifyConfigureIfPending = notifyConfigureIfPending,
    .onWindowGone = onWindowGone,
    .setEwmhFullscreenState = setEwmhFullscreenState,
    .armPendingBarHide = armPendingBarHide,
    .armPendingBarShow = armPendingBarShow,
    .resolvePendingBarNow = resolvePendingBarNow,
    .covering = .{
        .toggleCovering = toggleFullscreen,
        .releaseCovering = releaseCovering,
        .moveCoveringTo = moveFullscreenTo,
    },
    .command = .{
        .toggleFullscreenWindow = fullscreenToggleWindow,
        .setFullscreenWindow = fullscreenSetWindow,
    },
};
