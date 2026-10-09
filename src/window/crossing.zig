//! Enter/LeaveNotify handling: hover focus and crossing suppression.
//!
//! Split out of window.zig, which re-exports the two handlers as the event
//! dispatch surface events.zig's table binds. The focus protocol itself
//! (prepare/apply, suppression state) stays in protocol/focus.zig.

const core = @import("core");
const xcb = core.xcb;
const focus = @import("focus");
const query = @import("query");
const pipeline = @import("pipeline");

const actions = @import("actions");
const window = @import("window");
const registry = @import("registry");

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    // The spawn snapshot (focus.spawnCursor()) is taken by
    // handleMapRequest
    // when the spawn's MapRequest arrives. Mapping a new window under the
    // stationary cursor produces a PAIR of synthetic crossings, both carrying
    // the spawn's root coordinates: the enter into the spawned window, and the
    // return crossing into the window it displaced (which, when the spawned
    // window immediately parks offscreen, is the previous focus). A one-shot
    // guard only drops the first, letting the return crossing re-steal focus
    // from the just-spawned window via mouse_enter.
    //
    // Keep the guard armed while crossings stay at the spawn pixel: only a
    // genuine pointer move (different coordinates) is a real hover and may
    // clear it. A cursor parked where it was when the app launched can't hover
    // a different window at that same pixel until it moves, which is the
    // acceptable price for not stealing focus during the spawn's layout.
    const cursor = focus.spawnCursor();
    if (root_x == cursor.x and root_y == cursor.y) return true;
    focus.setSuppressReason(.none);
    return false;
}

/// Shared guard tail for the EnterNotify/LeaveNotify handlers, run after each
/// handler's event-shape filter (mode/detail/root): a floating drag owns the
/// pointer, and a spawn's synthetic crossing (the window mapping under the
/// parked cursor) must be suppressed. Returns true when the crossing should
/// be dropped.
inline fn crossingShouldDrop(root_x: i16, root_y: i16) bool {
    if (actions.isDragging()) return true;
    return suppressSpawnCrossing(root_x, root_y);
}

/// Attempt to focus `win` via the hover (EnterNotify) path.
///
/// Guards against workspace membership and hidden state before calling
/// focus.grabFocus(.mouse_enter). The .mouse_enter reason is the direct
/// EnterNotify path: lightweight, no raise, no confirm.
inline fn maybeFocusWindow(win: u32) void {
    // In all-view mode every window is visible on the current workspace
    // regardless of its tag mask, so hover must be able to focus it too; a
    // bare membership check made all-view windows un-focusable by ENTER.
    if (!query.isOnCurrentWorkspace(win) and !pipeline.model().all_view_active) return;
    if (registry.callHookBool(.isWindowHidden, .{ pipeline.model(), win })) return;
    focus.grabFocus(win, .mouse_enter);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_INFERIOR)
        return;
    if (crossingShouldDrop(event.root_x, event.root_y)) return;
    if (focus.shouldSuppressEnterNotify()) return;
    maybeFocusWindow(window.findManagedWindow(core.getState().conn, event.event, query.isManaged));
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.getState().root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (crossingShouldDrop(event.root_x, event.root_y)) return;
    // When child is zero the pointer left to an area not covered by any window.
    if (event.child == 0) return;
    // Guard against unmanaged subwindows (e.g. embedded GTK widgets): a root
    // LeaveNotify with non-zero child doesn't guarantee a managed toplevel.
    // Walk up to the managed toplevel, consistent with handleEnterNotify's
    // findManagedWindow.
    maybeFocusWindow(window.findManagedWindow(core.getState().conn, event.child, query.isManaged));
}
