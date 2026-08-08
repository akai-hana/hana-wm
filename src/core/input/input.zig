//! User input handling
//! Handles keyboard, mouse buttons, pointer motion, and drag operations.

const std = @import("std");

// libc bindings for fork/exec/wait (no Zig stdlib wrappers exist for these low-level syscalls)
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
});

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const utils = @import("utils");
const constants = @import("constants");
const debug = @import("debug");
const config = @import("config");
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const fullscreen = @import("fullscreen");
const minimize = @import("minimize");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const drag = @import("drag");
const xkbcommon = @import("xkbcommon");
const bar = @import("bar");
const prompt = @import("prompt");

// Constants

const mouse_button_left: u8 = 1;
const mouse_button_middle: u8 = 2;
const mouse_button_right: u8 = 3;
const mouse_button_scroll_up: u8 = 4;
const mouse_button_scroll_down: u8 = 5;

const mouse_buttons = [_]u8{
    mouse_button_left,      mouse_button_middle,      mouse_button_right,
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
///
/// The returned pointer is invalidated by deinitXkb/initXkb (e.g. during a
/// config reload) — callers must not cache it across those calls.
pub fn getXkbState() *xkbcommon.XkbState {
    return &xkb_state.?;
}

// Grab setup

/// Grabs mouse buttons on the root window and applies the user's cursor theme.
pub fn setup(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t, root: u32) void {
    setupGrabs(conn, root);
    XcbCursor.setupRoot(conn, screen);
}

/// Grabs Super+Button{1,2,3,4,5} (including the scroll buttons) on the root
/// window for all LOCK_MODIFIERS combinations (NumLock, CapsLock,
/// ScrollLock, and their combinations).
pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    for (mouse_buttons) |button| {
        for (constants.LOCK_MODIFIERS) |lock| {
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
                @intCast(constants.MOD_SUPER | lock),
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
    if (prompt.handlePromptKeypress(event, matched)) return;

    debug.info("[KEY] keycode={} state=0x{x} mods=0x{x} keysym=0x{x}", .{ event.detail, event.state, mods, keysym });

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

    const cs = core.getState();
    const clicked_window = if (event.child != 0) event.child else event.event;
    const managed_window = window.findManagedWindow(cs.conn, clicked_window, tracking.isManaged);

    if (clicked_window == 0 or clicked_window == cs.root or managed_window == 0) {
        replayPointer(event.time);
        return;
    }

    const super_held = (event.state & constants.MOD_SUPER) != 0;
    const mods = utils.normalizeModifiers(event.state);

    // Scroll-wheel binds (buttons 4/5) are viewport actions — check before the
    // managed-window guard that would otherwise discard desktop/bar events.
    if (super_held and (event.detail == mouse_button_scroll_up or event.detail == mouse_button_scroll_down)) {
        if (!tryConfigMouseBind(mods, event.detail, 0, event.time)) {
            replayPointer(event.time);
        }
        return;
    }

    if (super_held) {
        if (tryConfigMouseBind(mods, event.detail, managed_window, event.time)) return;
    }

    if (super_held and (event.detail == mouse_button_left or event.detail == mouse_button_right)) {
        drag.startDrag(managed_window, event.detail, event.root_x, event.root_y);
        // Do NOT releaseGrab (ReplayPointer) here. Replaying hands the rest
        // of the gesture to normal event delivery, which almost always means
        // the app itself — real toolkits select ButtonReleaseMask on their
        // own windows, and the pointer sits over that (moving) window for
        // the whole drag. That swallows our ButtonRelease before it ever
        // reaches root, so drag.stopDrag() never runs and drag.active is
        // stuck true until the WM is restarted (see keepDragGrab below).
        // AsyncPointer instead keeps the Super+Button grab from setupGrabs
        // engaged, so MotionNotify/ButtonRelease keep arriving to us — the
        // grab ends automatically once the button is physically released.
        keepDragGrab(event.time);
        return;
    }

    // Fallback: any other click focuses and raises the window. Raise must
    // happen before setFocus — setFocus short-circuits when managed_window
    // is already focused and skips the raise, leaving a covered focused
    // window buried despite the click.
    _ = xcb.xcb_configure_window(cs.conn, managed_window, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
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

    // POINTER_MOTION_HINT delivers one event per gesture; re-arm with a
    // QueryPointer. Fire-and-discard — the server re-arms on receipt, not
    // reply. This must happen on EVERY path through this handler, including
    // while dragging — skipping it here would starve the drag of any motion
    // event after the first, since the hint is not re-armed by anything else.
    const cs = core.getState();
    xcb.xcb_discard_reply(cs.conn, xcb.xcb_query_pointer(cs.conn, cs.root).sequence);

    if (drag.isDragging()) {
        drag.updateDrag(event.root_x, event.root_y);
        return;
    }

    if (focus.getSuppressReason() != .none) focus.setSuppressReason(.none);
}

// Window operations

/// Closes a window gracefully via WM_DELETE_WINDOW (ICCCM §4.1.2.7), falling
/// back to xcb_destroy_window for clients that don't advertise the protocol.
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

    // Zero-initialise: XCB transmits raw bytes, so uninitialised padding
    // would be undefined behaviour on the wire.
    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.window = win;
    event.type = protocols_atom;
    event.data.data32[0] = delete_atom;
    event.data.data32[1] = focus.getLastEventTime(); // ICCCM §4.1.7

    _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
}

// Action dispatch

/// Top-level action dispatcher. Routes each action tag to the appropriate
/// domain helper. Error-producing cases (exec, sequence) are handled directly.
fn executeAction(action: *const types.Action) !void {
    switch (action.*) {
        // Core
        .close_window => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => utils.reload(),
        .dump_state => dumpState(),
        .exec => |cmd| try executeShellCommand(cmd),
        .sequence => |acts| for (acts) |*a| try executeAction(a),

        // Fullscreen
        .toggle_fullscreen => fullscreen.toggle(),

        // Tiling — delegated to executeTilingAction
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

        // Bar
        .toggle_bar_visibility => bar.setBarState(.toggle),
        .toggle_bar_position => bar.toggleBarSegmentAnchor(),

        // Minimize
        .minimize_window => minimize.minimizeWindow(),
        .unminimize_lifo => minimize.unminimize(.lifo),
        .unminimize_fifo => minimize.unminimize(.fifo),
        .unminimize_all => minimize.unminimizeAll(),

        // Workspaces — delegated to executeWorkspaceAction
        .switch_workspace,
        .move_to_workspace,
        .move_window,
        .toggle_tag,
        .all_workspaces,
        .move_to_all_workspaces,
        .toggle_tag_all,
        => executeWorkspaceAction(action),

        // Prompt
        .toggle_prompt => prompt.toggle(),

        // Window focus cycling (dwm-style Mod+k / Mod+j).
        // Snaps the scroll-layout viewport to the newly focused window when
        // it is off-screen. The server grab prevents a partial retile frame.
        .focus_next_window => {
            focus.focusNext();
            withTilingGrab(tiling.snapScrollToFocused);
        },
        .focus_prev_window => {
            focus.focusPrev();
            withTilingGrab(tiling.snapScrollToFocused);
        },
    }
}

/// Dispatches tiling-related actions, each wrapped in a server grab so the
/// compositor cannot render a partial retile frame.
fn executeTilingAction(action: *const types.Action) void {
    switch (action.*) {
        .toggle_floating_window => if (focus.getFocused()) |win|
            withTilingGrabKeepFocus(struct {
                win: u32,
                fn call(self: @This()) void {
                    tiling.toggleWindowFloat(self.win);
                }
            }{ .win = win }),

        .toggle_layout => withTilingGrab(tiling.toggleLayout),
        .toggle_layout_reverse => withTilingGrab(tiling.toggleLayoutReverse),
        .cycle_layout_variants => withTilingGrab(tiling.stepLayoutVariant),
        .increase_master => withTilingGrab(tiling.increaseMasterWidth),
        .decrease_master => withTilingGrab(tiling.decreaseMasterWidth),
        .increase_master_count => withTilingGrab(tiling.increaseMasterCount),
        .decrease_master_count => withTilingGrab(tiling.decreaseMasterCount),
        .grow_stack_top => withTilingGrab(tiling.growTopSlave),
        .grow_stack_bottom => withTilingGrab(tiling.growBottomSlave),

        .swap_master, .swap_master_focus_swap => executeSwapMaster(action),

        .move_window_next => withTilingGrab(focus.moveWindowNext),
        .move_window_prev => withTilingGrab(focus.moveWindowPrev),

        .scroll_view_left => withTilingGrab(tiling.scrollViewLeft),
        .scroll_view_right => withTilingGrab(tiling.scrollViewRight),

        else => {},
    }
}

/// Executes the swap_master / swap_master_focus_swap action inside a server grab.
fn executeSwapMaster(action: *const types.Action) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_grab_server(conn);
    if (action.* == .swap_master) {
        // Capture the focused window ID before the swap so we can pass it as
        // defer_configure — the shrinking window fills its new slot before the
        // growing window vacates its old one, eliminating a one-frame gap.
        const new_master = focus.getFocused();
        _ = tiling.swapWithMaster();
        tiling.retileCurrentWorkspaceDeferred(new_master);
    } else {
        // follow-focus: capture, reorder, transfer focus, retile deferred —
        // all inside the grab so the border change is part of the same flush.
        //
        // Focus MUST be transferred before the retile: layouts that derive
        // their visible/raised window from focus.getFocused() at retile time
        // (e.g. monocle — see monocle.zig's tileWithOffset) would otherwise
        // retile against the stale, about-to-be-displaced window, then have
        // no follow-up retile to correct course once focus actually moves.
        const new_master = focus.getFocused();
        const displaced = tiling.swapWithMaster();
        if (displaced) |win| focus.setFocus(win, .tiling_operation);
        tiling.retileCurrentWorkspaceDeferred(new_master);
    }
    // Async pointer-sync: queues the cookie without blocking so no premature
    // flush occurs inside the grab. drainPointerSync() consumes it next loop.
    focus.beginPointerSync();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    // redrawInsideGrab renders to the off-screen pixmap and queues xcb_copy_area
    // without flushing; ungrabAndFlush sends everything atomically.
    bar.redrawInsideGrab();
    utils.ungrabAndFlush(conn);
}

/// Dispatches workspace-related actions. workspaces.zig self-gates to a
/// single implicit workspace when core.getState().config.workspaces.enabled
/// is false, so these calls are always valid regardless of that setting.
fn executeWorkspaceAction(action: *const types.Action) void {
    switch (action.*) {
        .switch_workspace => |ws| workspaces.switchTo(ws),
        .move_to_workspace => |ws| if (focus.getFocused()) |win|
            workspaces.moveWindowTo(win, ws) catch |e| debug.warnOnErr(e, "move_to_workspace"),
        .move_window => |ws| if (focus.getFocused()) |win| workspaces.moveWindowExclusive(win, ws),
        .toggle_tag => |ws| if (focus.getFocused()) |win| workspaces.tagToggle(win, ws, true),
        .all_workspaces => workspaces.switchToAll(),
        .move_to_all_workspaces => if (focus.getFocused()) |win| workspaces.moveWindowToAll(win),
        .toggle_tag_all => if (focus.getFocused()) |win| workspaces.tagToggleAll(win),
        else => {},
    }
}

/// Like executeAction but acts on the clicked window rather than the
/// keyboard-focused one, so e.g. toggle_floating_window affects what was clicked.
fn executeMouseAction(action: *const types.Action, clicked_win: u32) !void {
    switch (action.*) {
        .toggle_floating_window => withTilingGrab(struct {
            win: u32,
            fn call(self: @This()) void {
                tiling.toggleWindowFloat(self.win);
            }
        }{ .win = clicked_win }),
        else => try executeAction(action),
    }
}

// Shell execution
//
// Commands run via a double-fork so the grandchild re-parents to init and
// the WM never accumulates zombies. A single O_CLOEXEC pipe (see
// utils.makePipe) carries the outcome: a successful execvp() closes its
// copy automatically, so nothing is sent on success. Otherwise the
// intermediate child always writes TAG_PID (its child's pid) right before
// exiting, and the grandchild writes TAG_FAILED only if execvp() fails —
// two independently-scheduled writers, so the two messages can arrive in
// either order (finishSpawn() handles both). EOF ends the conversation.
//
// executeShellCommand returns right after fork(). The pending entry then
// lives in g_pending until drainPendingSpawns() (polled every event batch)
// or reapPendingChildren() (SIGCHLD) resolves it.

/// Tags for the two possible messages written onto the spawn pipe. Sent as
/// a leading byte so the reader can tell them apart no matter which order
/// they arrive in (see finishSpawn()).
const TAG_PID: u8 = 0;
const TAG_FAILED: u8 = 1;

/// Byte length of a TAG_PID message: the tag plus a raw c_int.
const PID_MSG_LEN: usize = 1 + @sizeOf(c_int);

/// Grandchild: detaches from the session and execs the command.
/// On execvp failure, writes a TAG_FAILED byte to pipe_write before exiting.
/// On success this function never returns far enough to write anything —
/// pipe_write's O_CLOEXEC copy closes itself as part of the exec.
fn execAsGrandchild(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    _ = c.setsid();
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
    const msg = [1]u8{TAG_FAILED};
    _ = c.write(pipe_write, &msg, msg.len);
    std.process.exit(1);
}

/// Intermediate child: forks the grandchild, forwards its PID over the
/// spawn pipe tagged as TAG_PID, then exits so the grandchild is
/// re-parented to init.
fn forkIntermediate(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    const grandchild_pid = c.fork();
    if (grandchild_pid < 0) {
        debug.err("Second fork failed", .{});
        std.process.exit(1);
    }
    if (grandchild_pid == 0) {
        // Grandchild: keep pipe_write open rather than closing it up front.
        // Its copy is O_CLOEXEC, so a successful execvp() closes it for us;
        // execAsGrandchild only writes to it explicitly if exec fails.
        execAsGrandchild(pipe_write, cmd_z);
    }

    const gp: c_int = grandchild_pid;
    var msg: [PID_MSG_LEN]u8 = undefined;
    msg[0] = TAG_PID;
    @memcpy(msg[1..], std.mem.asBytes(&gp));
    _ = c.write(pipe_write, &msg, msg.len);
    _ = c.close(pipe_write);
    std.process.exit(0);
}

// Pending spawn table
//
// Capacity: 16 is sufficient — firing 16 exec keybindings in the ~100 ms
// window before /bin/sh finishes exec-ing would require inhuman speed.

const MAX_PENDING_SPAWNS: usize = 16;

/// Largest possible spawn-pipe conversation: a TAG_PID message plus an
/// optional trailing (or leading) TAG_FAILED byte.
const SPAWN_MSG_MAX: usize = PID_MSG_LEN + 1;

/// Lifecycle state for a single double-fork spawn.
const PendingSpawn = struct {
    pid: c_int, // PID of intermediate child; used for targeted waitpid.
    spawn_fd: c_int, // Read end of the spawn pipe (O_NONBLOCK). -1 once done.
    buf: [SPAWN_MSG_MAX]u8 = undefined, // Accumulates bytes until the conversation ends.
    len: usize = 0, // Valid bytes accumulated in buf so far.
    spawn_ws: ?u8, // Target workspace for window.registerSpawn.
};

// std.BoundedArray is not available in the standard library (removed as of
// the Zig 0.16 toolchain this project targets); utils.BoundedList is the
// shared fixed-buffer-plus-length stand-in used everywhere this shape is
// needed.
var g_pending: utils.BoundedList(PendingSpawn, MAX_PENDING_SPAWNS) = .{};

/// Swap-removes the entry at `i`; caller must `continue` the drain loop after.
/// Order doesn't matter here — pending spawns aren't replayed in sequence.
inline fn removePending(i: usize) void {
    g_pending.swapRemove(i);
}

/// Spawns `cmd` as a detached grandchild (double-fork). Returns immediately —
/// lifecycle is tracked in g_pending and resolved by drainPendingSpawns() /
/// reapPendingChildren() without blocking the event loop.
fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now; correct for sequence actions of the form
    // [exec, switch_workspace] where a later action mutates g_current.
    const spawn_ws = tracking.getCurrentWorkspace();

    const alloc = core.getState().alloc;
    const cmd_z = try alloc.dupeZ(u8, cmd);
    defer alloc.free(cmd_z);

    if (g_pending.len >= MAX_PENDING_SPAWNS)
        debug.warn("spawn: pending table full, spawning '{s}' without workspace routing", .{cmd});

    const pipe_fds = utils.makePipe() catch {
        debug.err("pipe2() failed (spawn pipe): {s}", .{cmd});
        return error.PipeFailed;
    };

    const pid = c.fork();
    if (pid < 0) {
        closePipe(pipe_fds);
        debug.err("First fork failed: {s}", .{cmd});
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.close(pipe_fds[0]);
        forkIntermediate(pipe_fds[1], cmd_z.ptr);
    }

    // Parent: close the write end so our read end eventually sees EOF.
    _ = c.close(pipe_fds[1]);

    // Cursor position for spawn-crossing suppression is queried synchronously
    // by window.mapWindowToScreen when the MapRequest actually arrives, rather
    // than prefetched here at key-press time: MapRequest is a one-time event
    // per window, so that round-trip isn't worth pipelining ahead of time.

    const queued = g_pending.append(.{
        .pid = pid,
        .spawn_fd = pipe_fds[0],
        .spawn_ws = spawn_ws,
    });
    if (!queued) {
        // Table full: close the read end we won't track.
        _ = c.close(pipe_fds[0]);
        // `pid` (the intermediate child) isn't in g_pending, so
        // reapPendingChildren's waitpid loop will never wait on it. It
        // exits almost instantly (one more fork() + a 5-byte write +
        // exit()), so a synchronous reap here is cheap and bounded, and
        // avoids leaving a permanent zombie behind.
        _ = c.waitpid(pid, null, 0);
    }
}

/// Drains pending spawn entries non-blockingly (every event batch and on
/// SIGCHLD). Bytes accumulate into entry.buf until EOF or until the buffer
/// is full — a full buffer already holds both possible messages, so there's
/// no need to wait for EOF too. finishSpawn() classifies the result.
pub fn drainPendingSpawns() void {
    var i: usize = 0;
    while (i < g_pending.len) {
        const entry = &g_pending.slice()[i];

        if (entry.spawn_fd >= 0) {
            const n = c.read(entry.spawn_fd, &entry.buf[entry.len], entry.buf.len - entry.len);
            if (n > 0) {
                entry.len += @intCast(n);
                if (entry.len == entry.buf.len) {
                    // Buffer full: both possible messages have necessarily
                    // arrived already — no need to wait for EOF too.
                    _ = c.close(entry.spawn_fd);
                    entry.spawn_fd = -1;
                }
            } else if (n < 0 and std.posix.errno(n) == .AGAIN) {
                // Not ready yet — retry on the next call.
            } else {
                // EOF (n == 0) or a hard read error: conversation is over.
                _ = c.close(entry.spawn_fd);
                entry.spawn_fd = -1;
            }
        }

        if (entry.spawn_fd >= 0) {
            i += 1;
            continue;
        }

        finishSpawn(entry);
        removePending(i);
    }
}

/// Classifies a fully-drained spawn-pipe conversation and, on success,
/// registers the spawn for workspace routing.
///
/// Both writes (TAG_PID's PID_MSG_LEN bytes, TAG_FAILED's single byte) are
/// well under PIPE_BUF, so neither is ever torn or interleaved — a
/// TAG_FAILED byte anywhere in the buffer is a reliable failure signal
/// regardless of arrival order, and an empty buffer means the second
/// fork() never completed.
fn finishSpawn(entry: *PendingSpawn) void {
    const data = entry.buf[0..entry.len];

    var grandchild: c_int = -1;
    var failed = data.len == 0;

    var idx: usize = 0;
    while (idx < data.len) {
        switch (data[idx]) {
            TAG_PID => {
                if (idx + PID_MSG_LEN > data.len) {
                    failed = true;
                    break;
                }
                grandchild = std.mem.bytesToValue(c_int, data[idx + 1 ..][0..@sizeOf(c_int)]);
                idx += PID_MSG_LEN;
            },
            TAG_FAILED => {
                failed = true;
                idx += 1;
            },
            else => {
                failed = true;
                break;
            },
        }
    }

    if (!failed) {
        if (entry.spawn_ws) |ws| {
            const pid_u32: u32 = if (grandchild > 0) @intCast(grandchild) else 0;
            window.registerSpawn(ws, pid_u32);
        }
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
    debug.info("Total windows:  {}", .{tracking.windowCount()});
    debug.info("Suppress focus: {s}", .{@tagName(focus.getSuppressReason())});
    debug.info("Drag active:    {}", .{drag.isDragging()});

    fullscreen.forEachFullscreen(struct {
        fn cb(ws: u8, info: fullscreen.FullscreenInfo) void {
            debug.info("Fullscreen on workspace {}: {x}", .{ ws, info.window });
        }
    }.cb);
    if (!fullscreen.hasAnyFullscreen()) debug.info("Fullscreen: none", .{});

    if (workspaces.getState()) |ws_state| {
        debug.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |_, i|
            debug.info("  WS{}: {} windows", .{ i + 1, tracking.countWindowsOnWorkspace(@intCast(i)) });
    }

    if (tiling.getStateOpt()) |t| {
        debug.info("Tiling enabled: {}", .{t.is_enabled});
        debug.info("Tiling layout:  {s}", .{@tagName(t.config.layout)});
        debug.info("Tiled windows:  {}", .{t.windows.len});
        debug.info("Master count:   {}", .{t.config.master_count});
        debug.info("Master width:   {d:.2}", .{t.config.master_width});
        debug.info("Stack balance:  {d:.2} (+ = top slave grown, - = bottom slave grown)", .{t.config.stack_balance});
    }

    debug.info("================================", .{});
}

// Helpers

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, time: u32) bool {
    for (core.getState().config.mouse_bindings.items) |*mb| {
        if (mb.modifiers == mods and mb.button == button) {
            executeMouseAction(&mb.action, win) catch |err| debug.err("mouse bind error: {}", .{err});
            releaseGrab(time);
            return true;
        }
    }
    return false;
}

/// Runs `op` inside an xcb server grab, then sweeps borders, redraws the
/// bar, and flushes atomically. Used for every tiling/layout/master op.
///
/// `op` is a plain `fn () void`, or — since Zig has no closures — a small
/// value-capturing struct with a `call(self) void` method when a window ID
/// needs to ride along (see toggle_floating_window below).
inline fn withTilingGrab(op: anytype) void {
    withTilingGrabImpl(op, true);
}

/// Like `withTilingGrab`, but does not re-sync focus to whatever window is
/// currently under the pointer afterward.
///
/// Used for actions that already have an explicit, keyboard-chosen target
/// window (e.g. toggle_floating_window's keybind path). The pointer-sync
/// step exists so mouse-driven reflows (layout changes, master swaps) hand
/// focus to whichever window physically ends up under a stationary cursor.
/// But when the action was itself keyboard-triggered against a specific
/// window, that same step can silently move keyboard focus onto a
/// completely different, unrelated window the cursor merely happens to be
/// resting over (e.g. a floating window stacked on top of the one just
/// acted on) — so a second, un-intended keypress (autorepeat, a fast
/// double-tap, etc.) then lands on that other window instead of the one
/// the user was just interacting with.
///
/// This guarantee depends on suppression staying active until any crossing
/// events the reflow itself generates have actually been delivered and
/// filtered — see beginTilingOpSettle's doc comment in focus.zig for why
/// that can't just be done synchronously here.
inline fn withTilingGrabKeepFocus(op: anytype) void {
    withTilingGrabImpl(op, false);
}

inline fn withTilingGrabImpl(op: anytype, sync_pointer: bool) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_grab_server(conn);
    // Suppress EnterNotify events generated as a side effect of windows
    // moving/resizing under a stationary cursor during this reflow — X11
    // fires real crossing events for that, not just for cursor motion, and
    // without this they get processed as genuine hover and steal focus to
    // whatever window transiently ends up under the pointer mid-shuffle.
    focus.setSuppressReason(.tiling_operation);
    switch (@typeInfo(@TypeOf(op))) {
        .@"fn" => op(),
        else => op.call(),
    }
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    bar.redrawInsideGrab();
    if (sync_pointer) {
        // Once the layout has settled, resolve focus against where the pointer
        // actually rests — mirrors executeSwapMaster's use of the same call.
        // Clears the suppression above and queues an authoritative query that
        // drainPointerSync() consumes on the next event-loop iteration.
        focus.beginPointerSync();
    } else {
        // No pointer resync — but suppression still needs clearing eventually,
        // or hover-focus stays masked until some other action happens to call
        // beginPointerSync. It must NOT be cleared synchronously here, though:
        // the configure_window calls queued above by `op()` are not sent to
        // the X server until ungrabAndFlush below, so clearing suppression
        // now would turn EnterNotify filtering back off before the server has
        // even processed the reflow that suppression exists to mask — letting
        // a real crossing event (e.g. a neighbour window's edge sliding under
        // a stationary cursor) slip through unfiltered and silently steal
        // focus. beginTilingOpSettle defers the clear to the next
        // event-dispatch iteration, after any such event is guaranteed to
        // have already been dispatched and filtered. See its doc comment in
        // focus.zig for the full ordering argument.
        focus.beginTilingOpSettle();
    }
    utils.ungrabAndFlush(conn);
}

/// Replays a frozen pointer event without releasing the keyboard grab.
/// Always pass event.time — never XCB_CURRENT_TIME.
inline fn replayPointer(time: u32) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_flush(conn);
}

/// Releases both the pointer and keyboard SYNC grabs acquired on Super+click.
/// Replays the pointer, so the triggering click is handed to normal event
/// delivery (i.e. to the app underneath). Only safe for click paths that
/// don't need to keep tracking pointer events afterward — NOT for drag
/// start; use keepDragGrab for that. Always pass event.time — never
/// XCB_CURRENT_TIME.
inline fn releaseGrab(time: u32) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, time);
    _ = xcb.xcb_flush(conn);
}

/// Un-freezes the pointer for a drag gesture while keeping the Super+Button
/// grab from setupGrabs (root, SYNC, event_mask BUTTON_PRESS|BUTTON_RELEASE|
/// POINTER_MOTION) engaged — AsyncPointer resumes delivery without replaying
/// or ending the grab, unlike releaseGrab's ReplayPointer. That guarantees
/// the drag's MotionNotify/ButtonRelease keep arriving to us (dispatched to
/// input.handleMotionNotify/handleButtonRelease) instead of going straight
/// to whichever client window the cursor ends up over. The grab ends on its
/// own once the button is physically released, so no matching "reacquire"
/// call is needed. The keyboard grab is released immediately since dragging
/// doesn't need it held. Always pass event.time — never XCB_CURRENT_TIME.
inline fn keepDragGrab(time: u32) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_ASYNC_POINTER, time);
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, time);
    _ = xcb.xcb_flush(conn);
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
            conn,
            screen.*.root,
            xcb.XCB_CW_CURSOR,
            &[_]u32{cursor},
        );
        if (xcb.xcb_request_check(conn, cookie)) |err| {
            debug.err("Failed to set root cursor: error_code={}", .{err.*.error_code});
            std.c.free(err);
        }

        // The server reference-counts cursors; freeing our handle is safe —
        // it stays alive as long as the root window holds a reference.
        _ = xcb.xcb_free_cursor(conn, cursor);
    }
};