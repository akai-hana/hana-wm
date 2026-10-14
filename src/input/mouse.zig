//! Mouse intake: button and motion events, press classification,
//! and routing to the floating drag engine. Split out of input.zig
//! (review 05-input, Phase 6): the press-classification and
//! motion-routing halves -- the mouse gesture state machine -- are a
//! distinct concern from key dispatch. Every symbol is re-exported by
//! input.zig, so the events.zig dispatch table, main.setup, and the
//! input tests keep their single unchanged surface.

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const constants = @import("constants");
const masks = @import("masks");
const log = @import("log");
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const keybind = @import("keybind");
const build_options = @import("build_options");
const actions = @import("actions");
const grabs = @import("grabs");
const surfaces = @import("surfaces").Surfaces;
// The action dispatcher and its scaffold graft live in
// dispatch.zig (split out of input.zig): mouse binds dispatch
// through dispatch without importing input.zig -- which
// re-exports this module's handlers -- breaking the
// input <-> mouse import cycle.
const dispatch = @import("dispatch");

/// Dispatches a priority-ordered button-press event, splitting the two named
/// paths: a plain click on the bar window routes to the bar; every other
/// press goes through the managed-window mouse machinery.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);
    const super_held = (event.state & masks.mod_super) != 0;
    const clicked_window = if (event.child != 0) event.child else event.event;
    // The bar path: a plain (non-Super) click whose target is the bar window.
    // The bar selects BUTTON_PRESS directly rather than through the
    // Super+Button grab, so a plain click arrives ungrabbed; route it to the bar
    // and skip the managed-window/replay-pointer machinery built for the
    // synchronous grab a client-window click goes through. Super-held clicks
    // fall through to the normal mouse-binding/drag path. Previously two
    // wrappers stood between this and the surfaces hook, for one call site.
    if (!super_held and surfaces.isBarWindow(clicked_window)) {
        surfaces.handleButtonPress(event);
        return;
    }
    handleWindowButtonPress(event, super_held, clicked_window);
}

/// The facts a button press is routed on, taken as FIELDS so the routing rule
/// is a pure function of them: the dispatch below cannot be exercised without
/// an X server and a live grab, but this can.
pub const MousePress = struct {
    /// Super was held, i.e. the press came through the root grab rather than
    /// being delivered to a client.
    super_held: bool,
    button: u8,
    /// The press landed on a managed, non-root window.
    target_managed: bool,
    /// A config mouse bind matched and has ALREADY been dispatched (which
    /// released the grab as part of dispatching). Set by the caller, in the
    /// order `classifyMousePress` documents, because the lookup needs the live
    /// config and the managed-window id.
    bind_fired: bool,
};

/// What a press should do, and -- the part that used to be implicit -- what
/// happens to the grab afterwards. Every arm of the dispatch below is one of
/// these, and the dispatch is exhaustive with no `else`, so a new arm that
/// forgets to settle the grab is a compile error rather than a frozen
/// keyboard and pointer.
pub const MouseIntent = union(enum) {
    /// Super+scroll: a viewport bind, or a plain release when unbound. Checked
    /// before the managed-window guard because scroll binds do not target a
    /// window, so they must still fire over the desktop and the bar.
    scroll_bind,
    /// The press landed on the root or an unmanaged window.
    unmanaged,
    /// Plain click on a managed window: focus it.
    focus_click,
    /// A config mouse bind already ran; the grab was released with it.
    bound_action,
    /// Super+left/right with no bind: start a drag and keep the grab.
    start_drag,
    /// Super+any other button, unbound: replay as a plain click, which is what
    /// thaws both devices. Omitting it is how a grab silently freezes input.
    replay,
};

/// The mouse routing rule, as a pure function.
///
/// The ORDER here is the whole contract, and it is why this is worth pinning:
/// scroll binds precede the managed-window guard; focus precedes the bind
/// lookup; the drag and the replay fallback are both "Super and unbound", and
/// only the button number tells them apart.
pub fn classifyMousePress(p: MousePress) MouseIntent {
    if (p.super_held and
        (p.button == constants.mouse_button_scroll_up or p.button == constants.mouse_button_scroll_down))
    {
        // A fired scroll bind reports the SAME intent as any other fired bind,
        // so every intent has exactly one grab outcome and a path cannot
        // release twice (or, once the discipline is trusted, not at all).
        return if (p.bind_fired) .bound_action else .scroll_bind;
    }
    if (!p.target_managed) return .unmanaged;
    if (!p.super_held) return .focus_click;
    if (p.bind_fired) return .bound_action;
    if (p.button == constants.mouse_button_left or p.button == constants.mouse_button_right)
        return .start_drag;
    return .replay;
}

/// The managed-window path: scroll-wheel binds, focus, config mouse-bind
/// lookup, drag, and the unbound-Super replay fallback.
fn handleWindowButtonPress(event: *const xcb.xcb_button_press_event_t, super_held: bool, clicked_window: u32) void {
    const cs = core.getState();
    const mods = masks.toMask(masks.normalizeModifiers(event.state));

    const managed_window = window.findManagedWindow(cs.conn, clicked_window, tracking.isManaged);
    const target_managed = clicked_window != cs.root and managed_window != 0;

    // A scroll bind is looked up FIRST, with window 0, because it does not
    // target a window and must fire over the desktop and the bar too; every
    // other bind targets the clicked window, which is not known to be managed
    // until the lookup above has run. `classifyMousePress` documents the order.
    const scroll_bind = super_held and (event.detail == constants.mouse_button_scroll_up or
        event.detail == constants.mouse_button_scroll_down);
    const bind_fired = if (scroll_bind)
        tryConfigMouseBind(mods, event.detail, 0, event.time)
    else if (target_managed and super_held)
        tryConfigMouseBind(mods, event.detail, managed_window, event.time)
    else
        false;

    const intent = classifyMousePress(.{
        .super_held = super_held,
        .button = event.detail,
        .target_managed = target_managed,
        .bind_fired = bind_fired,
    });

    // Exhaustive, no `else`: an arm that forgets to settle the grab, or a new
    // intent, stops the build.
    switch (intent) {
        .scroll_bind, .unmanaged, .replay => releaseGrab(event.time),
        .focus_click => {
            focus.grabFocus(managed_window, .mouse_click);
            releaseGrab(event.time);
        },
        // The bind dispatch already released the grab.
        .bound_action => {},
        .start_drag => {
            if (build_options.has_floating) actions.startDrag(managed_window, event.detail, event.root_x, event.root_y);
            keepDragGrab(event.time);
        },
    }
}

/// Stops any active drag and updates the last event timestamp.
pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    // Releases on the bar window terminate a segment scrub (the bar clears
    // its drag anchor). Routed before the managed-window path, as clicks are.
    if (surfaces.isBarWindow(event.event)) {
        surfaces.handleButtonRelease(event);
        return;
    }
    if (build_options.has_floating and actions.isDragging()) actions.stopDrag();
}

/// Forwards motion to the drag engine and clears focus suppression.
/// Raw PointerMotion is coalesced upstream (events.handleXcbEvents collapses
/// runs to the last event), so this runs at most once per poll wakeup.
pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t) void {
    focus.setLastEventTime(event.time);

    // Press-hold motion on the bar window feeds the scrub-drag path: it is
    // routed before the managed-window drag engine, which targets a client
    // window grab, never the bar.
    if (surfaces.isBarWindow(event.event)) {
        surfaces.handleButtonMotion(event);
        return;
    }

    if (build_options.has_floating and actions.isDragging()) {
        actions.updateDrag(event.root_x, event.root_y);
        return;
    }

    focus.setSuppressReason(.none);
}

/// Warns about every `[binds]` mouse entry the root grab can never deliver.
///
/// This is the worst failure mode a config surface has: the bind parses, the
/// config loads, `configChanged` sees no change, the user presses the combo
/// and the click simply goes to the client. Nothing anywhere else reports it.
/// De-duplicated by the (modifiers, button) pair, so a dead combo bound three
/// times is reported once, and the message names the binding's index in config
/// order so it can be found.
pub fn reportUndeliverableMouseBinds() void {
    const binds = core.getState().config.mouse_bindings.items;
    // The grab as `setupGrabs` actually makes it, handed to the pure rule so
    // that rule needs no knowledge of the X layer and stays unit-testable.
    const grab: keybind.MouseGrabSpec = .{
        .buttons = &grabs.mouse_grab_buttons,
        .modifiers = masks.mod_super,
        .lock_bits = masks.lock_bits,
    };
    for (binds, 0..) |mb, i| {
        const reason = keybind.undeliverableMouseBindReason(mb, grab) orelse continue;
        var dup = false;
        for (binds[0..i]) |earlier| {
            if (earlier.button == mb.button and earlier.modifiers == mb.modifiers) dup = true;
        }
        if (dup) continue;
        log.warn(
            "Mouse binding #{} (mods=0x{x:0>4} button={}) can never fire: {s}",
            .{ i + 1, mb.modifiers, mb.button, reason },
        );
    }
}

/// Last entry in `binds` matching (mods, button), or null.
///
/// The scan deliberately does NOT stop at the first match: the last entry wins,
/// and every entry it shadows is reported through the same reporter the
/// keyboard table uses. Taking the first match instead made one config mistake
/// a warning on a key and silence on a button, and made the winner depend on
/// file order in one path but not the other.
///
/// Pure over the slice (the only side effect is the warning) so the policy is
/// testable without a live core state.
pub fn findMouseBind(
    binds: []const types.MouseBind,
    mods: u16,
    button: u8,
) ?*const types.MouseBind {
    var found: ?*const types.MouseBind = null;
    for (binds, 0..) |*mb, i| {
        if (mb.modifiers != mods or mb.button != button) continue;
        if (found != null) keybind.logShadowConflict("Mouse binding", i, mods, "button", button);
        found = mb;
    }
    return found;
}

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, ts: u32) bool {
    // Linear scan is intentional: mouse bindings are few (~5-10), hash overhead not worth it.
    const mb = findMouseBind(core.getState().config.mouse_bindings.items, mods, button) orelse
        return false;

    // Most mouse binds execute against the keyboard-focused window
    // (executeAction); toggle_floating_window is inherently per-window
    // and so targets the CLICKED window instead.
    switch (mb.action) {
        .toggle_floating_window => dispatch.grafted(.toggle_floating_window, actions.toggleFloating, win),
        else => dispatch.executeAction(&mb.action),
    }
    releaseGrab(ts);
    return true;
}

/// Shared tail for releasing grab sequences. The two callers differ only in
/// the pointer mode: REPLAY_POINTER (release the grab, let the click through)
/// vs ASYNC_POINTER (keep the grab for drag tracking).
inline fn finishGrab(ts: u32, pointer_mode: c_uint) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, pointer_mode, ts);
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, ts);
    _ = xcb.xcb_flush(conn);
}

/// Releases both SYNC grabs acquired on Super+click, replaying the pointer so
/// the click reaches the app underneath. Only safe for click paths that don't
/// need to keep tracking the pointer afterward; NOT for drag start; use
/// keepDragGrab. Always pass event.time, never XCB_CURRENT_TIME.
inline fn releaseGrab(ts: u32) void {
    finishGrab(ts, xcb.XCB_ALLOW_REPLAY_POINTER);
}

/// Un-freezes the pointer for a drag while keeping the Super+Button grab
/// engaged: AsyncPointer resumes delivery without replaying or ending the
/// grab, so MotionNotify/ButtonRelease keep reaching us. The grab ends on
/// release; the keyboard grab drops immediately. Always pass event.time.
inline fn keepDragGrab(ts: u32) void {
    finishGrab(ts, xcb.XCB_ALLOW_ASYNC_POINTER);
}
