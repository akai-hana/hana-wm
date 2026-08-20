//! Focus management module.
//! Manages setting, clearing, and tracking the currently focused window.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const utils = @import("utils");
const window = @import("window");
const tracking = @import("tracking");
const build_options = @import("build_options");
const bar = if (build_options.has_bar) @import("bar") else null;
const tiling = if (build_options.has_tiling) @import("tiling") else null;

// Module state
//
// Grouped into a single State struct so init() resets everything in one
// assignment and the encapsulation boundary is obvious. Still exactly one
// focus context per process; the struct is for reset discipline, not
// multi-context support.

const State = struct {
    focused_window: ?u32 = null,
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
    // pointer_cookie: pending pointer-position query from beginPointerSync().
    // tiling_op_cookie: "has the server caught up" round trip from
    //   beginTilingOpSettle() (see its doc comment).
    // pre_protocols_cookie: WM_PROTOCOLS query fired at the START of setFocus
    //   so the server processes it in parallel with focus bookkeeping; by the
    //   time commitFocusTransition needs it the reply is typically already in
    //   the receive buffer. null when not in use.
    confirm_cookie: ?xcb.xcb_get_input_focus_cookie_t = null,
    confirm_win: ?u32 = null,
    pointer_cookie: ?xcb.xcb_query_pointer_cookie_t = null,
    tiling_op_cookie: ?xcb.xcb_get_input_focus_cookie_t = null,
    pre_protocols_cookie: ?xcb.xcb_get_property_cookie_t = null,
};

var state: ?State = null;

pub inline fn getState() *State {
    if (state) |*s| return s;
    @panic("focus: getState() called before init()");
}

pub inline fn getStateOpt() ?*State {
    return if (state) |*s| s else null;
}

pub fn init() void {
    // Reset every field so a deinit()+init() cycle starts from a clean slate.
    state = .{};
    state.?.net_active_window = utils.getAtomCached("_NET_ACTIVE_WINDOW") catch 0;
}

/// Discard an optional XCB cookie without blocking.
/// All XCB cookie types share a `.sequence` field, so anytype covers all of them.
inline fn discardOptCookie(opt: anytype) void {
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

pub inline fn getFocused() ?u32 {
    return state.?.focused_window;
}

pub inline fn getSuppressReason() core.FocusSuppressReason {
    return state.?.suppress_reason;
}

/// True when an incoming EnterNotify should be silently ignored.
///
/// Centralises suppression policy here so window.handleEnterNotify doesn't need
/// to know specific Reason values. NOTE: window_spawn suppression is handled in
/// window.zig's suppressSpawnCrossing, which needs the saved cursor position to
/// distinguish a real move from a synthetic crossing; any reason that doesn't
/// need coordinate disambiguation belongs here.
pub inline fn shouldSuppressEnterNotify() bool {
    return state.?.suppress_reason == .tiling_operation;
}

pub inline fn getLastEventTime() u32 {
    return state.?.last_event_time;
}

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
// non-transition call site is window.zig's registerWindowOffscreen, served by
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
/// first time it receives focus via commitFocusTransition.
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

// CommitFlags: controls which side effects commitFocusTransition applies.
// All fields are non-defaulted so every call site must be explicit; an
// accidental zero-flags call fails to compile, preventing silent
// no-protocol transitions that are hard to debug.
const CommitFlags = struct {
    /// Send xcb_set_input_focus. False for no_input (never receives focus
    /// protocol) and globally_active (manages its own focus, ICCCM §4.1.7).
    set_input_focus: bool,

    /// Raise to the top of the stack. True for click/command (user-driven)
    /// and globally_active hover (raising is its only focus signal).
    raise: bool,

    /// Send WM_TAKE_FOCUS after xcb_set_input_focus. Required for
    /// locally_active and globally_active input models.
    send_wm_take_focus: bool,

    /// Arm the async focus-confirm cookie for a deferred raise-and-retry.
    /// Used by pointer_sync for windows that may silently drop focus.
    arm_confirm: bool,

    /// Call bar.scheduleFocusRedraw. False only inside a server grab; the
    /// caller then calls bar.redrawInsideGrab() instead.
    schedule_bar: bool,

    /// New suppress_reason. setFocus derives it via suppressionFor(); direct
    /// callers hardcode `.none`.
    new_suppress: core.FocusSuppressReason,
};

/// Core focus-transition implementation shared by all focus paths.
/// NOTE: handleFocusIn does NOT call this; it delegates to
/// sendFocusProtocol, which operates on different invariants (no grab
/// management, no suppression update).
///
/// Every focus path follows the same sequence: update global state -> sync
/// button grabs -> X protocol -> notify observers; differing only in which
/// side effects apply, encoded in `flags`.
///
/// Preconditions (enforced by callers): `win` is a valid managed window,
/// `win` != focused_window, and any stale confirm cookie has been cancelled.
fn commitFocusTransition(old: ?u32, win: u32, flags: CommitFlags) void {
    state.?.focused_window = win;
    state.?.suppress_reason = flags.new_suppress;

    grabButtons(win, true);
    if (old) |o| grabButtons(o, false);

    const conn = core.getState().conn;

    if (flags.set_input_focus) focusNow(conn, win);

    if (flags.raise) utils.raiseWindow(conn, win);

    // Consume the pre-fired WM_PROTOCOLS cookie: drain it through
    // sendWMTakeFocusWithCookie when we send WM_TAKE_FOCUS (the server has
    // been processing it during our bookkeeping, so this is typically a
    // near-zero-cost buffer read), or discard it when we don't.
    const pre_cookie = state.?.pre_protocols_cookie;
    state.?.pre_protocols_cookie = null;
    if (flags.send_wm_take_focus) {
        if (pre_cookie) |ck|
            window.sendWMTakeFocusWithCookie(conn, win, 0, ck)
        else
            window.sendWMTakeFocus(conn, win, 0);
    } else if (pre_cookie) |ck| {
        xcb.xcb_discard_reply(conn, ck.sequence);
    }

    if (flags.arm_confirm) {
        state.?.confirm_cookie = xcb.xcb_get_input_focus(conn);
        state.?.confirm_win = win;
    }

    if (build_options.has_tiling) tiling.updateWindowFocus(old, win);
    if (build_options.has_bar) bar.carouselNotifyFocusChanged(win);
    if (flags.schedule_bar) if (build_options.has_bar) bar.scheduleFocusRedraw(win);

    advertiseActiveWindow(win);
}

/// Returns true when `win` must never receive focus from any focus-granting
/// path (setFocus). NOTE: handleFocusIn intentionally does NOT use this guard.

/// True if `win` currently has map_state == Viewable. Guards destroy/unmap
/// races on paths that can't guarantee the window is still alive.
/// Public because the unmanageWindow destroy path re-runs this pre-grab to
/// keep the grab body free of blocking reply waits.
pub fn isWindowMapped(conn: core.Connection, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn,
        xcb.xcb_get_window_attributes(conn, win),
        null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}

pub fn setFocus(win: u32, reason: Reason) void {
    if (window.isInvalidWindow(win)) return;
    if (state.?.focused_window == win) return;

    const conn = core.getState().conn;

    // Liveness guard: the event may have been queued before the window was
    // destroyed (mouse_click/user_command), or the queried pointer position
    // may be stale (pointer_sync). EnterNotify is exempt; the server
    // guarantees the window exists when it generates the crossing event.
    if ((reason == .mouse_click or reason == .user_command or reason == .pointer_sync) and
        !isWindowMapped(conn, win)) return;

    // getInputModel's WM_TAKE_FOCUS half is always queried live (see its doc
    // comment in window.zig), deliberately not merged into the pipelined
    // cookie fired below. Neither round trip is perceptible on this
    // infrequent, human-triggered path.
    const input_model = window.getInputModel(conn, win);
    if (input_model == .no_input) return;

    setFocusWithModel(win, reason, input_model);
}

/// Focus `win` using a caller-resolved input model, skipping the two blocking
/// round trips setFocus performs (the isWindowMapped liveness guard and
/// getInputModel's WM_PROTOCOLS query).
///
/// Intended for server-grab-held callers: they resolve the window and its
/// input model BEFORE xcb_grab_server so the grab body stays fire-and-forget;
/// a blocking reply wait inside the grab would implicitly flush the queued
/// configure/set_input_focus batch to the compositor mid-grab, breaking the
/// grab's atomicity. The caller must already have validated the window's
/// liveness for .mouse_click/.user_command/.pointer_sync; setFocus's guard is
/// deliberately NOT repeated here.
pub fn setFocusWithModel(win: u32, reason: Reason, input_model: window.InputModel) void {
    if (window.isInvalidWindow(win)) return;
    if (state.?.focused_window == win) return;
    if (input_model == .no_input) return;

    // Invariant: focused_window must be null or on the current workspace;
    // downstream consumers (fullscreen.toggle in particular) trust this
    // blindly. .workspace_switch targets the workspace being switched to and
    // .window_spawn may target an off-workspace registration, so both are
    // exempt; every other reason is a refocus target its caller must already
    // workspace-scope (see findBestAvailable). Asserting here catches a
    // violation at the introducing call site, not later as a visual bug in an
    // unrelated module.
    std.debug.assert(reason == .workspace_switch or reason == .window_spawn or
        tracking.isOnCurrentWorkspace(win));

    const conn = core.getState().conn;

    // Pipeline: fire the WM_PROTOCOLS cookie now, before the bookkeeping
    // below, so the reply is typically already buffered by the time
    // commitFocusTransition drains it. Discard any leftover from a previous
    // interrupted path first.
    discardOptCookie(state.?.pre_protocols_cookie);
    state.?.pre_protocols_cookie = window.fireTakeFocusCookie(conn, win);

    cancelPendingConfirm();

    const old = state.?.focused_window;
    commitFocusTransition(old, win, .{
        .set_input_focus = input_model != .globally_active,
        .raise = shouldRaise(reason, win),
        .send_wm_take_focus = true,
        .arm_confirm = reason == .pointer_sync,
        .schedule_bar = true,
        .new_suppress = suppressionFor(reason, state.?.suppress_reason),
    });
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
    clearConfirmState();

    const conn = core.getState().conn;

    // Reply must be consumed before any return to drain the XCB queue.
    const focus_reply = xcb.xcb_get_input_focus_reply(conn, cookie, null);
    defer if (focus_reply) |r| std.c.free(r);

    if (!window.isValidManagedWindow(win)) return;

    // Live take_focus check, same as setFocus above; see getInputModel's
    // doc comment in window.zig.
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
inline fn clearConfirmState() void {
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

/// Re-assert focus on `win` from inside handleFocusIn.
///
/// Skips xcb_set_input_focus for .globally_active (ICCCM §4.1.7) and never
/// raises or arms confirm/retry; this responds to a focus steal, so
/// stability, not raise-order, is the priority. Always updates _NET_ACTIVE_WINDOW
/// so EWMH clients stay in sync.
fn sendFocusProtocol(win: u32) void {
    const conn = core.getState().conn;
    // take_focus is checked live twice here (getInputModel, then again inside
    // sendWMTakeFocus); same "not worth entangling to save one round trip"
    // reasoning as setFocus, just unpipelined since this path fires on focus
    // steals, not on every event.
    const model = window.getInputModel(conn, win);
    if (model == .no_input) return;
    if (model != .globally_active) {
        focusNow(conn, win);
    }
    // Always advertise the active window, regardless of input model.
    // Without this, a globally_active window that has stolen focus would leave
    // _NET_ACTIVE_WINDOW pointing at the thief even after we re-assert `win`.
    advertiseActiveWindow(win);
    window.sendWMTakeFocus(conn, win, 0);
}

/// DWM's focusin: translated exactly. No mode/detail/managed filtering.
///
/// Every FocusIn that doesn't match the intended window triggers an immediate
/// re-assertion via sendFocusProtocol, which uses CurrentTime so the X server
/// never rejects it. Filtering mode/detail was incorrect: it allowed Electron's
/// internal focus steals to slip through unchallenged.
pub fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t) void {
    if (state.?.confirm_win) |exp| {
        if (event.event == exp) cancelPendingConfirm();
    }
    const cs = core.getState();
    const is_offscreen_steal = !window.isInvalidWindow(event.event) and
        !tracking.isOnCurrentWorkspace(event.event);

    const prev = state.?.focused_window orelse {
        if (is_offscreen_steal) {
            focusNow(cs.conn, cs.root);
            advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
        }
        return;
    };

    if (event.event == prev) return;

    // An off-workspace window (Wine, Electron, a game) that re-focuses
    // itself on every FocusOut would otherwise create a three-way
    // fight that never converges. Redirecting to root first breaks the
    // cycle: the thief fights root (which never replies), exhausting
    // its retry budget, then sendFocusProtocol(prev) reclaims focus
    // with no active opponent.
    if (is_offscreen_steal) focusNow(cs.conn, cs.root);
    sendFocusProtocol(prev);
}

/// Returns the first window satisfying `visible`, walking the tracking list.
/// Pure, no side effects, so grab-held callers can resolve the target and
/// pre-query its input model before xcb_grab_server, keeping the grab body
/// fire-and-forget (see setFocusWithModel).
///
/// This is the resolver behind the dwm focus(NULL) idiom; callers that need to
/// focus "whatever is best after X happened" use this instead of rolling their
/// own scan + setFocus sequence. The `visible` predicate decouples workspace
/// visibility from focus mechanics (e.g. pass
/// tracking.isOnCurrentWorkspaceAndVisible for normal post-action re-focus).
pub fn findBestAvailable(visible: *const fn (u32) bool) ?u32 {
    for (tracking.allWindows()) |entry| {
        if (visible(entry.win)) return entry.win;
    }
    return null;
}

/// Focus the first available window on the current workspace. Fallback for
/// callers that just cleared focus. No-op if the workspace is empty.
pub fn focusBestAvailable() void {
    if (findBestAvailable(tracking.isOnCurrentWorkspaceAndVisible)) |win|
        setFocus(win, .tiling_operation);
}

pub fn clearFocus() void {
    if (state.?.focused_window) |old_win| {
        grabButtons(old_win, false);
        if (build_options.has_tiling) tiling.updateWindowFocus(old_win, null);
    }
    cancelPendingConfirm();
    state.?.focused_window = null;
    state.?.suppress_reason = .none;
    const cs = core.getState();
    focusNow(cs.conn, cs.root);
    if (build_options.has_bar) bar.carouselNotifyFocusChanged(null);
    if (build_options.has_bar) bar.scheduleFocusRedraw(null);
    advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
}

/// Focus `target` with `model` when both are present, else clear focus when
/// `target` is null. `target` non-null with a null `model` is a no-op (the
/// caller decided not to focus, mirroring the inline `if (model) |m|` pattern
/// it replaces).
pub fn focusOrClear(target: ?u32, model: ?window.InputModel, reason: Reason) void {
    if (target) |t| {
        if (model) |m| setFocusWithModel(t, reason, m);
        return;
    }
    clearFocus();
}

/// Pre-grab focus resolution: bundles a window target with its input
/// model, resolved before `xcb_grab_server` so the grab body stays
/// fire-and-forget. Use with `focusOrClear` to apply in one call.
pub const FocusContext = struct {
    target: ?u32,
    model: ?window.InputModel,

    pub fn resolve(target: ?u32) FocusContext {
        return .{
            .target = target,
            .model = if (target) |t| window.getInputModel(core.getState().conn, t) else null,
        };
    }

    pub fn apply(self: FocusContext, reason: Reason) void {
        focusOrClear(self.target, self.model, reason);
    }
};

/// Write `_NET_ACTIVE_WINDOW` to the root window so EWMH clients stay in sync.
/// No-ops when the atom was not resolved at init time.
inline fn advertiseActiveWindow(win: u32) void {
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
        .mouse_click, .user_command, .pointer_sync => !(build_options.has_tiling and tiling.isWindowActiveTiled(win)),
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

/// Cancel a pending pointer-sync cookie without consuming the reply. Call on
/// workspace switches so a stale pre-switch pointer position cannot redirect
/// focus back to an off-workspace window via drainPointerSync.
pub fn cancelPointerSync() void {
    discardOptCookie(state.?.pointer_cookie);
    state.?.pointer_cookie = null;
}

/// Fire an async pointer-position query for focus-after-tiling sync: clears
/// suppression (so subsequent EnterNotify events are no longer masked) and
/// queues xcb_query_pointer without blocking. The reply is handled by
/// drainPointerSync from the event loop.
pub fn beginPointerSync() void {
    state.?.suppress_reason = .none;
    discardOptCookie(state.?.pointer_cookie);
    const cs = core.getState();
    state.?.pointer_cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
}

/// Drain the deferred pointer-position reply and route focus to whichever
/// managed window is currently under the pointer. Called from the event loop;
/// safe to call when no query is pending.
pub fn drainPointerSync() void {
    const cookie = state.?.pointer_cookie orelse return;
    state.?.pointer_cookie = null;
    const cs = core.getState();
    const reply = xcb.xcb_query_pointer_reply(cs.conn, cookie, null) orelse return;
    defer std.c.free(reply);
    const child = reply.*.child;
    if (child == 0 or child == cs.root or !window.isValidManagedWindow(child)) return;
    // A stale reply may reference a window from a workspace that is no longer
    // current (e.g. after a workspace switch); discard it rather than
    // redirecting focus to an offscreen window.
    if (!tracking.isOnCurrentWorkspace(child)) return;
    setFocus(child, .pointer_sync);
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
    state.?.tiling_op_cookie = null;
    const cs = core.getState();
    // The reply's content is unused; only its arrival signals that the server
    // has processed everything queued before it. It must be consumed to drain
    // the XCB queue.
    const reply = xcb.xcb_get_input_focus_reply(cs.conn, cookie, null) orelse return;
    std.c.free(reply);
    if (state.?.suppress_reason == .tiling_operation) state.?.suppress_reason = .none;
}

// Window focus cycling
//
// Scratch buffer for collectVisibleWindows, module-level so it isn't
// stack-allocated on every key press. Sized to tracking.Tracking.capacity
// (the max tiled windows across the whole WM, not per workspace).

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
/// Prefers the tiling module's window list when tiling is active; it matches
/// on-screen order (master first, then stack); else falls back to the
/// tracking table in iteration order. Both paths emit only windows that are on
/// the current workspace and not minimized. Returns the count written into
/// `cycle_buf`, or 0 if none.
fn collectVisibleWindows() usize {
    var len: usize = 0;

    if (build_options.has_tiling and tiling.isEnabled()) {
        for (if (build_options.has_tiling) tiling.getTiledWindows() else &.{}) |w| appendVisible(w, &len);
        if (len > 0) return len;
    }

    // Fallback: all visible windows in tracking-table order. No pre-insertion
    // or dedup needed; focusCycle locates the focused window via indexOfScalar.
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
    const idx = if (state.?.focused_window) |w|
        std.mem.indexOfScalar(u32, wins, w) orelse sentinel
    else
        sentinel;
    setFocus(wins[cycleIndex(forward, idx, len)], .user_command);
}

/// Cycle focus to the next visible window (Mod+k, moves right/forward).
pub fn focusNext() void {
    focusCycle(true);
}
/// Cycle focus to the previous visible window (Mod+j, moves left/backward).
pub fn focusPrev() void {
    focusCycle(false);
}

/// Shared implementation for moving the focused window through the cycle.
/// Swaps it with the neighbour in the given direction.
fn moveWindowCycle(comptime forward: bool) void {
    const len = collectVisibleWindows();
    if (len < 2) return;
    const wins = cycle_buf[0..len];
    const focused = state.?.focused_window orelse return;
    const idx = std.mem.indexOfScalar(u32, wins, focused) orelse return;
    const target = wins[cycleIndex(forward, idx, len)];
    if (build_options.has_tiling) tiling.swapWindowsById(focused, target);
}

/// Move the focused window one step forward in the cycle (Mod+Shift+k).
pub fn moveWindowNext() void {
    moveWindowCycle(true);
}
/// Move the focused window one step backward in the cycle (Mod+Shift+j).
pub fn moveWindowPrev() void {
    moveWindowCycle(false);
}
