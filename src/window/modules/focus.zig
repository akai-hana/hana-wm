//! Focus management — set, clear, and reason-aware focus routing.

const std    = @import("std");
const core = @import("core");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const utils  = @import("utils");
const bar      = @import("bar");
const window   = @import("window");
const carousel = @import("carousel");
const xcb      = core.xcb;

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

// Lifecycle 

pub fn init(allocator: std.mem.Allocator) void {
    g_allocator = allocator;
    g_history   = .empty;
}

pub fn deinit() void {
    g_history.deinit(g_allocator);
    g_history = .empty;
}

/// Push `win` to the front of the history, deduplicating if already present.
/// Called internally whenever g_focused_window changes to a new value.
/// Allocation failures are silently ignored — the history may be shorter than
/// ideal, but focus still functions correctly.
fn recordInHistory(win: u32) void {
    if (win == 0) return;
    // Short-circuit: if win is already the most-recent entry there is nothing
    // to do — skip the O(n) scan+shift pair entirely.
    if (g_history.items.len > 0 and g_history.items[0] == win) return;
    // Remove any existing entry so each window appears exactly once.
    removeFromHistory(win);
    // Prepend: insert at index 0, shifting everything else right.
    g_history.insert(g_allocator, 0, win) catch {};
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

pub inline fn getFocused()        ?u32                       { return g_focused_window; }
pub inline fn getSuppressReason() core.FocusSuppressReason   { return g_suppress_reason; }
pub inline fn getLastEventTime()  u32                        { return g_last_event_time; }

pub inline fn setFocused(win: ?u32) void                         { g_focused_window  = win; }
pub inline fn setSuppressReason(r: core.FocusSuppressReason) void { g_suppress_reason = r; }
pub inline fn setLastEventTime(t: u32) void                      { g_last_event_time = t; }

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

    const old = g_focused_window;
    if (old) |old_win| recordInHistory(old_win);
    g_focused_window = win;
    g_suppress_reason = suppressionFor(reason, g_suppress_reason);

    window.grabButtons(win, true);
    if (old) |old_win| window.grabButtons(old_win, false);

    _ = xcb.xcb_set_input_focus(
        core.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        win,
        g_last_event_time,
    );

    // Raise on click/command, and also on hover for globally_active windows
    // (they never receive xcb_set_input_focus, so raising is the only signal).
    if (shouldRaise(reason) or (reason == .mouse_enter and input_model == .globally_active)) {
        _ = xcb.xcb_configure_window(
            core.conn, win,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
        );
    }

    if (input_model == .locally_active or input_model == .globally_active) {
        utils.sendWMTakeFocus(core.conn, win, g_last_event_time);
    }

    // Compliant locally_active clients respond to xcb_set_input_focus directly
    // and need no raise. Non-compliant ones (e.g. Electron, which mis-declares
    // its input model) silently ignore the request unless they are already
    // topmost. Passive clients (Java/AWT, some Electron builds that omit
    // WM_TAKE_FOCUS) have the same problem — xcb_set_input_focus is silently
    // dropped when the window is not topmost.
    //
    // Confirm via xcb_get_input_focus: if focus didn't land, raise and retry.
    // The blocking reply also acts as a flush barrier, ensuring the original
    // xcb_set_input_focus request has been processed before we check.
    //
    // This avoids unconditionally raising all passive/locally_active windows on
    // hover while still self-correcting for any non-compliant client regardless
    // of toolkit, class name, or property advertisement.
    //
    // For locally_active windows (e.g. Qt), WM_TAKE_FOCUS is the real focus
    // activation trigger.  The client processes it asynchronously — potentially
    // after our confirm check has already passed — and may redirect input focus
    // to a child widget.  Re-sending WM_TAKE_FOCUS after the raise ensures the
    // client processes it in the correct stacking context.
    if (reason == .mouse_enter and
        (input_model == .locally_active or input_model == .passive))
    {
        const confirm_cookie = xcb.xcb_get_input_focus(core.conn);
        const confirm = xcb.xcb_get_input_focus_reply(core.conn, confirm_cookie, null);
        if (confirm) |c| {
            defer std.c.free(c);
            if (c.*.focus != win) {
                _ = xcb.xcb_configure_window(
                    core.conn, win,
                    xcb.XCB_CONFIG_WINDOW_STACK_MODE,
                    &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
                );
                _ = xcb.xcb_set_input_focus(
                    core.conn,
                    xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
                    win,
                    g_last_event_time,
                );
                // Re-send WM_TAKE_FOCUS after the raise so locally_active
                // clients (e.g. Qt) process it in the correct stacking context.
                // Not sent for passive windows — they have no WM_TAKE_FOCUS
                // handler and xcb_set_input_focus alone is the correct protocol.
                if (input_model == .locally_active) {
                    utils.sendWMTakeFocus(core.conn, win, g_last_event_time);
                }
            }
        }
    }

    if (comptime build_options.has_tiling) tiling.updateWindowFocus(old, win);
    // Notify the carousel immediately so it can free the stale seg-carousel
    // pixmap and record focus-click time before the draw cycle runs.
    carousel.notifyFocusChanged(win);
    bar.scheduleFocusRedraw(win);
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
    if (event.mode == xcb.XCB_NOTIFY_MODE_GRAB or
        event.mode == xcb.XCB_NOTIFY_MODE_UNGRAB) return;
    // NotifyWhileGrabbed: focus change during an active grab — skip to avoid
    // spurious updates during drag or key-grab sequences.
    if (event.mode == xcb.XCB_NOTIFY_MODE_WHILE_GRABBED) return;
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

    const old = g_focused_window;
    if (old) |old_win| recordInHistory(old_win);
    g_focused_window = win;
    if (comptime build_options.has_tiling) tiling.updateWindowFocus(old, win);
    carousel.notifyFocusChanged(win);
    bar.scheduleFocusRedraw(win);
}

pub fn clearFocus() void {
    if (g_focused_window) |old_win| {
        window.grabButtons(old_win, false);
        if (comptime build_options.has_tiling) tiling.updateWindowFocus(old_win, null);
    }
    g_focused_window = null;
    g_suppress_reason = .none;
    _ = xcb.xcb_set_input_focus(
        core.conn,
        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
        core.root,
        g_last_event_time,
    );
    carousel.notifyFocusChanged(null);
    bar.scheduleFocusRedraw(null);
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
    // the fullscreen-exit path, which calls setSuppressReason directly before
    // calling setFocus(.tiling_operation).
    //
    // Without this, the sequence:
    //   setSuppressReason(.window_spawn)        ← fullscreen exit
    //   setFocus(win, .tiling_operation)         ← restores focus
    //     → suppressionFor(.tiling_operation) returned .none
    //     → g_suppress_reason clobbered to .none before the EnterNotify arrives
    //     → spurious EnterNotify is no longer suppressed, focus goes to the wrong
    //       window; or if setFocus hit the g_focused_window == win early-return,
    //       suppression was never cleared and all subsequent hover events are
    //       silently swallowed until the user clicks.
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

/// After a tiling operation that repositions windows, sync WM focus state to
/// whichever managed window is currently under the pointer.  This prevents the
/// `.tiling_operation` suppression from persisting indefinitely when there is no
/// active pointer grab to deliver MotionNotify events that would normally clear it.
pub fn syncFocusToPointer() void {
    const reply = xcb.xcb_query_pointer_reply(
        core.conn, xcb.xcb_query_pointer(core.conn, core.root), null,
    ) orelse {
        g_suppress_reason = .none;
        return;
    };
    defer std.c.free(reply);

    const child = reply.*.child;
    if (child == 0 or child == core.root or !window.isValidManagedWindow(child)) {
        g_suppress_reason = .none;
        return;
    }

    // Use .mouse_enter so the window is not raised, just focused.
    // If g_focused_window already equals child, setFocus returns early —
    // that's fine, we just need the suppression cleared below.
    setFocus(child, .mouse_enter);
    g_suppress_reason = .none; // clear regardless of whether setFocus short-circuited
}

fn isWindowMapped(conn: *xcb.xcb_connection_t, win: u32) bool {
    const reply = xcb.xcb_get_window_attributes_reply(
        conn, xcb.xcb_get_window_attributes(conn, win), null,
    ) orelse return false;
    defer std.c.free(reply);
    return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
}
