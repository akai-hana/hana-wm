//! User input handling
//! Handles keyboard, mouse buttons, pointer motion, and drag operations.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const utils = @import("utils");
const constants = @import("constants");
const x11_masks = @import("x11_masks");
const debug = @import("debug");
const config = @import("config");
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const fullscreen = @import("fullscreen");
const minimize = @import("minimize");
const workspaces = @import("workspaces");
const xkbcommon = @import("xkbcommon");
const build_options = @import("build_options");
const pipeline = @import("pipeline");
const actions = @import("actions");
const spawn = @import("spawn");
const bar = if (build_options.has_bar) @import("bar") else null;
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const floating = if (build_options.has_floating) @import("floating") else null;

// Constants

const mouse_button_middle: u8 = 2;
const mouse_button_scroll_up: u8 = 4;
const mouse_button_scroll_down: u8 = 5;

const mouse_buttons = [_]u8{
    constants.mouse_button_left, mouse_button_middle,      constants.mouse_button_right,
    mouse_button_scroll_up,      mouse_button_scroll_down,
};

// Named adapter functions for tiling actions that need argument forwarding.

// XKB state

var xkb_state: ?xkbcommon.XkbState = null;

/// Initialises the XKB context, keymap, and key state
/// from the server's current keyboard configuration.
pub fn initXkb(conn: core.Connection) !void {
    xkb_state = try xkbcommon.XkbState.init(conn);
}

/// Tears down XKB state. Must be called after all other deinit steps.
pub fn deinitXkb() void {
    if (xkb_state) |*s| s.deinit();
    xkb_state = null;
}

/// Returns a pointer to the module-owned XkbState,
/// used by events.zig during config reloads.
///
/// The returned pointer is invalidated by deinitXkb/initXkb (e.g. during a
/// config reload); callers must not cache it across those calls.
pub fn getXkbState() *xkbcommon.XkbState {
    return &xkb_state.?;
}

/// Rebuilds the keymap/keysym table after the server changes the keyboard
/// mapping (setxkbmap/xmodmap). Keybinding resolution is keysym-indexed, so
/// rebuilding the flat keycode->keysym table keeps existing bindings working
/// under the new layout.
pub fn handleMappingNotify() void {
    const cs = core.getState();
    if (xkb_state) |*s| s.rebuild(cs.conn);
}

// Grab setup

/// Grabs mouse buttons on the root window and applies the user's cursor theme.
pub fn setup(conn: core.Connection, screen: core.Screen, root: u32) void {
    setupGrabs(conn, root);
    XcbCursor.setupRoot(conn, screen);
}

/// Grabs Super+Button{1,2,3,4,5} (including the scroll buttons) on the root
/// window for all lock_modifiers combinations (NumLock, CapsLock,
/// ScrollLock, and their combinations).
fn setupGrabs(conn: core.Connection, root: u32) void {
    for (mouse_buttons) |button| {
        for (x11_masks.lock_modifiers) |lock| {
            _ = xcb.xcb_grab_button(
                conn,
                0,
                root,
                xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                    xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
                    xcb.XCB_EVENT_MASK_POINTER_MOTION,
                xcb.XCB_GRAB_MODE_SYNC,
                xcb.XCB_GRAB_MODE_SYNC,
                root,
                xcb.XCB_NONE,
                button,
                @intCast(x11_masks.mod_super | lock),
            );
        }
    }
    _ = xcb.xcb_flush(conn);
}

// Event handlers

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void {
    focus.setLastEventTime(event.time);

    const state = xkb_state orelse {
        debug.warn("[KEY] keypress before XKB init; ignoring", .{});
        return;
    };

    const mods = utils.normalizeModifiers(event.state);
    const keysym = state.keycodeToKeysym(event.detail);

    // O(1) dispatch via the (modifiers << 32 | keysym) map built by
    // config.resolveKeybindings.
    const matched: ?*const types.Action = config.lookupKeybinding(mods, keysym);

    // The prompt owns all key input while active; routing is handled inside it.
    if (build_options.has_bar) if (bar.promptHandleKeypress(event, matched)) return;

    if (matched) |action| {
        debug.info("[KEY] mods=0x{x} keysym=0x{x} action={s}", .{ mods, keysym, @tagName(action.*) });
        executeAction(action);
    } else if (mods == 0 and keysym >= 0xffe1 and keysym <= 0xffee) {
        // Bare modifier press (Shift/Ctrl/Alt/Super/Hyper L/R): can never
        // match a binding; staying silent keeps logs free of keystroke noise.
    } else {
        debug.info("[KEY] mods=0x{x} keysym=0x{x} no binding", .{ mods, keysym });
    }
}

/// Dispatches a priority-ordered button-press event.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);

    const cs = core.getState();
    const clicked_window = if (event.child != 0) event.child else event.event;
    const super_held = (event.state & x11_masks.mod_super) != 0;
    const mods = utils.normalizeModifiers(event.state);

    // The bar selects BUTTON_PRESS directly (not via the Super+Button grab),
    // so a plain click arrives ungrabbed; route it to the bar and skip the
    // managed-window/replay-pointer machinery built for the synchronous grab
    // a client-window click goes through. Super-held clicks fall through to
    // the normal mouse-binding/drag path.
    if (!super_held and build_options.has_bar and bar.isBarWindow(clicked_window)) {
        bar.handleButtonPress(event);
        return;
    }

    // Scroll-wheel binds (buttons 4/5) are viewport actions that don't target
    // a specific window, so they're checked before the managed-window guard
    // that would otherwise discard events fired over the desktop/bar.
    if (super_held and (event.detail == mouse_button_scroll_up or event.detail == mouse_button_scroll_down)) {
        if (!tryConfigMouseBind(mods, event.detail, 0, event.time))
            replayPointer(event.time);
        return;
    }

    const managed_window = window.findManagedWindow(cs.conn, clicked_window, tracking.isManaged);
    if (clicked_window == 0 or clicked_window == cs.root or managed_window == 0) {
        replayPointer(event.time);
        return;
    }

    if (!super_held) {
        focus.grabFocus(managed_window, .mouse_click);
        releaseGrab(event.time);
        return;
    }

    if (tryConfigMouseBind(mods, event.detail, managed_window, event.time)) return;

    if (event.detail == constants.mouse_button_left or event.detail == constants.mouse_button_right) {
        if (build_options.has_floating) floating.startDrag(managed_window, event.detail, event.root_x, event.root_y);
        keepDragGrab(event.time);
        return;
    }
}

/// Stops any active drag and updates the last event timestamp.
pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    if (build_options.has_floating and floating.isDragging()) floating.stopDrag();
}

/// Forwards motion to the drag engine and clears focus suppression.
/// Raw PointerMotion is coalesced upstream (events.handleXcbEvents collapses
/// runs to the last event), so this runs at most once per poll wakeup.
pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t) void {
    focus.setLastEventTime(event.time);

    if (build_options.has_floating and floating.isDragging()) {
        floating.updateDrag(event.root_x, event.root_y);
        return;
    }

    if (focus.getSuppressReason() != .none) focus.setSuppressReason(.none);
}

// Window operations

/// Sends a WM_DELETE_WINDOW client message per ICCCM §4.1.2.7.
fn sendWmDelete(conn: core.Connection, win: u32, protos_atom: u32, del_atom: u32) void {
    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = win;
    event.type = protos_atom;
    event.data.data32[0] = del_atom;
    event.data.data32[1] = focus.getLastEventTime(); // ICCCM §4.1.7

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

/// Force-destroys a window unconditionally via xcb_destroy_window.
fn forceDestroy(conn: core.Connection, win: u32) void {
    _ = xcb.xcb_destroy_window(conn, win);
}

/// Closes a window gracefully via WM_DELETE_WINDOW (ICCCM §4.1.2.7), falling
/// back to xcb_destroy_window for clients that don't advertise the protocol.
fn closeWindow(win: u32) void {
    const conn = core.getState().conn;
    if (!window.supportsWMDeleteCached(conn, win)) {
        forceDestroy(conn, win);
        return;
    }

    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return forceDestroy(conn, win);
    const delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch return forceDestroy(conn, win);

    sendWmDelete(conn, win, protocols_atom, delete_atom);
}

// Action dispatch

/// Shared trap for an action tag that reached a dispatcher class that does
/// not handle it. Config validation rejects unknown mappings long before
/// dispatch, so this documents an internal dispatch-table gap rather than
/// bad user input; the tagged message makes the culprit class obvious in a
/// crash log (consolidated from per-switch `unreachable`s).
noinline fn unhandledAction(class: []const u8) noreturn {
    std.debug.panic("{s} action dispatcher received an unhandled action", .{class});
}

/// Top-level action dispatcher. Routes each action tag to the appropriate
/// domain helper. Errors are handled internally.
fn executeAction(action: *const types.Action) void {
    switch (action.*) {
        // Core
        .close_window => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => utils.reload(),
        .dump_state => dumpState(),
        .exec => |cmd| spawn.executeShellCommand(cmd) catch |err| debug.err("exec failed: {}", .{err}),
        .sequence => |acts| for (acts) |*a| executeAction(a),

        // Fullscreen: keybind path resolves the focused window, then shares
        // the EWMH/title-click transition.
        .toggle_fullscreen => {
            if (pipeline.model().focused) |win| actions.fullscreenToggleWindow(win);
        },

        // Tiling, delegated to executeTilingAction
        .toggle_floating_window,
        .toggle_layout,
        .toggle_layout_reverse,
        .cycle_layout_variants,
        .increase_master,
        .decrease_master,
        .increase_master_count,
        .decrease_master_count,
        .grow_stack_top,
        .grow_stack_bottom,
        .swap_master,
        .swap_master_focus_swap,
        .move_window_next,
        .move_window_prev,
        .scroll_view_left,
        .scroll_view_right,
        => executeTilingAction(action),

        // Bar, delegated to executeBarAction
        .toggle_bar_visibility,
        .toggle_bar_position,
        .toggle_prompt,
        => executeBarAction(action),

        // Minimize, delegated to executeMinimizeAction
        .minimize_window,
        .unminimize_lifo,
        .unminimize_fifo,
        .unminimize_all,
        => executeMinimizeAction(action),

        // Workspaces, delegated to executeWorkspaceAction
        .switch_workspace,
        .move_to_workspace,
        .toggle_tag,
        .all_workspaces,
        .move_to_all_workspaces,
        .toggle_tag_all,
        => executeWorkspaceAction(action),

        // Window focus, delegated to executeWindowAction
        .focus_next_window,
        .focus_prev_window,
        => executeWindowAction(action),
    }
}

/// Dispatches tiling-related actions, each wrapped in a server grab so the
/// compositor cannot render a partial retile frame.
fn executeTilingAction(action: *const types.Action) void {
    switch (action.*) {
        .toggle_floating_window => if (focus.getFocused()) |win| {
            focus.setSuppressReason(.tiling_operation);
            actions.toggleFloating(win);
            focus.beginTilingOpSettle();
        },
        .toggle_layout => {
            focus.setSuppressReason(.tiling_operation);
            actions.cycleLayoutKind(1);
            focus.beginTilingOpSettle();
        },
        .toggle_layout_reverse => {
            focus.setSuppressReason(.tiling_operation);
            actions.cycleLayoutKind(-1);
            focus.beginTilingOpSettle();
        },
        .cycle_layout_variants => {
            focus.setSuppressReason(.tiling_operation);
            actions.stepVariantDir(1);
            focus.beginTilingOpSettle();
        },
        .increase_master => actions.adjustMasterWidthAction(0.025),
        .decrease_master => actions.adjustMasterWidthAction(-0.025),
        .increase_master_count => actions.adjustMasterCount(1),
        .decrease_master_count => actions.adjustMasterCount(-1),
        .grow_stack_top => actions.adjustStackBalance(0.5),
        .grow_stack_bottom => actions.adjustStackBalance(-0.5),

        .swap_master, .swap_master_focus_swap => actions.swapMasterAction(action.* == .swap_master_focus_swap),

        .move_window_next => actions.moveFocused(1),
        .move_window_prev => actions.moveFocused(-1),

        .scroll_view_left => actions.scrollStep(-1),
        .scroll_view_right => actions.scrollStep(1),

        else => unhandledAction("tiling"),
    }
}

/// Dispatches workspace-related actions. workspaces.zig self-gates to a
/// single implicit workspace when core.getState().config.workspaces.enabled
/// is false, so these calls are always valid regardless of that setting.
fn executeWorkspaceAction(action: *const types.Action) void {
    switch (action.*) {
        .switch_workspace => |ws| actions.switchTo(ws),
        .move_to_workspace => |ws| if (focus.getFocused()) |wid| actions.moveWindowTo(wid, ws),
        .toggle_tag => |ws| if (focus.getFocused()) |wid| actions.tagToggle(wid, ws, true),
        .all_workspaces => actions.allViewToggle(),
        .move_to_all_workspaces, .toggle_tag_all => if (focus.getFocused()) |wid| actions.pinToggle(wid),
        else => unhandledAction("workspace"),
    }
}

/// Dispatches bar-related actions: visibility toggle, position toggle,
/// and prompt toggle.
fn executeBarAction(action: *const types.Action) void {
    switch (action.*) {
        .toggle_bar_visibility => if (build_options.has_bar) bar.setBarState(.toggle),
        .toggle_bar_position => if (build_options.has_bar) bar.toggleBarSegmentAnchor(),
        .toggle_prompt => if (build_options.has_bar) bar.promptToggle(),
        else => unhandledAction("bar"),
    }
}

/// Dispatches minimize-related actions: minimize, unminimize (LIFO/FIFO),
/// and restore all.
fn executeMinimizeAction(action: *const types.Action) void {
    switch (action.*) {
        .minimize_window => actions.minimize(focus.getFocused()),
        .unminimize_lifo => actions.restoreOrdered(.lifo),
        .unminimize_fifo => actions.restoreOrdered(.fifo),
        .unminimize_all => actions.restoreAll(),
        else => unhandledAction("minimize"),
    }
}

/// Dispatches window focus cycling (dwm-style Mod+k / Mod+j).
/// Snaps the scroll-layout viewport to the newly focused window when
/// it is off-screen. The server grab prevents a partial retile frame.
fn executeWindowAction(action: *const types.Action) void {
    switch (action.*) {
        .focus_next_window => {
            focus.focusNext();
            actions.snapScrollToFocused();
        },
        .focus_prev_window => {
            focus.focusPrev();
            actions.snapScrollToFocused();
        },
        else => unhandledAction("window"),
    }
}

/// Like executeAction but acts on the clicked window rather than the
/// keyboard-focused one, so e.g. toggle_floating_window affects what was clicked.
fn executeMouseAction(action: *const types.Action, clicked_win: u32) void {
    switch (action.*) {
        .toggle_floating_window => {
            focus.setSuppressReason(.tiling_operation);
            actions.toggleFloating(clicked_win);
            focus.beginTilingOpSettle();
        },
        else => executeAction(action),
    }
}

// Diagnostics

/// Logs a full WM state snapshot at info level. Used for diagnostics only.
fn dumpState() void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused:        {?x}", .{focus.getFocused()});
    debug.info("Total windows:  {}", .{tracking.windowCount()});
    debug.info("Suppress focus: {s}", .{@tagName(focus.getSuppressReason())});

    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces, 0..) |_, i|
            debug.info("  WS{}: {} windows", .{ i + 1, tracking.countWindowsOnWorkspace(core.WorkspaceId.fromIndex(@intCast(i))) });
    }

    if (build_options.has_tiling and tiling.isEnabled()) {
        debug.info("Tiling enabled: true", .{});
        debug.info("Tiling layout:  {s}", .{@tagName(tiling.getCurrentLayout())});
        debug.info("Tiled windows:  {}", .{tracking.tiledCountOnCurrent()});
    }

    debug.info("================================", .{});
}

// Helpers

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, time: u32) bool {
    for (core.getState().config.mouse_bindings.items) |*mb| {
        if (mb.modifiers == mods and mb.button == button) {
            executeMouseAction(&mb.action, win);
            releaseGrab(time);
            return true;
        }
    }
    return false;
}

/// Runs `op` inside an xcb server grab, then sweeps borders, redraws the
/// Replays a frozen pointer event without releasing the keyboard grab.
/// Always pass event.time, never XCB_CURRENT_TIME.
inline fn replayPointer(time: u32) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_flush(conn);
}

/// Shared tail for releasing grab sequences. The two callers differ only in
/// the pointer mode: REPLAY_POINTER (release the grab, let the click through)
/// vs ASYNC_POINTER (keep the grab for drag tracking).
inline fn finishGrab(time: u32, pointer_mode: c_uint) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, pointer_mode, time);
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, time);
    _ = xcb.xcb_flush(conn);
}

/// Releases both SYNC grabs acquired on Super+click, replaying the pointer so
/// the click reaches the app underneath. Only safe for click paths that don't
/// need to keep tracking the pointer afterward; NOT for drag start; use
/// keepDragGrab. Always pass event.time, never XCB_CURRENT_TIME.
inline fn releaseGrab(time: u32) void {
    finishGrab(time, xcb.XCB_ALLOW_REPLAY_POINTER);
}

/// Un-freezes the pointer for a drag while keeping the Super+Button grab
/// engaged: AsyncPointer resumes delivery without replaying or ending the
/// grab, so MotionNotify/ButtonRelease keep reaching us. The grab ends on
/// release; the keyboard grab drops immediately. Always pass event.time.
inline fn keepDragGrab(time: u32) void {
    finishGrab(time, xcb.XCB_ALLOW_ASYNC_POINTER);
}

// XcbCursor, declared manually because xcb_cursor_load_cursor is a static
// inline function cImport cannot bind.

const XcbCursor = struct {
    const Context = opaque {};

    extern fn xcb_cursor_context_new(
        conn: core.Connection,
        screen: *xcb.xcb_screen_t,
        ctx: *?*Context,
    ) c_int;
    extern fn xcb_cursor_load_cursor(ctx: *Context, name: [*:0]const u8) u32;
    extern fn xcb_cursor_context_free(ctx: ?*Context) void;

    /// Applies the user's cursor theme to the root window. Falls back silently
    /// if xcb-cursor is unavailable or the cursor cannot be loaded.
    fn setupRoot(conn: core.Connection, screen: core.Screen) void {
        var cursor_ctx: ?*Context = null;
        if (xcb_cursor_context_new(conn, screen, &cursor_ctx) < 0) return;
        defer xcb_cursor_context_free(cursor_ctx);

        const cursor = xcb_cursor_load_cursor(cursor_ctx.?, "left_ptr");
        if (cursor == xcb.XCB_NONE) return;

        const cookie = xcb.xcb_change_window_attributes_checked(
            conn,
            screen.*.root,
            xcb.XCB_CW_CURSOR,
            &[_]u32{cursor},
        );
        if (xcb.xcb_request_check(conn, cookie)) |err| {
            debug.err("Failed to set root cursor: error_code={}", .{err.*.error_code});
            std.c.free(err);
        }

        // The server reference-counts cursors; freeing our handle is safe;
        // it stays alive as long as the root window holds a reference.
        _ = xcb.xcb_free_cursor(conn, cursor);
    }
};
