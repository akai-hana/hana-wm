//! Focus management
//! Handles setting, clearing, and tracking the currently focused window.

const std   = @import("std");
const build = @import("build_options");

const core    = @import("core");
    const xcb = core.xcb;
const utils   = @import("utils");

const window   = @import("window");
const tracking = @import("tracking");
const tiling   = if (build.has_tiling) @import("tiling") else struct {
    pub fn getStateOpt() ?*anyopaque { return null; }
};

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn scheduleFocusRedraw(_: anytype) void {}
    pub fn isBarWindow(_: u32) bool { return false; }
    pub fn redrawInsideGrab() void {}
};

const carousel = if (build.has_bar and build.has_carousel) @import("carousel") else struct {
    pub fn notifyFocusChanged(_: anytype) void {}
};


// Module state
//
// All mutable focus state is grouped into a single State struct so that:
//   • init() can reset everything in one assignment (no scattered field resets).
//   • Tests can construct a State and pass *State to internal helpers without
//     requiring a live XCB connection.
//   • The encapsulation boundary is obvious — no scattered module-level vars.
//
// There is still exactly one focus context per process (the single module-level
// `state` variable). The struct is for reset discipline and future testability,
// not for multi-context support.

const State = struct {
    focused_window:    ?u32                                = null,
    suppress_reason:   core.FocusSuppressReason            = .none,

    // Maintained for callers outside this module that need the most recent X
    // event timestamp (e.g. to forward it to subsystems that require it for
    // protocol ordering).  focus.zig itself always passes CurrentTime (0) to
    // xcb_set_input_focus and WM_TAKE_FOCUS; see "Timestamp handling" below.
    // This field is retained rather than removed so external consumers are not
    // broken; it must NOT be used inside this module — use 0 (CurrentTime).
    last_event_time:   u32                                 = 0,

    // EWMH atom for _NET_ACTIVE_WINDOW — interned once in init().
    net_active_window: xcb.xcb_atom_t                     = xcb.XCB_ATOM_NONE,

    // Deferred async state
    //
    // Rather than blocking on xcb_get_input_focus and xcb_query_pointer
    // replies inline, we fire the requests immediately and store the cookies.
    // The drain functions are called from the event-dispatch loop on the next
    // iteration, keeping the hot paths non-blocking.
    //
    // confirm_cookie / confirm_win
    //   Non-compliant-client focus confirmation.  confirm_win is the window
    //   the query was issued for.  handleFocusIn cancels early when the
    //   FocusIn arrives first, avoiding a blocking drain.
    //
    // pointer_cookie
    //   Pending pointer-position query from beginPointerSync().
    //   Cancelled non-blockingly via xcb_discard_reply in beginPointerSync
    //   when superseded by a new query.
    //
    // pre_protocols_cookie
    //   WM_PROTOCOLS get_property request fired at the START of setFocus,
    //   before commitFocusTransition runs its bookkeeping.  This lets the X
    //   server process the property request in parallel with grab management,
    //   tiling border updates, and bar scheduling.  By the time
    //   commitFocusTransition calls sendWMTakeFocus, the reply is typically
    //   already sitting in the XCB receive buffer, turning a synchronous
    //   round-trip into a near-zero-cost buffer drain.
    //   null when not in use (most call paths do not pre-fire).
    confirm_cookie:        ?xcb.xcb_get_input_focus_cookie_t  = null,
    confirm_win:           ?u32                               = null,
    pointer_cookie:        ?xcb.xcb_query_pointer_cookie_t    = null,
    pre_protocols_cookie:  ?xcb.xcb_get_property_cookie_t     = null,
};

var state: State = .{};

// Lifecycle

pub fn init() void {
    // Reset every field to its zero value so that a deinit() + init() cycle
    // (test harness, session restart) starts from a clean slate.
    state = .{};

    // Intern _NET_ACTIVE_WINDOW so setFocus can advertise the focused window
    // on the root.  null reply -> stays XCB_ATOM_NONE; advertiseActiveWindow
    // no-ops.
    const ck = xcb.xcb_intern_atom(core.conn, 0, "_NET_ACTIVE_WINDOW".len, "_NET_ACTIVE_WINDOW");
    if (xcb.xcb_intern_atom_reply(core.conn, ck, null)) |r| {
        state.net_active_window = r.*.atom;
        std.c.free(r);
    }
}

/// Discard an optional XCB cookie without blocking.
/// All XCB cookie types share a `.sequence` field, so anytype covers all of them.
inline fn discardOptCookie(opt: anytype) void {
    if (opt) |ck| xcb.xcb_discard_reply(core.conn, ck.sequence);
}

pub fn deinit() void {
    // Discard any pending XCB cookies so they do not accumulate in the reply
    // queue across a deinit() + init() cycle (e.g. in a test harness).
    // At process exit the connection close handles this implicitly, but for
    // restart / reload paths explicit cleanup keeps the queue clean.
    discardOptCookie(state.pre_protocols_cookie);
    discardOptCookie(state.confirm_cookie);
    discardOptCookie(state.pointer_cookie);
    // Reset all fields so that any accessor called between deinit() and the
    // next init() observes a clean zero-value state rather than stale data.
    state = .{};
}

// Public accessors

pub inline fn getFocused()        ?u32                       { return state.focused_window;  }
pub inline fn getSuppressReason() core.FocusSuppressReason   { return state.suppress_reason; }

/// Returns true when the current suppress reason indicates that an incoming
/// EnterNotify event should be silently ignored by the window layer.
///
/// Centralises suppression policy for EnterNotify here in focus.zig so that
/// window.handleEnterNotify does not need to know about specific Reason values.
///
/// NOTE: window_spawn suppression is intentionally NOT handled here — it is
/// checked earlier in handleEnterNotify via suppressSpawnCrossing(), which uses
/// the saved cursor position to distinguish a real cursor move from a synthetic
/// crossing caused by a new window mapping under the pointer.  Any new suppress
/// reason that does NOT need coordinate-based disambiguation belongs here;
/// coordinate-based reasons belong in suppressSpawnCrossing().
pub inline fn shouldSuppressEnterNotify() bool {
    return state.suppress_reason == .tiling_operation;
}
pub inline fn getLastEventTime() u32 { return state.last_event_time; }

/// Update the X11 event timestamp.  Called by the EnterNotify and
/// LeaveNotify handlers before they call into focus logic.
///
/// See "Timestamp handling" below for why focus.zig itself always uses
/// CurrentTime (0) rather than forwarding this value.
pub inline fn setLastEventTime(t: u32) void { state.last_event_time = t; }

// Timestamp handling
//
// CRITICAL: setLastEventTime MUST be called with enter_event.time BEFORE
// calling setFocus(.mouse_enter).  If it is only called for button and key
// events, g_last_event_time will be from the last click/keystroke, not the
// current hover event.
//
// Why this matters:
//   1. The WM sends xcb_set_input_focus(win, T_enter).
//      X server: last-focus-change-time = T_enter.
//   2. The WM sends WM_TAKE_FOCUS(win, state.last_event_time).
//      If state.last_event_time is an old button-press timestamp T_old < T_enter,
//      the app (e.g. Discord, Prism Launcher) receives WM_TAKE_FOCUS with T_old
//      and calls XSetInputFocus(internal_widget, T_old).
//   3. X server: T_old < last-focus-change-time (T_enter) -> request IGNORED.
//   4. The app's internal focus widget never gets focus; the app appears
//      unresponsive to hover even though the X server reported success for
//      the WM's own xcb_set_input_focus.
//
// Terminals and Firefox are often immune: terminals are passive (no
// WM_TAKE_FOCUS, so no app-side XSetInputFocus to fail), and Firefox may use
// CurrentTime rather than the WM-provided timestamp.  Electron apps (Discord)
// and Qt apps (Prism Launcher) strictly use the provided timestamp per ICCCM.
//
// dwm avoids this entirely by always passing CurrentTime (0) everywhere,
// which the X server interprets as "now" and bypasses the ordering check.
// focus.zig follows the same approach.  state.last_event_time is therefore
// maintained for external consumers (e.g. subsystems that forward timestamps
// to input-method frameworks) rather than for use inside this module.

/// Direct write to suppress_reason.
///
/// Use this for cases where suppression must be cleared or set independently
/// of any focus change — e.g. MotionNotify clearing suppression when real
/// pointer movement is detected.
pub inline fn setSuppressReason(r: core.FocusSuppressReason) void { state.suppress_reason = r; }

// Button grab management
//
// Owned here rather than in window.zig because grabs are exclusively a
// focus-protocol concern: they are acquired and released only during focus
// transitions.  The only non-transition call site is registerWindowOffscreen
// in window.zig (off-workspace windows need initial grabs before their first
// focus), which is served by the public initWindowGrabs shim below.

/// Unconditionally release all button grabs on `win`, then — if `focused` is
/// false — re-grab all buttons so click-to-focus events are delivered to us.
fn grabButtons(win: u32, focused: bool) void {
    _ = xcb.xcb_ungrab_button(core.conn, xcb.XCB_BUTTON_INDEX_ANY, win, xcb.XCB_MOD_MASK_ANY);
    if (focused) return;
    _ = xcb.xcb_grab_button(
        core.conn, 0, win, xcb.XCB_EVENT_MASK_BUTTON_PRESS,
        xcb.XCB_GRAB_MODE_SYNC, xcb.XCB_GRAB_MODE_SYNC,
        xcb.XCB_NONE, xcb.XCB_NONE, xcb.XCB_BUTTON_INDEX_ANY, xcb.XCB_MOD_MASK_ANY,
    );
}

/// Configure initial button grabs for a window that is being registered on a
/// non-current workspace (and thus never focused via the normal transition
/// path).  The window will have its grabs updated to `focused = true` the
/// first time it receives focus via commitFocusTransition.
pub fn initWindowGrabs(win: u32) void { grabButtons(win, false); }

// Focus logic

pub const Reason = enum {
    /// Direct click on an unfocused window.
    mouse_click,

    /// EnterNotify: pointer entered the window (hover / focus-follows-mouse).
    /// Lightweight path — no window raise, no focus-confirm machinery.
    /// DWM's focus(c) called from focusin / EnterNotify maps to this.
    mouse_enter,

    /// Deferred pointer-position query resolved after a tiling retile or
    /// window-close (drainPointerSync / focusWindowUnderPointer).
    /// Heavier path: may raise a floating window, arms confirm/retry.
    pointer_sync,

    /// Keyboard-driven focus cycle or explicit WM command.
    user_command,

    /// Internal retile reassigned focus (tiling module owns stacking).
    tiling_operation,

    // Distinct from other reasons so tiling operations cannot accidentally
    // inherit window_spawn crossing suppression via external state.
    window_spawn,

    // Workspace switch: windows are guaranteed mapped (skip the round-trip
    // guard), focus-follow-mouse suppression is cleared, and the window is
    // never raised (the stacking order is already correct after the switch).
    workspace_switch,
};

// CommitFlags — controls which side effects commitFocusTransition applies.
// All fields are non-defaulted so that every call site must be explicit.
// An accidental zero-flags call (e.g. CommitFlags{}) will fail to compile,
// preventing silent no-protocol transitions that are extremely hard to debug.
const CommitFlags = struct {
    /// Send xcb_set_input_focus to the new window.
    /// False for no_input and globally_active windows: no_input never receives
    /// focus protocol; globally_active manages its own focus and must not be
    /// sent xcb_set_input_focus per ICCCM §4.1.7.
    set_input_focus:    bool,

    /// Raise the window to the top of the stack.
    /// True for click/command (user-driven), and for globally_active hover
    /// (raising is the only focus signal these windows receive).
    raise:              bool,

    /// Send a WM_TAKE_FOCUS ClientMessage after xcb_set_input_focus.
    /// Required for locally_active and globally_active input models.
    send_wm_take_focus: bool,

    /// Arm the async focus-confirm cookie for a deferred raise-and-retry.
    /// Used by pointer_sync for passive and locally_active windows that may
    /// silently drop xcb_set_input_focus when not already topmost.
    arm_confirm:        bool,

    /// Call bar.scheduleFocusRedraw after the transition.
    /// False only when running inside a server grab; the caller is then
    /// responsible for calling bar.redrawInsideGrab() instead.
    schedule_bar:       bool,

    /// New value for suppress_reason after the transition.
    /// `setFocus` derives this from reason + current state via suppressionFor();
    /// all direct callers of `commitFocusTransition` hardcode `.none`.
    new_suppress: core.FocusSuppressReason,
};

/// Core focus-transition implementation shared by all focus paths.
/// NOTE: handleFocusIn does NOT call this function — it delegates to
/// sendFocusProtocol, which operates on a different set of invariants (no
/// grab management, no suppression update).
///
/// All focus paths perform the same logical sequence — update global state ->
/// sync button grabs -> X protocol requests -> notify downstream observers —
/// and differ only in which side effects apply, encoded in `flags`.
///
/// Preconditions (enforced by callers):
///   • `win` is a valid managed window (non-zero, not root, not bar).
///   • `win` != focused_window (no-op transitions are filtered upstream).
///   • Any stale confirm cookie has been cancelled or consumed by the caller.
fn commitFocusTransition(old: ?u32, win: u32, flags: CommitFlags) void {
    state.focused_window  = win;
    state.suppress_reason = flags.new_suppress;

    grabButtons(win, true);
    if (old) |o| grabButtons(o, false);

    if (flags.set_input_focus)
        // Always CurrentTime (0): the X server interprets CurrentTime as "now"
        // and bypasses its timestamp-ordering check entirely.  Passing a real
        // event timestamp risks rejection if it predates the server's last
        // focus-change time, and also risks Electron/Qt apps forwarding a stale
        // timestamp back to XSetInputFocus on their internal widget.
        _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            win, 0); // CurrentTime

    if (flags.raise)
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    if (flags.send_wm_take_focus) {
        // If setFocus pre-fired the WM_PROTOCOLS cookie before entering this
        // function, consume it now — the server has been processing it while we
        // did bookkeeping above, so this drain is typically a near-zero-cost
        // buffer read rather than a round-trip.
        // Fall back to the blocking sendWMTakeFocus for callers that don't
        // pre-fire (drainPendingConfirm).
        if (state.pre_protocols_cookie) |ck| {
            state.pre_protocols_cookie = null;
            window.sendWMTakeFocusWithCookie(core.conn, win, 0, ck); // CurrentTime
        } else {
            window.sendWMTakeFocus(core.conn, win, 0); // CurrentTime
        }
    } else if (state.pre_protocols_cookie) |ck| {
        // send_wm_take_focus is false (e.g. no_input model) but a cookie was
        // pre-fired — discard it to keep the XCB reply queue drained.
        xcb.xcb_discard_reply(core.conn, ck.sequence);
        state.pre_protocols_cookie = null;
    }

    if (flags.arm_confirm) {
        state.confirm_cookie = xcb.xcb_get_input_focus(core.conn);
        state.confirm_win    = win;
    }

    if (build.has_tiling) tiling.updateWindowFocus(old, win);
    carousel.notifyFocusChanged(win);
    if (flags.schedule_bar) bar.scheduleFocusRedraw(win);

    advertiseActiveWindow(win);
}

/// Returns true when `win` must never receive focus from any focus-granting
/// path (setFocus).
/// NOTE: handleFocusIn intentionally does NOT use this guard.
inline fn isInvalidFocusTarget(win: u32) bool {
    return win == 0 or win == core.root or bar.isBarWindow(win);
}

/// Returns true if `win` currently has map_state == Viewable.
/// Used to guard against destroy/unmap races on paths that cannot guarantee
/// the window is still alive at call time.
inline fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn, xcb.xcb_get_window_attributes(conn, win), null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}

pub fn setFocus(win: u32, reason: Reason) void {
    if (isInvalidFocusTarget(win)) return;
    if (state.focused_window == win) return;

    // Guard against destroy/unmap races on paths where the window's liveness
    // cannot be guaranteed without asking the server.
    //   • mouse_click / user_command: event may have been queued before destroy.
    //   • pointer_sync: queried pointer position may be stale by the time the
    //     reply arrives (window destroyed between query and drain).
    // EnterNotify (.mouse_enter) is excluded: the server guarantees the window
    // exists and is mapped when it generates the crossing event.  The remaining
    // reasons either operate inside a server grab or use windows verified by the
    // tiling/workspace machinery.
    if ((reason == .mouse_click or reason == .user_command or reason == .pointer_sync) and
        !isWindowMapped(core.conn, win)) return;

    const input_model = window.getInputModelCached(core.conn, win);
    if (input_model == .no_input) return;

    // Pipeline: fire the WM_PROTOCOLS get_property cookie NOW, before
    // cancelPendingConfirm and commitFocusTransition do their bookkeeping.
    // The X server processes the property request while we swap button grabs,
    // update tiling borders, and notify the bar.  By the time
    // commitFocusTransition calls sendWMTakeFocusWithCookie, the reply is
    // typically already in the XCB receive buffer.
    if (state.pre_protocols_cookie) |stale| {
        // Discard any leftover cookie from a previous interrupted path.
        xcb.xcb_discard_reply(core.conn, stale.sequence);
    }
    state.pre_protocols_cookie = window.fireTakeFocusCookie(core.conn, win);

    cancelPendingConfirm();

    const old = state.focused_window;
    commitFocusTransition(old, win, .{
        .set_input_focus    = input_model != .globally_active,
        .raise              = shouldRaise(reason, win),
        .send_wm_take_focus = true, // no_input already returned early above
        .arm_confirm        = reason == .pointer_sync,
        .schedule_bar       = true,
        .new_suppress       = suppressionFor(reason, state.suppress_reason),
    });
}

/// Drain the deferred focus-confirm reply, if one is pending.
///
/// Must be called from the event-dispatch loop before processing the next
/// event.  In the common case (focus landed, compliant client, window already
/// topmost) this completes in microseconds.
///
/// If focus did not land on `confirm_win`, xcb_set_input_focus is retried
/// with CurrentTime and WM_TAKE_FOCUS is re-sent.  The window is NOT raised on
/// retry: raising generates synthetic FocusOut/FocusIn pairs that reset
/// Electron's internal focus state machine.
///
/// ONE-SHOT: the retry fires once and does not re-arm a new confirm cookie.
/// If the retry also fails, the window remains in focused_window without actual
/// X focus until the user clicks or handleFocusIn fires from a steal.  This is
/// intentional — an infinite retry loop would thrash the X server.
///
/// Safe to call when no confirm is pending (returns immediately).
pub fn drainPendingConfirm() void {
    const cookie = state.confirm_cookie orelse return;
    const win    = state.confirm_win.?;  // invariant: always set/cleared together with confirm_cookie
    clearConfirmState();

    // Reply must be consumed before any return to drain the XCB queue.
    const focus_reply = xcb.xcb_get_input_focus_reply(core.conn, cookie, null);
    defer if (focus_reply) |r| std.c.free(r);

    if (!window.isValidManagedWindow(win)) return;

    const input_model = window.getInputModelCached(core.conn, win);
    if (input_model == .no_input) return;

    const c = focus_reply orelse return;

    // Consider focus successfully landed if ANY real window has it (focus > 1).
    // Electron/Qt respond to WM_TAKE_FOCUS by calling XSetInputFocus on an
    // internal child widget, so xcb_get_input_focus returns the child XID —
    // not the managed toplevel.  Only retry when focus is completely absent
    // (None or PointerRoot, i.e. <= 1).
    if (c.*.focus == win or c.*.focus > 1) return;

    // Log the retry so failed confirmations are visible in debug sessions
    // rather than silently degrading into an unresponsive window.
    std.log.debug("focus: confirm retry for 0x{x}: focus={} (expected > 1), retrying once", .{ win, c.*.focus });

    _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win, 0); // CurrentTime
    window.sendWMTakeFocus(core.conn, win, 0); // CurrentTime
}

/// Clear the paired confirm cookie and window together.
/// Invariant: these two fields are always set/cleared as a unit.
inline fn clearConfirmState() void {
    state.confirm_cookie = null;
    state.confirm_win    = null;
}

/// Discard a pending confirm reply without acting on it.
///
/// Uses xcb_discard_reply, a non-blocking primitive that instructs XCB to
/// silently drop the reply when it arrives, correctly releasing the reply-queue
/// entry.
///
/// Safe to call when no confirm is pending.
fn cancelPendingConfirm() void {
    const cookie = state.confirm_cookie orelse return;
    clearConfirmState();
    xcb.xcb_discard_reply(core.conn, cookie.sequence);
}

/// Invalidate the cached input model for `win`.
///
/// MUST be called from the PropertyNotify handler whenever `XA_WM_HINTS` OR
/// `WM_PROTOCOLS` changes for a managed window.
///
/// Rationale for WM_HINTS: Electron and Java/Qt apps routinely update WM_HINTS
/// after their window is mapped.  A stale cache that missed an input=False→True
/// update would return early at `if (input_model == .no_input)` on every hover,
/// silently discarding all focus for that window.
///
/// Rationale for WM_PROTOCOLS: apps can register WM_TAKE_FOCUS after mapping.
/// A stale cache would skip the message, leaving the app's internal widget
/// inactive.
pub fn invalidateInputModelCache(win: u32) void {
    window.recacheInputModel(core.conn, win);
}

/// Re-assert focus on `win` from inside handleFocusIn.
///
/// Skips xcb_set_input_focus for .globally_active (ICCCM §4.1.7).
/// WM_TAKE_FOCUS is sent to all models that support it; sendWMTakeFocus
/// is a no-op for windows that do not advertise it.
/// Always updates _NET_ACTIVE_WINDOW so EWMH clients stay in sync.
/// No raise, no confirm/retry machinery — re-assertion happens in response
/// to a focus steal, so stability (not raise-order) is the priority.
fn sendFocusProtocol(win: u32) void {
    const model = window.getInputModelCached(core.conn, win);
    if (model == .no_input) return;
    if (model != .globally_active) {
        _ = xcb.xcb_set_input_focus(core.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, 0); // CurrentTime
    }
    // Always advertise the active window, regardless of input model.
    // Without this, a globally_active window that has stolen focus would leave
    // _NET_ACTIVE_WINDOW pointing at the thief even after we re-assert `win`.
    advertiseActiveWindow(win);
    window.sendWMTakeFocus(core.conn, win, 0); // CurrentTime
}

/// DWM's focusin — translated exactly. No mode/detail/managed filtering.
///
/// Every FocusIn that doesn't match the intended window triggers an immediate
/// re-assertion via sendFocusProtocol, which uses CurrentTime so the X server
/// never rejects it.  Filtering mode/detail (GRAB/UNGRAB/WHILE_GRABBED,
/// NotifyInferior) was incorrect: it allowed Electron's internal focus steals
/// to slip through unchallenged.
pub fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t) void {
    if (state.confirm_win)    |exp| if (event.event == exp)  cancelPendingConfirm();
    const is_offscreen_steal = !isInvalidFocusTarget(event.event) and
        !tracking.isOnCurrentWorkspace(event.event);
    if (state.focused_window) |sel| {
        if (event.event != sel) {
            // If the stealing window is not on the current workspace, first
            // redirect X focus to root — the same defocus used in the null
            // branch below — before re-asserting `sel`.
            //
            // Without this, an off-workspace window (Wine, Electron, a game)
            // that reacts to every FocusOut with XSetInputFocus(itself) creates
            // a three-way fight: WM→sel, sel's app→child, thief→itself.
            // That loop never converges because sendFocusProtocol(sel) for
            // .globally_active windows only sends WM_TAKE_FOCUS (no direct
            // xcb_set_input_focus), and for passive/locally_active it creates
            // a ping-pong that Wine's internal focus manager feeds indefinitely.
            //
            // Redirecting to root first breaks the cycle: the thief fights root
            // (which never replies), exhausting its retry budget.  Then
            // sendFocusProtocol(sel) reclaims focus with no active opponent.
            if (is_offscreen_steal)
                _ = xcb.xcb_set_input_focus(core.conn,
                    xcb.XCB_INPUT_FOCUS_POINTER_ROOT, core.root, 0); // CurrentTime
            sendFocusProtocol(sel);
        }
    } else if (is_offscreen_steal) {
        _ = xcb.xcb_set_input_focus(core.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT, core.root, 0); // CurrentTime
        advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
    }
}

/// Focus any visible window satisfying `visible`, walking the tracking list.
/// Falls back to `on_miss()` if provided, or clearFocus() if null, when no
/// candidate is found.
///
/// This is the Zig equivalent of dwm's focus(NULL) idiom — callers that need
/// to focus "whatever is best after X happened" (window close, workspace switch,
/// unmanage, etc.) use this instead of rolling their own scan + setFocus sequence.
///
/// The `visible` predicate decouples workspace visibility from focus mechanics:
///   • Pass tracking.isOnCurrentWorkspaceAndVisible for normal post-action
///     re-focus (on current workspace and not minimized).
///   • Pass window.isValidManagedWindow for cleanup contexts where any managed
///     window is acceptable regardless of workspace membership.
pub fn focusBestAvailable(
    reason:  Reason,
    visible: *const fn (u32) bool,
    on_miss: ?*const fn () void,
) void {
    for (tracking.allWindows()) |entry| {
        if (visible(entry.win)) { setFocus(entry.win, reason); return; }
    }
    if (on_miss) |f| f() else clearFocus();
}

pub fn clearFocus() void {
    if (state.focused_window) |old_win| {
        grabButtons(old_win, false);
        if (build.has_tiling) tiling.updateWindowFocus(old_win, null);
    }
    cancelPendingConfirm();
    state.focused_window  = null;
    state.suppress_reason = .none;
    _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        core.root, 0); // CurrentTime
    carousel.notifyFocusChanged(null);
    bar.scheduleFocusRedraw(null);
    advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
}

inline fn advertiseActiveWindow(win: u32) void {
    if (state.net_active_window == xcb.XCB_ATOM_NONE) return;
    _ = xcb.xcb_change_property(core.conn, xcb.XCB_PROP_MODE_REPLACE,
        core.root, state.net_active_window, xcb.XCB_ATOM_WINDOW, 32, 1, &win);
}

/// True when `reason` should raise `win` to the top of the stacking order.
///
/// Tiled windows are excluded: the tiling retile owns their stacking order
/// and will raise the top window atomically via configureWithHintsAndRaise.
/// A pre-raise here would produce a redundant XCB request that creates an
/// intermediate compositor frame when a retile also runs in the same batch.
///
/// mouse_enter (raw EnterNotify) never raises, matching DWM's focus(c)
/// behaviour: raising on every hover event generates synthetic
/// FocusOut/FocusIn pairs that confuse Electron's internal focus state machine.
inline fn shouldRaise(reason: Reason, win: u32) bool {
    return switch (reason) {
        .mouse_click, .user_command, .pointer_sync =>
            if (build.has_tiling) !tiling.isWindowActiveTiled(win) else true,
        .mouse_enter, .tiling_operation, .window_spawn, .workspace_switch => false,
    };
}

inline fn suppressionFor(reason: Reason, current: core.FocusSuppressReason) core.FocusSuppressReason {
    return switch (reason) {
        // workspace_switch always clears too: crossing events generated by
        // windows mapping/unmapping during the switch must not be masked on
        // the new workspace.  Documented in Reason.workspace_switch.
        .mouse_click, .user_command, .workspace_switch => .none,
        .window_spawn                                  => .window_spawn,
        else                                           => current,
    };
}

/// Cancel a pending pointer-sync cookie without consuming the reply.
/// Call this on workspace switches so a stale pre-switch pointer position
/// cannot redirect focus back to an off-workspace window via drainPointerSync.
pub fn cancelPointerSync() void {
    discardOptCookie(state.pointer_cookie);
    state.pointer_cookie = null;
}

/// Fire an async pointer-position query for focus-after-tiling sync.
///
/// Clears suppression immediately (so subsequent EnterNotify events are no
/// longer masked) and queues xcb_query_pointer without blocking.  The reply
/// is handled by drainPointerSync(), called from the event-dispatch loop.
pub fn beginPointerSync() void {
    state.suppress_reason = .none;
    discardOptCookie(state.pointer_cookie);
    state.pointer_cookie = xcb.xcb_query_pointer(core.conn, core.root);
}

/// Drain the deferred pointer-position reply and route focus to whichever
/// managed window is currently under the pointer.
///
/// Called from the event-dispatch loop.  Safe to call when no query is pending.
pub fn drainPointerSync() void {
    const cookie = state.pointer_cookie orelse return;
    state.pointer_cookie = null;
    const reply = xcb.xcb_query_pointer_reply(core.conn, cookie, null) orelse return;
    defer std.c.free(reply);
    const child = reply.*.child;
    if (child == 0 or child == core.root or !window.isValidManagedWindow(child)) return;
    // BUG FIX: if the stale pointer reply contains a window from a workspace
    // that is no longer current (e.g., the reply was fired before a workspace
    // switch), silently discard it — do not redirect focus to an offscreen window.
    if (!tracking.isOnCurrentWorkspace(child)) return;
    setFocus(child, .pointer_sync);
}

// Window focus cycling
//
// Scratch buffer for collectVisibleWindows.  Module-level so it is not
// stack-allocated on every key press.  Safe in a single-threaded WM.
// Sized to match tracking.Tracking.capacity (64 windows per workspace).

var cycle_buf: [64]u32 = undefined;

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
/// When tiling is active the tiling module's window list is used — it matches
/// the order windows appear on screen (master first, then stack), giving the
/// same traversal order that a user sees on screen.
///
/// Falls back to a list built from the tracking table in iteration order when
/// tiling is disabled or has no windows.  Both paths emit only windows that are
/// on the current workspace and not minimized — invisible windows are excluded.
///
/// Returns the number of windows written into `cycle_buf`, or 0 if none.
/// `focusCycle` / `moveWindowCycle` locate the currently-focused window by
/// scanning the returned slice with indexOfScalar; no pre-rotation is needed.
fn collectVisibleWindows() usize {
    var len: usize = 0;

    if (build.has_tiling) {
        if (tiling.getStateOpt()) |t| {
            if (t.is_enabled) {
                for (t.windows.items()) |w| appendVisible(w, &len);
                if (len > 0) return len;
            }
        }
    }

    // Fallback: collect all visible windows in tracking-table order.
    // No pre-insertion of focused_window and no O(n²) dedup scan needed —
    // focusCycle finds the focused window's position via indexOfScalar and
    // wraps from there, regardless of where it appears in the slice.
    for (tracking.allWindows()) |entry| appendVisible(entry.win, &len);
    return len;
}

/// Shared implementation for focus cycling.
/// forward=true  → next  (Mod+k, ascending  order)
/// forward=false → prev  (Mod+j, descending order)
fn focusCycle(comptime forward: bool) void {
    const len = collectVisibleWindows();
    if (len == 0) return;
    const wins = cycle_buf[0..len];
    // Sentinel wraps the very next step to wins[0] (forward) or wins[len-1]
    // (backward) when the focused window is not found in the visible list.
    const sentinel: usize = if (comptime forward) len - 1 else 0;
    const idx = if (state.focused_window) |w|
        std.mem.indexOfScalar(u32, wins, w) orelse sentinel
    else
        sentinel;
    const next_idx = if (forward) (idx + 1) % len else (idx + len - 1) % len;
    setFocus(wins[next_idx], .user_command);
}

/// Cycle focus to the next visible window (Mod+k — moves right/forward).
pub fn focusNext() void { focusCycle(true);  }
/// Cycle focus to the previous visible window (Mod+j — moves left/backward).
pub fn focusPrev() void { focusCycle(false); }

/// Shared implementation for moving the focused window through the cycle.
/// Swaps it with the neighbour in the given direction.
/// Only has an effect when tiling is active and at least two windows are visible.
fn moveWindowCycle(comptime forward: bool) void {
    if (!build.has_tiling) return;
    const len = collectVisibleWindows();
    if (len < 2) return;
    const wins = cycle_buf[0..len];
    const focused = state.focused_window orelse return;
    const idx = std.mem.indexOfScalar(u32, wins, focused) orelse return;
    const target = if (forward) wins[(idx + 1) % len] else wins[(idx + len - 1) % len];
    tiling.swapWindowsById(focused, target);
}

/// Move the focused window one step forward in the cycle (Mod+Shift+k).
pub fn moveWindowNext() void { moveWindowCycle(true);  }
/// Move the focused window one step backward in the cycle (Mod+Shift+j).
pub fn moveWindowPrev() void { moveWindowCycle(false); }
