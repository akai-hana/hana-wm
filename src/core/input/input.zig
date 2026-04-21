//! User input handling
//! Handles keyboard, mouse buttons, pointer motion, and drag operations.

const std   = @import("std");
const build = @import("build_options");

// libc bindings for fork/exec/wait — no Zig stdlib wrappers exist for these low-level syscalls.
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

const core      = @import("core");
    const xcb   = core.xcb;
const types     = @import("types");
const utils     = @import("utils");
const constants = @import("constants");

const debug  = @import("debug");
const config = @import("config");

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

/// Returns the workspaces.State pointer, or null when workspaces are compiled out.
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

/// Grabs Super+Button{1,2,3} on the root window for all LOCK_MODIFIERS
/// combinations (NumLock, CapsLock, ScrollLock, and their combinations).
/// Button1 = move, Button3 = resize, Button2 = config-driven mouse binds.
pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    for (mouse_buttons) |button| {
        for (constants.LOCK_MODIFIERS) |lock| {
            _ = xcb.xcb_grab_button(
                conn, 0, root,
                xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                    xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
                    xcb.XCB_EVENT_MASK_POINTER_MOTION,
                xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
                root, xcb.XCB_NONE, button, @intCast(constants.MOD_SUPER | lock),
            );
        }
    }
    _ = xcb.xcb_flush(conn);
}

// Event handlers 

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void {
    focus.setLastEventTime(event.time);

    const mods = utils.normalizeModifiers(event.state);
    const keysym = xkb_state.?.keycodeToKeysym(event.detail);

    // O(1) keybinding dispatch via the persistent (modifiers << 32 | keysym) map
    // built by config.resolveKeybindings.  Replaces the previous O(n) linear
    // scan, eliminating up to 50 comparisons per key press.
    const matched: ?*const types.Action = config.lookupKeybinding(mods, keysym);

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

/// Dispatches a priority order button-press event.
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
        if (tryConfigMouseBind(mods, event.detail, managed_window, event.time)) return;
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

/// Stops any active drag and updates the last event timestamp.
pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    if (drag.isDragging()) drag.stopDrag();
}

/// Forwards motion to the drag engine, clears focus suppression, and re-arms POINTER_MOTION_HINT.
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

/// Top-level action dispatcher.  Routes each action tag to the appropriate
/// domain helper.  Only the two error-producing cases (exec and sequence) are
/// handled here directly; all others delegate to void sub-dispatchers.
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

        // Tiling — delegated to executeTilingAction
        .toggle_floating_window,
        .toggle_layout, .toggle_layout_reverse, .cycle_layout_variants,
        .increase_master, .decrease_master, .increase_master_count, .decrease_master_count,
        .swap_master, .swap_master_focus_swap,
        .move_window_next, .move_window_prev,
            => executeTilingAction(action),

        // Bar
        .toggle_bar_visibility => if (comptime build.has_bar) bar.setBarState(.toggle),
        .toggle_bar_position   => if (comptime build.has_bar) bar.toggleBarSegmentAnchor(),

        // Minimize
        .minimize_window => if (comptime build.has_minimize) minimize.minimizeWindow(),
        .unminimize_lifo => if (comptime build.has_minimize) minimize.unminimize(.lifo),
        .unminimize_fifo => if (comptime build.has_minimize) minimize.unminimize(.fifo),
        .unminimize_all  => if (comptime build.has_minimize) minimize.unminimizeAll(),

        // Workspaces — delegated to executeWorkspaceAction
        .switch_workspace, .move_to_workspace, .move_window, .toggle_tag,
        .all_workspaces, .move_to_all_workspaces, .toggle_tag_all,
            => executeWorkspaceAction(action),

        // Prompt
        .toggle_prompt => prompt.toggle(),

        // Window focus cycling (dwm-style Mod+k / Mod+j)
        .focus_next_window => focus.focusNext(),
        .focus_prev_window => focus.focusPrev(),
    }
}

/// Dispatches tiling-related actions, each wrapped in a server grab so the
/// compositor cannot render a partial retile frame.
fn executeTilingAction(action: *const types.Action) void {
    if (comptime !build.has_tiling) return;
    switch (action.*) {
        // toggle_floating_window: wrap in a server grab so that the retile,
        // border sweep, and bar blit all land in one compositor frame.
        // Previously a naked xcb_flush fired after retileCurrentWorkspace but
        // before the border sweep, producing a flash where border colors were
        // wrong for the newly-tiled or newly-floating window.
        .toggle_floating_window => if (focus.getFocused()) |win|
            withTilingGrabAndBordersWin(win, tiling.toggleWindowFloat),

        // Layout and master operations: wrap each retile in a server grab so
        // the compositor cannot render a partial retile frame.  Consistent with
        // swap_master which already uses this pattern for the same reason.
        .toggle_layout         => withTilingGrab(tiling.toggleLayout),
        .toggle_layout_reverse => withTilingGrab(tiling.toggleLayoutReverse),
        .cycle_layout_variants => withTilingGrab(tiling.stepLayoutVariant),
        .increase_master       => withTilingGrab(tiling.increaseMasterWidth),
        .decrease_master       => withTilingGrab(tiling.decreaseMasterWidth),
        .increase_master_count => withTilingGrab(tiling.increaseMasterCount),
        .decrease_master_count => withTilingGrab(tiling.decreaseMasterCount),

        .swap_master, .swap_master_focus_swap => executeSwapMaster(action),

        // Window move in cycle (dwm-style Mod+Shift+k / Mod+Shift+j).
        // Wrapped in a server grab matching swap_master: both swap two windows
        // and retile all others, so without a grab the compositor can render a
        // partial retile frame between individual configure_window calls.
        .move_window_next => withTilingGrabAndBorders(focus.moveWindowNext),
        .move_window_prev => withTilingGrabAndBorders(focus.moveWindowPrev),

        else => {},
    }
}

/// Executes the swap_master / swap_master_focus_swap action inside a server grab.
fn executeSwapMaster(action: *const types.Action) void {
    _ = xcb.xcb_grab_server(core.conn);
    if (action.* == .swap_master) {
        // Capture the focused window ID *before* the swap so we can
        // pass it as defer_configure.  After swapWithMaster() the
        // focused window is the new master (the growing window); by
        // deferring its configure_window call to last inside every
        // column/stack, the shrinking window (old master) fills its new
        // stack slot before the growing window vacates its old one —
        // eliminating the one-frame wallpaper gap (Fix 3).
        const new_master = focus.getFocused();
        tiling.swapWithMaster();
        tiling.retileCurrentWorkspaceDeferred(new_master);
    } else {
        // For follow-focus: capture focused window, reorder, retile
        // with deferred configure, then transfer focus — all inside
        // the grab so the focus border change is part of the same flush.
        const new_master = focus.getFocused();
        const displaced = tiling.swapWithMasterFollowFocus();
        tiling.retileCurrentWorkspaceDeferred(new_master);
        if (displaced) |win| focus.setFocus(win, .tiling_operation);
    }
    // Use the async pointer-sync variant: it queues the xcb_query_pointer
    // cookie without blocking, so no premature XCB buffer flush occurs
    // inside the grab.  drainPointerSync() in the event loop will
    // consume the reply and route focus on the next iteration.
    focus.beginPointerSync();
    window.updateWorkspaceBorders();
    window.markBordersFlushed();
    // redrawInsideGrab now renders to the off-screen pixmap via the bar
    // thread (no xcb_flush) and queues xcb_copy_area without flushing.
    // The blit is sent atomically with configure_window + xcb_ungrab_server
    // by ungrabAndFlush() below — one compositor frame, no wallpaper flash.
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}

/// Dispatches workspace-related actions.
fn executeWorkspaceAction(action: *const types.Action) void {
    switch (action.*) {
        .switch_workspace       => |ws| switchToWs(ws),
        .move_to_workspace      => |ws| if (focus.getFocused()) |win|
            moveWindowToWs(win, ws) catch |e| debug.warnOnErr(e, "move_to_workspace"),
        .move_window            => |ws| if (focus.getFocused()) |win| wsMoveWindowExclusive(win, ws),
        .toggle_tag             => |ws| if (focus.getFocused()) |win| wsTagToggle(win, ws, true),
        .all_workspaces         => wsSwitchToAll(),
        .move_to_all_workspaces => if (focus.getFocused()) |win| wsMoveWindowToAll(win),
        .toggle_tag_all         => if (focus.getFocused()) |win| wsTagToggleAll(win),
        else => {},
    }
}

/// Like executeAction but acts on the clicked window rather than the
/// keyboard-focused one. Used by the mouse bind dispatcher so that e.g.
/// toggle_floating_window affects whichever window was actually clicked.
fn executeMouseAction(action: *const types.Action, clicked_win: u32) !void {
    switch (action.*) {
        // Same grab pattern as the keyboard path in executeAction: retile,
        // border sweep, and bar blit must be atomic from the compositor's view.
        .toggle_floating_window => if (comptime build.has_tiling)
            withTilingGrabAndBordersWin(clicked_win, tiling.toggleWindowFloat),
        else => try executeAction(action),
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

/// Creates an O_CLOEXEC pipe pair atomically via pipe2.
/// pipe2(O_CLOEXEC) sets close-on-exec on both ends in a single syscall,
/// closing the TOCTOU window that existed between the old pipe() and the
/// subsequent fcntl(F_SETFD, FD_CLOEXEC) call.
fn makePipe() ![2]c_int {
    const flags = std.os.linux.O{ .CLOEXEC = true };
    var fds: [2]c_int = undefined;
    return switch (std.posix.errno(std.os.linux.pipe2(&fds, flags))) {
        .SUCCESS => fds,
        else     => error.PipeFailed,
    };
}

/// Spawns `cmd` as a detached grandchild (double-fork) so the WM never accumulates zombie processes.
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

    // exec_pipe write end is CLOEXEC via makePipe — no separate fcntl needed.
    // exec success silently closes it (EOF); exec failure writes a sentinel byte.
    const exec_fds = makePipe() catch {
        debug.err("pipe2() failed (exec_pipe): {s}", .{cmd});
        return error.PipeFailed;
    };
    const pid_fds = makePipe() catch {
        closePipe(exec_fds);
        debug.err("pipe2() failed (pid_pipe): {s}", .{cmd});
        return error.PipeFailed;
    };

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

/// Logs fullscreen state for each workspace, or "none" when compiled out.
fn dumpFullscreenState() void {
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
}

/// Logs current workspace and per-workspace window counts.
/// No-op when workspaces are compiled out.
fn dumpWorkspaceState() void {
    if (comptime !build.has_workspaces) return;
    if (getWsState()) |ws_state| {
        debug.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |_, i| {
            debug.info("  WS{}: {} windows", .{ i + 1, tracking.countWindowsOnWorkspace(@intCast(i)) });
        }
    }
}

/// Logs tiling layout, window count, and master geometry.
/// No-op when tiling is compiled out.
fn dumpTilingState() void {
    if (comptime !build.has_tiling) return;
    if (tiling.getStateOpt()) |t| {
        debug.info("Tiling enabled: {}",     .{t.is_enabled});
        debug.info("Tiling layout:  {s}",    .{@tagName(t.layout)});
        debug.info("Tiled windows:  {}",     .{t.windows.len});
        debug.info("Master count:   {}",     .{t.master_count});
        debug.info("Master width:   {d:.2}", .{t.master_width});
    }
}

/// Logs a full WM state snapshot at info level. Used for diagnostics only.
fn dumpState() void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused:        {?x}", .{focus.getFocused()});
    debug.info("Total windows:  {}",   .{tracking.windowCount()});
    debug.info("Suppress focus: {s}",  .{@tagName(focus.getSuppressReason())});
    debug.info("Drag active:    {}",   .{drag.isDragging()});
    dumpFullscreenState();
    dumpWorkspaceState();
    dumpTilingState();
    debug.info("================================", .{});
}

// Helpers 

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, time: u32) bool {
    for (core.config.mouse_bindings.items) |*mb| {
        if (mb.modifiers == mods and mb.button == button) {
            executeMouseAction(&mb.action, win)
                catch |err| debug.err("mouse bind error: {}", .{err});
            releaseGrab(time);
            return true;
        }
    }
    return false;
}

/// Runs `op()` inside an xcb server grab, redraws the bar, and flushes atomically.
/// Use for layout/master operations where no border sweep is needed.
inline fn withTilingGrab(op: anytype) void {
    _ = xcb.xcb_grab_server(core.conn);
    op();
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}

/// Like withTilingGrab but also sweeps workspace borders after op().
/// Use for operations that reorder or restack windows (move_window_next/prev).
inline fn withTilingGrabAndBorders(op: anytype) void {
    _ = xcb.xcb_grab_server(core.conn);
    op();
    window.updateWorkspaceBorders();
    window.markBordersFlushed();
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}

/// Like withTilingGrabAndBorders but passes `win` as the sole argument to `op`.
/// Use for per-window operations such as toggleWindowFloat.
inline fn withTilingGrabAndBordersWin(win: u32, op: anytype) void {
    _ = xcb.xcb_grab_server(core.conn);
    op(win);
    window.updateWorkspaceBorders();
    window.markBordersFlushed();
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}

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