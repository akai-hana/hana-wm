//! Focus management — set, clear, and reason-aware focus routing.

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
const carousel      = if (build.has_bar and build.has_carousel) @import("carousel") else struct {
    pub fn notifyFocusChanged(_: anytype) void {}
};


// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------
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
    // broken; it should be documented at any future call site that reads it.
    last_event_time:   u32                                 = 0,

    // Full MRU list of previously focused windows.  Index 0 is the most
    // recently focused window before the current one.
    //
    // Invariants:
    //   • focused_window is never present in the history.
    //   • Each window appears at most once.
    //   • Entries are never left pointing at destroyed windows; callers must
    //     call removeFromHistory(win) when a window is unmanaged.
    history:           std.ArrayListUnmanaged(u32)         = .empty,

    // Optional so that deinit() called before init() (e.g. a defensive deinit
    // in an error-path test) is a safe no-op.  A null allocator means the
    // history list has never been populated; .deinit() skips the free.
    allocator:         ?std.mem.Allocator                  = null,

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
    confirm_cookie:    ?xcb.xcb_get_input_focus_cookie_t  = null,
    confirm_win:       ?u32                               = null,
    pointer_cookie:    ?xcb.xcb_query_pointer_cookie_t    = null,
};

var state: State = .{};

// Lifecycle

pub fn init(allocator: std.mem.Allocator) void {
    // Deinit any existing history before overwriting the allocator, so we
    // never leak the old buffer.  A null allocator means no history was ever
    // allocated, so the deinit is a safe no-op.
    if (state.allocator) |old_alloc| state.history.deinit(old_alloc);

    // Reset every field to its zero value, then set the allocator.  This
    // covers all module globals so that a deinit() + init() cycle (test
    // harness, session restart) starts from a clean slate.
    state = .{ .allocator = allocator };

    // Intern _NET_ACTIVE_WINDOW so setFocus can advertise the focused window
    // on the root.  null reply -> stays XCB_ATOM_NONE; advertiseActiveWindow
    // no-ops.
    const ck = xcb.xcb_intern_atom(core.conn, 0, "_NET_ACTIVE_WINDOW".len, "_NET_ACTIVE_WINDOW");
    if (xcb.xcb_intern_atom_reply(core.conn, ck, null)) |r| {
        state.net_active_window = r.*.atom;
        std.c.free(r);
    }
}

pub fn deinit() void {
    // Guard: if init() was never called, allocator is null and there is
    // nothing to free.  This makes a defensive deinit() before init() safe.
    if (state.allocator) |alloc| state.history.deinit(alloc);
    state.history  = .empty;
    state.allocator = null;
}

/// Push `win` to the front of the history, deduplicating if already present.
/// Called internally whenever focused_window changes to a new value.
/// Allocation failures are silently ignored — the history may be shorter than
/// ideal, but focus still functions correctly.
///
/// O(n) single-pass: when `win` is already present, one scan and one in-place
/// memmove moves items[0..idx] right by one and writes `win` at index 0, with
/// no allocation.  When absent, falls back to insert(0, …), which may allocate.
fn recordInHistory(win: u32) void {
    if (win == 0) return;
    // Invariant: recordInHistory is always called with the pre-transition window.
    // If this fires, a caller passed the post-transition value instead.
    std.debug.assert(state.focused_window != win);
    // Short-circuit: already the most-recent entry — nothing to do.
    if (state.history.items.len > 0 and state.history.items[0] == win) return;

    const alloc = state.allocator orelse return;

    if (std.mem.indexOfScalar(u32, state.history.items, win)) |idx| {
        std.mem.copyBackwards(u32, state.history.items[1 .. idx + 1], state.history.items[0..idx]);
        state.history.items[0] = win;
    } else {
        state.history.insert(alloc, 0, win) catch {};
    }
}

/// Remove `win` from the history (called when a window is unmanaged).
/// Safe to call even if `win` is not present.
pub fn removeFromHistory(win: u32) void {
    const idx = std.mem.indexOfScalar(u32, state.history.items, win) orelse return;
    _ = state.history.orderedRemove(idx);
}

/// Returns a slice of previously focused windows in MRU order.
/// The slice is valid until the next call to any focus mutator.
pub inline fn historyItems() []const u32 {
    return state.history.items;
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

/// Raw write to focused_window, bypassing all side effects: history recording,
/// grab management, XCB protocol calls, bar/carousel notifications, and
/// _NET_ACTIVE_WINDOW updates.  All of those invariants are the responsibility
/// of commitFocusTransition.  Callers must ensure they maintain every invariant
/// that commitFocusTransition normally enforces.
///
/// NOTE — escape hatch: this function exists for the one caller (the fullscreen
/// exit path) that cannot use commitFocusTransition directly.  If that caller is
/// ever refactored to call commitFocusTransition with an appropriate CommitFlags,
/// this function should be removed.  Do not add new callers.
pub inline fn setFocused(win: ?u32) void { state.focused_window = win; }

/// Update the X11 event timestamp used for xcb_set_input_focus and WM_TAKE_FOCUS
/// messages.  See "Timestamp handling" below for why this must be called for
/// EnterNotify events before setFocus(.mouse_enter).
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

/// Set the suppress reason and immediately focus `win` as an atomic operation.
///
/// This is the correct API for callers (e.g. the fullscreen-exit path) that
/// need to prime suppression before a programmatic focus change.  The two
/// operations must be paired: if they are split across separate calls, a
/// concurrent setFocus from another path can clear the suppression between the
/// setSuppressReason write and the setFocus call, or — if setFocus returns
/// early via the `focused_window == win` guard — suppression is set but focus
/// never changes, leaving it primed permanently.
///
/// Replace the split pattern:
///   focus.setSuppressReason(.window_spawn);  // fragile
///   focus.setFocus(win, .tiling_operation);
/// With the atomic form:
///   focus.setFocusWithSuppression(win, .tiling_operation, .window_spawn);
///
/// Edge case: if `win` equals focused_window, this function returns without
/// calling setFocus, so `suppress` is never applied.  The caller need not
/// guard against this — the early return is the safe outcome.
pub fn setFocusWithSuppression(win: u32, reason: Reason, suppress: core.FocusSuppressReason) void {
    // Runtime guard (not assert): if win is already focused, setFocus would
    // return early without committing a transition, leaving suppress permanently
    // set.  Bail out safely instead — the caller's intent (focus win) is already
    // satisfied and no suppression is needed.
    if (state.focused_window == win) return;
    state.suppress_reason = suppress;
    setFocus(win, reason);
}

/// Direct write to suppress_reason.
///
/// Prefer setFocusWithSuppression when suppression must be paired with a
/// focus change.  This setter exists for cases where suppression must be
/// cleared or set independently of any focus change — e.g. MotionNotify
/// clearing suppression when real pointer movement is detected.
///
/// NOTE — escape hatch: like setFocused, this bypasses commitFocusTransition
/// invariants and should only be used when a full transition is not appropriate.
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
    mouse_click,
    mouse_enter,
    user_command,
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
//
// All fields are non-defaulted so that every call site must be explicit.
// An accidental zero-flags call (e.g. CommitFlags{}) will fail to compile,
// preventing silent no-protocol transitions that are extremely hard to debug.
//
// Note: bruteForceMouseEnterFocus intentionally calls commitFocusTransition
// with set_input_focus/raise/send_wm_take_focus all false when the window is
// changing — those signals are sent unconditionally after the call returns.
// This is not a bug; the flags are still fully explicit at the call site.
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
    /// Used by mouse_enter for passive and locally_active windows that may
    /// silently drop xcb_set_input_focus when not already topmost.
    arm_confirm:        bool,

    /// Call bar.scheduleFocusRedraw after the transition.
    /// False only for syncPointerFocusNow, which runs inside a server grab;
    /// its caller is responsible for calling bar.redrawInsideGrab() instead.
    schedule_bar:       bool,

    /// New value for suppress_reason after the transition.
    /// `setFocus` derives this from reason + current state via suppressionFor();
    /// all direct callers of `commitFocusTransition` hardcode `.none`.
    new_suppress: core.FocusSuppressReason,
};

/// Core focus-transition implementation shared by setFocus, syncPointerFocusNow,
/// dwmFocus, and bruteForceMouseEnterFocus.
/// NOTE: handleFocusIn does NOT call this function — it delegates to
/// sendFocusProtocol, which operates on a different set of invariants (no
/// history recording, no grab management, no suppression update).
///
/// All focus paths perform the same logical sequence — record history -> update
/// global state -> sync button grabs -> X protocol requests -> notify downstream
/// observers — and differ only in which side effects apply, encoded in `flags`.
///
/// Preconditions (enforced by callers):
///   • `win` is a valid managed window (non-zero, not root, not bar).
///   • `win` != focused_window (no-op transitions are filtered upstream).
///   • Any stale confirm cookie has been cancelled or consumed by the caller.
fn commitFocusTransition(old: ?u32, win: u32, flags: CommitFlags) void {
    // Update focused_window BEFORE calling recordInHistory so the assertion
    // inside recordInHistory (focused_window != old) holds.
    state.focused_window  = win;
    state.suppress_reason = flags.new_suppress;
    if (old) |o| recordInHistory(o);

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

    if (flags.send_wm_take_focus)
        // CurrentTime (0) — same reason as xcb_set_input_focus above.
        window.sendWMTakeFocus(core.conn, win, 0); // CurrentTime

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
/// path (setFocus, dwmFocus, bruteForceMouseEnterFocus).
/// NOTE: handleFocusIn intentionally does NOT use this guard.
inline fn isInvalidFocusTarget(win: u32) bool {
    return win == 0 or win == core.root or bar.isBarWindow(win);
}

/// Hover focus with unconditional protocol resend.
///
/// Unlike dwmFocus, this does NOT short-circuit when `win` is already
/// focused_window.  Some Electron/Qt builds call XSetInputFocus spontaneously;
/// handleFocusIn accepts that grab (when nothing was focused), setting
/// focused_window without sending WM_TAKE_FOCUS, so the renderer widget never
/// activates.  Re-sending the protocol on every hover fixes that case without
/// harm to compliant clients.
///
/// When `win` differs from focused_window, delegates to commitFocusTransition
/// for all WM bookkeeping (history, grabs, tiling, bar, _NET_ACTIVE_WINDOW).
/// The X protocol signals are then issued unconditionally with CurrentTime (0),
/// bypassing input-model checks entirely.
///
/// Use dwmFocus for the common hover path; reserve this for clients known to
/// silently drop the initial WM_TAKE_FOCUS.
pub fn bruteForceMouseEnterFocus(win: u32) void {
    if (isInvalidFocusTarget(win)) return;

    cancelPendingConfirm();

    if (state.focused_window != win) {
        const old = state.focused_window;
        commitFocusTransition(old, win, .{
            .set_input_focus    = false, // sent unconditionally below
            .raise              = false, // raised unconditionally below
            .send_wm_take_focus = false, // sent unconditionally below
            .arm_confirm        = false,
            .schedule_bar       = true,
            .new_suppress       = .none,
        });
    } else {
        // Already focused: bookkeeping skipped, but suppression must still clear.
        state.suppress_reason = .none;
    }

    // Always re-send — raise, XSetInputFocus, WM_TAKE_FOCUS — with CurrentTime (0).
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win, 0);
    window.sendWMTakeFocus(core.conn, win, 0);
}

pub fn setFocus(win: u32, reason: Reason) void {
    if (isInvalidFocusTarget(win)) return;
    if (state.focused_window == win) return;

    // For click and command, a destroy race is possible between the user action
    // and this call.  Guard with a live xcb_get_window_attributes round-trip.
    // All other reasons guarantee the window is mapped without asking the server.
    if ((reason == .mouse_click or reason == .user_command) and
        !isWindowMapped(core.conn, win)) return;

    const input_model = window.getInputModelCached(core.conn, win);
    if (input_model == .no_input) return;

    cancelPendingConfirm();

    const old = state.focused_window;
    commitFocusTransition(old, win, .{
        .set_input_focus    = input_model != .globally_active,
        .raise              = shouldRaise(reason),
        .send_wm_take_focus = input_model != .no_input,
        .arm_confirm        = reason == .mouse_enter,
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
    const win_opt = state.confirm_win;
    state.confirm_cookie = null;
    state.confirm_win    = null;

    // Reply must be consumed before any return to drain the XCB queue.
    const focus_reply = xcb.xcb_get_input_focus_reply(core.conn, cookie, null);
    defer if (focus_reply) |r| std.c.free(r);

    std.debug.assert(win_opt != null);
    const win = win_opt orelse return;

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

/// Discard a pending confirm reply without acting on it.
///
/// Uses xcb_discard_reply, a non-blocking primitive that instructs XCB to
/// silently drop the reply when it arrives, correctly releasing the reply-queue
/// entry.  The earlier drainAndFree approach (xcb_get_input_focus_reply) was
/// used under the mistaken belief that xcb_discard_reply did not drain the XCB
/// reply queue — it does.  xcb_discard_reply is the correct tool here because
/// we do not need the reply contents; blocking on the round-trip is unnecessary
/// latency on what is already a non-hot path.
///
/// Safe to call when no confirm is pending.
fn cancelPendingConfirm() void {
    const cookie = state.confirm_cookie orelse return;
    state.confirm_cookie = null;
    state.confirm_win    = null;
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

/// Send the X protocol focus signals for `win` using CurrentTime (0).
///
/// Skips xcb_set_input_focus for .no_input and .globally_active windows.
/// WM_TAKE_FOCUS is always sent; sendWMTakeFocus is a no-op for windows that
/// do not advertise it.  No raise, no confirm/retry machinery.
fn sendFocusProtocol(win: u32) void {
    const model = window.getInputModelCached(core.conn, win);
    if (model == .no_input) return;
    if (model == .passive or model == .locally_active) {
        _ = xcb.xcb_set_input_focus(core.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, 0); // CurrentTime
        advertiseActiveWindow(win);
    }
    window.sendWMTakeFocus(core.conn, win, 0); // CurrentTime
}

/// Hover focus following DWM's focus(c) semantics.
///
/// Returns early when `win` is already focused — re-sending WM_TAKE_FOCUS on
/// every hover over an already-focused Electron window causes it to re-evaluate
/// its internal focus routing continuously.
///
/// Does NOT raise the window.  DWM's focus() contains no XRaiseWindow call;
/// raising on hover generates synthetic FocusOut/FocusIn events that confuse
/// Electron's internal focus state machine.
///
/// Uses CurrentTime (0) so the X server's timestamp ordering check never
/// rejects requests.  No confirm/retry machinery.
///
/// Contrast with bruteForceMouseEnterFocus, which re-sends the X protocol even
/// when the window is already focused_window.  Use that path only when a client
/// is known to silently drop the initial WM_TAKE_FOCUS.
pub fn dwmFocus(win: u32) void {
    if (isInvalidFocusTarget(win)) return;
    if (state.focused_window == win) return;

    cancelPendingConfirm();

    const model = window.getInputModelCached(core.conn, win);
    if (model == .no_input) return;
    const old = state.focused_window;
    commitFocusTransition(old, win, .{
        .set_input_focus    = model == .passive or model == .locally_active,
        .raise              = false,
        .send_wm_take_focus = true,
        .arm_confirm        = false,
        .schedule_bar       = true,
        .new_suppress       = .none,
    });
}

/// DWM's focusin — translated exactly. No mode/detail/managed filtering.
///
/// Every FocusIn that doesn't match the intended window triggers an immediate
/// re-assertion via sendFocusProtocol, which uses CurrentTime so the X server
/// never rejects it.  Filtering mode/detail (GRAB/UNGRAB/WHILE_GRABBED,
/// NotifyInferior) was incorrect: it allowed Electron's internal focus steals
/// to slip through unchallenged.
pub fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t) void {
    // Early-cancel the pending confirm cookie when the FocusIn we were waiting
    // for arrives before drainPendingConfirm() runs.  cancelPendingConfirm uses
    // xcb_discard_reply (non-blocking), releasing the reply-queue entry
    // immediately without a blocking drain.
    if (state.confirm_win)    |exp| if (event.event == exp)  cancelPendingConfirm();
    if (state.focused_window) |sel| if (event.event != sel) sendFocusProtocol(sel);
}

/// Focus the most recently focused window satisfying `visible`, consulting
/// the MRU history in order.  Falls back to `on_miss()` if provided, or
/// clearFocus() if null, when no candidate is found.
///
/// This is the Zig equivalent of dwm's focus(NULL) idiom — callers that need
/// to focus "whatever is best after X happened" (window close, workspace switch,
/// unmanage, etc.) use this instead of rolling their own history-scan + setFocus
/// sequence.
///
/// The `visible` predicate decouples workspace visibility from focus mechanics:
///   • Pass tracking.isOnCurrentWorkspaceAndVisible for normal post-action
///     re-focus (on current workspace and not minimized).
///   • Pass window.isValidManagedWindow for cleanup contexts where any managed
///     window is acceptable regardless of workspace membership.
///
/// NOTE — predicate provides the primary runtime filter.  Destroyed windows are
/// pruned from the history by removeFromHistory() at unmanage time, but there is
/// a narrow race between unmanage and history pruning.  The `visible` predicate
/// is therefore the definitive guard: callers must use a predicate that returns
/// false for unmanaged windows (e.g. tracking.isOnCurrentWorkspaceAndVisible,
/// which implicitly checks isManaged via the workspace-mask lookup).  Stale XIDs
/// that slip through a predicate that does not check isManaged may reach setFocus
/// and generate a BadWindow error on the XCB connection.
pub fn focusBestAvailable(
    reason:   Reason,
    visible:  *const fn (u32) bool,
    on_miss:  ?*const fn () void,
) void {
    for (state.history.items) |win| {
        if (visible(win)) {
            setFocus(win, reason);
            return;
        }
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

inline fn shouldRaise(reason: Reason) bool {
    return switch (reason) {
        .mouse_click, .user_command, .mouse_enter => true,
        .tiling_operation, .window_spawn, .workspace_switch => false,
    };
}

inline fn suppressionFor(reason: Reason, current: core.FocusSuppressReason) core.FocusSuppressReason {
    return switch (reason) {
        .mouse_click, .user_command => .none,
        .window_spawn               => .window_spawn,
        else                        => current,
    };
}

/// Synchronous pointer-position query for use inside a server grab.
///
/// Clears suppression, queries the pointer with a blocking reply, and updates
/// all focus state for whichever managed window is currently under the cursor —
/// all before returning.  Must be called inside xcb_grab_server /
/// xcb_ungrab_server so that the resulting border and focus changes are folded
/// into the same atomic batch as the tiling operation that preceded it.
///
/// Deliberately does NOT call bar.scheduleFocusRedraw: the caller is expected
/// to call bar.redrawInsideGrab() immediately after.
pub fn syncPointerFocusNow() void {
    state.suppress_reason = .none;
    const cookie = xcb.xcb_query_pointer(core.conn, core.root);
    const reply  = xcb.xcb_query_pointer_reply(core.conn, cookie, null) orelse return;
    defer std.c.free(reply);
    const child = reply.*.child;
    if (child == 0 or child == core.root) return;
    if (!window.isValidManagedWindow(child)) return;
    if (state.focused_window == child) return;

    cancelPendingConfirm();

    const input_model = window.getInputModelCached(core.conn, child);
    if (input_model == .no_input) return;

    const old = state.focused_window;
    commitFocusTransition(old, child, .{
        .set_input_focus    = input_model != .globally_active,
        .raise              = false,
        .send_wm_take_focus = true,
        .arm_confirm        = false,
        .schedule_bar       = false,
        .new_suppress       = .none,
    });
}

/// Fire an async pointer-position query for focus-after-tiling sync.
///
/// Clears suppression immediately (so subsequent EnterNotify events are no
/// longer masked) and queues xcb_query_pointer without blocking.  The reply
/// is handled by drainPointerSync(), called from the event-dispatch loop.
pub fn beginPointerSync() void {
    state.suppress_reason = .none;
    if (state.pointer_cookie) |stale| {
        xcb.xcb_discard_reply(core.conn, stale.sequence);
    }
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
    setFocus(child, .mouse_enter);
}

fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn, xcb.xcb_get_window_attributes(conn, win), null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}

// ---------------------------------------------------------------------------
// Window focus cycling — dwm-style Mod+j / Mod+k
// ---------------------------------------------------------------------------
//
// Scratch buffer for collectVisibleWindows.  Module-level so it is not
// stack-allocated on every key press.  Safe in a single-threaded WM.

var cycle_buf: [64]u32 = undefined;

/// Build an ordered list of visible windows for cycling.
///
/// When tiling is active the tiling module's window list is used — it matches
/// the order windows appear on screen (master first, then stack), which is
/// exactly what dwm's focusstack() walks.
///
/// Falls back to a list built from the focus MRU history (current focus first,
/// then history) when tiling is disabled or has no windows.
///
/// Returns the number of windows written into `cycle_buf`, or 0 if none.
fn collectVisibleWindows() usize {
    var len: usize = 0;

    if (comptime build.has_tiling) {
        if (tiling.getStateOpt()) |t| {
            if (t.is_enabled) {
                for (t.windows.items()) |w| {
                    if (len >= cycle_buf.len) break;
                    if (tracking.isOnCurrentWorkspaceAndVisible(w)) {
                        cycle_buf[len] = w;
                        len += 1;
                    }
                }
                if (len > 0) return len;
            }
        }
    }

    // Fallback: MRU order — current focus first, then history.
    if (state.focused_window) |w| {
        cycle_buf[len] = w;
        len += 1;
    }
    for (state.history.items) |w| {
        if (len >= cycle_buf.len) break;
        if (!tracking.isOnCurrentWorkspaceAndVisible(w)) continue;
        // Skip if already added (avoids duplicating focused_window).
        var dup = false;
        for (cycle_buf[0..len]) |existing| {
            if (existing == w) { dup = true; break; }
        }
        if (!dup) {
            cycle_buf[len] = w;
            len += 1;
        }
    }
    return len;
}

/// Cycle focus to the next visible window (dwm Mod+k — moves right/forward).
///
/// Walks the tiling window list in ascending order so the focus follows the
/// visual layout: master → first stack slot → second stack slot → … → master.
pub fn focusNext() void {
    const len = collectVisibleWindows();
    if (len == 0) return;
    const wins = cycle_buf[0..len];
    const idx = if (state.focused_window) |w|
        std.mem.indexOfScalar(u32, wins, w) orelse 0
    else
        0;
    setFocus(wins[(idx + 1) % len], .user_command);
}

/// Cycle focus to the previous visible window (dwm Mod+j — moves left/backward).
///
/// Walks the tiling window list in descending order.
pub fn focusPrev() void {
    const len = collectVisibleWindows();
    if (len == 0) return;
    const wins = cycle_buf[0..len];
    const idx = if (state.focused_window) |w|
        std.mem.indexOfScalar(u32, wins, w) orelse 0
    else
        0;
    setFocus(wins[(idx + len - 1) % len], .user_command);
}
/// Move the focused window one step forward in the cycle (Mod+Shift+k).
///
/// Swaps the focused window with the window that would receive focus on
/// Mod+k, keeping focus on the moved window.  Only has an effect when
/// tiling is active and at least two windows are visible.
pub fn moveWindowNext() void {
    if (comptime !build.has_tiling) return;
    const len = collectVisibleWindows();
    if (len < 2) return;
    const wins = cycle_buf[0..len];
    const focused = state.focused_window orelse return;
    const idx = std.mem.indexOfScalar(u32, wins, focused) orelse return;
    const target = wins[(idx + 1) % len];
    tiling.swapWindowsById(focused, target);
}

/// Move the focused window one step backward in the cycle (Mod+Shift+j).
///
/// Swaps the focused window with the window that would receive focus on
/// Mod+j, keeping focus on the moved window.
pub fn moveWindowPrev() void {
    if (comptime !build.has_tiling) return;
    const len = collectVisibleWindows();
    if (len < 2) return;
    const wins = cycle_buf[0..len];
    const focused = state.focused_window orelse return;
    const idx = std.mem.indexOfScalar(u32, wins, focused) orelse return;
    const target = wins[(idx + len - 1) % len];
    tiling.swapWindowsById(focused, target);
}
