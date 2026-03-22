//! User input handling
//!
//! Handles keyboard, mouse buttons, pointer motion and drag operations.

const std           = @import("std");
const constants     = @import("constants");
const core          = @import("core");
const xkbcommon     = @import("xkbcommon");
const utils         = @import("utils");
const focus         = @import("focus");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};
const workspaces    = @import("workspaces");
const drag          = @import("drag");
const fullscreen    = @import("fullscreen");
const bar           = if (build_options.has_bar) @import("bar") else struct {};
const window        = @import("window");
const debug         = @import("debug");
const minimize      = @import("minimize");
const prompt        = @import("prompt");
const xcb           = core.xcb;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
});

const MOUSE_BUTTON_LEFT:   u8 = 1;
const MOUSE_BUTTON_MIDDLE: u8 = 2;
const MOUSE_BUTTON_RIGHT:  u8 = 3;
const MOUSE_BUTTONS = [_]u8{ MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT };

var xkb_state: ?xkbcommon.XkbState = null;

/// Initializes XKB context, keymap, and key state from the server's current keyboard config.
pub fn initXkb(conn: *xcb.xcb_connection_t) !void {
    xkb_state = try xkbcommon.XkbState.init(conn);
}

/// Cleans up XKB state. Must be called after deinit().
pub fn deinitXkb() void {
    if (xkb_state) |*s| s.deinit();
    xkb_state = null;
}

/// Returns a pointer to the module-owned XkbState. Used by events.zig for config reload.
pub fn getXkbState() *xkbcommon.XkbState {
    return &xkb_state.?;
}

// Grab setup

/// Grabs mouse buttons and sets the root window cursor. Call once at startup.
pub fn setup(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t, root: u32) void {
    setupGrabs(conn, root);
    XcbCursor.setupRoot(conn, screen);
}

/// Grabs Super+Button1/2/3 on the root window.
/// Button1 = move, Button3 = resize, Button2 = config-driven binds (e.g. toggle_floating).
pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    for (MOUSE_BUTTONS) |button| {
        _ = xcb.xcb_grab_button(
            conn, 0, root,
            xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.XCB_EVENT_MASK_POINTER_MOTION,
            xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
            root, xcb.XCB_NONE, button, constants.MOD_SUPER,
        );
    }
    _ = xcb.xcb_flush(conn);
}

// Event handlers

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void {
    focus.setLastEventTime(event.time);

    const mods   = utils.normalizeModifiers(event.state);
    const keysym = xkb_state.?.keycodeToKeysym(event.detail);

    // Scan keybindings linearly. n is bounded by what a human can type into a
    // config file (typically < 50, hard ceiling ~200). At that size a flat scan
    // over contiguous memory is faster than a hash lookup due to cache locality
    // and has no allocation, no deinit, and no sync liability.
    var matched: ?*const core.Action = null;
    for (core.config.keybindings.items) |*kb| {
        if (kb.modifiers == mods and kb.keysym == keysym) {
            matched = &kb.action;
            break;
        }
    }

    // Prompt owns all key input when active. Routing decisions (including the
    // close_window dismiss shortcut) live entirely in prompt.handleKeyEvent.
    if (prompt.handlePromptKeypress(event, matched)) return;

    debug.info("[KEY] keycode={} state=0x{x} mods=0x{x} keysym=0x{x}",
        .{ event.detail, event.state, mods, keysym });

    if (matched) |action| {
        debug.info("[KEY] action found: {s}", .{@tagName(action.*)});
        executeAction(action) catch |err| debug.err("Failed to execute action: {}", .{err});
    } else {
        debug.info("[KEY] no binding found for this key", .{});
    }
}

/// Dispatches a button-press event using the following priority order:
///   1. Ignore clicks on the root window or unknown windows (replay pointer).
///   2. Check config-driven mouse bindings (e.g. Super+MiddleClick = toggle_floating).
///   3. Super+Left/Right drag: start a move or resize operation.
///   4. Any other click: focus the window under the cursor.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);
    const clicked_window = if (event.child != 0) event.child else event.event;

    if (clicked_window == 0 or clicked_window == core.root) {
        // Use event.time, not XCB_CURRENT_TIME — server matches by timestamp.
        replayPointer(event.time);
        return;
    }

    const managed_window = utils.findManagedWindow(core.conn, clicked_window, workspaces.isManaged);
    if (managed_window == 0) {
        replayPointer(event.time);
        return;
    }

    // Check config-driven mouse binds (e.g. Super+MiddleClick = "toggle_floating").
    // These take priority over the default drag behaviour so a bind is never
    // swallowed by the drag handler.
    const super_held = (event.state & constants.MOD_SUPER) != 0;
    if (super_held) {
        const mods = utils.normalizeModifiers(event.state);
        for (core.config.mouse_bindings.items) |*mb| {
            if (mb.modifiers == mods and mb.button == event.detail) {
                executeMouseAction(&mb.action, managed_window)
                    catch |err| debug.err("mouse bind error: {}", .{err});
                releaseGrab(event.time);
                return;
            }
        }
    }

    if (super_held and (event.detail == MOUSE_BUTTON_LEFT or event.detail == MOUSE_BUTTON_RIGHT)) {
        drag.startDrag(managed_window, event.detail, event.root_x, event.root_y);
    } else {
        focus.setFocus(managed_window, .mouse_click);
    }

    // Release the SYNC grab; use event.time not XCB_CURRENT_TIME to avoid silent drop.
    releaseGrab(event.time);
}

pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    if (drag.isDragging()) drag.stopDrag();
}

pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (drag.isDragging()) {
        drag.updateDrag(event.root_x, event.root_y);
        return;
    }
    // Real movement lifts any active focus suppression (window_spawn or tiling_operation).
    if (focus.getSuppressReason() != .none) focus.setSuppressReason(.none);
    // POINTER_MOTION_HINT delivers one event per gesture; re-arm by querying pointer.
    //
    // We fire the request and immediately discard the reply — we don't use any
    // of the reply fields here.  The X server re-arms motion delivery when it
    // receives the *request*, not when we receive the *reply*, so the discard is
    // semantically identical to waiting but without the blocking round-trip.
    //
    // This matters because MotionNotify is the highest-frequency X event under
    // normal use.  The old blocking read stalled the entire event loop for a
    // full RTT on every non-drag motion, delaying processing of any other events
    // queued behind it (EnterNotify, KeyPress, etc.).
    xcb.xcb_discard_reply(core.conn, xcb.xcb_query_pointer(core.conn, core.root).sequence);
}

// Window close

fn closeWindow(win: u32) void {
    // Prefer a graceful shutdown: send a WM_DELETE_WINDOW client message so the
    // application can save state and clean up before exiting (ICCCM §4.1.2.7).
    if (utils.supportsWMDeleteCached(core.conn, win)) {
        const protocols_atom = utils.getAtomCached("WM_PROTOCOLS")     catch return;
        const delete_atom    = utils.getAtomCached("WM_DELETE_WINDOW") catch return;

        // Zero-initialise the event struct. XCB transmits the raw bytes over
        // the wire, so any uninitialised padding would be undefined behaviour.
        var event = std.mem.zeroes(xcb.xcb_client_message_event_t);

        event.response_type  = xcb.XCB_CLIENT_MESSAGE;
        event.format         = 32;
        event.window         = win;
        event.type           = protocols_atom;
        event.data.data32[0] = delete_atom;
        event.data.data32[1] = focus.getLastEventTime(); // ICCCM §4.1.7

        _ = xcb.xcb_send_event(core.conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
    } else {
        // The window does not support WM_DELETE_WINDOW, so destroy it forcefully.
        _ = xcb.xcb_destroy_window(core.conn, win);
    }
    _ = xcb.xcb_flush(core.conn);
}

// Action dispatch

fn executeAction(action: *const core.Action) !void {
    switch (action.*) {
        .toggle_fullscreen => fullscreen.toggle(),
        .close_window      => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config     => utils.reload(),
        // Runs each action in the list in order. Stops and propagates the
        // first error encountered, leaving any remaining actions unexecuted.
        .sequence   => |acts| for (acts) |*a| try executeAction(a),
        .exec       => |cmd| try executeShellCommand(cmd),
        .dump_state => dumpState(),

        .toggle_floating,
        .toggle_layout,
        .toggle_layout_reverse,
        .cycle_layout_variants,
        .increase_master,
        .decrease_master,
        .increase_master_count,
        .decrease_master_count,
        .swap_master,
        .swap_master_focus_swap => if (comptime build_options.has_tiling) {
            switch (action.*) {
                .toggle_floating        => { if (focus.getFocused()) |win| tiling.toggleWindowFloat(win); bar.scheduleFullRedraw(); },
                .toggle_layout          => { tiling.toggleLayout();             bar.scheduleRedraw();     },
                .toggle_layout_reverse  => { tiling.toggleLayoutReverse();      bar.scheduleRedraw();     },
                .cycle_layout_variants => { tiling.cycleLayoutVariants();     bar.scheduleRedraw();     },
                .increase_master        => tiling.increaseMasterWidth(),
                .decrease_master        => tiling.decreaseMasterWidth(),
                .increase_master_count  => tiling.increaseMasterCount(),
                .decrease_master_count  => tiling.decreaseMasterCount(),
                .swap_master            => { tiling.swapWithMaster();           focus.beginPointerSync(); bar.scheduleRedraw(); },
                .swap_master_focus_swap => { tiling.swapWithMasterFocusSwap();  focus.beginPointerSync(); bar.scheduleRedraw(); },
                else => unreachable,
            }
        },

        .toggle_bar_visibility,
        .toggle_bar_position => if (comptime build_options.has_bar) {
            switch (action.*) {
                .toggle_bar_visibility => bar.setBarState(.toggle),
                .toggle_bar_position   => bar.toggleBarPosition(),
                else => unreachable,
            }
        },

        .minimize_window => minimize.minimizeWindow(),
        .unminimize_lifo => minimize.unminimize(.lifo),
        .unminimize_fifo => minimize.unminimize(.fifo),
        .unminimize_all  => minimize.unminimizeAll(),
        .switch_workspace  => |ws| workspaces.switchTo(ws),
        .move_to_workspace => |ws| { if (focus.getFocused()) |win| workspaces.moveWindowTo(win, ws) catch |e| debug.warnOnErr(e, "move_to_workspace"); },
        .move_window       => |ws| { if (focus.getFocused()) |win| workspaces.moveWindowExclusive(win, ws); },
        .toggle_tag        => |ws| { if (focus.getFocused()) |win| workspaces.tagToggle(win, ws, true); },
        .toggle_prompt => prompt.toggle(),
    }
}

/// Like executeAction but carries the specific window that was clicked.
/// Used by the mouse bind dispatcher so toggle_floating acts on the clicked
/// window rather than the keyboard-focused one (they may differ).
fn executeMouseAction(action: *const core.Action, clicked_win: u32) !void {
    switch (action.*) {
        .toggle_floating => if (comptime build_options.has_tiling) tiling.toggleWindowFloat(clicked_win),
        else             => try executeAction(action),
    }
}

// Shell execution

/// Grandchild process: detach from the session and exec the command.
/// Writes a sentinel byte to exec_pipe_write if execvp fails, so the WM
/// can distinguish exec failure from success (which closes the pipe via CLOEXEC).
fn grandchildExec(exec_pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    _ = c.setsid();
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
    // execvp only returns on failure; signal this to the WM via exec_pipe.
    const sentinel: u8 = 1;
    _ = c.write(exec_pipe_write, &sentinel, 1);
    std.process.exit(1);
}

/// Intermediate child process: spawns the grandchild, forwards its PID over
/// pid_pipe, then exits so the grandchild is re-parented to init.
/// Closing exec_pipe_write before exit is required — without it the WM's
/// read would block indefinitely waiting for an EOF that never comes.
fn intermediateChild(exec_pipe_write: c_int, pid_pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    const grandchild_pid = c.fork();
    switch (grandchild_pid) {
        0  => grandchildExec(exec_pipe_write, cmd_z),
        -1 => { debug.err("Second fork failed", .{}); std.process.exit(1); },
        else => {},
    }
    _ = c.write(pid_pipe_write, &grandchild_pid, @sizeOf(c_int));
    _ = c.close(pid_pipe_write);
    _ = c.close(exec_pipe_write);
    std.process.exit(0);
}

/// Spawns `cmd` via double-fork so the grandchild is re-parented to init.
///
/// exec_pipe: write end is FD_CLOEXEC; EOF on success, sentinel byte on exec failure.
/// pid_pipe:  intermediate child writes grandchild PID before exiting.
/// registerSpawn() is only called when exec is confirmed to have succeeded.
fn executeShellCommand(cmd: []const u8) !void {
    const cmd_z = try core.alloc.dupeZ(u8, cmd);
    defer core.alloc.free(cmd_z);

    var exec_pipe: [2]c_int = undefined;
    var pid_pipe:  [2]c_int = undefined;

    if (c.pipe(&exec_pipe) != 0) {
        debug.err("pipe() failed (exec_pipe) for command: {s}", .{cmd});
        return error.PipeFailed;
    }
    if (c.pipe(&pid_pipe) != 0) {
        closePipe(exec_pipe);
        debug.err("pipe() failed (pid_pipe) for command: {s}", .{cmd});
        return error.PipeFailed;
    }
    // exec_pipe write end is CLOEXEC: exec success silently closes it (EOF to WM).
    _ = c.fcntl(exec_pipe[1], c.F_SETFD, c.FD_CLOEXEC);

    const pid = c.fork();
    switch (pid) {
        0 => {
            // Intermediate child process. Close the read ends we don't need,
            // then hand off to the named helper.
            _ = c.close(exec_pipe[0]);
            _ = c.close(pid_pipe[0]);
            intermediateChild(exec_pipe[1], pid_pipe[1], cmd_z.ptr);
        },
        -1 => {
            closePipe(exec_pipe);
            closePipe(pid_pipe);
            debug.err("First fork failed for command: {s}", .{cmd});
            return error.ForkFailed;
        },
        else => {
            // WM (parent) process: close write ends we don't own, then wait
            // for the intermediate child so it doesn't become a zombie.
            _ = c.close(exec_pipe[1]);
            _ = c.close(pid_pipe[1]);

            var status: c_int = 0;
            if (c.waitpid(pid, &status, 0) == -1) {
                _ = c.close(exec_pipe[0]);
                _ = c.close(pid_pipe[0]);
                debug.err("waitpid failed", .{});
                return error.WaitpidFailed;
            }

            // By the time waitpid returns, the intermediate child has already
            // written the grandchild PID into pid_pipe, so this read won't block.
            var grandchild_pid: c_int = -1;
            _ = c.read(pid_pipe[0], &grandchild_pid, @sizeOf(c_int));
            _ = c.close(pid_pipe[0]);

            // EOF (n == 0) on exec_pipe means exec succeeded (CLOEXEC closed it).
            // A sentinel byte (n == 1) means execvp failed; skip spawn registration.
            var sentinel: u8 = 0;
            const n = c.read(exec_pipe[0], &sentinel, 1);
            _ = c.close(exec_pipe[0]);
            if (n > 0) return;

            if (workspaces.getCurrentWorkspace()) |ws| {
                const pid_u32: u32 = if (grandchild_pid > 0) @intCast(grandchild_pid) else 0;
                window.registerSpawn(ws, pid_u32);
            }
        },
    }
}

// Diagnostics

fn dumpState() void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused: {?x}",         .{focus.getFocused()});
    const win_count = if (workspaces.getState()) |s| s.window_to_workspaces.count() else 0;
    debug.info("Total windows: {}",     .{win_count});
    debug.info("Suppress focus: {s}",   .{@tagName(focus.getSuppressReason())});

    fullscreen.forEachFullscreen(struct {
        fn cb(ws: u8, info: fullscreen.FullscreenInfo) void {
            debug.info("Fullscreen on workspace {}: {x}", .{ ws, info.window });
        }
    }.cb);
    if (!fullscreen.hasAnyFullscreen()) debug.info("Fullscreen: none", .{});
    debug.info("Drag active: {}", .{drag.isDragging()});

    if (workspaces.getState()) |ws_state| {
        debug.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |*ws, i| {
            debug.info("  WS{}: {} windows", .{ i + 1, ws.windows.len });
        }
    }

    if (comptime build_options.has_tiling) {
        if (tiling.getStateOpt()) |t_state| {
            debug.info("Tiling enabled: {}",  .{t_state.enabled});
            debug.info("Tiling layout: {s}", .{@tagName(t_state.layout)});
            debug.info("Tiled windows: {}",  .{t_state.windows.len});
            debug.info("Master count: {}",   .{t_state.master_count});
            debug.info("Master width: {d:.2}", .{t_state.master_width});
        }
    }
    debug.info("================================", .{});
}

// Helpers

/// Replays a frozen pointer event and flushes. Always pass `event.time`, never XCB_CURRENT_TIME.
/// Only sends REPLAY_POINTER — used when no keyboard grab is active (e.g. clicking root/unmanaged).
inline fn replayPointer(time: u32) void {
    _ = xcb.xcb_allow_events(core.conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_flush(core.conn);
}

/// Releases both the pointer and keyboard SYNC grabs acquired during Super+button events,
/// then flushes. Always pass `event.time`, never XCB_CURRENT_TIME.
inline fn releaseGrab(time: u32) void {
    _ = xcb.xcb_allow_events(core.conn, xcb.XCB_ALLOW_REPLAY_POINTER,  time);
    _ = xcb.xcb_allow_events(core.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, time);
    _ = xcb.xcb_flush(core.conn);
}

/// Closes both ends of a pipe pair.
inline fn closePipe(p: [2]c_int) void {
    _ = c.close(p[0]);
    _ = c.close(p[1]);
}

/// xcb-cursor extern declarations and helpers.
///
/// Declared manually instead of using cImport because cImport cannot bind
/// static inline functions, and xcb_cursor_load_cursor is defined that way.
const XcbCursor = struct {
    const Context = opaque {};

    extern fn xcb_cursor_context_new(
        conn:   *xcb.xcb_connection_t,
        screen: *xcb.xcb_screen_t,
        ctx:    *?*Context,
    ) c_int;

    extern fn xcb_cursor_load_cursor(ctx: *Context, name: [*:0]const u8) u32;
    extern fn xcb_cursor_context_free(ctx: ?*Context) void;

    /// Makes the user theme's cursor be used by the root window (hovering hana's background wallpaper),
    /// respecting the user's custom cursor instead of just displaying the default X server's cursor.
    ///
    /// Falls back to no change if xcb-cursor fails to load it.
    fn setupRoot(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
        var cursor_ctx: ?*Context = null;

        if (xcb_cursor_context_new(conn, screen, &cursor_ctx) < 0)
            return;
        defer xcb_cursor_context_free(cursor_ctx);

        const cursor  = xcb_cursor_load_cursor(cursor_ctx.?, "left_ptr"); // Set custom cursor
        if (cursor == xcb.XCB_NONE) return;                               // Fallback; no settable cursor detected

        // Apply the loaded cursor to the root window.
        const cookie = xcb.xcb_change_window_attributes_checked(
            conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor},
        );

        if (xcb.xcb_request_check(conn, cookie)) |err| {
            debug.err("Failed to set custom cursor onto hana's root window: {}", .{err});
            std.c.free(err);
        }

        // Release our client-side handle. The server uses reference counting — it keeps
        // the cursor alive as long as any window still has it set, so this is safe to
        // call immediately after applying it to the root window.
        _ = xcb.xcb_free_cursor(conn, cursor);
    }
};
