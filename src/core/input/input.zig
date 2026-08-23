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
const workspaces = @import("workspaces");
const xkbcommon = @import("xkbcommon");
const build_options = @import("build_options");
const pipeline = @import("pipeline");
const actions = @import("actions");
const bar = if (build_options.has_bar) @import("bar") else null;
const tiling = if (build_options.has_tiling) @import("tiling") else null;
const floating = if (build_options.has_floating) @import("floating") else null;

// Constants

const mouse_button_middle: u8 = 2;
const mouse_button_scroll_up: u8 = 4;
const mouse_button_scroll_down: u8 = 5;

const mouse_buttons = [_]u8{
    constants.mouse_button_left, mouse_button_middle,      constants.mouse_button_right,
    mouse_button_scroll_up,      mouse_button_scroll_down,
};

// Named adapter functions for tiling actions that need argument forwarding.

// XKB state

var xkb_state: ?xkbcommon.XkbState = null;

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

/// Returns a pointer to the module-owned XkbState,
/// used by events.zig during config reloads.
///
/// The returned pointer is invalidated by deinitXkb/initXkb (e.g. during a
/// config reload); callers must not cache it across those calls.
pub fn getXkbState() *xkbcommon.XkbState {
    return &xkb_state.?;
}

/// Rebuilds the keymap/keysym table after the server changes the keyboard
/// mapping (setxkbmap/xmodmap). Keybinding resolution is keysym-indexed, so
/// rebuilding the flat keycode->keysym table keeps existing bindings working
/// under the new layout.
pub fn handleMappingNotify() void {
    const cs = core.getState();
    if (xkb_state) |*s| s.rebuild(cs.conn);
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
        for (constants.lock_modifiers) |lock| {
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
                @intCast(constants.mod_super | lock),
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
    if (build_options.has_bar) if (bar.promptHandleKeypress(event, matched)) return;

    if (matched) |action| {
        debug.info("[KEY] keycode={} state=0x{x} mods=0x{x} keysym=0x{x}", .{ event.detail, event.state, mods, keysym });
        debug.info("[KEY] action={s}", .{@tagName(action.*)});
        executeAction(action);
    } else if (mods == 0 and keysym >= 0xffe1 and keysym <= 0xffee) {
        // Bare modifier press (Shift/Ctrl/Alt/Super/Hyper L/R): can never
        // match a binding; staying silent keeps logs free of keystroke noise.
    } else {
        debug.info("[KEY] keycode={} state=0x{x} mods=0x{x} keysym=0x{x}", .{ event.detail, event.state, mods, keysym });
        debug.info("[KEY] no binding", .{});
    }
}

/// Dispatches a priority-ordered button-press event.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);

    const cs = core.getState();
    const clicked_window = if (event.child != 0) event.child else event.event;
    const super_held = (event.state & constants.mod_super) != 0;
    const mods = utils.normalizeModifiers(event.state);

    // The bar selects BUTTON_PRESS directly (not via the Super+Button grab),
    // so a plain click arrives ungrabbed; route it to the bar and skip the
    // managed-window/replay-pointer machinery built for the synchronous grab
    // a client-window click goes through. Super-held clicks fall through to
    // the normal mouse-binding/drag path.
    if (!super_held and build_options.has_bar and bar.isBarWindow(clicked_window)) {
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

    if (!super_held) {
        _ = xcb.xcb_configure_window(cs.conn, managed_window, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
        focus.setFocus(managed_window, .mouse_click);
        releaseGrab(event.time);
        return;
    }

    if (tryConfigMouseBind(mods, event.detail, managed_window, event.time)) return;

    if (event.detail == constants.mouse_button_left or event.detail == constants.mouse_button_right) {
        if (build_options.has_floating) floating.startDrag(managed_window, event.detail, event.root_x, event.root_y);
        keepDragGrab(event.time);
        return;
    }
}

/// Stops any active drag and updates the last event timestamp.
pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    if (build_options.has_floating and floating.isDragging()) floating.stopDrag();
}

/// Forwards motion to the drag engine and clears focus suppression.
/// Raw PointerMotion is coalesced upstream (events.handleXcbEvents collapses
/// runs to the last event), so this runs at most once per poll wakeup.
pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t) void {
    focus.setLastEventTime(event.time);

    if (build_options.has_floating and floating.isDragging()) {
        floating.updateDrag(event.root_x, event.root_y);
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
    const delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch return forceDestroy(conn, win);

    sendWmDelete(conn, win, protocols_atom, delete_atom);
}

// Action dispatch

/// PIPELINE: per-dispatch action context for the new path (train a+).
var action_ctx: actions.Ctx = .{};
var mouse_ctx: actions.Ctx = .{};

inline fn focusedId() ?u32 {
    return focus.getFocused();
}

/// Top-level action dispatcher. Routes each action tag to the appropriate
/// domain helper. Errors are handled internally.
fn executeAction(action: *const types.Action) void {
    switch (action.*) {
        // Core
        .close_window => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => utils.reload(),
        .dump_state => dumpState(),
        .exec => |cmd| executeShellCommand(cmd) catch |err| debug.err("exec failed: {}", .{err}),
        .sequence => |acts| for (acts) |*a| executeAction(a),

        // Fullscreen
        .toggle_fullscreen => actions.fullscreenToggle(&action_ctx), // WP6

        // Tiling, delegated to executeTilingAction
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
        .toggle_bar_visibility => if (build_options.has_bar) bar.setBarState(.toggle),
        .toggle_bar_position => if (build_options.has_bar) bar.toggleBarSegmentAnchor(),

        // Minimize
        .minimize_window => actions.minimize(&action_ctx, focusedId()), // WP6
        .unminimize_lifo => actions.restoreLifo(&action_ctx), // WP6
        .unminimize_fifo => actions.restoreFifo(&action_ctx), // WP6
        .unminimize_all => actions.restoreAll(&action_ctx), // WP6

        // Workspaces, delegated to executeWorkspaceAction
        .switch_workspace,
        .move_to_workspace,
        .toggle_tag,
        .all_workspaces,
        .move_to_all_workspaces,
        .toggle_tag_all,
        => executeWorkspaceAction(action),

        // Prompt
        .toggle_prompt => if (build_options.has_bar) bar.promptToggle(),

        // Window focus cycling (dwm-style Mod+k / Mod+j).
        // Snaps the scroll-layout viewport to the newly focused window when
        // it is off-screen. The server grab prevents a partial retile frame.
        .focus_next_window => {
            focus.focusNext();
            actions.snapScrollToFocused(&action_ctx); // PIPELINE: WP6
        },
        .focus_prev_window => {
            focus.focusPrev();
            actions.snapScrollToFocused(&action_ctx); // PIPELINE: WP6
        },
    }
}

/// Dispatches tiling-related actions, each wrapped in a server grab so the
/// compositor cannot render a partial retile frame.
fn executeTilingAction(action: *const types.Action) void {
    switch (action.*) {
        .toggle_floating_window => if (focus.getFocused()) |win| {
            focus.setSuppressReason(.tiling_operation);
            actions.toggleFloating(&action_ctx, win);
            focus.beginTilingOpSettle();
        },
        .toggle_layout => {
            focus.setSuppressReason(.tiling_operation);
            actions.cycleLayoutKind(&action_ctx, 1);
            focus.beginTilingOpSettle();
        },
        .toggle_layout_reverse => {
            focus.setSuppressReason(.tiling_operation);
            actions.cycleLayoutKind(&action_ctx, -1);
            focus.beginTilingOpSettle();
        },
        .cycle_layout_variants => {
            focus.setSuppressReason(.tiling_operation);
            actions.stepVariant(&action_ctx);
            focus.beginTilingOpSettle();
        },
        .increase_master => actions.adjustMasterWidthAction(&action_ctx, 0.025),
        .decrease_master => actions.adjustMasterWidthAction(&action_ctx, -0.025),
        .increase_master_count => actions.adjustMasterCount(&action_ctx, 1),
        .decrease_master_count => actions.adjustMasterCount(&action_ctx, -1),
        .grow_stack_top => actions.adjustStackBalance(&action_ctx, 0.5),
        .grow_stack_bottom => actions.adjustStackBalance(&action_ctx, -0.5),

        .swap_master, .swap_master_focus_swap => actions.swapMasterAction(&action_ctx, action.* == .swap_master_focus_swap),

        .move_window_next => actions.moveFocused(&action_ctx, 1),
        .move_window_prev => actions.moveFocused(&action_ctx, -1),

        .scroll_view_left => actions.scrollStep(&action_ctx, -1),
        .scroll_view_right => actions.scrollStep(&action_ctx, 1),

        else => unreachable,
    }
}

/// Dispatches workspace-related actions. workspaces.zig self-gates to a
/// single implicit workspace when core.getState().config.workspaces.enabled
/// is false, so these calls are always valid regardless of that setting.
fn executeWorkspaceAction(action: *const types.Action) void {
    switch (action.*) {
        .switch_workspace => |ws| actions.switchTo(&action_ctx, ws), // WP6
        .move_to_workspace => |ws| if (focusedId()) |wid| actions.moveWindowTo(&action_ctx, wid, ws), // WP6
        .toggle_tag => |ws| if (focusedId()) |wid| actions.tagToggle(&action_ctx, wid, ws, true), // WP6
        .all_workspaces => actions.allViewToggle(&action_ctx), // WP6
        .move_to_all_workspaces, .toggle_tag_all => if (focusedId()) |wid| actions.pinToggle(&action_ctx, wid), // WP6
        else => unreachable,
    }
}

/// Like executeAction but acts on the clicked window rather than the
/// keyboard-focused one, so e.g. toggle_floating_window affects what was clicked.
fn executeMouseAction(action: *const types.Action, clicked_win: u32) void {
    switch (action.*) {
        .toggle_floating_window => { // WP6
            focus.setSuppressReason(.tiling_operation);
            actions.toggleFloating(&mouse_ctx, clicked_win);
            focus.beginTilingOpSettle();
        },
        else => executeAction(action),
    }
}

// Shell execution
//
// Double-fork so the grandchild re-parents to init and the WM never
// accumulates zombies. A single O_CLOEXEC pipe carries the outcome: success
// closes its copy automatically; otherwise the intermediate child writes
// tag_pid and the grandchild writes tag_failed only if execvp() fails; two
// independently-scheduled writers, so messages can arrive in either order
// (finishSpawn() handles both). EOF ends the conversation; entries resolve via
// drainPendingSpawns() (every event batch) or reapPendingChildren() (SIGCHLD).

/// Tags for the two possible messages written onto the spawn pipe. Sent as
/// a leading byte so the reader can tell them apart no matter which order
/// they arrive in (see finishSpawn()).
const tag_pid: u8 = 0;
const tag_failed: u8 = 1;

/// Byte length of a tag_pid message: the tag plus a raw c_int.
const pid_msg_len: usize = 1 + @sizeOf(c_int);

/// Grandchild: detaches from the session and execs the command.
/// On execvp failure, writes a tag_failed byte to pipe_write before exiting.
/// On success this function never returns far enough to write anything;
/// pipe_write's O_CLOEXEC copy closes itself as part of the exec.
fn execAsGrandchild(pipe_write: c_int, cmd_z: [*:0]const u8) noreturn {
    _ = c.setsid();
    _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z, null }));
    const msg = [1]u8{tag_failed};
    _ = c.write(pipe_write, &msg, msg.len);
    std.process.exit(1);
}

/// Intermediate child: forks the grandchild, forwards its PID over the
/// spawn pipe tagged as tag_pid, then exits so the grandchild is
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
    var msg: [pid_msg_len]u8 = undefined;
    msg[0] = tag_pid;
    @memcpy(msg[1..], std.mem.asBytes(&gp));
    _ = c.write(pipe_write, &msg, msg.len);
    _ = c.close(pipe_write);
    std.process.exit(0);
}

// Pending spawn table
//
// 16 execs within the ~100 ms before /bin/sh execs would be inhuman speed.

const max_pending_spawns: usize = 16;

/// Largest possible spawn-pipe conversation: a tag_pid message plus an
/// optional trailing (or leading) tag_failed byte.
const spawn_msg_max: usize = pid_msg_len + 1;

/// Lifecycle state for a single double-fork spawn.
const PendingSpawn = struct {
    pid: c_int, // PID of intermediate child; used for targeted waitpid.
    spawn_fd: c_int, // Read end of the spawn pipe (O_NONBLOCK). -1 once done.
    buf: [spawn_msg_max]u8 = undefined, // Accumulates bytes until the conversation ends.
    len: usize = 0, // Valid bytes accumulated in buf so far.
    spawn_ws: ?u8, // Target workspace for window.registerSpawn.
};

// std.BoundedArray was removed in the Zig 0.16 toolchain; utils.BoundedList
// is the shared fixed-buffer-plus-length stand-in used everywhere this shape
// is needed.
var g_pending: utils.BoundedList(PendingSpawn, max_pending_spawns) = .{};

/// Spawns `cmd` as a detached grandchild (double-fork). Returns immediately;
/// lifecycle is tracked in g_pending and resolved by drainPendingSpawns() /
/// reapPendingChildren() without blocking the event loop.
fn executeShellCommand(cmd: []const u8) !void {
    // Snapshot the workspace now; correct for sequence actions of the form
    // [exec, switch_workspace] where a later action mutates g_current.
    const spawn_ws = tracking.getCurrentWorkspace();

    var cmd_buf: [256]u8 = undefined;
    var heap_cmd_z: ?[:0]const u8 = null;
    defer if (heap_cmd_z) |h| core.getState().alloc.free(h);
    const cmd_z: [*:0]const u8 = if (cmd.len < cmd_buf.len) blk: {
        @memcpy(cmd_buf[0..cmd.len], cmd);
        cmd_buf[cmd.len] = 0;
        break :blk @ptrCast(&cmd_buf[0]);
    } else blk: {
        const owned = try core.getState().alloc.dupeZ(u8, cmd);
        heap_cmd_z = owned;
        break :blk owned.ptr;
    };

    if (g_pending.len >= max_pending_spawns)
        debug.warn("spawn: pending table full, spawning '{s}' without workspace routing", .{cmd});

    const pipe_fds = utils.makePipe() catch {
        debug.err("pipe2() failed (spawn pipe): {s}", .{cmd});
        return error.PipeFailed;
    };

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipe_fds[0]);
        _ = c.close(pipe_fds[1]);
        debug.err("First fork failed: {s}", .{cmd});
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = c.close(pipe_fds[0]);
        forkIntermediate(pipe_fds[1], cmd_z);
    }

    // Parent: close the write end so our read end eventually sees EOF.
    _ = c.close(pipe_fds[1]);

    // Cursor position for spawn-crossing suppression is queried synchronously
    // in mapWindowToScreen when the MapRequest arrives; MapRequest is
    // one-time per window, so the round-trip isn't worth pipelining here.

    const queued = g_pending.append(.{
        .pid = pid,
        .spawn_fd = pipe_fds[0],
        .spawn_ws = spawn_ws,
    });
    if (!queued) {
        // Table full: close the read end we won't track; reap `pid`
        // synchronously; it exits almost instantly and isn't tracked (no zombie).
        _ = c.close(pipe_fds[0]);
        _ = c.waitpid(pid, null, 0);
    }
}

/// Drains pending spawn entries non-blockingly (every event batch and on
/// SIGCHLD), until EOF or a full buffer; a full buffer already holds both
/// possible messages, so EOF needn't be awaited. finishSpawn() classifies.
pub fn drainPendingSpawns() void {
    if (g_pending.len == 0) return;
    var i: usize = 0;
    while (i < g_pending.len) {
        const entry = &g_pending.slice()[i];

        if (entry.spawn_fd >= 0) {
            const n = c.read(entry.spawn_fd, &entry.buf[entry.len], entry.buf.len - entry.len);
            if (n > 0) {
                entry.len += @intCast(n);
                if (entry.len == entry.buf.len) {
                    // Buffer full: both possible messages have necessarily
                    // arrived already; no need to wait for EOF too.
                    _ = c.close(entry.spawn_fd);
                    entry.spawn_fd = -1;
                }
            } else if (n < 0 and std.posix.errno(n) == .AGAIN) {
                // Not ready yet; retry on the next call.
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
        g_pending.swapRemove(i);
    }
}

/// Classifies a fully-drained spawn-pipe conversation and, on success,
/// registers the spawn for workspace routing.
///
/// Both writes are under PIPE_BUF, so neither is torn or interleaved: a
/// tag_failed byte anywhere is a reliable failure signal in any arrival
/// order; an empty buffer means the second fork() never ran.
fn finishSpawn(entry: *PendingSpawn) void {
    const data = entry.buf[0..entry.len];

    var grandchild: c_int = -1;
    var failed = data.len == 0;

    var idx: usize = 0;
    while (idx < data.len) {
        switch (data[idx]) {
            tag_pid => {
                if (idx + pid_msg_len > data.len) {
                    failed = true;
                    break;
                }
                grandchild = std.mem.bytesToValue(c_int, data[idx + 1 ..][0..@sizeOf(c_int)]);
                idx += pid_msg_len;
            },
            tag_failed => {
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
            window.registerSpawn(core.WorkspaceId.fromIndex(ws), pid_u32);
        }
    }
}

/// Reaps zombie intermediate children without blocking. Called from the
/// SIGCHLD handler; the spawn-pipe drain stays in signals.zig so it doesn't
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
    debug.info("Drag active:    {}", .{build_options.has_floating and floating.isDragging()});

    // Fullscreen truth: scan the model store (the legacy record store is gone).
    {
        const m = pipeline.model();
        var any_fs = false;
        for (0..m.store.count()) |i| {
            const it = m.store.at(i);
            if (it.val.mode != .fullscreen) continue;
            any_fs = true;
            debug.info("Fullscreen on workspace {}: {x}", .{ it.val.mode.fullscreen.ws, it.key });
        }
        if (!any_fs) debug.info("Fullscreen: none", .{});
    }

    if (workspaces.getState()) |ws_state| {
        // Live source (tracking is dual-written by switchTo); the legacy
        // workspaces.State.current mirror lags when read mid-switch.
        const cur_ws = tracking.getCurrentWorkspace() orelse 0;
        debug.info("Current workspace: {}", .{cur_ws + 1});
        for (ws_state.workspaces, 0..) |_, i|
            debug.info("  WS{}: {} windows", .{ i + 1, tracking.countWindowsOnWorkspace(core.WorkspaceId.fromIndex(@intCast(i))) });
    }

    if (build_options.has_tiling and tiling.isEnabled()) {
        debug.info("Tiling enabled: true", .{});
        debug.info("Tiling layout:  {s}", .{@tagName(tiling.getCurrentLayout())});
        // Count from the model (WP5 truth), not the legacy pool: the pool is
        // no longer fed on the model spawn path, so its length would read 0.
        debug.info("Tiled windows:  {}", .{tracking.tiledCountOnCurrent()});
    }

    debug.info("================================", .{});
}

// Helpers

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, time: u32) bool {
    for (core.getState().config.mouse_bindings.items) |*mb| {
        if (mb.modifiers == mods and mb.button == button) {
            executeMouseAction(&mb.action, win);
            releaseGrab(time);
            return true;
        }
    }
    return false;
}

/// Runs `op` inside an xcb server grab, then sweeps borders, redraws the
/// Replays a frozen pointer event without releasing the keyboard grab.
/// Always pass event.time, never XCB_CURRENT_TIME.
inline fn replayPointer(time: u32) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_flush(conn);
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
