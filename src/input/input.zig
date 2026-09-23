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
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const xkbcommon = @import("xkbcommon");
const keybind = @import("keybind");
const build_options = @import("build_options");
const pipeline = @import("pipeline");
const actions = @import("actions");
const spawn = @import("spawn");
const model = @import("model");
// Layout-name resolution for diagnostics. Reached through the build-generated
// `tiling_seam` (empty struct when tiling is absent); every member use is
// gated on has_tiling, so the tiling-less build still compiles.
const tiling = @import("tiling_seam").tiling;
// The bar's hook set is reached through the core-owned `surfaces` composition
// root, never by importing the bar module here. When the bar is absent it is
// the comptime `null` type, so every `if (build_options.has_bar)` call below
// compiles away.
const surfaces = @import("surfaces").Surfaces;
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

// The (modifiers, keysym) -> Action dispatch map. Owned here, not by Config:
// building it needs the live XKB state, which the pure config layer must not
// depend on. Rebuilt on startup and every config reload (buildKeybinds); the
// entries borrow `*const Action` pointers from the live config's keybindings.
var keybind_resolver: keybind.KeybindResolver = .{};

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

/// Resolves `keybindings` against the live XKB state and rebuilds the dispatch
/// map. Call once at startup (after `initXkb` and config load) and again on
/// every config reload with the new config's keybindings. No-op without XKB;
/// callers that must not run on stale XKB (the reload path) should check
/// `getXkbState` themselves and abort first.
pub fn buildKeybinds(keybindings: []types.Keybind) void {
    const state = getXkbState() orelse return;
    keybind.resolveKeycodes(keybindings, state);
    keybind_resolver.rebuildDispatchMap(keybindings, core.getState().alloc);
}

/// Releases the dispatch map. Call before the config whose keybindings the
/// entries point into is freed (shutdown).
pub fn deinitKeybinds() void {
    keybind_resolver.deinit(core.getState().alloc);
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

    // The dispatch map is keyed on keysym (unaffected by the rebuild), but
    // `grabKeybindings` grabs the keycodes stored on each binding. Refresh
    // those keycodes from the new table, then let grabKeybindings() atomically
    // ungrab all and re-grab the updated set, avoiding duplicate/leaked grabs.
    keybind.resolveKeycodes(cs.config.keybindings.items, state);
    events.grabKeybindings();
}

// Grab setup

/// Grabs mouse buttons on the root window and applies the user's cursor theme.
pub fn setup(conn: core.Connection, screen: core.Screen) void {
    setupGrabs(conn, screen.root);
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
    // input.buildKeybinds.
    const matched = keybind_resolver.lookup(mods, keysym);

    // The chrome overlay owns all key input while active; routing is handled
    // inside it (input flows in, true = consumed, before keybinding dispatch).
    if (build_options.has_bar) if (surfaces.chromeHandleKeypress(event, matched)) return;

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

/// Tracks the event timestamp for focus machinery on release.
/// (Held-key auto-repeat semantics live in xkbcommon's detectable
/// auto-repeat; see there.)
pub fn handleKeyRelease(event: *const xcb.xcb_key_release_event_t) void {
    focus.setLastEventTime(event.time);
}

/// True when the press/release/motion target is the bar window (bar path);
/// always false in a bar-less build, where `surfaces` compiles to the null
/// plugin type and the shape is pruned at comptime.
inline fn onBarWindow(win: u32) bool {
    return build_options.has_bar and surfaces.isBarWindow(win);
}

/// Dispatches a priority-ordered button-press event, splitting the two named
/// paths: a plain click on the bar window routes to the bar; every other
/// press goes through the managed-window mouse machinery.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);
    const super_held = (event.state & masks.mod_super) != 0;
    const clicked_window = if (event.child != 0) event.child else event.event;
    if (handleBarButtonPress(event, super_held, clicked_window)) return;
    handleWindowButtonPress(event, super_held, clicked_window);
}

/// The bar path: a plain (non-Super) click whose target is the bar window.
/// The bar selects BUTTON_PRESS directly (not via the Super+Button grab), so
/// a plain click arrives ungrabbed; route it to the bar and skip the
/// managed-window/replay-pointer machinery built for the synchronous grab a
/// client-window click goes through. Super-held clicks fall through to the
/// normal mouse-binding/drag path. Returns true when the event was consumed.
fn handleBarButtonPress(event: *const xcb.xcb_button_press_event_t, super_held: bool, clicked_window: u32) bool {
    if (super_held) return false;
    if (!onBarWindow(clicked_window)) return false;
    surfaces.handleButtonPress(event);
    return true;
}

/// The managed-window path: scroll-wheel binds, focus, config mouse-bind
/// lookup, drag, and the unbound-Super replay fallback.
fn handleWindowButtonPress(event: *const xcb.xcb_button_press_event_t, super_held: bool, clicked_window: u32) void {
    const cs = core.getState();
    const mods = utils.normalizeModifiers(event.state);

    // Scroll-wheel binds (buttons 4/5) are viewport actions that don't target
    // a specific window, so they're checked before the managed-window guard
    // that would otherwise discard events fired over the desktop/bar.
    if (super_held and (event.detail == constants.mouse_button_scroll_up or event.detail == constants.mouse_button_scroll_down)) {
        if (!tryConfigMouseBind(mods, event.detail, 0, event.time)) releaseGrab(event.time);
        return;
    }

    const managed_window = window.findManagedWindow(cs.conn, clicked_window, tracking.isManaged);
    if (clicked_window == cs.root or managed_window == 0) return releaseGrab(event.time);

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
    if (onBarWindow(event.event)) {
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
    if (onBarWindow(event.event)) {
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

/// Closes a window gracefully via WM_DELETE_WINDOW (ICCCM §4.1.2.7), falling
/// back to xcb_destroy_window for clients that don't advertise the protocol.
/// The timestamp in data32[1] is the time passed to the client per §4.1.2.7.
fn closeWindow(win: u32) void {
    const conn = core.getState().conn;
    if (!window.supportsWMDeleteCached(conn, win)) {
        _ = xcb.xcb_destroy_window(conn, win);
        return;
    }

    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch {
        _ = xcb.xcb_destroy_window(conn, win);
        return;
    };
    const delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch {
        _ = xcb.xcb_destroy_window(conn, win);
        return;
    };

    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = win;
    event.type = protocols_atom;
    event.data.data32[0] = delete_atom;
    event.data.data32[1] = focus.getLastEventTime();

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

// Action dispatch

/// Directional actions carry a `Dir`; map it to the signed step used by the
/// tiling ops (`.forward` = +1, `.reverse` = -1).
inline fn dirSign(dir: types.Dir) i32 {
    return if (dir == .forward) 1 else -1;
}

/// A `,`-sequence advances strictly one step at a time. A raw exec step is the
/// one that needs real waiting: the next step must not begin until the command
/// has actually finished, so it goes through spawn.execSynchronous, which keeps
/// the child a direct child and blocks on waitpid until it exits (freezing the
/// WM for the duration -- see its doc). Every other step kind completes
/// instantly and is dispatched with the normal non-blocking path.
fn executeSequenceStep(action: *const types.Action) void {
    if (action.* == .exec) {
        spawn.execSynchronous(action.exec);
        return;
    }
    executeAction(action);
}

/// Top-level action dispatcher. Routes each action tag to its handler inline
/// (single switch, no per-class delegates). Errors are handled internally.
fn executeAction(action: *const types.Action) void {
    switch (action.*) {
        // A `,`-sequence runs steps in strict order: each step fully finishes
        // (for a raw exec step, that means waiting until the command exits,
        // see spawn.execSynchronous) before the next one begins.
        .sequence => |acts| for (acts) |*a| executeSequenceStep(a),
        // Core
        .close_window => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => utils.reload(),
        .reload_hana => restart.requestReexec(),
        .dump_state => dumpState(),
        .exec => |cmd| spawn.executeShellCommand(cmd) catch |err|
            debug.err("exec failed: {}", .{err}),
        // A `+` batch is fire-and-forget: members are launched together, no
        // member waits on another, and execs spawn as detached children that
        // keep running after the batch moves on.
        .parallel => |acts| for (acts) |*a| executeAction(a),

        // Fullscreen: keybind path resolves the focused window, then shares
        // the chrome-click transition.
        .toggle_fullscreen => {
            if (pipeline.model().focused) |win| actions.fullscreenToggleWindow(win);
        },

        .toggle_floating_window => if (focus.getFocused()) |win| tilingOp(actions.toggleFloating, win),
        .cycle_layout => |dir| tilingOp(actions.cycleLayoutKind, dirSign(dir)),
        .cycle_variants => |dir| tilingOp(actions.stepVariantDir, dirSign(dir)),
        .set_master_width => |dir| actions.adjustPrimaryWidthAction(@as(f32, @floatFromInt(dirSign(dir))) * constants.master_width_step),
        .set_master_count => |dir| actions.adjustPrimaryCount(dirSign(dir)),
        .grow_stack => |dir| actions.adjustSecondaryBalance(@as(f32, @floatFromInt(dirSign(dir))) * constants.stack_balance_step),
        .swap_master => |mode| actions.swapPrimaryAction(mode == .focus_swap),
        .move_window_next => actions.moveFocused(1),
        .move_window_prev => actions.moveFocused(-1),
        .scroll_view => |dir| actions.viewportStep(dirSign(dir)),

        // Cycle focus forward/backward. The viewport snap runs as a duty
        // inside the focus transition's single grab (see
        // actions.snapViewportFocusedDuty), so a cycle that scrolls the
        // viewport is still one grab+reconcile, not focus-then-snap's two.
        .cycle_focus => |dir| {
            if (focus.cycleTarget(dir)) |target|
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
        .unminimize => |order| actions.restoreOrdered(order),
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

    if (build_options.has_tiling and core.tilingEnabled()) {
        const m = pipeline.model();
        debug.info("Tiling enabled: true", .{});
        debug.info("Tiling layout:  {s}", .{tiling.moduleName(pipeline.getCurrentLayout())});
        debug.info("Tiled windows:  {}", .{model.tiledCountOnWs(m, m.current)});
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
            screen.root,
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
