//! Focus management module.
//! Manages setting, clearing, and tracking the currently focused window.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const utils = @import("utils");
const window = @import("window");
const tracking = @import("tracking");

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

    // Most recent X event timestamp, maintained for external consumers that
    // need it for protocol ordering. focus.zig itself always uses CurrentTime
    // (0), see "Timestamp handling" below.
    last_event_time: u32 = 0,

    // _NET_ACTIVE_WINDOW atom, resolved in init(); XCB_ATOM_NONE when the
    // atom cache was unavailable (advertiseActiveWindow no-ops then).
    net_active_window: xcb.xcb_atom_t = xcb.XCB_ATOM_NONE,

    // Deferred async state: rather than blocking on xcb_get_input_focus and
    // xcb_query_pointer replies inline, we fire the requests immediately and
    // store the cookies, draining them from the event loop on the next
    // iteration to keep hot paths non-blocking.
    //
    // confirm_cookie/confirm_win: non-compliant-client focus confirmation.
    // pointer_cookie: pending pointer-position query.
    // tiling_op_cookie: "has the server caught up" round trip from
    //   beginTilingOpSettle() (see its doc comment).
    // pre_protocols_cookie: WM_PROTOCOLS query fired at the START of focus
    //   preparation so the server processes it in parallel with bookkeeping;
    //   by the time applyPendingFocus needs it the reply is typically already
    //   in the receive buffer. null when not in use.
    confirm_cookie: ?xcb.xcb_get_input_focus_cookie_t = null,
    confirm_win: ?u32 = null,
    pointer_cookie: ?xcb.xcb_query_pointer_cookie_t = null,
    tiling_op_cookie: ?xcb.xcb_get_input_focus_cookie_t = null,
    pre_protocols_cookie: ?xcb.xcb_get_property_cookie_t = null,
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

/// Discard an optional XCB cookie without blocking.
/// All XCB cookie types share a `.sequence` field, so anytype covers all of them.
fn discardOptCookie(opt: anytype) void {
    if (opt) |ck| xcb.xcb_discard_reply(core.getState().conn, ck.sequence);
}

pub fn deinit() void {
    // Discard pending cookies so they don't accumulate across a deinit()+init()
    // cycle; at process exit the connection close handles this implicitly.
    discardOptCookie(state.?.pre_protocols_cookie);
    discardOptCookie(state.?.confirm_cookie);
    discardOptCookie(state.?.pointer_cookie);
    discardOptCookie(state.?.tiling_op_cookie);
    state = .{};
}

// ---- Query API (pure reads) ----

/// Focus truth: reads model.focused; falls back to the protocol
/// cache only before pipeline.init (boot).
pub inline fn getFocused() ?u32 {
    const pl = @import("pipeline");
    if (pl.initialized) {
        if (pl.model().focused) |w| return @intCast(w);
        return null;
    }
    return state.?.last_applied;
}

pub inline fn getSuppressReason() core.FocusSuppressReason {
    return state.?.suppress_reason;
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

    /// Deferred pointer-position query resolved after a tiling retile or
    /// window-close (drainPointerSync / resolveDestroyFocusTarget). Heavier:
    /// may raise a floating window, arms confirm/retry.
    pointer_sync,

    /// Keyboard-driven focus cycle or explicit WM command.
    user_command,

    /// Internal retile reassigned focus (tiling owns stacking).
    tiling_operation,

    /// Kept distinct so tiling operations cannot accidentally inherit
    /// window_spawn crossing suppression via external state.
    window_spawn,

    /// Workspace switch: window guaranteed mapped, suppression cleared, never
    /// raised (stacking order is already correct after the switch).
    workspace_switch,
};

// CommitFlags: controls which side effects applyPendingFocus applies.
// All fields are non-defaulted (except take_focus_known, see below) so every
// call site must be explicit; an accidental zero-flags call fails to compile,
// preventing silent no-protocol transitions that are hard to debug.
const CommitFlags = struct {
    /// Send xcb_set_input_focus. False for no_input (never receives focus
    /// protocol) and globally_active (manages its own focus, ICCCM 4.1.7).
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

    /// Arm the async focus-confirm cookie for a deferred raise-and-retry.
    /// Used by pointer_sync for windows that may silently drop focus.
    arm_confirm: bool,

    /// Bump the core focus fact so focus-consuming surfaces (e.g. the bar's
    /// title segment) redraw. False only inside a server grab; the caller
    /// triggers the synchronous in-grab redraw (bar.redrawInsideGrab) instead.
    schedule_bar: bool,

    /// New suppress_reason. setFocus derives it via suppressionFor(); direct
    /// callers hardcode `.none`.
    new_suppress: core.FocusSuppressReason,
};

// Two-phase focus protocol (Gap 1 atomicity fix)
//
// Some actions need focus protocol + geometry to land under one server grab.
// The existing `setFocus`/`clearFocus` path does round trips (input-model
// resolve) that cannot run inside a grab. Split into two phases:
//
//   Phase 1 (outside grab): prepareFocus / prepareClearFocus
//     - Round trips: isWindowMapped, getInputModelResolved
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

/// Phase 1: resolve input model via round trips (outside grab).
/// Returns a FocusTransition that can be committed inside the grab.
/// Returns .none when focus should not change (invalid window, same window,
/// unmapped liveness guard, or no_input model).
pub fn prepareFocus(win: u32, reason: Reason) FocusTransition {
    if (window.isInvalidWindow(win)) return .none;
    if (state.?.last_applied == win) return .none;

    const conn = core.getState().conn;

    // Liveness guard: same as setFocus (mouse_click/user_command/pointer_sync
    // must not focus a destroyed window).
    // .user_command is excluded: collectVisibleWindows already confirmed the
    // window is on the current workspace and visible, so the blocking
    // xcb_get_window_attributes round-trip is redundant.
    if ((reason == .mouse_click or reason == .pointer_sync) and
        !isWindowMapped(conn, win)) return .none;

    const resolved = window.getInputModelResolved(conn, win);
    if (resolved.model == .no_input) return .none;

    // Cancel any stale confirm cookie (client-side, no round trip).
    cancelPendingConfirm();

    // Discard any stale pre-protocols cookie.
    discardOptCookie(state.?.pre_protocols_cookie);
    state.?.pre_protocols_cookie = null;

    const old = state.?.last_applied;
    return .{ .set = .{
        .win = win,
        .old = old,
        .flags = .{
            .set_input_focus = resolved.model != .globally_active,
            .raise = shouldRaise(reason, win),
            .send_wm_take_focus = true,
            .take_focus_known = resolved.take_focus,
            .arm_confirm = reason == .pointer_sync,
            .schedule_bar = true,
            .new_suppress = suppressionFor(reason, state.?.suppress_reason),
        },
    } };
}

/// Phase 1: prepare a focus-clear transition (outside grab).
/// Returns .none when there is no X focus to clear.
pub fn prepareClearFocus() FocusTransition {
    if (state.?.last_applied == null) return .none;
    cancelPendingConfirm();
    return .{ .clear = .{ .old = state.?.last_applied } };
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
                if (intent.flags.take_focus_known) |advertises| {
                    window.sendWMTakeFocusKnown(conn, intent.win, 0, advertises);
                }
            }

            if (intent.flags.arm_confirm) {
                state.?.confirm_cookie = xcb.xcb_get_input_focus(conn);
                state.?.confirm_win = intent.win;
            }

            if (intent.flags.schedule_bar) core.bumpFocus();

            advertiseActiveWindow(intent.win);
        },
        .clear => |intent| {
            if (intent.old) |old_win| grabButtons(old_win, false);
            state.?.last_applied = null;
            state.?.suppress_reason = .none;
            const cs = core.getState();
            focusNow(cs.conn, cs.root);
            core.bumpFocus();
            advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
        },
        .none => {},
    }
}

/// True if `win` currently has map_state == Viewable. Guards destroy/unmap
/// races on paths that can't guarantee the window is still alive.
inline fn isWindowMapped(conn: core.Connection, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn,
        xcb.xcb_get_window_attributes(conn, win),
        null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}

/// Drain the deferred focus-confirm reply, if one is pending. Must be called
/// from the event loop before processing the next event; in the common case
/// (focus landed, compliant client, already topmost) it completes in
/// microseconds.
///
/// If focus did not land on `confirm_win`, retry xcb_set_input_focus with
/// CurrentTime and re-send WM_TAKE_FOCUS, without raising (a raise generates
/// synthetic FocusOut/FocusIn pairs that reset Electron's internal focus
/// state). ONE-SHOT: the retry fires once and never re-arms; an infinite retry
/// loop would thrash the X server. Safe to call when nothing is pending.
pub fn drainPendingConfirm() void {
    const cookie = state.?.confirm_cookie orelse return;
    const win = state.?.confirm_win.?; // invariant: always set/cleared together with confirm_cookie

    const conn = core.getState().conn;
    var reply: ?*anyopaque = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(conn, cookie.sequence, &reply, &err);

    if (reply == null and err == null) {
        // Not ready yet; keep the cookie alive for next batch
        return;
    }

    // Reply ready or error: consume and clear state
    clearConfirmState();

    if (err) |e| {
        std.c.free(e);
        return;
    }

    const focus_reply: ?*xcb.xcb_get_input_focus_reply_t = if (reply) |r| @ptrCast(@alignCast(r)) else null;
    defer if (focus_reply) |r| std.c.free(r);

    if (!window.isValidManagedWindow(win)) return;

    // Live re-query of input model: the take_focus state may have changed
    // since prepareFocus/applyPendingFocus resolved it (the client could
    // modify WM_PROTOCOLS between our first query and now), so we must
    // re-query rather than reuse the CommitFlags snapshot.
    const input_model = window.getInputModel(conn, win);
    if (input_model == .no_input) return;

    const c = focus_reply orelse return;

    // Consider focus landed if ANY real window has it (focus > 1): Electron/Qt
    // respond to WM_TAKE_FOCUS by focusing an internal child widget, so
    // xcb_get_input_focus returns a child XID, not the managed toplevel. Only
    // retry when focus is completely absent (None or PointerRoot, i.e. <= 1).
    if (c.*.focus > 1) return;

    // Log the retry so failed confirmations are visible in debug sessions
    // rather than silently degrading into an unresponsive window.
    std.log.debug("focus: confirm retry for 0x{x}: focus={} (expected > 1), retrying once", .{ win, c.*.focus });

    focusNow(conn, win);
    window.sendWMTakeFocus(conn, win, 0);
}

/// Clear the paired confirm cookie and window together.
fn clearConfirmState() void {
    state.?.confirm_cookie = null;
    state.?.confirm_win = null;
}

/// Discard a pending confirm reply without acting on it, using the
/// non-blocking xcb_discard_reply. Safe to call when no confirm is pending.
fn cancelPendingConfirm() void {
    const cookie = state.?.confirm_cookie orelse return;
    clearConfirmState();
    xcb.xcb_discard_reply(core.getState().conn, cookie.sequence);
}

/// DWM's focusin: translated exactly. No mode/detail/managed filtering.
///
/// Every FocusIn that doesn't match the intended window triggers an immediate
/// re-assertion via grabFocusReassert, which uses CurrentTime so the X server
/// never rejects it. Filtering mode/detail was incorrect: it allowed Electron's
/// internal focus steals to slip through unchallenged.
pub fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t) void {
    if (state.?.confirm_win) |exp| {
        if (event.event == exp) cancelPendingConfirm();
    }
    const is_offscreen_steal = !window.isInvalidWindow(event.event) and
        !tracking.isOnCurrentWorkspace(event.event);

    const prev = state.?.last_applied orelse {
        if (is_offscreen_steal) grabFocusClear();
        return;
    };

    if (event.event == prev) return;

    grabFocusReassert(prev, is_offscreen_steal);
}

pub fn clearFocus() void {
    // Model is truth; clear it here so every clearFocus caller gets
    // one-store semantics without a separate model call.
    {
        const pl = @import("pipeline");
        if (pl.initialized) @import("model").clearFocus(pl.model());
    }
    if (state.?.last_applied) |old_win| {
        grabButtons(old_win, false);
    }
    cancelPendingConfirm();
    state.?.last_applied = null;
    state.?.suppress_reason = .none;
    const cs = core.getState();
    focusNow(cs.conn, cs.root);
    core.bumpFocus();
    advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
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
        .mouse_click, .user_command, .pointer_sync => !tracking.isTiledMode(win),
        .mouse_enter, .tiling_operation, .window_spawn, .workspace_switch => false,
    };
}

inline fn suppressionFor(reason: Reason, current: core.FocusSuppressReason) core.FocusSuppressReason {
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

/// Atomically focus `win` with `reason`. Round trips (input-model resolve)
/// happen outside the grab; focus protocol, borders, and geometry land
/// inside one grab+reconcile+flush. Drop-in for the old setFocus path.
pub fn grabFocus(win: u32, reason: Reason) void {
    const ft = prepareFocus(win, reason);
    if (ft == .none) return;
    const pl = @import("pipeline");
    @import("model").setFocus(pl.model(), win);
    pl.reconcileUnderGrabNowWithFocus(.{}, ft);
}

/// Atomically clear focus to root. Model clear + focus protocol + borders
/// + geometry all land inside one grab.
pub fn grabFocusClear() void {
    const pl = @import("pipeline");
    @import("model").clearFocus(pl.model());
    const ft = prepareClearFocus();
    if (ft == .none) {
        // last_applied already null: no X focus to clear, but still
        // reconcile so borders/stacking reflect the no-focus state.
        pl.reconcileUnderGrabNow(.{});
        return;
    }
    pl.reconcileUnderGrabNowWithFocus(.{}, ft);
}

/// Re-assert focus on `prev` after a FocusIn event indicates the server's
/// focus drifted. Bypasses the last_applied dedup because the server's
/// actual focus no longer matches what we last applied.
pub fn grabFocusReassert(prev: u32, is_offscreen_steal: bool) void {
    const conn = core.getState().conn;
    if (window.isInvalidWindow(prev)) {
        if (is_offscreen_steal) grabFocusClear();
        return;
    }

    // Round trip outside grab: resolves input model and take_focus
    // advertisement from a single WM_PROTOCOLS query.
    const resolved = window.getInputModelResolved(conn, prev);
    if (resolved.model == .no_input) {
        if (is_offscreen_steal) grabFocusClear();
        return;
    }

    cancelPendingConfirm();
    discardOptCookie(state.?.pre_protocols_cookie);
    state.?.pre_protocols_cookie = null;

    const ft: FocusTransition = .{ .set = .{
        .win = prev,
        .old = state.?.last_applied,
        .flags = .{
            .set_input_focus = resolved.model != .globally_active,
            .raise = false,
            .send_wm_take_focus = true,
            .take_focus_known = resolved.take_focus,
            .arm_confirm = false,
            .schedule_bar = true,
            .new_suppress = .none,
        },
    } };

    const pl = @import("pipeline");
    @import("model").setFocus(pl.model(), prev);
    // Inline grab: need focusNow(root) before applyPendingFocus for
    // offscreen steals (breaks the fight with the stealing client).
    const c = pl.grabCtx();
    c.sink.grabServer();
    defer c.sink.ungrabAndFlush();
    if (is_offscreen_steal) focusNow(conn, core.getState().root);
    applyPendingFocus(ft);
    @import("sync").reconcile(pl.model(), c, .{});
}

/// Cancel a pending pointer-sync cookie without consuming the reply. Call on
/// workspace switches so a stale pre-switch pointer position cannot redirect
/// focus back to an off-workspace window via drainPointerSync.
pub fn cancelPointerSync() void {
    discardOptCookie(state.?.pointer_cookie);
    state.?.pointer_cookie = null;
}

/// Drain the deferred pointer-position reply and route focus to whichever
/// managed window is currently under the pointer. Called from the event loop;
/// safe to call when no query is pending.
pub fn drainPointerSync() void {
    const cookie = state.?.pointer_cookie orelse return;

    const cs = core.getState();
    var reply: ?*anyopaque = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(cs.conn, cookie.sequence, &reply, &err);

    if (reply == null and err == null) {
        // Not ready yet; keep the cookie alive for next batch
        return;
    }

    state.?.pointer_cookie = null;

    if (err) |e| {
        std.c.free(e);
        return;
    }

    const pointer_reply: ?*xcb.xcb_query_pointer_reply_t = if (reply) |r| @ptrCast(@alignCast(r)) else null;
    defer if (pointer_reply) |r| std.c.free(r);

    const p = pointer_reply orelse return;
    const child = p.*.child;
    if (child == 0 or child == cs.root) return;
    // Same ownership predicate as a workspace switch's pointer pick: the
    // window must be visible on the CURRENT workspace (managed + tagged +
    // not minimized). A stale reply referencing an off-workspace or
    // unmanaged window is discarded rather than redirecting focus.
    const pl = @import("pipeline");
    if (!@import("model").visibleOn(pl.model(), child, pl.model().current)) return;
    grabFocus(child, .pointer_sync);
}

/// Fire an async "has the server caught up" round trip that defers lifting
/// EnterNotify suppression until any crossing events generated by a tiling
/// reflow have been delivered and filtered.
///
/// Used by tiling operations that must NOT re-sync focus to wherever the
/// pointer ends up afterward (e.g. toggle_floating_window via
/// withTilingGrabKeepFocus); unlike beginPointerSync, this never calls
/// setFocus itself. The reflow's configure_window calls flush only at the
/// caller's ungrabAndFlush, so windows that slid under a stationary cursor can
/// generate real EnterNotify events afterward; cleared suppression would let
/// those crossings silently reassign keyboard focus. xcb_get_input_focus is
/// queued in the same flush as the reflow, and X delivers any event generated
/// by a request before the reply to a later request; so when
/// drainTilingOpSettle() consumes this reply, the crossings are already
/// drained and filtered (suppression is still active).
pub fn beginTilingOpSettle() void {
    discardOptCookie(state.?.tiling_op_cookie);
    const cs = core.getState();
    state.?.tiling_op_cookie = xcb.xcb_get_input_focus(cs.conn);
}

/// Drain the deferred tiling-op-settle reply, if one is pending, and lift
/// EnterNotify suppression. Safe to call when nothing is pending.
///
/// Only clears suppression while it is still .tiling_operation, so a different
/// reason set meanwhile (e.g. window_spawn) is never clobbered.
pub fn drainTilingOpSettle() void {
    const cookie = state.?.tiling_op_cookie orelse return;

    const cs = core.getState();
    var reply: ?*anyopaque = null;
    var err: ?*xcb.xcb_generic_error_t = null;
    _ = xcb.xcb_poll_for_reply(cs.conn, cookie.sequence, &reply, &err);

    if (reply == null and err == null) {
        // Not ready yet; keep the cookie alive for next batch
        return;
    }

    state.?.tiling_op_cookie = null;

    // The reply's content is unused; only its arrival signals that the server
    // has processed everything queued before it. It must be consumed to drain
    // the XCB queue.
    if (reply) |r| std.c.free(r);
    if (err) |e| {
        std.c.free(e);
        return;
    }
    if (state.?.suppress_reason == .tiling_operation) state.?.suppress_reason = .none;
}

// Window focus cycling
//
// Scratch buffer for collectVisibleWindows, module-level so it isn't
// stack-allocated on every key press. Sized to the max tiled windows across
// the whole WM (not per workspace).

var cycle_buf: [constants.Limits.max_tiled_windows]u32 = undefined;

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
/// All visible windows in tracking-table order; the pool list is never fed. Emits only windows that are
/// on the current workspace and not minimized. Returns the count written into
/// `cycle_buf`, or 0 if none.
fn collectVisibleWindows() usize {
    var len: usize = 0;
    for (tracking.allWindows()) |entry| appendVisible(entry.win, &len);
    return len;
}

/// Returns the next (forward=true) or previous (forward=false) index in a
/// circular list of `len` elements, starting from `idx`.
inline fn cycleIndex(comptime forward: bool, idx: usize, len: usize) usize {
    return if (forward) (idx + 1) % len else (idx + len - 1) % len;
}

/// Shared implementation for focus cycling.
/// forward=true -> next (Mod+k, ascending), forward=false -> prev (Mod+j).
fn focusCycle(comptime forward: bool) void {
    const len = collectVisibleWindows();
    if (len == 0) return;
    const wins = cycle_buf[0..len];
    // When the focused window isn't in the visible list, wrap so the very next
    // step lands on wins[0] (forward) or wins[len-1] (backward).
    const sentinel: usize = if (comptime forward) len - 1 else 0;
    const idx = if (getFocused()) |w|
        std.mem.indexOfScalar(u32, wins, w) orelse sentinel
    else
        sentinel;
    grabFocus(wins[cycleIndex(forward, idx, len)], .user_command);
}

/// Cycle focus to the next visible window (Mod+k, moves right/forward).
pub fn focusNext() void {
    focusCycle(true);
}
/// Cycle focus to the previous visible window (Mod+j, moves left/backward).
pub fn focusPrev() void {
    focusCycle(false);
}
