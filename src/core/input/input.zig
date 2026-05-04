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

const fullscreen = if (build.has_fullscreen) @import("fullscreen");
const minimize   = if (build.has_minimize) @import("minimize");
const tiling     = if (build.has_tiling) @import("tiling");

// Stub struct keeps executeWorkspaceAction guard-free; the comptime if-else
// means stub methods are never analyzed when has_workspaces = true, matching
// the same pattern used by `drag`, `bar`, and `prompt` below.
const workspaces = if (build.has_workspaces) @import("workspaces") else struct {
    pub fn switchTo(_: u8) void {}
    pub fn moveWindowTo(_: u32, _: u8) !void {}
    pub fn moveWindowExclusive(_: u32, _: u8) void {}
    pub fn tagToggle(_: u32, _: u8, _: bool) void {}
    pub fn switchToAll() void {}
    pub fn moveWindowToAll(_: u32) void {}
    pub fn tagToggleAll(_: u32) void {}
};

const drag = if (build.has_drag) @import("drag") else struct {
    pub fn isDragging()                              bool { return false; }
    pub fn stopDrag()                                void {}
    pub fn updateDrag(_: i16, _: i16)               void {}
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

// Constants

const mouse_button_left:        u8 = 1;
const mouse_button_middle:      u8 = 2;
const mouse_button_right:       u8 = 3;
const mouse_button_scroll_up:   u8 = 4;
const mouse_button_scroll_down: u8 = 5;

const mouse_buttons = [_]u8{
    mouse_button_left, mouse_button_middle, mouse_button_right,
    mouse_button_scroll_up, mouse_button_scroll_down,
};

// XKB state

var xkb_state: ?xkbcommon.XkbState = null;

/// Initialises the XKB context, keymap, and key state
/// from the server's current keyboard configuration.
pub fn initXkb(conn: *xcb.xcb_connection_t) !void {
    xkb_state = try xkbcommon.XkbState.init(conn);
}

/// Tears down XKB state. Must be called after all other deinit steps.
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

    const mods   = utils.normalizeModifiers(event.state);
    const keysym = xkb_state.?.keycodeToKeysym(event.detail);

    // O(1) dispatch via the persistent (modifiers << 32 | keysym) map built
    // by config.resolveKeybindings — replaces the former O(n) linear scan.
    const matched: ?*const types.Action = config.lookupKeybinding(mods, keysym);

    // The prompt owns all key input while active; routing is handled inside it.
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

/// Dispatches a priority-ordered button-press event.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);

    const clicked_window = if (event.child != 0) event.child else event.event;
    const managed_window = window.findManagedWindow(core.conn, clicked_window, tracking.isManaged);

    if (clicked_window == 0 or clicked_window == core.root or managed_window == 0) {
        replayPointer(event.time);
        return;
    }

    const super_held = (event.state & constants.MOD_SUPER) != 0;

    // Scroll-wheel binds (buttons 4/5) are viewport actions — check before the
    // managed-window guard that would otherwise discard desktop/bar events.
    if (super_held and (event.detail == mouse_button_scroll_up or event.detail == mouse_button_scroll_down)) {
        _ = tryConfigMouseBind(utils.normalizeModifiers(event.state), event.detail, 0, event.time);
        return;
    }

    if (super_held) {
        if (tryConfigMouseBind(utils.normalizeModifiers(event.state), event.detail, managed_window, event.time)) return;
    }

    if (super_held and (event.detail == mouse_button_left or event.detail == mouse_button_right)) {
        drag.startDrag(managed_window, event.detail, event.root_x, event.root_y);
        releaseGrab(event.time);
        return;
    }

    // Fallback: any other click focuses and raises the window.
    //
    // The raise must be issued unconditionally here, before setFocus, because
    // setFocus short-circuits when managed_window is already focused_window
    // and never reaches the raise inside commitFocusTransition. Without this,
    // a covered window that holds focus stays buried despite the click.
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

    if (focus.getSuppressReason() != .none) focus.setSuppressReason(.none);

    // POINTER_MOTION_HINT delivers one event per gesture; re-arm by sending a
    // QueryPointer. Fire-and-discard — the server re-arms on receipt, not reply.
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

    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS")   catch return;
    const delete_atom    = utils.getAtomCached("WM_DELETE_WINDOW") catch return;

    // Zero-initialise: XCB transmits raw bytes, so uninitialised padding
    // would be undefined behaviour on the wire.
    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type  = xcb.XCB_CLIENT_MESSAGE;
    event.format         = 32;
    event.window         = win;
    event.type           = protocols_atom;
    event.data.data32[0] = delete_atom;
    event.data.data32[1] = focus.getLastEventTime(); // ICCCM §4.1.7

    _ = xcb.xcb_send_event(core.conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

// Action dispatch

/// Top-level action dispatcher. Routes each action tag to the appropriate
/// domain helper. Error-producing cases (exec, sequence) are handled directly.
fn executeAction(action: *const types.Action) !void {
    switch (action.*) {
        // Core
        .close_window  => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => utils.reload(),
        .dump_state    => dumpState(),
        .exec          => |cmd| try executeShellCommand(cmd),
        .sequence      => |acts| for (acts) |*a| try executeAction(a),

        // Fullscreen
        .toggle_fullscreen => if (build.has_fullscreen) fullscreen.toggle(),

        // Tiling — delegated to executeTilingAction
        .toggle_floating_window,
        .toggle_layout, .toggle_layout_reverse, .cycle_layout_variants,
        .increase_master, .decrease_master, .increase_master_count, .decrease_master_count,
        .swap_master, .swap_master_focus_swap,
        .move_window_next, .move_window_prev,
        .scroll_view_left, .scroll_view_right,
            => executeTilingAction(action),

        // Bar
        .toggle_bar_visibility => if (build.has_bar) bar.setBarState(.toggle),
        .toggle_bar_position   => if (build.has_bar) bar.toggleBarSegmentAnchor(),

        // Minimize
        .minimize_window => if (build.has_minimize) minimize.minimizeWindow(),
        .unminimize_lifo => if (build.has_minimize) minimize.unminimize(.lifo),
        .unminimize_fifo => if (build.has_minimize) minimize.unminimize(.fifo),
        .unminimize_all  => if (build.has_minimize) minimize.unminimizeAll(),

        // Workspaces — delegated to executeWorkspaceAction
        .switch_workspace, .move_to_workspace, .move_window, .toggle_tag,
        .all_workspaces, .move_to_all_workspaces, .toggle_tag_all,
            => executeWorkspaceAction(action),

        // Prompt
        .toggle_prompt => prompt.toggle(),

        // Window focus cycling (dwm-style Mod+k / Mod+j).
        // Snaps the scroll-layout viewport to the newly focused window when
        // it is off-screen. The server grab prevents a partial retile frame.
        .focus_next_window => {
            focus.focusNext();
            if (build.has_tiling) withTilingGrab(tiling.snapScrollToFocused);
        },
        .focus_prev_window => {
            focus.focusPrev();
            if (build.has_tiling) withTilingGrab(tiling.snapScrollToFocused);
        },
    }
}

/// Dispatches tiling-related actions, each wrapped in a server grab so the
/// compositor cannot render a partial retile frame.
fn executeTilingAction(action: *const types.Action) void {
    if (!build.has_tiling) return;
    switch (action.*) {
        .toggle_floating_window => if (focus.getFocused()) |win|
            withTilingGrabAndBordersWin(win, tiling.toggleWindowFloat),

        .toggle_layout         => withTilingGrab(tiling.toggleLayout),
        .toggle_layout_reverse => withTilingGrab(tiling.toggleLayoutReverse),
        .cycle_layout_variants => withTilingGrab(tiling.stepLayoutVariant),
        .increase_master       => withTilingGrab(tiling.increaseMasterWidth),
        .decrease_master       => withTilingGrab(tiling.decreaseMasterWidth),
        .increase_master_count => withTilingGrab(tiling.increaseMasterCount),
        .decrease_master_count => withTilingGrab(tiling.decreaseMasterCount),

        .swap_master, .swap_master_focus_swap => executeSwapMaster(action),

        .move_window_next => withTilingGrabAndBorders(focus.moveWindowNext),
        .move_window_prev => withTilingGrabAndBorders(focus.moveWindowPrev),

        .scroll_view_left  => withTilingGrab(tiling.scrollViewLeft),
        .scroll_view_right => withTilingGrab(tiling.scrollViewRight),

        else => {},
    }
}

/// Executes the swap_master / swap_master_focus_swap action inside a server grab.
fn executeSwapMaster(action: *const types.Action) void {
    _ = xcb.xcb_grab_server(core.conn);
    if (action.* == .swap_master) {
        // Capture the focused window ID before the swap so we can pass it as
        // defer_configure — the shrinking window fills its new slot before the
        // growing window vacates its old one, eliminating a one-frame gap.
        const new_master = focus.getFocused();
        if (tiling.swapWithMasterGetWins()) |ws_wins| {
            tiling.retileCurrentWorkspaceDeferredPrebuilt(ws_wins, new_master);
        } else {
            tiling.retileCurrentWorkspaceDeferred(new_master);
        }
    } else {
        // follow-focus: capture, reorder, retile deferred, transfer focus —
        // all inside the grab so the border change is part of the same flush.
        const new_master = focus.getFocused();
        if (tiling.swapWithMasterFollowFocusGetWins()) |result| {
            tiling.retileCurrentWorkspaceDeferredPrebuilt(result.ws_wins, new_master);
            if (result.displaced) |win| focus.setFocus(win, .tiling_operation);
        } else {
            tiling.retileCurrentWorkspaceDeferred(new_master);
        }
    }
    // Async pointer-sync: queues the cookie without blocking so no premature
    // flush occurs inside the grab. drainPointerSync() consumes it next loop.
    focus.beginPointerSync();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    // redrawInsideGrab renders to the off-screen pixmap and queues xcb_copy_area
    // without flushing; ungrabAndFlush sends everything atomically.
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}

/// Dispatches workspace-related actions. The workspaces stub struct ensures
/// calls here are always valid regardless of build.has_workspaces.
fn executeWorkspaceAction(action: *const types.Action) void {
    switch (action.*) {
        .switch_workspace       => |ws| workspaces.switchTo(ws),
        .move_to_workspace      => |ws| if (focus.getFocused()) |win|
            workspaces.moveWindowTo(win, ws) catch |e| debug.warnOnErr(e, "move_to_workspace"),
        .move_window            => |ws| if (focus.getFocused()) |win| workspaces.moveWindowExclusive(win, ws),
        .toggle_tag             => |ws| if (focus.getFocused()) |win| workspaces.tagToggle(win, ws, true),
        .all_workspaces         => workspaces.switchToAll(),
        .move_to_all_workspaces => if (focus.getFocused()) |win| workspaces.moveWindowToAll(win),
        .toggle_tag_all         => if (focus.getFocused()) |win| workspaces.tagToggleAll(win),
        else => {},
    }
}

/// Like executeAction but acts on the clicked window rather than the
/// keyboard-focused one, so e.g. toggle_floating_window affects what was clicked.
fn executeMouseAction(action: *const types.Action, clicked_win: u32) !void {
    switch (action.*) {
        .toggle_floating_window => if (build.has_tiling)
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
//   exec_pipe — write end is O_CLOEXEC; exec success closes it (EOF),
//               exec failure writes a sentinel byte.
//   pid_pipe  — intermediate child writes the grandchild PID before exiting.
//
// executeShellCommand returns immediately after fork(). The pending entry is
// stored in g_pending and resolved asynchronously:
//   drainPendingSpawns()  — called every event batch; does O_NONBLOCK reads.
//   reapPendingChildren() — called on SIGCHLD; targeted waitpid(WNOHANG).

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
        _ = c.close(pid_pipe_write);
        execAsGrandchild(exec_pipe_write, cmd_z);
    }

    const gp: c_int = grandchild_pid;
    _ = c.write(pid_pipe_write, &gp, @sizeOf(c_int));
    _ = c.close(pid_pipe_write);
    _ = c.close(exec_pipe_write);
    std.process.exit(0);
}

/// Creates an O_CLOEXEC|O_NONBLOCK pipe pair atomically via pipe2.
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
// Capacity: 16 is sufficient — firing 16 exec keybindings in the ~100 ms
// window before /bin/sh finishes exec-ing would require inhuman speed.

const MAX_PENDING_SPAWNS: usize = 16;

/// Lifecycle state for a single double-fork spawn.
const PendingSpawn = struct {
    pid:        c_int,  // PID of intermediate child; used for targeted waitpid.
    pid_fd:     c_int,  // Read end of pid_pipe (O_NONBLOCK). -1 after closed.
    exec_fd:    c_int,  // Read end of exec_pipe (O_NONBLOCK). -1 after closed.
    grandchild: c_int,  // Grandchild PID read from pid_pipe. -1 until known.
    spawn_ws:   ?u8,    // Target workspace for window.registerSpawn.
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
        pub fn swapRemove(self: *@This(), i: usize) void {
            self.len -= 1;
            if (i != self.len) self.buffer[i] = self.buffer[self.len];
        }
    };
}

var g_pending: BoundedArray(PendingSpawn, MAX_PENDING_SPAWNS) = .{};

/// Swap-removes the entry at `i`; caller must `continue` the drain loop after.
inline fn removePending(i: usize) void { g_pending.swapRemove(i); }

/// Spawns `cmd` as a detached grandchild (double-fork). Returns immediately —
/// lifecycle is tracked in g_pending and resolved by drainPendingSpawns() /
/// reapPendingChildren() without blocking the event loop.
fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now; correct for sequence actions of the form
    // [exec, switch_workspace] where a later action mutates g_current.
    const spawn_ws = tracking.getCurrentWorkspace();

    const cmd_z = try core.alloc.dupeZ(u8, cmd);
    defer core.alloc.free(cmd_z);

    if (g_pending.len >= MAX_PENDING_SPAWNS)
        debug.warn("spawn: pending table full, spawning '{s}' without workspace routing", .{cmd});

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

    // Fire xcb_query_pointer now to snapshot cursor position for
    // spawn-crossing suppression. Reply is drained lazily by mapWindowToScreen.
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
        // Table full: close the read ends we won't track.
        _ = c.close(pid_fds[0]);
        _ = c.close(exec_fds[0]);
    }
}

/// Drains pending spawn entries non-blockingly.
/// Called every event batch and on SIGCHLD. For each entry:
///   1. pid_fd: non-blocking read for the grandchild PID from the intermediate child.
///   2. exec_fd: non-blocking read — EOF = exec succeeded, sentinel byte = failed,
///      EAGAIN = not yet exec'd, other = hard error treated as failure.
pub fn drainPendingSpawns() void {
    var i: usize = 0;
    while (i < g_pending.len) {
        const entry = &g_pending.slice()[i];

        if (entry.pid_fd >= 0) {
            var gcp: c_int = -1;
            const nr = c.read(entry.pid_fd, &gcp, @sizeOf(c_int));
            if (nr == @sizeOf(c_int)) {
                entry.grandchild = gcp;
                _ = c.close(entry.pid_fd);
                entry.pid_fd = -1;
            } else if (nr < 0 and std.posix.errno(nr) == .AGAIN) {
                // Not ready yet — retry on next call.
            } else {
                _ = c.close(entry.pid_fd); // EOF without data or hard error.
                entry.pid_fd = -1;
            }
        }

        if (entry.exec_fd >= 0) {
            var sentinel: u8 = 0;
            const ne = c.read(entry.exec_fd, &sentinel, 1);
            if (ne == 0) {
                // EOF: exec succeeded — register the spawn.
                if (entry.spawn_ws) |ws| {
                    const pid_u32: u32 = if (entry.grandchild > 0) @intCast(entry.grandchild) else 0;
                    window.registerSpawn(ws, pid_u32);
                }
                _ = c.close(entry.exec_fd);
                removePending(i);
                continue;
            } else if (ne == 1) {
                // Sentinel: exec failed — skip registerSpawn.
                _ = c.close(entry.exec_fd);
                removePending(i);
                continue;
            } else if (ne < 0 and std.posix.errno(ne) == .AGAIN) {
                // Not exec'd yet — retry next call.
            } else {
                // Hard read error — treat as exec failure.
                _ = c.close(entry.exec_fd);
                removePending(i);
                continue;
            }
        }

        i += 1;
    }
}

/// Reaps zombie intermediate children without blocking.
/// Called from the SIGCHLD handler (via the signal self-pipe).
pub fn reapPendingChildren() void {
    for (g_pending.slice()) |*entry| {
        if (entry.pid > 0 and c.waitpid(entry.pid, null, c.WNOHANG) > 0)
            entry.pid = -1;
    }
    drainPendingSpawns();
}

// Diagnostics

/// Logs a full WM state snapshot at info level. Used for diagnostics only.
fn dumpState() void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused:        {?x}", .{focus.getFocused()});
    debug.info("Total windows:  {}",   .{tracking.windowCount()});
    debug.info("Suppress focus: {s}",  .{@tagName(focus.getSuppressReason())});
    debug.info("Drag active:    {}",   .{drag.isDragging()});

    if (build.has_fullscreen) {
        fullscreen.forEachFullscreen(struct {
            fn cb(ws: u8, info: fullscreen.FullscreenInfo) void {
                debug.info("Fullscreen on workspace {}: {x}", .{ ws, info.window });
            }
        }.cb);
        if (!fullscreen.hasAnyFullscreen()) debug.info("Fullscreen: none", .{});
    } else {
        debug.info("Fullscreen: none", .{});
    }

    if (build.has_workspaces) {
        if (workspaces.getState()) |ws_state| {
            debug.info("Current workspace: {}", .{ws_state.current + 1});
            for (ws_state.workspaces, 0..) |_, i|
                debug.info("  WS{}: {} windows", .{ i + 1, tracking.countWindowsOnWorkspace(@intCast(i)) });
        }
    }

    if (build.has_tiling) {
        if (tiling.getStateOpt()) |t| {
            debug.info("Tiling enabled: {}",     .{t.is_enabled});
            debug.info("Tiling layout:  {s}",    .{@tagName(t.config.layout)});
            debug.info("Tiled windows:  {}",     .{t.windows.len});
            debug.info("Master count:   {}",     .{t.config.master_count});
            debug.info("Master width:   {d:.2}", .{t.config.master_width});
        }
    }

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
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(core.conn);
}

/// Like withTilingGrabAndBorders but passes `win` as the sole argument to `op`.
/// Use for per-window operations such as toggleWindowFloat.
inline fn withTilingGrabAndBordersWin(win: u32, op: anytype) void {
    _ = xcb.xcb_grab_server(core.conn);
    op(win);
    window.updateFloatingWindowBorders();
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

        // The server reference-counts cursors; freeing our handle is safe —
        // it stays alive as long as the root window holds a reference.
        _ = xcb.xcb_free_cursor(conn, cursor);
    }
};
