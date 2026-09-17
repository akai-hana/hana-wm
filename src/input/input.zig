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
// Layout-name resolution for diagnostics. Reached through the build-generated
// `tiling_seam` (empty struct when tiling is absent); every member use is
// gated on has_tiling, so the tiling-less build still compiles.
const tiling = @import("tiling_seam").tiling;
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

const mouse_buttons = [_]u8{ constants.mouse_button_left, constants.mouse_button_middle, constants.mouse_button_right, constants.mouse_button_scroll_up, constants.mouse_button_scroll_down };

var xkb_state: ?xkbcommon.XkbState = null;

// Held binding-key ledger. A passive grab returns a bound key's KeyRelease
// to the grabbing window only if the mask selects it; keycodes are stable
// across a gesture regardless of modifier release order, so keying on the
// raw KEYCODE both suppresses autorepeat and always clears on release.
var held_keys = std.StaticBitSet(256).initEmpty();

fn keyHeld(keycode: u8) bool {
    return held_keys.isSet(keycode);
}

fn setKeyHeld(keycode: u8) void {
    held_keys.set(keycode);
}

fn clearKeyHeld(keycode: u8) void {
    held_keys.unset(keycode);
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
    const state = getXkbState() orelse return;
    state.rebuild(cs.conn);
    held_keys = std.StaticBitSet(256).initEmpty();

    // The dispatch map is keyed on keysym (unaffected by the rebuild), but
    // `grabKeybindings` grabs the keycodes stored on each binding. Refresh
    // those keycodes from the new table, then let grabKeybindings() atomically
    // ungrab all and re-grab the updated set, avoiding duplicate/leaked grabs.
    types.resolveKeycodes(cs.config.keybindings.items, state);
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

    // A held binding key emits repeated KeyPress events: either the server
    // replays KeyPress (detectable auto-repeat, enabled in xkbcommon.zig) or it
    // interleaves a deactivating KeyRelease with each repeat. The real
    // KeyRelease clears the ledger, but an autorepeat KeyPress must not re-fire
    // the action, so suppress re-dispatch while the keycode is already held.
    // Only keycodes this WM's grabs intercepted ever reach here, so the set
    // stays small.
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
    } else if (mods != 0 or keysym < masks.modifier_keysym_lo or keysym > masks.modifier_keysym_hi) {
        // Bare modifier press (Shift/Ctrl/Alt/Super/Hyper L/R) can never
        // match a binding; staying silent keeps logs free of keystroke noise.
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
    if (super_held and (event.detail == constants.mouse_button_scroll_up or event.detail == constants.mouse_button_scroll_down)) {
        if (!tryConfigMouseBind(mods, event.detail, 0, event.time)) releaseGrab(event.time);
        return;
    }

    const managed_window = window.findManagedWindow(cs.conn, clicked_window, tracking.isManaged);
    if (clicked_window == 0 or clicked_window == cs.root or managed_window == 0) return releaseGrab(event.time);

    if (!super_held) {
        focus.grabFocus(managed_window, .mouse_click);
        releaseGrab(event.time);
        return;
    }

    if (tryConfigMouseBind(mods, event.detail, managed_window, event.time)) return;

    if (event.detail == constants.mouse_button_left or event.detail == constants.mouse_button_right) {
        if (build_options.has_floating) actions.startDrag(managed_window, event.detail, event.root_x, event.root_y);
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
    // Releases on the bar window terminate a segment scrub (the bar clears
    // its drag anchor). Routed before the managed-window path, as clicks are.
    if (build_options.has_bar and surfaces.isBarWindow(event.event)) {
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
    if (build_options.has_bar and surfaces.isBarWindow(event.event)) {
        surfaces.handleButtonMotion(event);
        return;
    }

    if (build_options.has_floating and actions.isDragging()) {
        actions.updateDrag(event.root_x, event.root_y);
        return;
    }

    focus.setSuppressReason(.none);
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

/// Top-level action dispatcher. Routes each action tag to its handler inline
/// (single switch, no per-class delegates). Errors are handled internally.
fn executeAction(action: *const types.Action) void {
    switch (action.*) {
        // Core
        .close_window => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => utils.reload(),
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

        .toggle_floating_window => if (focus.getFocused()) |win| tilingOp(actions.toggleFloating, win),
        .cycle_layout => |dir| tilingOp(actions.cycleLayoutKind, if (dir == .forward) @as(i32, 1) else -1),
        .cycle_variants => |dir| tilingOp(actions.stepVariantDir, if (dir == .forward) @as(i32, 1) else -1),
        .set_master_width => |dir| actions.adjustPrimaryWidthAction(if (dir == .forward) 0.025 else -0.025),
        .set_master_count => |dir| actions.adjustPrimaryCount(if (dir == .forward) @as(i32, 1) else -1),
        .grow_stack => |dir| actions.adjustSecondaryBalance(if (dir == .forward) 0.5 else -0.5),
        .swap_master => |mode| actions.swapPrimaryAction(mode == .focus_swap),
        .move_window_next => actions.moveFocused(1),
        .move_window_prev => actions.moveFocused(-1),
        .scroll_view => |dir| actions.viewportStep(if (dir == .forward) @as(i32, 1) else -1),

        // Cycle focus forward/backward. The viewport snap runs as a duty
        // inside the focus transition's single grab (see
        // actions.snapViewportFocusedDuty), so a cycle that scrolls the
        // viewport is still one grab+reconcile, not focus-then-snap's two.
        .cycle_focus => |dir| {
            if (focus.cycleTarget(dir == .forward)) |target|
                focus.grabFocusWithDuty(target, .user_command, &actions.snapViewportFocusedDuty);
        },

        // Workspaces. workspaces.zig self-gates to a single implicit
        // workspace when core.getState().config.workspaces.enabled is false,
        // so these calls are always valid regardless of that setting.
        .switch_workspace => |ws| actions.switchTo(ws),
        .move_to_workspace => |ws| if (focus.getFocused()) |wid| actions.moveWindowTo(wid, ws),
        .toggle_tag => |ws| if (focus.getFocused()) |wid| actions.tagToggle(wid, ws, true),
        .all_workspaces => actions.allViewToggle(),
        .pin_window => if (focus.getFocused()) |wid| actions.pinToggle(wid),

        // Bar: visibility toggle, position toggle, and chrome-overlay toggle.
        .toggle_bar_visibility => if (build_options.has_bar) surfaces.setBarState(.toggle_bar_visibility),
        .toggle_bar_position => if (build_options.has_bar) surfaces.toggleBarSegmentAnchor(),
        .toggle_prompt => if (build_options.has_bar) surfaces.chromeToggleOverlay(),

        // Minimize: minimize, unminimize (LIFO/FIFO), and restore all.
        .minimize_window => actions.minimize(focus.getFocused()),
        .unminimize => |order| switch (order) {
            .lifo => actions.restoreOrdered(.lifo),
            .fifo => actions.restoreOrdered(.fifo),
        },
        .unminimize_all => actions.restoreAll(),
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
        debug.info("Tiled windows:  {}", .{@import("model").tiledCountOnWs(pipeline.model(), pipeline.model().current)});
    }

    debug.info("================================", .{});
}

// Helpers

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, time: u32) bool {
    // Linear scan is intentional: mouse bindings are few (~5-10), hash overhead not worth it.
    for (core.getState().config.mouse_bindings.items) |*mb|
        if (mb.modifiers == mods and mb.button == button) {
            // Most mouse binds execute against the keyboard-focused window
            // (executeAction); toggle_floating_window is inherently per-window
            // and so targets the CLICKED window instead.
            switch (mb.action) {
                .toggle_floating_window => tilingOp(actions.toggleFloating, win),
                else => executeAction(&mb.action),
            }
            releaseGrab(time);
            return true;
        };
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
