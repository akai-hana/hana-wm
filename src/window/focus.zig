//! Focus management module.
//! Manages setting, clearing, and tracking the currently focused window.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const utils = @import("utils");
const window = @import("window");
const tracking = @import("tracking");
const debug = @import("debug");
const pipeline = @import("pipeline");
const model_mod = @import("model");

// Private transition-layer gate for mutable model access (per-owner token,
// see tracking.gate).
const gate: @import("pipeline").Gate = .{};

// Module state
//
// Grouped into a single State struct so init() resets everything in one
// assignment and the encapsulation boundary is obvious. Still exactly one
// focus context per process; the struct is for reset discipline, not
// multi-context support.

const State = struct {
    /// Focus TRUTH is `model.focused`; this is a private protocol-side
    /// cache of the last window we APPLIED X input focus to (dedupe + grab
    /// bookkeeping). Not a second store; readers go through getFocused().
    last_applied: ?u32 = null,
    suppress_reason: core.FocusSuppressReason = .none,
    /// True when the most recent prepareFocus returned `.none` because the
    /// target resolved to a no_input input model (as opposed to the
    /// already-applied dedup). Call sites that mutate the model themselves
    /// read `lastRejectWasNoInput()` synchronously after prepareFocus.
    no_input_reject: bool = false,

    // Most recent X event timestamp, maintained for external consumers that
    // need it for protocol ordering. focus.zig itself always uses CurrentTime
    // (0), see "Timestamp handling" below.
    last_event_time: u32 = 0,

    // _NET_ACTIVE_WINDOW atom, resolved in init(); XCB_ATOM_NONE when the
    // atom cache was unavailable (advertiseActiveWindow no-ops then).
    net_active_window: xcb.xcb_atom_t = xcb.XCB_ATOM_NONE,

    // Deferred async state: rather than blocking on xcb_get_input_focus
    // replies inline, we fire the request immediately and store the cookie,
    // draining it from the event loop on the next iteration to keep hot
    // paths non-blocking.
    //
    // tiling_op_cookie: "has the server caught up" round trip from
    //   beginTilingOpSettle() (see its doc comment).
    tiling_op_cookie: ?xcb.xcb_get_input_focus_cookie_t = null,
};

// PATTERN: module-global state with explicit init/deinit lifecycle (called
// from main.zig); avoids allocator threading through every function call.
// All functions operate on `state` directly rather than passing it as a
// parameter.
var state: ?State = null;

pub fn init() void {
    // Reset every field so a deinit()+init() cycle starts from a clean slate.
    state = .{};
    state.?.net_active_window = utils.getAtomCached("_NET_ACTIVE_WINDOW") catch 0;
}

pub fn deinit() void {
    // Discard pending cookies so they don't accumulate across a deinit()+init()
    // cycle; at process exit the connection close handles this implicitly.
    window.discardProtocolCookie(core.getState().conn, state.?.tiling_op_cookie);
    state = null;
}

// ---- Query API (pure reads) ----

/// Focus truth: reads model.focused; falls back to the protocol
/// cache only before pipeline.init (boot).
pub inline fn getFocused() ?u32 {
    if (pipeline.initialized) {
        if (pipeline.model().focused) |w| return @intCast(w);
        return null;
    }
    return state.?.last_applied;
}

pub inline fn getSuppressReason() core.FocusSuppressReason {
    return state.?.suppress_reason;
}

/// Debug/test invariant: the private protocol cache (`last_applied`) must
/// equal focus truth (`model.focused`) once a transition has SETTLED. The two
/// legitimately differ only while a two-phase prepare/apply is in flight
/// (apply updates the cache before the caller's model write lands). Before
/// pipeline.init there is no model truth, so the cache is the only record and
/// the invariant is vacuously true.
/// Test-only invariant check: the focus cache must mirror the model's last
/// assigned focus. Lives in-module (not the test) because it reads the
/// private `state`.
pub fn protocolParityHolds() bool {
    if (!pipeline.initialized) return true;
    const truth: ?u32 = if (pipeline.model().focused) |w| @intCast(w) else null;
    return state.?.last_applied == truth;
}

/// True when the most recent prepareFocus returned `.none` because the
/// target resolved to a no_input input model. prepareFocus returns `.none`
/// for both the no_input verdict and the already-applied dedup; call sites
/// that write the model on their own read this right after prepareFocus to
/// tell the two apart (a no_input target must never take model focus).
pub inline fn lastRejectWasNoInput() bool {
    return state.?.no_input_reject;
}

/// True when an incoming EnterNotify should be silently ignored.
///
/// Centralises suppression policy here so window.handleEnterNotify doesn't need
/// to know specific Reason values. NOTE: window_spawn suppression is handled in
/// window.zig's suppressSpawnCrossing, which inspects the crossing's own
/// coordinates (the origin-parked predicate); any reason
/// that doesn't need coordinate disambiguation belongs here.
pub inline fn shouldSuppressEnterNotify() bool {
    return state.?.suppress_reason == .tiling_operation;
}

pub inline fn getLastEventTime() u32 {
    return state.?.last_event_time;
}

// ---- Mutation API (side effects) ----

/// Update the X11 event timestamp.  Called by the EnterNotify and
/// LeaveNotify handlers before they call into focus logic.
/// See "Timestamp handling" below for why focus.zig itself always uses
/// CurrentTime (0) rather than forwarding this value.
pub inline fn setLastEventTime(t: u32) void {
    state.?.last_event_time = t;
}

// Timestamp handling
//
// focus.zig always passes CurrentTime (0) to xcb_set_input_focus and
// WM_TAKE_FOCUS, matching dwm. A real timestamp would risk the request being
// silently ignored: Electron/Qt apps forward the WM-provided timestamp to
// their own XSetInputFocus, and if it's older than the X server's
// last-focus-change-time (set by a later hover) the request is dropped, making
// the app appear unresponsive to hover. CurrentTime is always accepted.
// state.last_event_time is therefore kept only for external consumers, never
// used inside this module.

/// Sets X input focus to `win`, always with CurrentTime (0), see
/// "Timestamp handling" above.
///
/// A plain xcb_set_input_focus is sufficient; an earlier momentary
/// xcb_grab_keyboard wrapper was both ineffective (XGrabKeyboard returns
/// AlreadyGrabbed) and harmful (the transient grab re-routes keys and drops
/// the held key's KeyRelease, so the next press is silently suppressed).
inline fn focusNow(conn: core.Connection, win: u32) void {
    _ = xcb.xcb_set_input_focus(conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, 0);
}

/// Direct write to suppress_reason, for cases where suppression must be
/// cleared/set independently of any focus change (e.g. MotionNotify clearing
/// it when real pointer movement is detected).
pub inline fn setSuppressReason(r: core.FocusSuppressReason) void {
    state.?.suppress_reason = r;
}

// Button grab management
//
// Owned here rather than in window.zig because grabs are a focus-protocol
// concern, acquired/released only during focus transitions. The sole
// non-transition call site is actions.mapRequest (spawn admission), served by
// the public initWindowGrabs shim below.

/// Unconditionally release all button grabs on `win`, then, if `focused` is
/// false, re-grab all buttons so click-to-focus events are delivered to us.
fn grabButtons(win: u32, focused: bool) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_ungrab_button(conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    if (focused) return;
    _ = xcb.xcb_grab_button(
        conn,
        0,
        win,
        xcb.XCB_EVENT_MASK_BUTTON_PRESS,
        xcb.XCB_GRAB_MODE_SYNC,
        xcb.XCB_GRAB_MODE_SYNC,
        xcb.XCB_NONE,
        xcb.XCB_NONE,
        xcb.XCB_BUTTON_INDEX_ANY,
        xcb.XCB_MOD_MASK_ANY,
    );
}

/// Configure initial button grabs for a window that is being registered on a
/// non-current workspace (and thus never focused via the normal transition
/// path).  The window will have its grabs updated to `focused = true` the
/// first time it receives focus via the grab-wrapped focus path.
pub fn initWindowGrabs(win: u32) void {
    grabButtons(win, false);
}

pub const Reason = enum {
    /// Direct click on an unfocused window.
    mouse_click,

    /// EnterNotify hover (focus-follows-mouse). Lightweight: no raise, no
    /// focus-confirm machinery.
    mouse_enter,

    /// Keyboard-driven focus cycle or explicit WM command.
    user_command,

    /// Internal retile reassigned focus (tiling owns stacking).
    tiling_operation,

    /// Kept distinct so tiling operations cannot accidentally inherit
    /// window_spawn crossing suppression via external state.
    window_spawn,

    /// Workspace switch: suppression cleared, xcb_set_input_focus forced
    /// (even for globally_active input models) so X focus always lands on the
    /// target window rather than relying on WM_TAKE_FOCUS self-focus.
    /// Never raised (stacking order is already correct after the switch).
    /// The reconcile maps the arriving window before focus targets it so
    /// xcb_set_input_focus never hits an unmapped window.
    workspace_switch,
};

// CommitFlags: controls which side effects applyPendingFocus applies.
// All fields are non-defaulted (except take_focus_known, see below) so every
// call site must be explicit; an accidental zero-flags call fails to compile,
// preventing silent no-protocol transitions that are hard to debug.
const CommitFlags = struct {
    /// Send xcb_set_input_focus. False for no_input (never receives focus
    /// protocol) and globally_active (manages its own focus, ICCCM 4.1.7).
    /// Overridden to true by workspace_switch: an explicit switch must land
    /// X focus on the target window regardless of input model.
    set_input_focus: bool,

    /// Raise to the top of the stack. True for click/command (user-driven)
    /// and globally_active hover (raising is its only focus signal).
    raise: bool,

    /// Send WM_TAKE_FOCUS after xcb_set_input_focus. Required for
    /// locally_active and globally_active input models.
    send_wm_take_focus: bool,

    /// Authoritative WM_TAKE_FOCUS advertisement from the caller's own live
    /// protocol query (setFocus path, one round trip saved). Null keeps the
    /// pre-fired-cookie pipeline; defaulted unlike its siblings because it
    /// refines `send_wm_take_focus` rather than gating a side effect.
    take_focus_known: ?bool = null,

    /// Bump the core focus fact so focus-consuming surfaces (e.g. the bar's
    /// title segment) redraw. False only inside a server grab; the caller
    /// triggers the synchronous in-grab redraw (bar.redrawInsideGrab) instead.
    schedule_bar: bool,

    /// New suppress_reason. setFocus derives it via suppressionFor(); direct
    /// callers hardcode `.none`.
    new_suppress: core.FocusSuppressReason,
};

// Two-phase focus protocol (focus protocol + geometry land under one grab)
//
// Some actions need focus protocol + geometry to land under one server grab.
// The existing `setFocus`/`clearFocus` path does round trips (input-model
// resolve) that cannot run inside a grab. Split into two phases:
//
//   Phase 1 (outside grab): prepareFocus / prepareClearFocus
//     - Cache-only input-model resolve (a miss provisions dwm-style focus);
//       the only remaining round trip is the isWindowMapped liveness guard
//       used by mouse_click.
//     - Returns a FocusTransition descriptor (no X traffic)
//
//   Phase 2 (inside grab): applyPendingFocus
//     - Fire-and-forget XCB only: set_input_focus, grab_buttons, raise,
//       WM_TAKE_FOCUS, _NET_ACTIVE_WINDOW, bar dirty flag
//     - No round trips, no model updates
//
// The caller owns the model update (model.setFocus / model.clearFocus)
// and does it BEFORE the grab, so the model is consistent when the
// reconcile runs inside the grab.

pub const SetFocusIntent = struct {
    win: u32,
    old: ?u32,
    flags: CommitFlags,
};

pub const ClearFocusIntent = struct {
    old: ?u32,
};

pub const FocusTransition = union(enum) {
    set: SetFocusIntent,
    clear: ClearFocusIntent,
    none: void,
};

/// Phase 1: resolve input model (cache-only, never blocking).
/// Returns a FocusTransition that can be committed inside the grab.
/// Returns .none when focus should not change (invalid window, same window,
/// unmapped liveness guard, or no_input model).
///
/// The input model comes strictly from the focus-property cache; a miss
/// resolves provisionally (dwm's XSetInputFocus model) instead of a blocking
/// live query, so this hot path has zero round trips.
///
/// Build a `.set` FocusTransition from a resolved input model.
fn setIntent(win: u32, old: ?u32, resolved: anytype, opts: struct {
    raise: bool,
    new_suppress: core.FocusSuppressReason,
    /// Force xcb_set_input_focus even for globally_active input models.
    /// Workspace switch is an explicit user action: the WM must land X focus
    /// on the target window rather than relying on the app to self-focus via
    /// WM_TAKE_FOCUS.  Parked windows on the departing workspace may not
    /// respond to the protocol message, leaving X focus stranded on the old
    /// workspace's window.
    force_set_input_focus: bool = false,
}) FocusTransition {
    return .{ .set = .{
        .win = win,
        .old = old,
        .flags = .{
            .set_input_focus = opts.force_set_input_focus or resolved.model != .globally_active,
            .raise = opts.raise,
            .send_wm_take_focus = true,
            .take_focus_known = resolved.take_focus,
            .schedule_bar = true,
            .new_suppress = opts.new_suppress,
        },
    } };
}

pub fn prepareFocus(win: u32, reason: Reason) FocusTransition {
    const conn = core.getState().conn;
    state.?.no_input_reject = false;
    if (window.isInvalidWindow(win)) return .none;

    // Liveness guard first: a destroyed window must never be re-focused or
    // raised, even when it was the last_applied window (mouse_click paths).
    // .user_command is excluded: collectVisibleWindows already confirmed the
    // window is on the current workspace and visible, so the blocking
    // xcb_get_window_attributes round-trip is redundant.
    if (reason == .mouse_click and !isWindowMapped(conn, win))
        return .none;

    const resolved = window.peekInputModelResolved(win) orelse window.provisionalResolution();
    if (resolved.model == .no_input) {
        // Expose the no_input verdict to call sites: it returns the same
        // `.none` as a dedup skip, and callers that mutate the model on their
        // own need to tell them apart (a no_input target must never take
        // model focus, and a lone no_input window should leave X focus on the
        // root rather than anywhere it can't be reached).
        state.?.no_input_reject = true;
        return .none;
    }

    // Dedup: the same window already owns applied focus. A no-op for most
    // reasons, but a user-driven click still expects its raise side effect,
    // so an already-focused window re-raises instead of being swallowed by
    // the dedup. `old = null` lets applyPendingFocus skip the ungrab/
    // re-grab of that same window's buttons (a button-regrab flash).
    const force = reason == .workspace_switch;
    if (state.?.last_applied == win) {
        if (!shouldRaise(reason, win)) return .none;
        return setIntent(win, null, resolved, .{
            .raise = shouldRaise(reason, win),
            .new_suppress = suppressionFor(reason, state.?.suppress_reason),
            .force_set_input_focus = force,
        });
    }

    return setIntent(win, state.?.last_applied, resolved, .{
        .raise = shouldRaise(reason, win),
        .new_suppress = suppressionFor(reason, state.?.suppress_reason),
        .force_set_input_focus = force,
    });
}

/// Phase 1: prepare a focus-clear transition (outside grab).
/// Returns .none when there is no focused window to clear.
///
/// The clear target derives from the protocol cache (last_applied), and the
/// MODEL is the truth source for callers. A window teardown legitimately
/// clears model.focused while last_applied still holds the (now-removed)
/// window, so `m.focused == null` is a normal reason to clear, not a
/// divergence. Only a live model.focused that disagrees with last_applied is
/// worth a diagnostic; it still proceeds -- every clear caller nulls
/// model.focused right after, and skipping would strand X input focus on a
/// stale window the model no longer claims. Callers MUST run model.clearFocus
/// after this call.
pub fn prepareClearFocus() FocusTransition {
    const m = pipeline.model();
    const applied = state.?.last_applied;
    const focused: ?u32 = if (m.focused) |w| @as(u32, @intCast(w)) else null;

    if (applied == null) return .none; // model-only focus (none) -- nothing applied to clear
    if (focused) |f| {
        if (f != applied) {
            debug.warn(
                "focus: clear divergence last_applied=0x{x} model.focused=0x{x}; clearing applied",
                .{ applied.?, f },
            );
        }
    }

    return .{ .clear = .{ .old = applied } };
}

/// Shared shutdown tail of the focus-clear paths (applyPendingFocus's `.clear`
/// limb and applyClear): drop applied focus, reset suppression, refocus root.
fn clearTail() void {
    state.?.last_applied = null;
    state.?.suppress_reason = .none;
    const cs = core.getState();
    focusNow(cs.conn, cs.root);
    core.focus.bump();
    advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
}

/// Phase 2: apply a prepared focus transition with fire-and-forget XCB only.
/// Safe to call inside a server grab (no round trips, no model updates).
pub fn applyPendingFocus(t: FocusTransition) void {
    switch (t) {
        .set => |intent| {
            state.?.last_applied = intent.win;
            state.?.suppress_reason = intent.flags.new_suppress;

            grabButtons(intent.win, true);
            if (intent.old) |o| grabButtons(o, false);

            const conn = core.getState().conn;

            if (intent.flags.set_input_focus) focusNow(conn, intent.win);
            if (intent.flags.raise) utils.raiseWindow(conn, intent.win);

            if (intent.flags.send_wm_take_focus) {
                if (intent.flags.take_focus_known) |advertises| window.sendWMTakeFocusKnown(conn, intent.win, 0, advertises);
            }

            if (intent.flags.schedule_bar) core.focus.bump();

            advertiseActiveWindow(intent.win);
        },
        .clear => |intent| {
            if (intent.old) |old_win| grabButtons(old_win, false);
            clearTail();
        },
        .none => {},
    }
}

/// True if `win` currently has map_state == Viewable. Guards destroy/unmap
/// races on paths that can't guarantee the window is still alive.
inline fn isWindowMapped(conn: core.Connection, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(conn, xcb.xcb_get_window_attributes(conn, win), null) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}

/// Non-blocking cookie poll shared by the deferred async drains. Returns:
///  - `.pending` reply not ready; cookie kept alive for the next batch
///  - `.error`   request failed; the error was already freed, cookie consumed
///  - `.raw`     a ready reply (heap), cookie consumed; the caller must free it
const PollResult = struct {
    pending: bool = true,
    errored: bool = false,
    raw: ?*anyopaque = null,
};

/// Non-blocking cookie poll. Never blocks; `pending` keeps the cookie alive.
fn pollCookie(conn: core.Connection, seq: u32) PollResult {
    var reply: ?*anyopaque = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(conn, seq, &reply, &err);
    if (reply == null and err == null) return .{};
    if (err) |e| {
        std.c.free(e);
        return .{ .pending = false, .errored = true };
    }
    return .{ .pending = false, .raw = reply };
}

/// Shared drain preamble for the deferred async reply fields. Polls the
/// cookie in `field`; on a ready/errored reply clears the field (the cookie
/// is then consumed) and returns the outcome. When nothing is pending or the
/// reply hasn't arrived, `pending` is set and the cookie stays in flight.
fn drainCookie(comptime T: type, field: *?T) PollResult {
    const cookie = field.* orelse return .{ .pending = true, .errored = true };
    const res = pollCookie(core.getState().conn, cookie.sequence);
    if (res.pending) return res;
    field.* = null;
    return res;
}

/// Shared post-model-clear tail of the focus-clear paths: prepare the clear
/// transition and replay it locally.
fn applyClear() void {
    // prepareClearFocus reads the MODEL as the focus truth, so it must run
    // BEFORE model.clearFocus clears that decision source.
    const ft = prepareClearFocus();
    if (pipeline.initialized) model_mod.clearFocus(pipeline.mut(&gate));
    if (ft == .none) {
        clearTail();
        return;
    }
    applyPendingFocus(ft);
}

/// Write `_NET_ACTIVE_WINDOW` to the root window so EWMH clients stay in sync.
/// No-ops when the atom was not resolved at init time.
fn advertiseActiveWindow(win: u32) void {
    if (state.?.net_active_window == xcb.XCB_ATOM_NONE) return;
    const cs = core.getState();
    _ = xcb.xcb_change_property(cs.conn, xcb.XCB_PROP_MODE_REPLACE, cs.root, state.?.net_active_window, xcb.XCB_ATOM_WINDOW, 32, 1, &win);
}

/// True when `reason` should raise `win` to the top of the stacking order.
///
/// Tiled windows are excluded: the retile owns their stacking order and raises
/// the top window atomically; a pre-raise here would be a redundant request
/// that creates an intermediate compositor frame. mouse_enter never raises,
/// matching DWM; raising on every hover generates synthetic FocusOut/FocusIn
/// pairs that confuse Electron's internal focus state machine.
inline fn shouldRaise(reason: Reason, win: u32) bool {
    return switch (reason) {
        // Tiled windows get their stacking from sync's raise-the-winner pass
        // during the post-transition reconcile; everything else raises here.
        .mouse_click, .user_command => !tracking.isTiledMode(win),
        .mouse_enter, .tiling_operation, .window_spawn, .workspace_switch => false,
    };
}

inline fn suppressionFor(
    reason: Reason,
    current: core.FocusSuppressReason,
) core.FocusSuppressReason {
    return switch (reason) {
        // workspace_switch clears too: crossing events generated by windows
        // mapping/unmapping during the switch must not be masked.
        .mouse_click, .user_command, .workspace_switch => .none,
        .window_spawn => .window_spawn,
        else => current,
    };
}

// Grab-wrapped focus operations (full atomicity)
//
// These wrap the two-phase protocol (prepare + apply) in a server grab
// with a reconcile, ensuring focus, borders, and geometry all land
// atomically under one server grab.

/// Atomically focus `win` with `reason`. Focus protocol, borders, and geometry
/// land inside one server grab. Drop-in for the old setFocus path.
pub fn grabFocus(win: u32, reason: Reason) void {
    grabFocusWithDuty(win, reason, null);
}

/// Focus `win` with an optional `duty` that runs inside the SAME grab, after
/// the focus protocol but before the reconcile. Used by the focus-cycle path
/// to apply the viewport snap to the freshly focused window, so a Mod+k/Mod+j
/// that scrolls the viewport lands focus + geometry in one grab+reconcile
/// instead of focus-then-snap's two. The duty is skipped whenever the
/// transition resolves to `.none`, so a rejected target (no_input) never
/// leaves a stray viewport move.
///
/// Hover focus (`.mouse_enter`) is a focus-only commit: nothing geometric
/// changes, so it skips the reconcile (dwm's enternotify -> focus()). Borders
/// repaint via the per-batch sweep on the commit's focus bump.
pub fn grabFocusWithDuty(win: u32, reason: Reason, duty: ?*const fn () void) void {
    const ft = prepareFocus(win, reason);
    if (ft == .none) return;
    model_mod.setFocus(pipeline.mut(&gate), win);
    if (reason == .mouse_enter) {
        pipeline.focusOnlyCommit(ft);
        return;
    }
    pipeline.reconcileUnderGrabNowWithFocusDuty(.{}, ft, duty);
}

/// Fire an async "has the server caught up" round trip that defers lifting
/// EnterNotify suppression until crossing events from the tiling reflow have
/// been delivered and filtered. Used by tiling ops that must NOT re-sync
/// focus to wherever the pointer ends up; it never calls setFocus itself. The
/// reflow's events precede this reply in XCB order.
pub fn beginTilingOpSettle() void {
    window.discardProtocolCookie(core.getState().conn, state.?.tiling_op_cookie);
    const cs = core.getState();
    state.?.tiling_op_cookie = xcb.xcb_get_input_focus(cs.conn);
}

/// Drain the deferred tiling-op-settle reply, if one is pending, and lift
/// EnterNotify suppression. Safe to call when nothing is pending.
///
/// Only clears suppression while it is still .tiling_operation, so a different
/// reason set meanwhile (e.g. window_spawn) is never clobbered.
pub fn drainTilingOpSettle() void {
    const res = drainCookie(xcb.xcb_get_input_focus_cookie_t, &state.?.tiling_op_cookie);
    if (res.pending or res.errored) return;

    // The reply's content is unused; only its arrival signals that the server
    // has processed everything queued before it. It must be consumed to drain
    // the XCB queue.
    if (res.raw) |r| std.c.free(r);
    if (state.?.suppress_reason == .tiling_operation) state.?.suppress_reason = .none;
}

// Window focus cycling
//
// Scratch buffer for collectVisibleWindows, module-level so it isn't
// stack-allocated on every key press. Sized to the model store capacity: the
// cycle pool is not restricted to tiled slots (floating windows are admitted
// too), so sizing by max_tiled_windows dropped a floating tail above 64.

var cycle_buf: [model_mod.store_capacity]u32 = undefined;

/// Append `w` to cycle_buf if there is room and it is on the current workspace
/// and visible (not minimised).  Shared by both paths in collectVisibleWindows.
inline fn appendVisible(w: u32, len: *usize) void {
    if (len.* < cycle_buf.len and tracking.isOnCurrentWorkspaceAndVisible(w)) {
        cycle_buf[len.*] = w;
        len.* += 1;
    }
}

/// Build an ordered list of currently-visible windows for cycling.
///
/// A covering (fullscreen) occupant owns the viewed workspace's screen: it
/// is the only window actually on screen, so the cycle pool collapses to it.
/// Cycling then re-focuses/re-raises the occupant instead of fading focus
/// into windows parked behind fullscreen.
/// Otherwise, all visible windows in tracking-table order; the pool list is
/// never fed. Emits only windows that are on the current workspace and not
/// minimized.
/// Returns the count written into `cycle_buf`, or 0 if none.
fn collectVisibleWindows() usize {
    const m = pipeline.model();
    if (model_mod.coveringOccupantOnWs(m, m.current)) |occ| {
        cycle_buf[0] = occ;
        return 1;
    }
    var len: usize = 0;
    for (tracking.allWindows()) |entry| appendVisible(entry.win, &len);
    return len;
}

/// Returns the next (forward=true) or previous (forward=false) index in a
/// circular list of `len` elements, starting from `idx`.
inline fn cycleIndex(forward: bool, idx: usize, len: usize) usize {
    return if (forward) (idx + 1) % len else (idx + len - 1) % len;
}

/// Resolve the visible window a focus-cycle step would land on, or null when
/// the step is a no-op (no visible windows, or the only visible window is
/// already focused). Pure read: no focus change, no grab. The Mod+k/Mod+j
/// input path folds the target's viewport snap into the SAME grab as the
/// focus transition (one grab+reconcile instead of focus-then-snap).
pub fn cycleTarget(forward: bool) ?u32 {
    const len = collectVisibleWindows();
    if (len == 0) return null;
    const wins = cycle_buf[0..len];
    // Single visible window: the only sensible cycle step is to focus it
    // when it isn't focused already; the modulo wrap below would otherwise
    // spin a redundant grabFocus against the same id.
    if (len == 1) {
        const only = wins[0];
        return if (getFocused() == only) null else only;
    }
    // When the focused window isn't in the visible list, wrap so the very next
    // step lands on wins[0] (forward) or wins[len-1] (backward).
    const sentinel: usize = if (forward) len - 1 else 0;
    const idx = if (getFocused()) |w|
        std.mem.indexOfScalar(u32, wins, w) orelse sentinel
    else
        sentinel;
    return wins[cycleIndex(forward, idx, len)];
}
