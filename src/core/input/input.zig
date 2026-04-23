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
const drag = if (build.has_drag) @import("drag") else struct {
    pub fn isDragging()                          bool { return false; }
    pub fn stopDrag()                            void {}
    pub fn updateDrag(_: i16, _: i16)            void {}
    pub fn startDrag(_: u32, _: u8, _: i16, _: i16) void {}
};

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
        //
        // Use swapWithMasterGetWins so the window list built during the
        // swap is passed directly into retile, avoiding a redundant
        // collectWorkspaceWindows scan on this hot path (Issue 3 fix).
        const new_master = focus.getFocused();
        if (tiling.swapWithMasterGetWins()) |ws_wins| {
            tiling.retileCurrentWorkspaceDeferredPrebuilt(ws_wins, new_master);
        } else {
            tiling.retileCurrentWorkspaceDeferred(new_master);
        }
    } else {
        // For follow-focus: capture focused window, reorder, retile
        // with deferred configure, then transfer focus — all inside
        // the grab so the focus border change is part of the same flush.
        // swapWithMasterFollowFocusGetWins returns the pre-built window
        // slice alongside the displaced window, eliminating the second
        // collectWorkspaceWindows call in retile (Issue 3 fix).
        const new_master = focus.getFocused();
        if (tiling.swapWithMasterFollowFocusGetWins()) |result| {
            tiling.retileCurrentWorkspaceDeferredPrebuilt(result.ws_wins, new_master);
            if (result.displaced) |win| focus.setFocus(win, .tiling_operation);
        } else {
            tiling.retileCurrentWorkspaceDeferred(new_master);
        }
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
//
// Previously the WM blocked on waitpid()+read() in the main event loop,
// stalling input and X-event processing for the duration of two fork() calls
// (typically 2–30 ms on weak hardware where page-table copying is slow).
//
// Now executeShellCommand returns immediately after fork().  The pending entry
// is stored in g_pending and resolved asynchronously:
//   • drainPendingSpawns()  – called every event batch; does O_NONBLOCK reads
//   • reapPendingChildren() – called on SIGCHLD; targeted waitpid(WNOHANG)
//
// All pipe FDs are created O_CLOEXEC|O_NONBLOCK so reads never stall the loop.

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

/// Creates an O_CLOEXEC|O_NONBLOCK pipe pair atomically via pipe2.
///
/// O_NONBLOCK on the read ends prevents the WM's event loop from stalling
/// when drainPendingSpawns() polls pipes whose data is not yet ready.
/// O_NONBLOCK on the write ends is harmless: the payloads are ≤4 bytes,
/// well within the PIPE_BUF atomic-write guarantee, so partial writes cannot
/// occur regardless of the non-blocking flag.
fn makePipe() ![2]c_int {
    const flags = std.os.linux.O{ .CLOEXEC = true, .NONBLOCK = true };
    var fds: [2]c_int = undefined;
    return switch (std.posix.errno(std.os.linux.pipe2(&fds, flags))) {
        .SUCCESS => fds,
        else     => error.PipeFailed,
    };
}

// Pending spawn table
//
// executeShellCommand stores one entry per fork() and returns immediately.
// drainPendingSpawns() is called from the event loop and from the SIGCHLD
// handler to process entries non-blockingly.
//
// Capacity: 16 is more than enough.  Firing 16 exec keybindings in the
// ~100 ms window before /bin/sh finishes exec-ing would require inhuman speed.

const MAX_PENDING_SPAWNS: usize = 16;

/// Lifecycle state for a single double-fork spawn.
const PendingSpawn = struct {
    /// PID of the intermediate (first) child.  Used for targeted waitpid.
    pid:        c_int,
    /// Read end of pid_pipe (O_NONBLOCK).  -1 after closed.
    pid_fd:     c_int,
    /// Read end of exec_pipe (O_NONBLOCK).  -1 after closed.
    exec_fd:    c_int,
    /// Grandchild PID read from pid_pipe.  -1 until known.
    grandchild: c_int,
    /// Target workspace for window.registerSpawn.
    spawn_ws:   ?u8,
};

fn BoundedArray(comptime T: type, comptime cap: usize) type {
    return struct {
        buffer: [cap]T = undefined,
        len: usize = 0,
        pub fn appendAssumeCapacity(self: *@This(), item: T) void {
            self.buffer[self.len] = item;
            self.len += 1;
        }
        pub fn slice(self: *@This()) []T { return self.buffer[0..self.len]; }
        pub fn swapRemove(self: *@This(), i: usize) T {
            const val = self.buffer[i];
            self.len -= 1;
            if (i != self.len) self.buffer[i] = self.buffer[self.len];
            return val;
        }
    };
}

var g_pending: BoundedArray(PendingSpawn, MAX_PENDING_SPAWNS) = .{};

/// Spawns `cmd` as a detached grandchild (double-fork).
/// Returns immediately — lifecycle is tracked in g_pending and resolved
/// by drainPendingSpawns() / reapPendingChildren() without blocking the loop.
fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now.  The event loop is single-threaded so
    // g_current cannot change while we run, but capturing it here is correct
    // for sequence actions of the form [exec, switch_workspace] where a later
    // action in the same sequence mutates g_current before registerSpawn fires.
    const spawn_ws = tracking.getCurrentWorkspace();

    const cmd_z = try core.alloc.dupeZ(u8, cmd);
    defer core.alloc.free(cmd_z);

    if (g_pending.len >= MAX_PENDING_SPAWNS) {
        // Extremely rare: 16 concurrent unresolved spawns.  Fall back to a
        // fire-and-forget spawn with no workspace routing rather than dropping
        // the user's command.
        debug.warn("spawn: pending table full, spawning '{s}' without workspace routing", .{cmd});
    }

    // Both pipes are O_CLOEXEC|O_NONBLOCK (see makePipe).
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

    // Parent: close write ends so our read ends eventually see EOF.
    _ = c.close(exec_fds[1]);
    _ = c.close(pid_fds[1]);

    // Fire xcb_query_pointer now (key-press time) to snapshot the cursor
    // position for spawn-crossing suppression.  The reply is NOT drained here;
    // it will be sitting in the XCB socket buffer by the time MapRequest arrives
    // (app startup takes at least tens of ms), so mapWindowToScreen drains it
    // for free with no added round-trip latency.
    window.prefetchSpawnPointer();

    if (g_pending.len < MAX_PENDING_SPAWNS) {
        g_pending.appendAssumeCapacity(.{
            .pid        = pid,
            .pid_fd     = pid_fds[0],
            .exec_fd    = exec_fds[0],
            .grandchild = -1,
            .spawn_ws   = spawn_ws,
        });
    } else {
        // Table full: close the read ends we won't track; intermediate child
        // will be reaped by the SIGCHLD handler's waitpid loop.
        _ = c.close(pid_fds[0]);
        _ = c.close(exec_fds[0]);
    }
}

/// Drain pending spawn entries non-blockingly.
///
/// Called every event batch and on SIGCHLD.  For each entry:
///   1. If pid_fd is still open, attempt a non-blocking read to obtain the
///      grandchild PID written by the intermediate child.
///   2. If exec_fd is still open, attempt a non-blocking read:
///        EOF (n == 0)    → exec succeeded; call registerSpawn; remove entry.
///        sentinel byte   → exec failed;    skip registration; remove entry.
///        EAGAIN          → grandchild has not exec'd yet; retry next call.
///
/// The intermediate child is reaped via reapPendingChildren() (SIGCHLD path),
/// keeping this function free of any blocking syscall.
pub fn drainPendingSpawns() void {
    var i: usize = 0;
    while (i < g_pending.len) {
        const entry = &g_pending.slice()[i];

        // Step 1: read grandchild PID from pid_pipe (written before the
        // intermediate child exits, so it becomes available shortly after fork).
        if (entry.pid_fd >= 0) {
            var gcp: c_int = -1;
            const nr = c.read(entry.pid_fd, &gcp, @sizeOf(c_int));
            if (nr == @sizeOf(c_int)) {
                entry.grandchild = gcp;
                _ = c.close(entry.pid_fd);
                entry.pid_fd = -1;
            } else if (nr < 0 and
                std.posix.errno(nr) == .AGAIN)
            {
                // Not ready yet — pid_pipe stays open; retry on next call.
            } else {
                // EOF without data or hard error: intermediate fork failed.
                _ = c.close(entry.pid_fd);
                entry.pid_fd = -1;
            }
        }

        // Step 2: read exec result from exec_pipe.
        // The write end is CLOEXEC in the grandchild: exec success closes it
        // (EOF); exec failure writes a sentinel byte then exits.
        if (entry.exec_fd >= 0) {
            var sentinel: u8 = 0;
            const ne = c.read(entry.exec_fd, &sentinel, 1);
            if (ne == 0) {
                // EOF: exec succeeded.
                if (entry.spawn_ws) |ws| {
                    const pid_u32: u32 = if (entry.grandchild > 0) @intCast(entry.grandchild) else 0;
                    window.registerSpawn(ws, pid_u32);
                }
                _ = c.close(entry.exec_fd);
                _ = g_pending.swapRemove(i);
                continue; // slot i now holds the swapped-in tail entry
            } else if (ne == 1) {
                // Sentinel byte: exec failed — skip registerSpawn.
                _ = c.close(entry.exec_fd);
                _ = g_pending.swapRemove(i);
                continue;
            } else if (ne < 0 and
                std.posix.errno(ne) == .AGAIN)
            {
                // Grandchild has not exec'd yet — retry next call.
            } else {
                // Hard read error — treat as exec failure.
                _ = c.close(entry.exec_fd);
                _ = g_pending.swapRemove(i);
                continue;
            }
        }

        i += 1;
    }
}

/// Reap zombie intermediate children without blocking.
/// Called from the SIGCHLD signal handler (via the signal self-pipe).
/// Uses targeted waitpid so we only reap the PIDs we forked, leaving any
/// other children (e.g., popen) to their own reaping paths.
pub fn reapPendingChildren() void {
    for (g_pending.slice()) |*entry| {
        if (entry.pid > 0) {
            if (c.waitpid(entry.pid, null, c.WNOHANG) > 0) {
                entry.pid = -1; // reaped; pipe draining continues independently
            }
        }
    }
    // Drain any pipe data that just became available due to the child exiting.
    drainPendingSpawns();
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
