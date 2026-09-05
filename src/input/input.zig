//! User input handling
//! Handles keyboard, mouse buttons, pointer motion, and drag operations.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const utils = @import("utils");
const restart = @import("restart");
const constants = @import("constants");
const masks = @import("masks");
const debug = @import("debug");
const config = @import("config");
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const xkbcommon = @import("xkbcommon");
const build_options = @import("build_options");
const pipeline = @import("pipeline");
const actions = @import("actions");
const spawn = @import("spawn");
// Layout-name resolution for diagnostics (registry-driven; gated so a
// tiling-less build still compiles).
const tiling = if (build_options.has_tiling) @import("tiling") else struct {};
// The bar's hook set is reached through the core-owned `surfaces` composition
// root, never by importing the bar module here. When the bar is absent it is
// the comptime `null` type, so every `if (build_options.has_bar)` call below
// compiles away.
const surfaces = @import("plugins").Surfaces;
// `grabKeybindings` lives in the event layer (it owns the X connection and
// reads the live config). events.zig also imports this module, so the two
// share a mutual runtime-only dependency; no comptime cycle is formed because
// both references are plain runtime function calls.
const events = @import("events");
// Floating drag commands are reached through actions (single command layer),
// not by naming the floating module here, keeping the loop layer free of
// the optional module import. The drag state (model-backed) is queried via
// the same action wrappers.

// Constants

const mouse_button_middle: u8 = 2;
const mouse_button_scroll_up: u8 = 4;
const mouse_button_scroll_down: u8 = 5;

const mouse_buttons = [_]u8{
    constants.mouse_button_left, mouse_button_middle,      constants.mouse_button_right,
    mouse_button_scroll_up,      mouse_button_scroll_down,
};

// XKB state

var xkb_state: ?xkbcommon.XkbState = null;

// Held binding-key ledger. A passive grab returns a bound key's KeyRelease to
// the grabbing window only if the mask selects it; handleKeyRelease removes
// the keycode stamped on the originating press, letting a later press of the
// same key be recognized as a genuine new gesture rather than an autorepeat.
//
// The ledger is keyed on the raw KEYCODE only, not mods|keycode. Keying on the
// full (mods,keycode) combo poisons an entry when a user lifts the modifier
// before the bound key: the release's modifier state then differs from the
// press's, so clearKeyHeld never matches and keyHeld suppresses every later
// press of that binding (e.g. the kill/close_window key silently dies after
// opening and closing a few windows). A keycode is stable across a gesture
// regardless of modifier release order, so it both suppresses autorepeat and
// always clears on release.
const held_key_capacity = 32;
var held_keys: [held_key_capacity]u8 = undefined;
var held_key_count: usize = 0;

fn keyHeld(keycode: u8) bool {
    for (held_keys[0..held_key_count]) |kc| if (kc == keycode) return true;
    return false;
}

fn setKeyHeld(keycode: u8) void {
    if (held_key_count == held_keys.len) return; // saturate; releases still clear
    held_keys[held_key_count] = keycode;
    held_key_count += 1;
}

fn clearKeyHeld(keycode: u8) void {
    var i: usize = 0;
    while (i < held_key_count) : (i += 1) {
        if (held_keys[i] == keycode) {
            held_keys[i] = held_keys[held_key_count - 1];
            held_key_count -= 1;
            return;
        }
    }
}

/// Drops the ledger; used when the keymap is rebuilt mid-hold (a keycode kept
/// in memory may no longer correspond to the same key, so tracking is stale).
fn clearHeldKeys() void {
    held_key_count = 0;
}

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

/// Returns a pointer to the module-owned XkbState, used by events.zig during
/// config reloads, or null before initXkb has run or after deinitXkb (e.g.
/// during a config reload's deinit/init window).
///
/// The returned pointer is invalidated by deinitXkb/initXkb (e.g. during a
/// config reload); callers must not cache it across those calls.
pub fn getXkbState() ?*xkbcommon.XkbState {
    return if (xkb_state) |*s| s else null;
}

/// Rebuilds the keymap/keysym table after the server changes the keyboard
/// mapping (setxkbmap/xmodmap). Keybinding resolution is keysym-indexed, so
/// rebuilding the flat keycode->keysym table keeps existing bindings working
/// under the new layout. However, the per-binding keycodes the key grabs were
/// made with were resolved against the old layout and go stale; re-resolve
/// them from the rebuilt table and re-grab (ungrab existing, then grab new)
/// so keybindings keep firing after the mapping change.
pub fn handleMappingNotify() void {
    const cs = core.getState();
    const state = if (xkb_state) |*s| s else return;
    state.rebuild(cs.conn);
    clearHeldKeys(); // keycodes may no longer map to the same keys post-rebuild

    // The dispatch map is keyed on keysym (unaffected by the rebuild), but
    // `grabKeybindings` grabs the keycodes stored on each binding. Refresh
    // those keycodes from the new table, then let grabKeybindings() atomically
    // ungrab all and re-grab the updated set, avoiding duplicate/leaked grabs.
    for (cs.config.keybindings.items) |*kb| {
        kb.keycode = state.keysymToKeycode(kb.keysym);
        if (kb.keycode == null) {
            // The keysym is absent from the rebuilt keymap (keyboard layout
            // change, e.g. a dead key or a non-Latin group). The binding goes
            // dead with no feedback otherwise, which looks like a config bug.
            var name_buf: [64]u8 = undefined;
            const name = xkbcommon.keysymGetName(kb.keysym, &name_buf);
            debug.warn(
                "Keybinding mods=0x{x:0>4} keysym={s} (0x{x}) has no keycode in the NEW " ++
                    "keymap and was disabled; bindings are re-resolved on MappingNotify",
                .{ kb.modifiers, name, kb.keysym },
            );
        }
    }
    events.grabKeybindings();
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
        for (masks.lock_modifiers) |lock| {
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
                @intCast(masks.mod_super | lock),
            );
        }
    }
    _ = xcb.xcb_flush(conn);
}

// Key-dispatch latency instrumentation. Measures the wall-clock time from
// event receipt (entry to handleKeyPress) to the bound action's dispatch,
// accumulated over a window so a periodic summary can be logged. Gated by
// `build_options.profile_key` so release WMs compile it out entirely.
const key_profile = utils.WindowedProfiler(
    build_options.profile_key,
    "KPROF",
    "[KPROF] receive->action last {} keys: avg={d:.0}ns min={d}ns max={d}ns",
    debug.info,
);

// Event handlers

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void {
    // Timing: wall-clock from event receipt to the bound action's dispatch.
    // Compiled out when `build_options.profile_key` is false.
    const key_t0: i128 = if (key_profile.enabled) utils.monotonicNs() else 0;

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

    // The chrome overlay owns all key input while active; routing is handled
    // inside it (input flows in, true = consumed, before keybinding dispatch).
    if (build_options.has_bar) if (surfaces.chromeHandleKeypress(event, matched)) return;

    // A held binding key makes the server replay KeyPress (autorepeat). The
    // release WAS captured by the passive grab, but without tracking we would
    // re-fire toggle actions on every repeat. Suppress re-dispatch while the
    // keycode is already held. Only keycodes this WM's grabs intercepted ever
    // reach here, so the set stays small.
    if (keyHeld(event.detail)) return;
    setKeyHeld(event.detail);

    if (matched) |action| {
        // Per-key dispatch logs are `.debug` so release WMs (default log
        // level `.info`) compile them out of the hot path; folding them into
        // a summary keeps tracing available without per-key formatting+write.
        debug.debug("[KEY] mods=0x{x} keysym=0x{x} action={s}", .{
            mods, keysym, @tagName(action.*),
        });
        if (key_profile.enabled) key_profile.note(utils.monotonicNs() - key_t0);
        executeAction(action);
    } else if (mods == 0 and
        keysym >= masks.modifier_keysym_lo and
        keysym <= masks.modifier_keysym_hi)
    {
        // Bare modifier press (Shift/Ctrl/Alt/Super/Hyper L/R): can never
        // match a binding; staying silent keeps logs free of keystroke noise.
    } else {
        debug.debug("[KEY] mods=0x{x} keysym=0x{x} no binding", .{ mods, keysym });
    }
}

/// Clears the held-key ledger on KeyRelease; the server reports a grabbed
/// key's release to the grabbing window, so this is what lets a repeat of the
/// same binding later be recognized as a genuine new press.
pub fn handleKeyRelease(event: *const xcb.xcb_key_release_event_t) void {
    focus.setLastEventTime(event.time);
    clearKeyHeld(event.detail);
}

/// Dispatches a priority-ordered button-press event.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);

    const cs = core.getState();
    const clicked_window = if (event.child != 0) event.child else event.event;
    const super_held = (event.state & masks.mod_super) != 0;
    const mods = utils.normalizeModifiers(event.state);

    // The bar selects BUTTON_PRESS directly (not via the Super+Button grab),
    // so a plain click arrives ungrabbed; route it to the bar and skip the
    // managed-window/replay-pointer machinery built for the synchronous grab
    // a client-window click goes through. Super-held clicks fall through to
    // the normal mouse-binding/drag path.
    if (!super_held and build_options.has_bar and surfaces.isBarWindow(clicked_window)) {
        surfaces.handleButtonPress(event);
        return;
    }

    // Scroll-wheel binds (buttons 4/5) are viewport actions that don't target
    // a specific window, so they're checked before the managed-window guard
    // that would otherwise discard events fired over the desktop/bar.
    if (super_held and
        (event.detail == mouse_button_scroll_up or
            event.detail == mouse_button_scroll_down))
    {
        if (!tryConfigMouseBind(mods, event.detail, 0, event.time))
            releaseGrab(event.time);
        return;
    }

    const managed_window = window.findManagedWindow(cs.conn, clicked_window, tracking.isManaged);
    if (clicked_window == 0 or clicked_window == cs.root or managed_window == 0) {
        releaseGrab(event.time);
        return;
    }

    if (!super_held) {
        focus.grabFocus(managed_window, .mouse_click);
        releaseGrab(event.time);
        return;
    }

    if (tryConfigMouseBind(mods, event.detail, managed_window, event.time)) return;

    if (event.detail == constants.mouse_button_left or
        event.detail == constants.mouse_button_right)
    {
        if (build_options.has_floating)
            actions.startDrag(managed_window, event.detail, event.root_x, event.root_y);
        keepDragGrab(event.time);
        return;
    }

    // Unbound Super+button on a managed window (e.g. Super+Middle when no
    // binding matches): no drag, no action — but the grab's activation FROZE
    // both devices. Replay the pointer as a plain click and thaw the keyboard;
    // returning without an allow_events would leave both frozen indefinitely.
    releaseGrab(event.time);
}

/// Stops any active drag and updates the last event timestamp.
pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    if (build_options.has_floating and actions.isDragging()) actions.stopDrag();
}

/// Forwards motion to the drag engine and clears focus suppression.
/// Raw PointerMotion is coalesced upstream (events.handleXcbEvents collapses
/// runs to the last event), so this runs at most once per poll wakeup.
pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t) void {
    focus.setLastEventTime(event.time);

    if (build_options.has_floating and actions.isDragging()) {
        actions.updateDrag(event.root_x, event.root_y);
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
    const delete_atom =
        utils.getAtomCached("WM_DELETE_WINDOW") catch return forceDestroy(conn, win);

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
        .reload_config => restart.requestReload(),
        .reload_hana => restart.requestReexec(),
        .dump_state => dumpState(),
        .exec => |cmd| spawn.executeShellCommand(cmd) catch |err|
            debug.err("exec failed: {}", .{err}),
        .sequence => |acts| for (acts) |*a| executeAction(a),

        // Fullscreen: keybind path resolves the focused window, then shares
        // the chrome-click transition.
        .toggle_fullscreen => {
            if (pipeline.model().focused) |win| actions.fullscreenToggleWindow(win);
        },

        // Tiling, delegated to executeTilingAction
        .toggle_floating_window,
        .toggle_layout,
        .toggle_layout_reverse,
        .cycle_layout_variants,
        .cycle_layout_variants_reverse,
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

/// Runs a tiling op under the standard graft scaffolding shared by the
/// cycle/step/toggle actions: suppress transient focus noise around the
/// mutation, then re-settle tiling. `op` is an actions fn taking the arg type
/// the action carries (step direction, or the floating toggle's window id).
inline fn tilingOp(comptime op: anytype, arg: anytype) void {
    focus.setSuppressReason(.tiling_operation);
    op(arg);
    focus.beginTilingOpSettle();
}

/// Dispatches tiling-related actions, each wrapped in a server grab so the
/// compositor cannot render a partial retile frame.
fn executeTilingAction(action: *const types.Action) void {
    switch (action.*) {
        .toggle_floating_window => if (focus.getFocused()) |win| tilingOp(actions.toggleFloating, win),
        .toggle_layout => tilingOp(actions.cycleLayoutKind, 1),
        .toggle_layout_reverse => tilingOp(actions.cycleLayoutKind, -1),
        .cycle_layout_variants => tilingOp(actions.stepVariantDir, 1),
        .cycle_layout_variants_reverse => tilingOp(actions.stepVariantDir, -1),
        .increase_master => actions.adjustPrimaryWidthAction(0.025),
        .decrease_master => actions.adjustPrimaryWidthAction(-0.025),
        .increase_master_count => actions.adjustPrimaryCount(1),
        .decrease_master_count => actions.adjustPrimaryCount(-1),
        .grow_stack_top => actions.adjustSecondaryBalance(0.5),
        .grow_stack_bottom => actions.adjustSecondaryBalance(-0.5),

        .swap_master, .swap_master_focus_swap => actions.swapPrimaryAction(action.* == .swap_master_focus_swap),

        .move_window_next => actions.moveFocused(1),
        .move_window_prev => actions.moveFocused(-1),

        .scroll_view_left => actions.viewportStep(-1),
        .scroll_view_right => actions.viewportStep(1),

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
/// and chrome-overlay toggle.
fn executeBarAction(action: *const types.Action) void {
    switch (action.*) {
        .toggle_bar_visibility => if (build_options.has_bar) surfaces.setBarState(.toggle_bar_visibility),
        .toggle_bar_position => if (build_options.has_bar) surfaces.toggleBarSegmentAnchor(),
        .toggle_prompt => if (build_options.has_bar) surfaces.chromeToggleOverlay(),
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

/// Dispatches window focus cycling (dwm-style Mod+k / Mod+j). Snaps the
/// viewport to the newly focused window when it is off-screen. The server grab
/// prevents a partial retile frame.
fn executeWindowAction(action: *const types.Action) void {
    switch (action.*) {
        .focus_next_window => {
            focus.focusNext();
            actions.snapViewportToFocused();
        },
        .focus_prev_window => {
            focus.focusPrev();
            actions.snapViewportToFocused();
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

    if (build_options.has_workspaces) {
        const ws_count = tracking.getWorkspaceCount();
        for (0..ws_count) |i|
            debug.info(
                "  WS{}: {} windows",
                .{
                    i + 1,
                    tracking.countWindowsOnWorkspace(core.WorkspaceId.fromIndex(@intCast(i))),
                },
            );
    }

    if (build_options.has_tiling and @import("core").tilingEnabled()) {
        debug.info("Tiling enabled: true", .{});
        debug.info("Tiling layout:  {s}", .{tiling.moduleName(pipeline.getCurrentLayout())});
        debug.info(
            "Tiled windows:  {}",
            .{@import("model").tiledCountOnWs(pipeline.model(), pipeline.model().current)},
        );
    }

    debug.info("================================", .{});
}

// Helpers

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, time: u32) bool {
    // Linear scan is intentional: mouse bindings are few (~5-10), hash overhead not worth it.
    for (core.getState().config.mouse_bindings.items) |*mb| {
        if (mb.modifiers == mods and mb.button == button) {
            executeMouseAction(&mb.action, win);
            releaseGrab(time);
            return true;
        }
    }
    return false;
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
