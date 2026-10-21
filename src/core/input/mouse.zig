//! Mouse intake: button and motion events, press classification, and routing
//! to the floating drag engine -- a distinct concern from key dispatch. The
//! event loop dispatches straight here (no facade); config mouse binds reach
//! the action interpreter through `dispatch`, the one dependency between them.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const masks = @import("masks");
const log = std.log.scoped(.mouse);
const window = @import("window");
const query = @import("query");
const focus = @import("focus");
const surfaces = @import("surfaces").Surfaces;
// Bind compilation, the conflict reporter, and the root-grab spec live together
// in keybinds.zig; mouse reads all three.
const keybinds = @import("keybinds");
// The action dispatcher; mouse binds dispatch through it. The alias keeps the
// call sites' `dispatch.*` spelling, and because dispatch does NOT import this
// file the two can never cycle.
const dispatch = @import("dispatch");

/// Dispatches a priority-ordered button-press event, splitting the two named
/// paths: a plain click on the bar window routes to the bar; every other
/// press goes through the managed-window mouse machinery.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);
    const super_held = (event.state & masks.mod_super) != 0;
    const clicked_window = if (event.child != 0) event.child else event.event;
    // The bar path: a plain (non-Super) click whose target is the bar window.
    // The bar selects BUTTON_PRESS directly rather than through the Super+Button
    // grab, so a plain click arrives ungrabbed; route it to the bar and skip
    // the managed-window/replay-pointer machinery built for the synchronous grab
    // a client-window click goes through.
    if (!super_held and surfaces.isBarWindow(clicked_window)) {
        surfaces.handleButtonPress(event);
        return;
    }
    handleWindowButtonPress(event, super_held, clicked_window);
}

/// The facts a button press is routed on, as FIELDS so the routing rule is a
/// pure function of them: the dispatch below cannot be exercised without an X
/// server and a live grab, but this can.
pub const MousePress = struct {
    /// Super was held: the press came through the root grab, not a client.
    super_held: bool,
    button: u8,
    /// The press landed on a managed, non-root window.
    target_managed: bool,
    /// A config mouse bind matched and ALREADY dispatched (which released the
    /// grab). Set by the caller, in the order `classifyMousePress` documents,
    /// because the lookup needs the live config and the managed-window id.
    bind_fired: bool,
};

/// What a press should do, and what happens to the grab afterwards. Every arm
/// of the dispatch below is one of these; it is exhaustive with no `else`, so an
/// arm that forgets to settle the grab is a compile error rather than a frozen
/// keyboard and pointer.
pub const MouseIntent = union(enum) {
    /// Super+scroll: a viewport bind, or a plain release when unbound. Checked
    /// before the managed-window guard because scroll binds do not target a
    /// window and must fire over the desktop and bar too.
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
    /// thaws both devices. Omitting this is how a grab freezes input.
    replay,
};

/// The mouse routing rule, as a pure function.
///
/// The ORDER here is the whole contract: scroll binds precede the managed-window
/// guard; focus precedes the bind lookup; drag and the replay fallback are both
/// "Super and unbound", and only the button number tells them apart.
inline fn isScrollButton(button: u8) bool {
    return button == masks.mouse_button_scroll_up or button == masks.mouse_button_scroll_down;
}

pub fn classifyMousePress(p: MousePress) MouseIntent {
    if (p.super_held and isScrollButton(p.button)) {
        // A fired scroll bind reports the SAME intent as any other fired bind, so
        // every intent has exactly one grab outcome and no path can release twice.
        return if (p.bind_fired) .bound_action else .scroll_bind;
    }
    if (!p.target_managed) return .unmanaged;
    if (!p.super_held) return .focus_click;
    if (p.bind_fired) return .bound_action;
    if (p.button == masks.mouse_button_left or p.button == masks.mouse_button_right)
        return .start_drag;
    return .replay;
}

/// The managed-window path: scroll-wheel binds, focus, config mouse-bind lookup,
/// drag, and the unbound-Super replay fallback.
fn handleWindowButtonPress(event: *const xcb.xcb_button_press_event_t, super_held: bool, clicked_window: u32) void {
    const cs = core.getState();
    const mods = masks.toMask(masks.normalizeModifiers(event.state));

    const managed_window = window.findManagedWindow(cs.conn, clicked_window, query.isManaged);
    const target_managed = clicked_window != cs.root and managed_window != 0;

    // A scroll bind is looked up FIRST, with window 0, because it does not target a
    // window and must fire over the desktop and bar too; every other bind targets
    // the clicked window, unknown-until-managed above.
    const scroll_bind = super_held and isScrollButton(event.detail);
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

    // Exhaustive, no `else`: an arm that forgets to settle the grab stops the build.
    switch (intent) {
        .scroll_bind, .unmanaged, .replay => releaseGrab(event.time),
        .focus_click => {
            focus.grabFocus(managed_window, .mouse_click);
            releaseGrab(event.time);
        },
        // The bind dispatch already released the grab.
        .bound_action => {},
        .start_drag => {
            window.drag.dispatchAll(.startDrag, .{ managed_window, event.detail, event.root_x, event.root_y });
            keepDragGrab(event.time);
        },
    }
}

/// Stops any active drag and updates the last event timestamp.
pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    // An active floating drag owns release even when the cursor is over the bar:
    // a release landing on the bar must still stop the drag, or the state latches
    // and later un-pressed motions keep moving the window via updateDrag. Route to
    // the bar only when no drag is in flight.
    if (window.drag.dispatchFirstTrue(.isDragging, .{})) {
        window.drag.dispatchAll(.stopDrag, .{});
        return;
    }
    // Releases on the bar window terminate a segment scrub (the bar clears
    // its drag anchor). Routed before the managed-window path, as clicks are.
    if (surfaces.isBarWindow(event.event)) {
        surfaces.handleButtonRelease(event);
        return;
    }
}

/// Forwards motion to the drag engine and clears focus suppression. Raw
/// PointerMotion is coalesced upstream (events.handleXcbEvents collapses runs to the
/// last event), so this runs at most once per poll wakeup.
pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t) void {
    focus.setLastEventTime(event.time);

    // An active floating drag owns motion even when the cursor crosses the bar:
    // routing to the bar first would freeze updateDrag and feed spurious scrub
    // motion. Shift-held at the motion event frees a resize from the aspect-ratio
    // band (ratio-lock escape hatch); the drag engine ignores it for move drags.
    if (window.drag.dispatchFirstTrue(.isDragging, .{})) {
        const break_aspect = (event.state & masks.mod_shift) != 0;
        window.drag.dispatchAll(.updateDrag, .{ event.root_x, event.root_y, break_aspect });
        return;
    }

    // Press-hold motion on the bar window feeds the scrub-drag path: it is
    // routed before the managed-window drag engine, which targets a client
    // window grab, never the bar.
    if (surfaces.isBarWindow(event.event)) {
        surfaces.handleButtonMotion(event);
        return;
    }

    focus.setSuppressReason(.none);
}

/// Warns about every `[binds]` mouse entry the root grab can never deliver -- the worst
/// failure mode a config surface has (the bind loads, the key does nothing). Nothing
/// elsewhere reports it. De-duplicated by (modifiers, button); the message names the
/// binding's index in config order.
pub fn reportUndeliverableMouseBinds() void {
    const binds = core.getState().config.core.mouse_bindings.items;
    // The grab as `keybinds.grabMouseButtons` actually makes it, handed to the
    // pure rule so it stays unit-testable without X knowledge.
    const grab: keybinds.MouseGrabSpec = .{
        .buttons = &keybinds.mouse_grab_buttons,
        .modifiers = masks.mod_super,
        .lock_bits = masks.lock_bits,
    };
    for (binds, 0..) |mb, i| {
        const reason = keybinds.undeliverableMouseBindReason(mb, grab) orelse continue;
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

/// Result of a mouse-bind scan: the last matching entry (or null) plus the
/// number of shadowed entries recorded, when a buffer was provided.
const ScanResult = struct {
    bind: ?*const types.MouseBind,
    shadowed_len: usize,
};

/// The one conflict scan shared by the dispatch path and the test-facing collecting
/// variant. The scan does NOT stop at the first match: the last entry wins, and every
/// entry it shadows is reported through the same reporter the keyboard table uses.
/// `shadowed_out` non-null collects the 0-based indices of every match that loses to a
/// later one (caller-owned fixed buffer; truncates past capacity). Null keeps
/// production behavior: each shadowed entry goes through the shared conflict logger.
fn scanMouseBind(
    binds: []const types.MouseBind,
    mods: u16,
    button: u8,
    shadowed_out: ?[]usize,
) ScanResult {
    var found: ?*const types.MouseBind = null;
    var shadowed_len: usize = 0;
    for (binds, 0..) |*mb, i| {
        if (mb.modifiers != mods or mb.button != button) continue;
        if (found != null) {
            if (shadowed_out) |out| {
                if (shadowed_len < out.len) {
                    out[shadowed_len] = i;
                    shadowed_len += 1;
                }
            } else {
                keybinds.logShadowConflict("Mouse binding", i, mods, "button", button);
            }
        }
        found = mb;
    }
    return .{ .bind = found, .shadowed_len = shadowed_len };
}

/// Last match wins, logging each shadowed entry. The dispatch path.
pub fn findMouseBind(
    binds: []const types.MouseBind,
    mods: u16,
    button: u8,
) ?*const types.MouseBind {
    return scanMouseBind(binds, mods, button, null).bind;
}

/// Same scan, but returns the shadowed entries as indices into `binds` instead of
/// logging, so a test can assert the conflict policy on real data.
pub fn findMouseBindShadowed(
    binds: []const types.MouseBind,
    mods: u16,
    button: u8,
    shadowed_out: []usize,
) ScanResult {
    return scanMouseBind(binds, mods, button, shadowed_out);
}

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, ts: u32) bool {
    // Linear scan is intentional: mouse bindings are few (~5-10), hash overhead not worth it.
    const mb = findMouseBind(core.getState().config.core.mouse_bindings.items, mods, button) orelse
        return false;

    // Most mouse binds execute against the keyboard-focused window
    // (executeAction); toggle_floating_window is per-window and targets the
    // CLICKED window instead. A scroll bind carries no clicked window (win==0),
    // so fall back to the keyboard-focused window rather than dispatching
    // against id 0 (a silent no-op).
    switch (mb.action) {
        .toggle_floating_window => {
            const target = if (win != 0) win else focus.getFocused() orelse return true;
            dispatch.grafted(.toggle_floating_window, dispatch.toggleFloatingWindow, target);
        },
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
/// need to keep tracking the pointer afterward; NOT for drag start -- use
/// keepDragGrab. Always pass event.time, never XCB_CURRENT_TIME.
inline fn releaseGrab(ts: u32) void {
    finishGrab(ts, xcb.XCB_ALLOW_REPLAY_POINTER);
}

/// Un-freezes the pointer for a drag while keeping the Super+Button grab
/// engaged: AsyncPointer resumes delivery without replaying or ending the grab,
/// so MotionNotify/ButtonRelease keep reaching us. The grab ends on release; the
/// keyboard grab drops immediately. Always pass event.time.
inline fn keepDragGrab(ts: u32) void {
    finishGrab(ts, xcb.XCB_ALLOW_ASYNC_POINTER);
}
