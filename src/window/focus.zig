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

var g_focused_window:  ?u32                     = null;
var g_suppress_reason: core.FocusSuppressReason = .none;
var g_last_event_time: u32                      = 0;

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

var g_history:   std.ArrayListUnmanaged(u32) = .empty;
var g_allocator: std.mem.Allocator           = undefined;

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
// Improvement #2: typed as ?u32 so "no pending confirm" is expressed with null
// rather than a sentinel value.  g_confirm_cookie and g_confirm_win are always
// set and cleared together; the optionality of both is now consistent.
var g_confirm_win:    ?u32                              = null;

var g_pointer_cookie: ?xcb.xcb_query_pointer_cookie_t = null;

// Lifecycle

pub fn init(allocator: std.mem.Allocator) void {
    // Improvement #1: reset every module global explicitly so that a
    // deinit() + init() cycle (test harness, session restart) starts from a
    // clean slate.  The linker zero-inits them on first load, but subsequent
    // reinits would otherwise inherit stale state from the previous session.
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
/// Implementation note: single-pass O(n).
///
/// The original code called removeFromHistory (scan + orderedRemove, which
/// shifts the tail left) followed by insert(0, …) (which shifts the whole
/// slice right again) — two linear scans and two memmoves.
///
/// When `win` is already in the list, we can do the same logical operation
/// with one scan and one memmove: locate the index, shift items[0..idx] one
/// position to the right with copyBackwards, then write `win` at index 0.
/// No allocation is needed because the list length is unchanged.
///
/// When `win` is absent, we still fall back to insert(0, …), which may
/// allocate on growth — same as before.
fn recordInHistory(win: u32) void {
    if (win == 0) return;
    // Improvement #15: assert the invariant that g_focused_window is never in
    // the history.  recordInHistory is always called with the *previous* focused
    // window (old_win), captured before g_focused_window is overwritten.  If
    // this fires, a caller has passed the post-transition value instead.
    std.debug.assert(g_focused_window != @as(?u32, win));
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

pub inline fn setFocused(win: ?u32) void    { g_focused_window  = win; }
pub inline fn setLastEventTime(t: u32) void { g_last_event_time = t;   }

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
    /// setFocus computes this via suppressionFor(); all other callers use .none.
    new_suppress: core.FocusSuppressReason = .none,
};

/// Core focus-transition implementation shared by setFocus, syncPointerFocusNow,
/// and handleFocusIn.
///
/// Improvement #3: all three focus paths perform the same logical sequence —
///   record history → update global state → sync button grabs →
///   X protocol requests → notify downstream observers
///
/// They differ only in which side effects apply, encoded in `flags`.  Pulling
/// the shared body into one function eliminates the three-way duplication,
/// ensuring all paths remain in sync as protocol handling evolves.
///
/// Preconditions (enforced by callers):
///   • `win` is a valid managed window (non-zero, not root, not bar).
///   • `win` != g_focused_window (no-op transitions are filtered upstream).
///   • Any stale confirm cookie has been cancelled or consumed by the caller.
fn commitFocusTransition(old: ?u32, win: u32, flags: CommitFlags) void {
    if (old) |o| recordInHistory(o);
    g_focused_window  = win;
    g_suppress_reason = flags.new_suppress;

    window.grabButtons(win, true);
    if (old) |o| window.grabButtons(o, false);

    if (flags.set_input_focus)
        _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            win, g_last_event_time);

    if (flags.raise)
        _ = xcb.xcb_configure_window(core.conn, win,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    if (flags.send_wm_take_focus)
        utils.sendWMTakeFocus(core.conn, win, g_last_event_time);

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

pub fn setFocus(win: u32, reason: Reason) void {
    if (win == 0 or win == core.root) return;
    if (g_focused_window == win) return;
    if (bar.isBarWindow(win)) return;

    // Skip the blocking xcb_get_window_attributes round-trip when we can
    // guarantee the window is mapped without asking the server:
    //
    //  mouse_enter / mouse_leave — only delivered for mapped windows.
    //  window_spawn              — map was queued on this connection moments ago.
    //  tiling_operation          — window is in the tiling tracking set, which is
    //                              populated at map time and kept coherent by
    //                              removeWindow on unmap/destroy.
    //
    // For all other reasons (click, command) a race with destroy is possible,
    // so we guard with a live attribute query.
    const input_model = utils.getInputModelCached(core.conn, win);
    if (input_model == .no_input) return;

    if (switch (reason) {
        .mouse_click, .user_command => !isWindowMapped(core.conn, win),
        .mouse_enter, .window_spawn, .tiling_operation, .workspace_switch => false,
    }) return;

    // Cancel any pending focus-confirm from a previous hover before we mutate
    // state.  Without this, a mouse_click on window B while a confirm cookie
    // for window A is still live will cause drainPendingConfirm to raise A and
    // clobber the click-focus on B, because the drain sees "focus = B, expected
    // A → raise A".  Any prior pending confirm is stale the moment we commit to
    // focusing a new window regardless of reason.
    cancelPendingConfirm();

    const old = g_focused_window;
    commitFocusTransition(old, win, .{
        .set_input_focus    = true,
        // Raise on click/command, and also on hover for globally_active windows
        // (they never receive xcb_set_input_focus, so raising is the only signal).
        .raise              = shouldRaise(reason) or
                              (reason == .mouse_enter and input_model == .globally_active),
        .send_wm_take_focus = input_model == .locally_active or input_model == .globally_active,
        // Arm the async confirm only for mouse_enter on passive/locally_active windows.
        //
        // Compliant locally_active clients respond to xcb_set_input_focus directly.
        // Non-compliant ones (e.g. Electron, which mis-declares its input model)
        // silently ignore the request unless they are already topmost.  Passive
        // clients (Java/AWT, some Electron builds that omit WM_TAKE_FOCUS) have the
        // same problem.  The confirm arms a deferred raise-and-retry: we fire
        // xcb_get_input_focus now; drainPendingConfirm() checks the result on the
        // next event-loop iteration and raises+retries if focus did not land.
        // If a FocusIn for `win` arrives first, handleFocusIn cancels the cookie.
        //
        // globally_active is excluded: it never receives xcb_set_input_focus so
        // raising is the only signal — already covered by the .raise flag above.
        .arm_confirm        = reason == .mouse_enter and
                              (input_model == .locally_active or input_model == .passive),
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
    // g_confirm_cookie and g_confirm_win are always set together via arm_confirm.
    // If win is somehow null here, drain the reply to prevent queue growth
    // and bail without attempting the raise-and-retry.
    const win = g_confirm_win orelse {
        if (xcb.xcb_get_input_focus_reply(core.conn, cookie, null)) |r| std.c.free(r);
        return;
    };
    g_confirm_cookie = null;
    g_confirm_win    = null;

    // Improvement #4: guard against the window being destroyed between the
    // setFocus call that armed the cookie and this drain.  Sending
    // xcb_configure_window / xcb_set_input_focus to a dead XID would generate
    // a BadWindow error on the connection.  Drain the reply regardless to
    // prevent XCB queue growth, but skip the raise-and-retry.
    if (!window.isValidManagedWindow(win)) {
        if (xcb.xcb_get_input_focus_reply(core.conn, cookie, null)) |r| std.c.free(r);
        return;
    }

    // Re-read the input model: the client may have updated its WM_HINTS
    // between the setFocus call and this drain.
    const input_model = utils.getInputModelCached(core.conn, win);

    const confirm = xcb.xcb_get_input_focus_reply(core.conn, cookie, null);
    if (confirm) |c| {
        defer std.c.free(c);
        if (c.*.focus != win) {
            _ = xcb.xcb_configure_window(core.conn, win,
                xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
            _ = xcb.xcb_set_input_focus(core.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
                win, g_last_event_time);
            // Re-send WM_TAKE_FOCUS after the raise so locally_active clients
            // (e.g. Qt) process it in the correct stacking context.
            // Not sent for passive windows — they have no WM_TAKE_FOCUS handler
            // and xcb_set_input_focus alone is the correct protocol.
            if (input_model == .locally_active) {
                utils.sendWMTakeFocus(core.conn, win, g_last_event_time);
            }
        }
    }
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
    // Collect and discard — we only care about freeing the queued reply.
    if (xcb.xcb_get_input_focus_reply(core.conn, cookie, null)) |r| std.c.free(r);
}

/// Called when the X server reports a FocusIn on a managed window.
///
/// When a window focuses itself (e.g. an app received a replayed click and
/// handled focus internally), the WM is never told via setFocus, so
/// g_focused_window stays stale.  A stale g_focused_window causes the
/// `getFocused() == win` guard in maybeFocusWindow to fire spuriously,
/// silently blocking all subsequent hover-focus attempts.
///
/// Syncing here keeps WM state consistent with the actual X focus so that
/// hover focus works correctly after any application-driven focus change.
///
/// NotifyGrab / NotifyUngrab are skipped — they are transient and do not
/// represent a real focus change (e.g. WM grabbing the server, key grabs).
pub fn handleFocusIn(event: *const xcb.xcb_focus_in_event_t) void {
    // Skip transient modes: GRAB/UNGRAB are server-initiated, WHILE_GRABBED
    // is a focus change during an active grab — none represent a real user focus event.
    if (event.mode == xcb.XCB_NOTIFY_MODE_GRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_WHILE_GRABBED) return;
    // NotifyInferior: a child of this window received focus; the managed
    // top-level did not change focus itself.  We only track top-level granularity.
    if (event.detail == xcb.XCB_NOTIFY_DETAIL_INFERIOR) return;
    // NotifyPointerRoot / NotifyNone: focus moved to no real window.
    if (event.detail == xcb.XCB_NOTIFY_DETAIL_POINTER_ROOT or
        event.detail == xcb.XCB_NOTIFY_DETAIL_NONE) return;

    const win = event.event;
    if (win == 0 or win == core.root) return;
    if (bar.isBarWindow(win)) return;
    if (!window.isValidManagedWindow(win)) return;
    if (g_focused_window == win) return;

    // If the pending confirm was waiting to see whether focus landed on
    // g_confirm_win, this FocusIn is our answer: it did.  Cancel the reply
    // so drainPendingConfirm does not perform a redundant raise-and-retry.
    if (g_confirm_win) |cw| { if (cw == win) cancelPendingConfirm(); }

    const old = g_focused_window;

    // Improvement #5: clear suppression on application-driven focus changes.
    // If any suppression (e.g. window_spawn) was active when the application
    // called XSetInputFocus itself, leaving g_suppress_reason unchanged would
    // cause every subsequent EnterNotify to be silently swallowed until the
    // next explicit user click or command — hover-focus appears broken with no
    // diagnostic.  App-driven focus is semantically equivalent to user
    // interaction from the WM's perspective, so suppression must be cleared.
    commitFocusTransition(old, win, .{
        .set_input_focus    = false, // application already moved focus; do not redirect it
        .raise              = false,
        .send_wm_take_focus = false,
        .arm_confirm        = false,
        .schedule_bar       = true,
        .new_suppress       = .none,
    });
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
        core.root, g_last_event_time);
    carousel.notifyFocusChanged(null);
    bar.scheduleFocusRedraw(null);

    // Clear _NET_ACTIVE_WINDOW on root to signal no window is focused.
    advertiseActiveWindow(xcb.XCB_WINDOW_NONE);
}

// Improvement #7: parameter changed from xcb.xcb_window_t to u32, matching
// every other window-ID parameter in this file.  xcb_window_t is a u32
// typedef; this is a transparent change that removes the type inconsistency.
inline fn advertiseActiveWindow(win: u32) void {
    if (g_net_active_window == xcb.XCB_ATOM_NONE) return;
    var val = win;
    _ = xcb.xcb_change_property(core.conn, xcb.XCB_PROP_MODE_REPLACE,
        core.root, g_net_active_window, xcb.XCB_ATOM_WINDOW, 32, 1, &val);
}

inline fn shouldRaise(reason: Reason) bool {
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
    // Improvement #6: the previous duplicate assignment of g_suppress_reason
    // inside the transition body is gone; this single entry-point clear is
    // the authoritative reset; CommitFlags.new_suppress = .none below is
    // consistent with it.
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
        .send_wm_take_focus = input_model == .locally_active or input_model == .globally_active,
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
    // Discard any stale query before issuing a fresh one.  This prevents
    // stale replies from accumulating if tiling operations fire faster than
    // the event loop can drain them.
    if (g_pointer_cookie) |stale| {
        if (xcb.xcb_query_pointer_reply(core.conn, stale, null)) |r| std.c.free(r);
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
    if (child != 0 and child != core.root and window.isValidManagedWindow(child))
        setFocus(child, .mouse_enter);
}

fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn, xcb.xcb_get_window_attributes(conn, win), null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}
