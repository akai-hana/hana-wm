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

// Shared struct so toggle_floating_window works via both the keybinding path
// (withTilingGrabKeepFocus) and the click path (withTilingGrab).
const ToggleFloatOp = struct {
    win: u32,
    fn call(self: @This()) void {
        tiling.toggleWindowFloat(self.win);
    }
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

/// Rebuilds the keymap/keysym table after the server changes the keyboard
/// mapping (setxkbmap/xmodmap). Keybinding resolution is keysym-indexed, so
/// rebuilding the flat keycode→keysym table keeps existing bindings working
/// under the new layout.
pub fn handleMappingNotify() void {
    const cs = core.getState();
    if (xkb_state) |*s| s.rebuild(cs.conn);
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
fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
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
    const super_held = (event.state & constants.MOD_SUPER) != 0;
    const mods = utils.normalizeModifiers(event.state);

    // The bar selects BUTTON_PRESS directly (not via the Super+Button grab),
    // so a plain click arrives ungrabbed; route it to the bar and skip the
    // managed-window/replay-pointer machinery built for the synchronous grab
    // a client-window click goes through. Super-held clicks fall through to
    // the normal mouse-binding/drag path.
    if (!super_held and bar.isBarWindow(clicked_window)) {
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

    if (super_held) {
        if (tryConfigMouseBind(mods, event.detail, managed_window, event.time)) return;

        if (event.detail == mouse_button_left or event.detail == mouse_button_right) {
            drag.startDrag(managed_window, event.detail, event.root_x, event.root_y);
            // Don't ReplayPointer here — replaying hands the rest of the
            // gesture to the app, which swallows our ButtonRelease before it
            // reaches root, leaving drag.active stuck. keepDragGrab instead
            // uses AsyncPointer so motion/release keep arriving until release.
            keepDragGrab(event.time);
            return;
        }
    }

    // Fallback: any other click focuses and raises. Raise must precede
    // setFocus — it short-circuits when managed_window is already focused,
    // which would leave a covered focused window buried despite the click.
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
    // fire-and-discard QueryPointer. Must run on EVERY path here, including
    // while dragging, or the drag is starved of motion events after the first.
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
            withTilingGrabKeepFocus(tiling.snapScrollToFocused);
        },
        .focus_prev_window => {
            focus.focusPrev();
            withTilingGrabKeepFocus(tiling.snapScrollToFocused);
        },
    }
}

/// Dispatches tiling-related actions, each wrapped in a server grab so the
/// compositor cannot render a partial retile frame.
fn executeTilingAction(action: *const types.Action) void {
    switch (action.*) {
        .toggle_floating_window => if (focus.getFocused()) |win|
            withTilingGrabKeepFocus(ToggleFloatOp{ .win = win }),

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

    // Capture the focused window ID before the swap so we can pass it as
    // defer_configure — the shrinking window fills its new slot before the
    // growing window vacates its old one, eliminating a one-frame gap.
    const new_master = focus.getFocused();
    const displaced = tiling.swapWithMaster();

    // Resolve the displaced window's input model BEFORE the grab: the
    // WM_PROTOCOLS reply wait would implicitly flush the swap's configure_window
    // batch to the compositor mid-grab (see focus.setFocusWithModel).
    const displaced_model: ?window.InputModel = if (action.* == .swap_master_focus_swap)
        if (displaced) |win| window.getInputModel(conn, win) else null
    else
        null;

    utils.grabServer(conn);

    // Follow-focus only: focus MUST move before the retile, or layouts that
    // derive their raised window from focus.getFocused() at retile time
    // (e.g. monocle) retile against the stale window with no follow-up fix.
    if (displaced) |win|
        if (displaced_model) |model| focus.setFocusWithModel(win, .tiling_operation, model);

    tiling.retileCurrentWorkspaceDeferred(new_master);

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
        .toggle_floating_window => withTilingGrab(ToggleFloatOp{ .win = clicked_win }),
        else => try executeAction(action),
    }
}

// Shell execution
//
// Double-fork so the grandchild re-parents to init and the WM never
// accumulates zombies. A single O_CLOEXEC pipe carries the outcome: success
// closes its copy automatically; otherwise the intermediate child writes
// TAG_PID and the grandchild writes TAG_FAILED only if execvp() fails — two
// independently-scheduled writers, so messages can arrive in either order
// (finishSpawn() handles both). EOF ends the conversation; entries resolve via
// drainPendingSpawns() (every event batch) or reapPendingChildren() (SIGCHLD).

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
// 16 execs within the ~100 ms before /bin/sh execs would be inhuman speed.

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

// std.BoundedArray was removed in the Zig 0.16 toolchain; utils.BoundedList
// is the shared fixed-buffer-plus-length stand-in used everywhere this shape
// is needed.
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
    // in mapWindowToScreen when the MapRequest arrives — MapRequest is
    // one-time per window, so the round-trip isn't worth pipelining here.

    const queued = g_pending.append(.{
        .pid = pid,
        .spawn_fd = pipe_fds[0],
        .spawn_ws = spawn_ws,
    });
    if (!queued) {
        // Table full: close the read end we won't track; reap `pid`
        // synchronously — it exits almost instantly and isn't tracked (no zombie).
        _ = c.close(pipe_fds[0]);
        _ = c.waitpid(pid, null, 0);
    }
}

/// Drains pending spawn entries non-blockingly (every event batch and on
/// SIGCHLD), until EOF or a full buffer — a full buffer already holds both
/// possible messages, so EOF needn't be awaited. finishSpawn() classifies.
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
/// Both writes are under PIPE_BUF, so neither is torn or interleaved: a
/// TAG_FAILED byte anywhere is a reliable failure signal in any arrival
/// order; an empty buffer means the second fork() never ran.
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

/// Reaps zombie intermediate children without blocking. Called from the
/// SIGCHLD handler; the spawn-pipe drain stays in events.zig so it doesn't
/// run twice per SIGCHLD.
pub fn reapPendingChildren() void {
    for (g_pending.slice()) |*entry| {
        if (entry.pid > 0 and c.waitpid(entry.pid, null, c.WNOHANG) > 0)
            entry.pid = -1;
    }
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
/// bar, and flushes atomically. `op` is a plain `fn () void`, or — since Zig
/// has no closures — a value-capturing struct with a `call(self) void` method
/// when a window ID must ride along (see toggle_floating_window below).
inline fn withTilingGrab(op: anytype) void {
    withTilingGrabImpl(op, true);
}

/// Like `withTilingGrab`, but skips the pointer-focus resync: on a
/// keyboard-triggered action it could silently move focus onto an unrelated
/// window under the cursor (e.g. a floating window stacked above the target).
///
/// Suppression stays active until reflow crossing events are filtered — see
/// beginTilingOpSettle in focus.zig for why that can't be synchronous.
inline fn withTilingGrabKeepFocus(op: anytype) void {
    withTilingGrabImpl(op, false);
}

inline fn withTilingGrabImpl(op: anytype, sync_pointer: bool) void {
    const conn = core.getState().conn;
    utils.grabServer(conn);
    // X11 fires real crossing events when windows move under a stationary
    // cursor; without suppression they read as hover and steal focus to
    // whichever window transiently ends up under the pointer mid-shuffle.
    focus.setSuppressReason(.tiling_operation);
    switch (@typeInfo(@TypeOf(op))) {
        .@"fn" => op(),
        else => op.call(),
    }
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    bar.redrawInsideGrab();
    if (sync_pointer) {
        // Once the layout has settled, resolve focus against the pointer's
        // resting spot: clears suppression and queues a query that
        // drainPointerSync() consumes next loop (mirrors executeSwapMaster).
        focus.beginPointerSync();
    } else {
        // Suppression still needs clearing, but not synchronously: `op()`'s
        // configure_window calls aren't sent until ungrabAndFlush, so clearing
        // now would disable the filtering too early. beginTilingOpSettle
        // defers it until after reflow crossing events are filtered.
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

/// Releases both SYNC grabs acquired on Super+click, replaying the pointer so
/// the click reaches the app underneath. Only safe for click paths that don't
/// need to keep tracking the pointer afterward — NOT for drag start; use
/// keepDragGrab. Always pass event.time — never XCB_CURRENT_TIME.
inline fn releaseGrab(time: u32) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, time);
    _ = xcb.xcb_flush(conn);
}

/// Un-freezes the pointer for a drag while keeping the Super+Button grab
/// engaged: AsyncPointer resumes delivery without replaying or ending the
/// grab, so MotionNotify/ButtonRelease keep reaching us. The grab ends on
/// release; the keyboard grab drops immediately. Always pass event.time.
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

// XcbCursor — declared manually because xcb_cursor_load_cursor is a static
// inline function cImport cannot bind.

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