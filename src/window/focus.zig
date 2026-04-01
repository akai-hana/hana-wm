//! Focus management — set, clear, and reason-aware focus routing.

const std    = @import("std");
const core   = @import("core");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const utils  = @import("utils");
const bar    = if (build_options.has_bar) @import("bar") else struct {
    pub fn scheduleFocusRedraw(_: anytype) void {}
    pub fn isBarWindow(_: u32) bool { return false; }
    pub fn redrawInsideGrab() void {}
};
const window = @import("window");
const carousel = if (build_options.has_bar and build_options.has_carousel) @import("carousel") else struct {
    pub fn notifyFocusChanged(_: anytype) void {}
};
const xcb    = core.xcb;

// Module state
//
// These three fields were formerly on the WM struct; they belong here because
// only focus.zig should be their primary writer.  All other modules call the
// typed accessors below rather than reaching into WM.

var g_focused_window: ?u32 = null;
var g_suppress_reason: core.FocusSuppressReason = .none;
var g_last_event_time: u32 = 0;

// Focus history
//
// Full MRU list of previously focused windows.  Index 0 is the most recently
// focused window before the current one, index 1 the one before that, and so on.
//
// Invariants:
//   • g_focused_window is never present in the history.
//   • Each window appears at most once.
//   • Entries are never left pointing at destroyed windows; callers must call
//     removeFromHistory(win) when a window is unmanaged.
//
// The list grows dynamically via the allocator supplied to focus.init and is
// freed by focus.deinit.  There is no artificial cap — the list will never
// hold more entries than there are managed windows.

var g_history: std.ArrayListUnmanaged(u32) = .empty;
var g_allocator: std.mem.Allocator = undefined;

// EWMH atom for _NET_ACTIVE_WINDOW — interned once in init().
var g_net_active_window: xcb.xcb_atom_t = xcb.XCB_ATOM_NONE;

// Deferred async state
//
// Rather than blocking on xcb_get_input_focus and xcb_query_pointer replies
// inline, we fire the requests immediately and store the cookies.  The
// corresponding drain functions are called from the event-dispatch loop on
// the next iteration, keeping the hot paths non-blocking.
//
// g_confirm_cookie / g_confirm_win
//   Non-compliant-client focus confirmation (passive / locally_active windows
//   that silently drop xcb_set_input_focus when not topmost on mouse_enter).
//   g_confirm_win is the window the query was issued for.  handleFocusIn uses
//   it to cancel the pending reply early when the FocusIn arrives first —
//   meaning the focus landed without needing a raise-and-retry.
//
// g_pointer_cookie
//   Pending pointer-position query issued by beginPointerSync().  Drained by
//   drainPointerSync() to route focus to whichever window is under the cursor.

var g_confirm_cookie: ?xcb.xcb_get_input_focus_cookie_t = null;
var g_confirm_win: ?u32 = null;

var g_pointer_cookie: ?xcb.xcb_query_pointer_cookie_t = null;

// Lifecycle

pub fn init(allocator: std.mem.Allocator) void {
    // Reset every module global so that a deinit() + init() cycle (test
    // harness, session restart) starts from a clean slate.  The linker
    // zero-inits them on first load, but subsequent reinits would otherwise
    // inherit stale state from the previous session.
    g_allocator         = allocator;
    g_history           = .empty;
    g_focused_window    = null;
    g_suppress_reason   = .none;
    g_last_event_time   = 0;
    g_confirm_cookie    = null;
    g_confirm_win       = null;
    g_pointer_cookie    = null;
    g_net_active_window = xcb.XCB_ATOM_NONE;

    // Intern _NET_ACTIVE_WINDOW so setFocus can advertise the focused window
    // on the root window — required for xev -root / xprop based external tools.
    // null reply → stays XCB_ATOM_NONE; advertiseActiveWindow no-ops.
    const ck = xcb.xcb_intern_atom(core.conn, 0, "_NET_ACTIVE_WINDOW".len, "_NET_ACTIVE_WINDOW");
    if (xcb.xcb_intern_atom_reply(core.conn, ck, null)) |r| {
        g_net_active_window = r.*.atom;
        std.c.free(r);
    }
}

pub fn deinit() void {
    g_history.deinit(g_allocator);
    g_history = .empty;
}

/// Push `win` to the front of the history, deduplicating if already present.
/// Called internally whenever g_focused_window changes to a new value.
/// Allocation failures are silently ignored — the history may be shorter than
/// ideal, but focus still functions correctly.
///
/// O(n) single-pass: when `win` is already present, one scan and one in-place
/// memmove (copyBackwards) moves items[0..idx] right by one and writes `win` at
/// index 0, with no allocation.  When absent, falls back to insert(0, …), which
/// may allocate on growth.
fn recordInHistory(win: u32) void {
    if (win == 0) return;
    // Invariant: recordInHistory is always called with the pre-transition window.
    // If this fires, a caller passed the post-transition value instead.
    std.debug.assert(g_focused_window != win);
    // Short-circuit: already the most-recent entry — nothing to do.
    if (g_history.items.len > 0 and g_history.items[0] == win) return;

    if (std.mem.indexOfScalar(u32, g_history.items, win)) |idx| {
        // Rotate [0, idx+1) left by one position:
        //   shift items[0..idx] → items[1..idx+1]  (one copyBackwards)
        //   write win at items[0]
        // This replaces the old remove-then-insert pair (two shifts) with a
        // single in-place shift.  Zero allocations, zero extra scans.
        std.mem.copyBackwards(u32, g_history.items[1 .. idx + 1], g_history.items[0..idx]);
        g_history.items[0] = win;
    } else {
        // Not present — prepend, allocating capacity if necessary.
        g_history.insert(g_allocator, 0, win) catch {};
    }
}

/// Remove `win` from the history (called when a window is unmanaged).
/// Safe to call even if `win` is not present.
pub fn removeFromHistory(win: u32) void {
    const idx = std.mem.indexOfScalar(u32, g_history.items, win) orelse return;
    _ = g_history.orderedRemove(idx);
}

/// Returns a slice of previously focused windows in MRU order.
/// The slice is valid until the next call to any focus mutator.
pub inline fn historyItems() []const u32 {
    return g_history.items;
}

// Public accessors

pub inline fn getFocused()        ?u32                       { return g_focused_window;  }
pub inline fn getSuppressReason() core.FocusSuppressReason   { return g_suppress_reason; }
pub inline fn getLastEventTime()  u32                        { return g_last_event_time; }

/// Raw write to g_focused_window, bypassing all side effects: history recording,
/// grab management, XCB protocol calls, bar/carousel notifications, and
/// _NET_ACTIVE_WINDOW updates.  All of those invariants are the responsibility
/// of commitFocusTransition.  Callers must ensure they maintain every invariant
/// that commitFocusTransition normally enforces.
pub inline fn setFocused(win: ?u32) void    { g_focused_window  = win; }

/// Update the X11 event timestamp used for xcb_set_input_focus and WM_TAKE_FOCUS
/// messages.  See "Timestamp handling" below for why this must be called for
/// EnterNotify events before setFocus(.mouse_enter).
pub inline fn setLastEventTime(t: u32) void { g_last_event_time = t;   }

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
//   2. The WM sends WM_TAKE_FOCUS(win, g_last_event_time).
//      If g_last_event_time is an old button-press timestamp T_old < T_enter,
//      the app (e.g. Discord, Prism Launcher) receives WM_TAKE_FOCUS with T_old
//      and calls XSetInputFocus(internal_widget, T_old).
//   3. X server: T_old < last-focus-change-time (T_enter) → request IGNORED.
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

/// Set the suppress reason and immediately focus `win` as an atomic operation.
///
/// This is the correct API for callers (e.g. the fullscreen-exit path) that
/// need to prime suppression before a programmatic focus change.  The two
/// operations must be paired: if they are split across separate calls, a
/// concurrent setFocus from another path (e.g. a workspace switch) can clear
/// the suppression between the setSuppressReason write and the setFocus call,
/// or — if setFocus returns early via the `g_focused_window == win` guard —
/// suppression is set but focus never changes, leaving it primed permanently.
///
/// Replace the split pattern:
///   focus.setSuppressReason(.window_spawn);  // fragile
///   focus.setFocus(win, .tiling_operation);
/// With the atomic form:
///   focus.setFocusWithSuppression(win, .tiling_operation, .window_spawn);
pub fn setFocusWithSuppression(win: u32, reason: Reason, suppress: core.FocusSuppressReason) void {
    g_suppress_reason = suppress;
    setFocus(win, reason);
}

/// Direct write to g_suppress_reason.
///
/// Prefer setFocusWithSuppression when suppression must be paired with a
/// focus change.  This setter exists for cases where suppression must be
/// cleared or set independently of any focus change — e.g. MotionNotify
/// clearing suppression when real pointer movement is detected.
pub inline fn setSuppressReason(r: core.FocusSuppressReason) void { g_suppress_reason = r; }

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
// All callers pre-compute their flag values from the input model and call
// reason before invoking commitFocusTransition, so the core transition
// function needs no input-model argument.  The reasoning about each flag
// lives at the call site where it is most relevant.
const CommitFlags = struct {
    /// Send xcb_set_input_focus to the new window.
    /// False for handleFocusIn (the application already moved focus) and for
    /// no_input windows (which never receive focus protocol).
    set_input_focus:    bool = false,

    /// Raise the window to the top of the stack.
    /// True for click/command (user-driven), and for globally_active hover
    /// (raising is the only focus signal these windows receive — they never
    /// get xcb_set_input_focus).
    raise:              bool = false,

    /// Send a WM_TAKE_FOCUS ClientMessage after xcb_set_input_focus.
    /// Required for locally_active and globally_active input models.
    send_wm_take_focus: bool = false,

    /// Arm the async focus-confirm cookie for a deferred raise-and-retry.
    /// Used by mouse_enter for passive and locally_active windows that may
    /// silently drop xcb_set_input_focus when not already topmost.
    arm_confirm:        bool = false,

    /// Call bar.scheduleFocusRedraw after the transition.
    /// False only for syncPointerFocusNow, which runs inside a server grab;
    /// its caller is responsible for calling bar.redrawInsideGrab() instead.
    schedule_bar:       bool = false,

    /// New value for g_suppress_reason after the transition.
    /// `setFocus` derives this from reason + current state via suppressionFor();
    /// all direct callers of `commitFocusTransition` hardcode `.none`.
    new_suppress: core.FocusSuppressReason = .none,
};

/// Core focus-transition implementation shared by setFocus, syncPointerFocusNow,
/// dwmFocus, bruteForceMouseEnterFocus, and handleFocusIn.
///
/// All focus paths perform the same logical sequence — record history → update
/// global state → sync button grabs → X protocol requests → notify downstream
/// observers — and differ only in which side effects apply, encoded in `flags`.
///
/// Preconditions (enforced by callers):
///   • `win` is a valid managed window (non-zero, not root, not bar).
///   • `win` != g_focused_window (no-op transitions are filtered upstream).
///   • Any stale confirm cookie has been cancelled or consumed by the caller.
fn commitFocusTransition(old: ?u32, win: u32, flags: CommitFlags) void {
    // Update g_focused_window BEFORE calling recordInHistory so the assertion
    // inside recordInHistory (g_focused_window != old) holds.  The old order
    // called recordInHistory(old) while g_focused_window still equalled old,
    // making old == old fire every time in debug/releaseSafe builds.
    g_focused_window  = win;
    g_suppress_reason = flags.new_suppress;
    if (old) |o| recordInHistory(o);

    window.grabButtons(win, true);
    if (old) |o| window.grabButtons(o, false);

    if (flags.set_input_focus)
        // Always CurrentTime (0): the X server interprets CurrentTime as "now"
        // and bypasses its timestamp-ordering check entirely.  Passing a real
        // event timestamp risks rejection if it predates the server's last
        // focus-change time, and also risks Electron/Qt apps forwarding a stale
        // timestamp back to XSetInputFocus on their internal widget — which the
        // server would then reject, leaving the renderer widget without focus.
        _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            win, 0); // CurrentTime

    if (flags.raise)
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    if (flags.send_wm_take_focus)
        // CurrentTime (0) — same reason as xcb_set_input_focus above.
        utils.sendWMTakeFocus(core.conn, win, 0); // CurrentTime

    if (flags.arm_confirm) {
        g_confirm_cookie = xcb.xcb_get_input_focus(core.conn);
        g_confirm_win    = win;
    }

    if (comptime build_options.has_tiling) tiling.updateWindowFocus(old, win);
    // Notify the carousel immediately so it can free the stale seg-carousel
    // pixmap and record focus-click time before the draw cycle runs.
    carousel.notifyFocusChanged(win);
    if (flags.schedule_bar) bar.scheduleFocusRedraw(win);

    // Advertise the newly focused window on the root so xev -root and any
    // EWMH-aware external tool (compositor scripts, polybar, etc.) can observe it.
    advertiseActiveWindow(win);
}

/// Hover focus with unconditional protocol resend.
///
/// Unlike dwmFocus, this does NOT short-circuit when `win` is already
/// g_focused_window.  Some Electron/Qt builds call XSetInputFocus spontaneously;
/// handleFocusIn accepts that grab (when nothing was focused), setting
/// g_focused_window without sending WM_TAKE_FOCUS, so the renderer widget never
/// activates.  Re-sending the protocol on every hover fixes that case without
/// harm to compliant clients.
///
/// When `win` differs from g_focused_window, delegates to commitFocusTransition
/// for all WM bookkeeping (history, grabs, tiling, bar, _NET_ACTIVE_WINDOW).
/// The X protocol signals — raise, xcb_set_input_focus, WM_TAKE_FOCUS — are
/// then issued unconditionally with CurrentTime (0), bypassing input-model
/// checks entirely.
///
/// Use dwmFocus for the common hover path; reserve this for clients known to
/// silently drop the initial WM_TAKE_FOCUS.
pub fn bruteForceMouseEnterFocus(win: u32) void {
    if (win == 0 or win == core.root) return;
    if (bar.isBarWindow(win)) return;

    cancelPendingConfirm();

    // Update WM bookkeeping only when this is a real focus change.
    // When g_focused_window already == win, skip history/grabs but still
    // re-send the X protocol below — that is the whole point of this path.
    if (g_focused_window != win) {
        const old = g_focused_window;
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
        g_suppress_reason = .none;
    }

    // Always re-send — raise, XSetInputFocus, WM_TAKE_FOCUS — with CurrentTime (0).
    _ = xcb.xcb_configure_window(core.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win, 0);
    utils.sendWMTakeFocus(core.conn, win, 0);
}

pub fn setFocus(win: u32, reason: Reason) void {
    if (win == 0 or win == core.root) return;
    if (g_focused_window == win) return;
    if (bar.isBarWindow(win)) return;

    // For click and command, a destroy race is possible between the user action
    // and this call.  Guard with a live xcb_get_window_attributes round-trip.
    // All other reasons guarantee the window is mapped without asking the server:
    //   mouse_enter        — EnterNotify is only delivered for mapped windows.
    //   window_spawn       — MapNotify was queued on this connection moments ago.
    //   tiling_operation   — window is in the tiling set, populated at map time
    //                        and kept coherent by removeWindow on unmap/destroy.
    //   workspace_switch   — workspace manager only exposes mapped windows.
    if ((reason == .mouse_click or reason == .user_command) and
        !isWindowMapped(core.conn, win)) return;

    const input_model = utils.getInputModelCached(core.conn, win);
    if (input_model == .no_input) return;

    // Cancel any pending focus-confirm from a previous hover before we mutate
    // state.  Without this, a mouse_click on window B while a confirm cookie
    // for window A is still live will cause drainPendingConfirm to raise A and
    // clobber the click-focus on B, because the drain sees "focus = B, expected
    // A → raise A".  Any prior pending confirm is stale the moment we commit to
    // focusing a new window regardless of reason.
    cancelPendingConfirm();

    const old = g_focused_window;
    commitFocusTransition(old, win, .{
        // globally_active windows manage their own input focus.  ICCCM §4.1.7:
        // "The window manager should not call XSetInputFocus for globally active
        // windows."  Sending XSetInputFocus to them delivers an unsolicited FocusIn
        // that some Electron/Chromium builds interpret as a signal to reset their
        // internal focus state machine, causing them to ignore the WM_TAKE_FOCUS
        // that follows.  dwm models this correctly via its neverfocus flag
        // (neverfocus = !wmh->input), which skips XSetInputFocus when input=False,
        // while still calling sendevent(WMTakeFocus).
        //
        // For globally_active windows the only correct signals are:
        //   1. raise the window (so the app knows it is on top)
        //   2. send WM_TAKE_FOCUS (so the app calls XSetInputFocus on itself)
        .set_input_focus    = input_model != .globally_active,
        // Always raise on mouse_enter regardless of input model.
        // When the window is miscached as passive (common for Electron due to the
        // PropertyNotify race), XSetInputFocus silently fails unless the window is
        // already topmost.  Raising upfront makes the initial attempt land correctly
        // for all models, not just globally_active.
        .raise              = shouldRaise(reason) or reason == .mouse_enter,
        // Send WM_TAKE_FOCUS for all focusable windows, not just those cached
        // as locally_active/globally_active.  sendWMTakeFocus performs a live
        // WM_PROTOCOLS check and is a no-op for windows that do not advertise
        // it, so this is always safe.  Sending unconditionally guards against a
        // stale cache: apps that register WM_TAKE_FOCUS after mapping (Electron,
        // Qt) may still be cached as .passive, but still require the message for
        // their internal renderer widget to activate.
        .send_wm_take_focus = input_model != .no_input,
        // Arm the async confirm for all mouse_enter attempts regardless of
        // input model.  Every hover path needs a fallback raise-and-retry in
        // case WM_TAKE_FOCUS is silently dropped by a broken client or the
        // cached model is stale.
        .arm_confirm        = reason == .mouse_enter,
        .schedule_bar       = true,
        .new_suppress       = suppressionFor(reason, g_suppress_reason),
    });
}

/// Drain the deferred focus-confirm reply, if one is pending.
///
/// Must be called from the event-dispatch loop before processing the next
/// event.  In the common case (focus landed, compliant client, window already
/// topmost) this completes in microseconds — the server-side work is already
/// done, we are just collecting the reply that was queued in setFocus.
///
/// If focus did not land on `g_confirm_win`, the window is raised and
/// xcb_set_input_focus is retried.  For locally_active windows, WM_TAKE_FOCUS
/// is also re-sent so the client processes it in the new stacking context.
///
/// Safe to call when no confirm is pending (returns immediately).
pub fn drainPendingConfirm() void {
    const cookie = g_confirm_cookie orelse return;
    // Capture win and clear both fields together before any branching.
    // Draining at the top makes the invariant self-evident: the cookie is
    // consumed exactly once regardless of which exit path is taken.
    const win_opt = g_confirm_win;
    g_confirm_cookie = null;
    g_confirm_win    = null;

    // Reply must be consumed before any return to drain the XCB queue.
    // defer frees the reply on every exit path.
    const focus_reply = xcb.xcb_get_input_focus_reply(core.conn, cookie, null);
    defer if (focus_reply) |r| std.c.free(r);

    // g_confirm_cookie and g_confirm_win are always set and cleared together;
    // a null win here should never happen, but we handle it gracefully.
    const win = win_opt orelse return;

    // Guard against the window being destroyed between the setFocus call that
    // armed the cookie and this drain.  Sending xcb_set_input_focus to a dead
    // XID generates a BadWindow error on the connection.
    if (!window.isValidManagedWindow(win)) return;

    // Re-read the input model: the client may have updated WM_HINTS since the
    // cookie was armed.
    const input_model = utils.getInputModelCached(core.conn, win);
    if (input_model == .no_input) return;

    const c = focus_reply orelse return;

    // Consider focus successfully landed if ANY real window has it (focus > 1).
    // Electron and Qt respond to WM_TAKE_FOCUS by calling XSetInputFocus on an
    // internal child widget, so xcb_get_input_focus returns the child XID —
    // not the managed toplevel.  Checking `== win` alone would always fail for
    // these apps and trigger a raise-and-retry that resets Electron's internal
    // focus state machine.  X11 special values: 0 = None, 1 = PointerRoot.
    // Any value > 1 means a real window has focus; we must not steal it back.
    // Only retry when focus is completely absent (None or PointerRoot).
    if (c.*.focus == win or c.*.focus > 1) return;

    // Retry using CurrentTime (0).  The server's focus-change-time is already
    // "server now" from the earlier xcb_set_input_focus; passing an older real
    // timestamp here would be rejected by the X server's ordering check.
    // No raise — raising generates synthetic FocusOut/FocusIn events that
    // confuse Electron's internal focus state machine.
    _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win, 0); // CurrentTime
    utils.sendWMTakeFocus(core.conn, win, 0); // CurrentTime
}

/// Drain an XCB reply and immediately free it without acting on the contents.
/// Prevents the XCB reply queue from growing unboundedly for spent cookies.
inline fn drainAndFree(reply_fn: anytype, cookie: anytype) void {
    if (reply_fn(core.conn, cookie, null)) |r| std.c.free(r);
}

/// Discard a pending confirm reply without acting on it.
///
/// The XCB reply must always be collected to prevent the reply queue from
/// growing unboundedly, even when we no longer care about the result.
/// Safe to call when no confirm is pending.
fn cancelPendingConfirm() void {
    const cookie = g_confirm_cookie orelse return;
    g_confirm_cookie = null;
    g_confirm_win    = null;
    drainAndFree(xcb.xcb_get_input_focus_reply, cookie);
}

/// Invalidate the cached input model for `win`.
///
/// MUST be called from the PropertyNotify handler whenever `XA_WM_HINTS`
/// changes for a managed window:
///
///   case XA_WM_HINTS:
///       focus.invalidateInputModelCache(ev.window);
///
/// Rationale: Electron (Discord, VS Code, etc.) and Java/Qt apps (Prism
/// Launcher, JetBrains IDEs) routinely update WM_HINTS after their window is
/// already mapped — they create the window with a placeholder WM_HINTS block
/// (often with input=False or no InputHint at all) and then overwrite it with
/// the real value once the application event loop has started.  If
/// getInputModelCached captured the placeholder value and never refreshed it,
/// setFocus would return early at `if (input_model == .no_input)` on every
/// hover attempt, silently discarding all focus for that window.
///
/// dwm handles this correctly by calling updatewmhints(c) from propertynotify:
///
///   case XA_WM_HINTS:
///       updatewmhints(c);   // re-reads wmh->input, resets neverfocus
///
/// This function is the focus.zig equivalent of that re-read.
pub fn invalidateInputModelCache(win: u32) void {
    utils.invalidateInputModelCache(win);
}

/// Send the X protocol focus signals for `win` using CurrentTime (0).
///
/// Skips xcb_set_input_focus for windows whose ICCCM input field is False
/// (.no_input and .globally_active), since sending it to those windows delivers
/// an unsolicited FocusIn that some Electron/Chromium builds use as a signal to
/// reset their internal focus state machine.  WM_TAKE_FOCUS is always sent;
/// sendWMTakeFocus performs a live WM_PROTOCOLS check and is a no-op for
/// windows that do not advertise it.
///
/// Uses CurrentTime (0) throughout so the X server's timestamp-ordering check
/// never rejects the request.  No raise, no confirm/retry machinery.
fn sendFocusProtocol(win: u32) void {
    // Use the cached input model rather than issuing a blocking xcb_get_property
    // round-trip.  Both .no_input and .globally_active have ICCCM input=False,
    // so xcb_set_input_focus must be skipped for both.
    const model = utils.getInputModelCached(core.conn, win);
    if (model == .passive or model == .locally_active) {
        _ = xcb.xcb_set_input_focus(core.conn,
            xcb.XCB_INPUT_FOCUS_POINTER_ROOT, win, 0); // CurrentTime
        advertiseActiveWindow(win);
    }
    // _NET_ACTIVE_WINDOW is intentionally not updated for .globally_active windows:
    // they manage their own input focus and never receive xcb_set_input_focus, so
    // advertising them here could mislead EWMH-aware tools about which window
    // actually holds X focus.
    utils.sendWMTakeFocus(core.conn, win, 0); // CurrentTime
}

/// Hover focus following DWM's focus(c) semantics.
///
/// Returns early when `win` is already focused — re-sending WM_TAKE_FOCUS on
/// every hover over an already-focused Electron window causes it to re-evaluate
/// its internal focus routing continuously, resetting the renderer widget on
/// each mouse movement.
///
/// Does NOT raise the window.  DWM's focus() contains no XRaiseWindow call;
/// raising happens only on click (buttonpress → restack).  Raising on hover
/// generates synthetic FocusOut/FocusIn events that confuse Electron's internal
/// focus state machine.
///
/// Uses CurrentTime (0) for all X protocol calls so the X server's timestamp
/// ordering check never rejects them.  No confirm/retry machinery.
///
/// Contrast with bruteForceMouseEnterFocus, which re-sends the X protocol even
/// when the window is already g_focused_window.  Use that path only when a
/// client is known to silently drop the initial WM_TAKE_FOCUS and needs the
/// resend to activate its internal focus state.
pub fn dwmFocus(win: u32) void {
    if (win == 0 or win == core.root) return;
    if (bar.isBarWindow(win)) return;
    if (g_focused_window == win) return;

    cancelPendingConfirm();

    // Determine the X protocol to send.  .globally_active windows manage their
    // own input focus (ICCCM §4.1.7); xcb_set_input_focus must be skipped for
    // them.  WM_TAKE_FOCUS is sent unconditionally — sendWMTakeFocus performs a
    // live WM_PROTOCOLS check and is a no-op for windows that don't advertise it.
    const model = utils.getInputModelCached(core.conn, win);
    const old   = g_focused_window;
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
/// DWM source (verbatim):
///   /* there are some broken focus acquiring clients needing extra handling */
///   void focusin(XEvent *e) {
///       XFocusChangeEvent *ev = &e->xfocus;
///       if (selmon->sel && ev->window != selmon->sel->win)
///           setfocus(selmon->sel);
///   }
///
/// The previous implementation filtered GRAB/UNGRAB/WHILE_GRABBED modes,
/// NotifyInferior detail, PointerRoot/None detail, and non-managed windows.
/// This caused Electron's internal focus steals (which arrive with various
/// mode/detail combinations) to slip through unchallenged, leaving
/// g_focused_window pointing at a window that had quietly lost focus.
///
/// DWM's approach is simpler and correct: every FocusIn that doesn't match the
/// intended window triggers an immediate re-assertion via sendFocusProtocol, which
/// uses CurrentTime so the X server never rejects it.
pub fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t) void {
    if (g_focused_window) |sel| {
        if (event.event != sel) {
            sendFocusProtocol(sel);
        }
    }
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
///   • Pass workspaces.isOnCurrentWorkspaceAndVisible for the normal post-action
///     re-focus (on current workspace and not minimized).
///   • Pass window.isValidManagedWindow for cleanup contexts where any managed
///     window is acceptable regardless of workspace membership.
///
/// The `on_miss` fallback handles callers that need specialised behaviour when
/// history is exhausted:
///   • Pass null (common case) to call clearFocus() on miss.
///   • Pass minimize.focusMasterOrFirst for post-unmanage recovery, where the
///     tiling master or first workspace window is preferred over an empty focus.
///
/// The explicit `reason` parameter is the one place this diverges intentionally
/// from dwm's single-argument form: dwm cannot distinguish "refocus after close"
/// from "refocus after workspace switch" at the call site, and that distinction
/// drives suppression semantics here.
pub fn focusBestAvailable(
    reason:   Reason,
    visible:  *const fn (u32) bool,
    on_miss:  ?*const fn () void,
) void {
    for (g_history.items) |win| {
        if (visible(win)) {
            setFocus(win, reason);
            return;
        }
    }
    if (on_miss) |f| f() else clearFocus();
}

pub fn clearFocus() void {
    if (g_focused_window) |old_win| {
        window.grabButtons(old_win, false);
        if (comptime build_options.has_tiling) tiling.updateWindowFocus(old_win, null);
    }
    // Any pending confirm is for a window that is about to lose focus anyway;
    // discard it rather than letting drainPendingConfirm raise a window we
    // are intentionally unfocusing.
    cancelPendingConfirm();
    g_focused_window  = null;
    g_suppress_reason = .none;
    _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        core.root, 0); // CurrentTime — bypasses the X server's timestamp ordering check.
    carousel.notifyFocusChanged(null);
    bar.scheduleFocusRedraw(null);

    // Clear _NET_ACTIVE_WINDOW on root to signal no window is focused.
    advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
}

inline fn advertiseActiveWindow(win: u32) void {
    if (g_net_active_window == xcb.XCB_ATOM_NONE) return;
    _ = xcb.xcb_change_property(core.conn, xcb.XCB_PROP_MODE_REPLACE,
        core.root, g_net_active_window, xcb.XCB_ATOM_WINDOW, 32, 1, &win);
}

inline fn shouldRaise(reason: Reason) bool {
    // Note: mouse_enter returns false here but is OR-ed in setFocus as
    // `shouldRaise(reason) or reason == .mouse_enter`.  It is kept separate
    // because the raise is tied to Electron/input-model interaction rather than
    // being a blanket policy; any new reason must check both this switch and
    // that inline condition.
    return switch (reason) {
        .mouse_click, .user_command => true,
        .mouse_enter, .tiling_operation, .window_spawn, .workspace_switch => false,
    };
}

inline fn suppressionFor(reason: Reason, current: core.FocusSuppressReason) core.FocusSuppressReason {
    // Only explicit user-driven actions clear suppression unconditionally.
    // Programmatic focus changes (tiling_operation, workspace_switch, mouse_enter)
    // must preserve any suppression that was set externally — most importantly by
    // the fullscreen-exit path, which calls setFocusWithSuppression to atomically
    // prime suppression before the focus change.
    //
    // Without the `else => current` branch, the sequence:
    //   setFocusWithSuppression(win, .tiling_operation, .window_spawn)
    //     -> g_suppress_reason = .window_spawn
    //     -> setFocus(win, .tiling_operation)
    //       -> suppressionFor(.tiling_operation) returned .none   ← old bug
    //       -> g_suppress_reason clobbered to .none before the EnterNotify arrives
    //       -> spurious EnterNotify is no longer suppressed, focus goes to the wrong
    //          window; or if setFocus hit the g_focused_window == win early-return,
    //          suppression was never cleared and all subsequent hover events are
    //          silently swallowed until the user clicks.
    //
    // Rules:
    //   mouse_click / user_command — explicit user interaction: always clear.
    //   window_spawn               — new window capturing focus: set suppression.
    //   everything else            — programmatic: leave current value unchanged.
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
/// to call bar.redrawInsideGrab() immediately after, which is the only bar
/// update needed.  Skipping scheduleFocusRedraw means the EnterNotify that the
/// X server queued when the swapped window moved under the cursor will arrive
/// post-ungrab, hit the g_focused_window == win early-return in setFocus, and
/// be a complete no-op — one flush total for the entire swap operation.
pub fn syncPointerFocusNow() void {
    // Clear suppression unconditionally at entry — even if no window is under
    // the pointer, the tiling operation that triggered this call has settled
    // and EnterNotify events should no longer be masked afterward.
    g_suppress_reason = .none;
    const cookie = xcb.xcb_query_pointer(core.conn, core.root);
    const reply  = xcb.xcb_query_pointer_reply(core.conn, cookie, null) orelse return;
    defer std.c.free(reply);
    const child = reply.*.child;
    if (child == 0 or child == core.root) return;
    if (!window.isValidManagedWindow(child)) return;
    if (g_focused_window == child) return;

    const input_model = utils.getInputModelCached(core.conn, child);
    if (input_model == .no_input) return;

    cancelPendingConfirm();

    const old = g_focused_window;
    commitFocusTransition(old, child, .{
        .set_input_focus    = true,
        .raise              = false,
        .send_wm_take_focus = true, // input_model != .no_input guaranteed by early-return above
        .arm_confirm        = false,
        // schedule_bar is false — caller must call bar.redrawInsideGrab() instead.
        // This prevents a second async redraw from being queued, ensuring the
        // subsequent EnterNotify is a no-op and there is only one flush.
        .schedule_bar       = false,
        .new_suppress       = .none,
    });
}

/// Fire an async pointer-position query for focus-after-tiling sync.
///
/// Clears suppression immediately (so subsequent EnterNotify events are no
/// longer masked) and queues xcb_query_pointer without blocking.  The reply
/// is handled by drainPointerSync(), called from the event-dispatch loop.
///
/// Split from the original syncFocusToPointer to remove the blocking reply
/// from the tiling hot path.  Callers that previously called
/// syncFocusToPointer() should call beginPointerSync() at the same site, and
/// ensure drainPointerSync() is called from the event-dispatch loop.
pub fn beginPointerSync() void {
    g_suppress_reason = .none;
    // If a previous query is still pending, discard it non-blockingly rather
    // than draining the reply synchronously.  xcb_discard_reply instructs XCB
    // to silently drop the reply when it arrives; it never blocks.  Draining
    // synchronously here would re-introduce the latency this async split was
    // designed to remove, particularly when tiling operations fire in rapid
    // succession before the event loop can catch up.
    if (g_pointer_cookie) |stale| {
        xcb.xcb_discard_reply(core.conn, stale.sequence);
    }
    g_pointer_cookie = xcb.xcb_query_pointer(core.conn, core.root);
}

/// Drain the deferred pointer-position reply and route focus to whichever
/// managed window is currently under the pointer.
///
/// Called from the event-dispatch loop.  Safe to call when no query is pending.
pub fn drainPointerSync() void {
    const cookie = g_pointer_cookie orelse return;
    g_pointer_cookie = null;
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
