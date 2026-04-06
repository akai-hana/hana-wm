//! User input handling
//! Handles keyboard, mouse buttons, pointer motion, and drag operations.

const std   = @import("std");
const build = @import("build_options");

// No Zig stdlibs wrap these AFAIK due to them being so low-level
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
});

const core      = @import("core");
    const xcb   = core.xcb;
const types     = @import("types");
const utils     = @import("utils");
const constants = @import("constants");

const debug = @import("debug");

const window   = @import("window");
const tracking = @import("tracking");
const focus    = @import("focus");

const fullscreen = if (build.has_fullscreen) @import("fullscreen") else struct {};
const minimize   = if (build.has_minimize) @import("minimize") else struct {};
const workspaces = if (build.has_workspaces) @import("workspaces") else struct {};
const tiling     = if (build.has_tiling) @import("tiling") else struct {};
const drag       = @import("drag");

const xkbcommon = @import("xkbcommon");

const bar = if (build.has_bar) @import("bar") else struct {
    pub fn scheduleFullRedraw() void {}
    pub fn scheduleRedraw() void {}
    pub fn redrawInsideGrab() void {}
    pub fn setBarState(_: anytype) void {}
    pub fn toggleBarSegmentAnchor() void {}
};

const prompt = if (build.has_bar and build.has_prompt) @import("prompt") else struct {
    pub fn handlePromptKeypress(_: anytype, _: anytype) bool { return false; }
    pub fn toggle() void {}
};

fn getWsState() ?*workspaces.State {
    return if (comptime build.has_workspaces) workspaces.getState() else null;
}
inline fn switchToWs(ws: u8) void {
    if (comptime build.has_workspaces) workspaces.switchTo(ws);
}
inline fn moveWindowToWs(win: u32, ws: u8) !void {
    if (comptime build.has_workspaces) try workspaces.moveWindowTo(win, ws);
}
inline fn wsMoveWindowExclusive(win: u32, ws: u8) void {
    if (comptime build.has_workspaces) workspaces.moveWindowExclusive(win, ws);
}
inline fn wsTagToggle(win: u32, ws: u8, p: bool) void {
    if (comptime build.has_workspaces) workspaces.tagToggle(win, ws, p);
}
inline fn wsSwitchToAll() void {
    if (comptime build.has_workspaces) workspaces.switchToAll();
}
inline fn wsMoveWindowToAll(win: u32) void {
    if (comptime build.has_workspaces) workspaces.moveWindowToAll(win);
}
inline fn wsTagToggleAll(win: u32) void {
    if (comptime build.has_workspaces) workspaces.tagToggleAll(win);
}


// Constants 

const mouse_button_left:   u8 = 1;
const mouse_button_middle: u8 = 2;
const mouse_button_right:  u8 = 3;

const mouse_buttons = [_]u8{ mouse_button_left, mouse_button_middle, mouse_button_right };

// XKB state 

var xkb_state: ?xkbcommon.XkbState = null;

/// Initialises the XKB context, keymap, and key state
/// from the server's current keyboard configuration.
pub fn initXkb(conn: *xcb.xcb_connection_t) !void {
    xkb_state = try xkbcommon.XkbState.init(conn);
}

/// Tears down XKB state.
/// Must be called after all other deinit steps.
pub fn deinitXkb() void {
    if (xkb_state) |*s| s.deinit();
    xkb_state = null;
}

/// Returns a pointer to the module-owned XkbState, 
/// used by events.zig during config reloads.
pub fn getXkbState() *xkbcommon.XkbState {
    return &xkb_state.?;
}

// Grab setup 

/// Grabs mouse buttons on the root window and applies the user's cursor theme.
pub fn setup(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t, root: u32) void {
    setupGrabs(conn, root);
    XcbCursor.setupRoot(conn, screen);
}

/// Grabs Super+Button{1,2,3} on the root window.
/// Button1 = move, Button3 = resize, Button2 = config-driven mouse binds.
pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    for (mouse_buttons) |button| {
        _ = xcb.xcb_grab_button(
            conn, 0, root,
            xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
                xcb.XCB_EVENT_MASK_POINTER_MOTION,
            xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
            root, xcb.XCB_NONE, button, constants.MOD_SUPER,
        );
    }
    _ = xcb.xcb_flush(conn);
}

// Event handlers 

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void {
    focus.setLastEventTime(event.time);

    const mods = utils.normalizeModifiers(event.state);
    const keysym = xkb_state.?.keycodeToKeysym(event.detail);

    // Linear scan over keybindings. In practice the list is < 50 entries and
    // bounded by what a human can type in a config file, so a flat scan over
    // contiguous memory beats a hash lookup (cache locality, zero allocation).
    var matched: ?*const types.Action = null;
    for (core.config.keybindings.items) |*kb| {
        if (kb.modifiers == mods and kb.keysym == keysym) {
            matched = &kb.action;
            break;
        }
    }

    // The prompt owns all key input while active; routing (including the
    // close_window dismiss shortcut) is handled entirely inside it.
    if (prompt.handlePromptKeypress(event, matched)) return;

    debug.info("[KEY] keycode={} state=0x{x} mods=0x{x} keysym=0x{x}",
        .{ event.detail, event.state, mods, keysym });

    if (matched) |action| {
        debug.info("[KEY] action={s}", .{@tagName(action.*)});
        executeAction(action) catch |err| debug.err("action failed: {}", .{err});
    } else {
        debug.info("[KEY] no binding", .{});
    }
}

/// Dispatches a priority order button-press event
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);

    // Ignore clicks on root / unknown windows
    const clicked_window = if (event.child != 0) event.child else event.event;
    const managed_window = window.findManagedWindow(core.conn, clicked_window, tracking.isManaged);

    if (clicked_window == 0 or clicked_window == core.root or managed_window == 0) {
        replayPointer(event.time);
        return;
    }

    const super_held = (event.state & constants.MOD_SUPER) != 0;

    // Config-driven mouse binds (Super + Key)
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

    // Super + Left/Right: Move or Resize
    if (super_held and (event.detail == mouse_button_left or event.detail == mouse_button_right)) {
        drag.startDrag(managed_window, event.detail, event.root_x, event.root_y);
        releaseGrab(event.time); // Explicitly release and exit
        return;
    }

    // Fallback: Any other click focuses and raises the window.
    //
    // The raise must be issued unconditionally here, before setFocus, because
    // setFocus short-circuits when managed_window is already focused_window
    // (the common case after hover-focus) and never reaches the raise inside
    // commitFocusTransition.  Without this explicit raise, a window that holds
    // focus but has been visually covered — by a newly-spawned window, a
    // floating peer, or any stacking change that bypasses the focus path —
    // stays buried despite the click.  The double-raise when setFocus also
    // raises is a no-op from the server's perspective.
    _ = xcb.xcb_configure_window(core.conn, managed_window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    focus.setFocus(managed_window, .mouse_click);
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

    // Real pointer movement clears any active focus suppression.
    if (focus.getSuppressReason() != .none) focus.setSuppressReason(.none);

    // POINTER_MOTION_HINT delivers one event per gesture; re-arm by sending a
    // QueryPointer. We fire and discard the reply — the server re-arms on
    // receipt of the request, not the reply, so there's no need to block.
    xcb.xcb_discard_reply(core.conn, xcb.xcb_query_pointer(core.conn, core.root).sequence);
}

// Window operations 

/// Closes a window gracefully via WM_DELETE_WINDOW (ICCCM §4.1.2.7), falling
/// back to xcb_destroy_window for clients that don't advertise the protocol.
fn closeWindow(win: u32) void {
    if (!window.supportsWMDeleteCached(core.conn, win)) {
        _ = xcb.xcb_destroy_window(core.conn, win);
        return;
    }

    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch return;
    const delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch return;

    // Zero-initialise: XCB transmits raw bytes, so uninitialised padding
    // would be undefined behaviour on the wire.
    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = win;
    event.type = protocols_atom;
    event.data.data32[0] = delete_atom;
    event.data.data32[1] = focus.getLastEventTime(); // ICCCM §4.1.7

    _ = xcb.xcb_send_event(core.conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

// Action dispatch 

fn executeAction(action: *const types.Action) !void {
    switch (action.*) {
        // Core 
        .close_window  => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => utils.reload(),
        .dump_state    => dumpState(),
        .exec          => |cmd| try executeShellCommand(cmd),
        .sequence      => |acts| for (acts) |*a| try executeAction(a),

        // Fullscreen 
        .toggle_fullscreen => if (comptime build.has_fullscreen) fullscreen.toggle(),

        // Tiling 
        .toggle_floating_window => if (comptime build.has_tiling) {
            if (focus.getFocused()) |win| tiling.toggleWindowFloat(win);
            bar.scheduleFullRedraw();
        },
        .toggle_layout         => if (comptime build.has_tiling) { tiling.toggleLayout();        bar.scheduleRedraw(); },
        .toggle_layout_reverse => if (comptime build.has_tiling) { tiling.toggleLayoutReverse(); bar.scheduleRedraw(); },
        .cycle_layout_variants => if (comptime build.has_tiling) { tiling.stepLayoutVariant(); bar.scheduleRedraw(); },
        .increase_master       => if (comptime build.has_tiling) tiling.increaseMasterWidth(),
        .decrease_master       => if (comptime build.has_tiling) tiling.decreaseMasterWidth(),
        .increase_master_count => if (comptime build.has_tiling) tiling.increaseMasterCount(),
        .decrease_master_count => if (comptime build.has_tiling) tiling.decreaseMasterCount(),

        .swap_master, .swap_master_focus_swap => if (comptime build.has_tiling) {
            _ = xcb.xcb_grab_server(core.conn);
            if (action.* == .swap_master)
                tiling.swapWithMaster()
            else
                tiling.swapWithMasterFollowFocus();
            focus.syncPointerFocusNow();
            window.updateWorkspaceBorders();
            window.markBordersFlushed();
            bar.redrawInsideGrab();
            _ = xcb.xcb_ungrab_server(core.conn);
            _ = xcb.xcb_flush(core.conn);
        },

        // Bar 
        .toggle_bar_visibility => if (comptime build.has_bar) bar.setBarState(.toggle),
        .toggle_bar_position   => if (comptime build.has_bar) bar.toggleBarSegmentAnchor(),

        // Minimize 
        .minimize_window => if (comptime build.has_minimize) minimize.minimizeWindow(),
        .unminimize_lifo => if (comptime build.has_minimize) minimize.unminimize(.lifo),
        .unminimize_fifo => if (comptime build.has_minimize) minimize.unminimize(.fifo),
        .unminimize_all  => if (comptime build.has_minimize) minimize.unminimizeAll(),

        // Workspaces 
        .switch_workspace       => |ws| switchToWs(ws),
        .move_to_workspace      => |ws| if (focus.getFocused()) |win| moveWindowToWs(win, ws) catch |e| debug.warnOnErr(e, "move_to_workspace"),
        .move_window            => |ws| if (focus.getFocused()) |win| wsMoveWindowExclusive(win, ws),
        .toggle_tag             => |ws| if (focus.getFocused()) |win| wsTagToggle(win, ws, true),
        .all_workspaces         => wsSwitchToAll(),
        .move_to_all_workspaces => if (focus.getFocused()) |win| wsMoveWindowToAll(win),
        .toggle_tag_all         => if (focus.getFocused()) |win| wsTagToggleAll(win),

        // Prompt 
        .toggle_prompt => prompt.toggle(),

        // Window focus cycling (dwm-style Mod+k / Mod+j)
        .focus_next_window => focus.focusNext(),
        .focus_prev_window => focus.focusPrev(),
        // Window move in cycle (dwm-style Mod+Shift+k / Mod+Shift+j)
        .move_window_next  => focus.moveWindowNext(),
        .move_window_prev  => focus.moveWindowPrev(),
    }
}

/// Like executeAction but acts on the clicked window rather than the
/// keyboard-focused one. Used by the mouse bind dispatcher so that e.g.
/// toggle_floating_window affects whichever window was actually clicked.
fn executeMouseAction(action: *const types.Action, clicked_win: u32) !void {
    switch (action.*) {
        .toggle_floating_window => if (comptime build.has_tiling) tiling.toggleWindowFloat(clicked_win),
        else             => try executeAction(action),
    }
}

// Shell execution 
//
// Commands are launched via a double-fork so the grandchild is re-parented to
// init and the WM never accumulates zombie processes.
//
// Two pipes co-ordinate the three processes:
//   exec_pipe  – write end is FD_CLOEXEC; exec success closes it silently
//                (EOF), exec failure writes a sentinel byte.
//   pid_pipe   – intermediate child writes the grandchild PID before exiting,
//                so the WM can register the spawn without racing.

/// Grandchild: detaches from the session and execs the command.
/// Writes a sentinel byte to exec_pipe_write on execvp failure.
fn execAsGrandchild(exec_pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    _ = c.setsid();
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
    const sentinel: u8 = 1;
    _ = c.write(exec_pipe_write, &sentinel, 1);
    std.process.exit(1);
}

/// Intermediate child: forks the grandchild, forwards its PID over pid_pipe,
/// then exits so the grandchild is re-parented to init.
fn forkIntermediate(exec_pipe_write: c_int, pid_pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    const grandchild_pid = c.fork();
    if (grandchild_pid < 0) {
        debug.err("Second fork failed", .{});
        std.process.exit(1);
    }
    if (grandchild_pid == 0) {
        _ = c.close(pid_pipe_write); // don't leak into the spawned process
        execAsGrandchild(exec_pipe_write, cmd_z);
    }

    const gp: c_int = grandchild_pid;
    _ = c.write(pid_pipe_write, &gp, @sizeOf(c_int));
    _ = c.close(pid_pipe_write);
    _ = c.close(exec_pipe_write);
    std.process.exit(0);
}

fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the target workspace before any blocking syscalls.  In a
    // single-threaded WM the value cannot change while we are blocked in
    // waitpid/read, but capturing it here makes the intent explicit and
    // correctly handles sequence actions of the form [exec, switch_workspace]
    // where a later action in the same sequence mutates g_current before
    // registerSpawn is called.
    const spawn_ws = tracking.getCurrentWorkspace();

    const cmd_z = try core.alloc.dupeZ(u8, cmd);
    defer core.alloc.free(cmd_z);

    var exec_fds: [2]c_int = undefined;
    var pid_fds: [2]c_int = undefined;

    if (c.pipe(&exec_fds) != 0) {
        debug.err("pipe() failed (exec_pipe): {s}", .{cmd});
        return error.PipeFailed;
    }
    if (c.pipe(&pid_fds) != 0) {
        closePipe(exec_fds);
        debug.err("pipe() failed (pid_pipe): {s}", .{cmd});
        return error.PipeFailed;
    }

    // exec_pipe write end is CLOEXEC: exec success silently closes it (EOF).
    _ = c.fcntl(exec_fds[1], c.F_SETFD, c.FD_CLOEXEC);

    const pid = c.fork();
    if (pid < 0) {
        closePipe(exec_fds);
        closePipe(pid_fds);
        debug.err("First fork failed: {s}", .{cmd});
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.close(exec_fds[0]);
        _ = c.close(pid_fds[0]);
        forkIntermediate(exec_fds[1], pid_fds[1], cmd_z.ptr);
    }

    // WM: close write ends, then reap the intermediate child.
    _ = c.close(exec_fds[1]);
    _ = c.close(pid_fds[1]);

    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) == -1) {
        _ = c.close(exec_fds[0]);
        _ = c.close(pid_fds[0]);
        debug.err("waitpid failed", .{});
        return error.WaitpidFailed;
    }

    // The intermediate child writes the grandchild PID before exiting, so
    // this read is guaranteed not to block by the time waitpid returns.
    var grandchild_pid: c_int = -1;
    _ = c.read(pid_fds[0], &grandchild_pid, @sizeOf(c_int));
    _ = c.close(pid_fds[0]);

    // EOF (n == 0) means exec succeeded; a sentinel byte means it failed.
    var sentinel: u8 = 0;
    const n = c.read(exec_fds[0], &sentinel, 1);
    _ = c.close(exec_fds[0]);
    if (n > 0) return; // exec failed; skip spawn registration

    if (spawn_ws) |ws| {
        const pid_u32: u32 = if (grandchild_pid > 0) @intCast(grandchild_pid) else 0;
        window.registerSpawn(ws, pid_u32);
    }
}

// Diagnostics 

fn dumpState() void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused:        {?x}", .{focus.getFocused()});
    debug.info("Total windows:  {}",   .{tracking.windowCount()});
    debug.info("Suppress focus: {s}",  .{@tagName(focus.getSuppressReason())});
    debug.info("Drag active:    {}",   .{drag.isDragging()});

    if (comptime build.has_fullscreen) {
        fullscreen.forEachFullscreen(struct {
            fn cb(ws: u8, info: fullscreen.FullscreenInfo) void {
                debug.info("Fullscreen on workspace {}: {x}", .{ ws, info.window });
            }
        }.cb);
        if (!fullscreen.hasAnyFullscreen()) debug.info("Fullscreen: none", .{});
    } else {
        debug.info("Fullscreen: none", .{});
    }

    if (comptime build.has_workspaces) {
        if (getWsState()) |ws_state| {
            debug.info("Current workspace: {}", .{ws_state.current + 1});
            for (ws_state.workspaces, 0..) |*ws, i| {
                debug.info("  WS{}: {} windows", .{ i + 1, ws.windows.len });
            }
        }
    }

    if (comptime build.has_tiling) {
        if (tiling.getStateOpt()) |t| {
            debug.info("Tiling enabled: {}",     .{t.is_enabled});
            debug.info("Tiling layout:  {s}",    .{@tagName(t.layout)});
            debug.info("Tiled windows:  {}",     .{t.windows.len});
            debug.info("Master count:   {}",     .{t.master_count});
            debug.info("Master width:   {d:.2}", .{t.master_width});
        }
    }

    debug.info("================================", .{});
}

// Helpers 

/// Replays a frozen pointer event without releasing the keyboard grab.
/// Always pass event.time — never XCB_CURRENT_TIME.
inline fn replayPointer(time: u32) void {
    _ = xcb.xcb_allow_events(core.conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_flush(core.conn);
}

/// Releases both the pointer and keyboard SYNC grabs acquired on Super+click.
/// Always pass event.time — never XCB_CURRENT_TIME.
inline fn releaseGrab(time: u32) void {
    _ = xcb.xcb_allow_events(core.conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_allow_events(core.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, time);
    _ = xcb.xcb_flush(core.conn);
}

inline fn closePipe(p: [2]c_int) void {
    _ = c.close(p[0]);
    _ = c.close(p[1]);
}

// XcbCursor 
//
// Declared manually rather than via cImport because xcb_cursor_load_cursor is
// a static inline function that cImport cannot bind.

const XcbCursor = struct {
    const Context = opaque {};

    extern fn xcb_cursor_context_new(
        conn: *xcb.xcb_connection_t,
        screen: *xcb.xcb_screen_t,
        ctx: *?*Context,
    ) c_int;
    extern fn xcb_cursor_load_cursor(ctx: *Context, name: [*:0]const u8) u32;
    extern fn xcb_cursor_context_free(ctx: ?*Context) void;

    /// Applies the user's cursor theme to the root window. Falls back silently
    /// if xcb-cursor is unavailable or the cursor cannot be loaded.
    fn setupRoot(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) void {
        var cursor_ctx: ?*Context = null;
        if (xcb_cursor_context_new(conn, screen, &cursor_ctx) < 0) return;
        defer xcb_cursor_context_free(cursor_ctx);

        const cursor = xcb_cursor_load_cursor(cursor_ctx.?, "left_ptr");
        if (cursor == xcb.XCB_NONE) return;

        const cookie = xcb.xcb_change_window_attributes_checked(
            conn, screen.*.root, xcb.XCB_CW_CURSOR, &[_]u32{cursor},
        );
        if (xcb.xcb_request_check(conn, cookie)) |err| {
            debug.err("Failed to set root cursor: {*}", .{err});
            std.c.free(err);
        }

        // The server reference-counts cursors, so freeing our handle here is
        // safe — it stays alive as long as the root window holds a reference.
        _ = xcb.xcb_free_cursor(conn, cursor);
    }
};