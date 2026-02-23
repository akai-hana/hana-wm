//! Input handling — keyboard, mouse buttons, pointer motion, drag operations.

const std        = @import("std");
const defs       = @import("defs");
const xkbcommon  = @import("xkbcommon");
const utils      = @import("utils");
const focus      = @import("focus");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const drag       = @import("drag");
const fullscreen = @import("fullscreen");
const bar        = @import("bar");
const window     = @import("window");
const debug      = @import("debug");
const minimize   = @import("minimize");
const lifecycle  = @import("lifecycle");
const xcb        = defs.xcb;
const WM         = defs.WM;

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
});

const MOUSE_BUTTON_LEFT:  u8 = 1;
const MOUSE_BUTTON_RIGHT: u8 = 3;
const MOUSE_BUTTONS = [_]u8{ MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT };

// Keybind state

const KeybindState = struct {
    map: std.AutoHashMap(u64, *const defs.Action),

    fn init(allocator: std.mem.Allocator) KeybindState {
        return .{ .map = std.AutoHashMap(u64, *const defs.Action).init(allocator) };
    }

    fn deinit(self: *KeybindState) void { self.map.deinit(); }

    fn rebuild(self: *KeybindState, wm: *WM) !void {
        self.map.clearRetainingCapacity();
        try self.map.ensureTotalCapacity(@intCast(wm.config.keybindings.items.len));
        for (wm.config.keybindings.items) |*kb| {
            self.map.putAssumeCapacity(makeHash(kb.modifiers, kb.keysym), &kb.action);
        }
    }
};

var keybind_state: ?KeybindState = null;

pub fn init(wm: *WM) void {
    var state = KeybindState.init(wm.allocator);
    state.rebuild(wm) catch |err| {
        debug.err("Failed to build keybind map: {}", .{err});
        state.deinit();
        return;
    };
    keybind_state = state;
}

pub fn deinit() void {
    if (keybind_state) |*state| { state.deinit(); keybind_state = null; }
}

/// Rebuilds the keybind lookup map from the current config (called after reload).
pub fn rebuildKeybindMap(wm: *WM) !void {
    if (keybind_state) |*state| {
        try state.rebuild(wm);
    } else {
        return error.KeybindStateNotInitialized;
    }
}

inline fn makeHash(mods: u16, keysym: u32) u64 {
    return (@as(u64, mods) << 32) | keysym;
}

// Grab setup

/// Grabs Super+Button1 (move) and Super+Button3 (resize) on the root window.
pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    for (MOUSE_BUTTONS) |button| {
        _ = xcb.xcb_grab_button(
            conn, 0, root,
            xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.XCB_EVENT_MASK_POINTER_MOTION,
            xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
            root, xcb.XCB_NONE, button, defs.MOD_SUPER,
        );
    }
    utils.flush(conn);
}

// Event handlers 

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    var state = &(keybind_state orelse return);
    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));

    const mods   = utils.normalizeModifiers(event.state);
    const keysym = xkb_ptr.keycodeToKeysym(event.detail);
    const key    = makeHash(mods, keysym);

    debug.info("[KEY] keycode={} state=0x{x} mods=0x{x} keysym=0x{x} hash=0x{x}",
        .{ event.detail, event.state, mods, keysym, key });

    if (state.map.get(key)) |action| {
        debug.info("[KEY] action found: {s}", .{@tagName(action.*)});
        executeAction(action, wm) catch |err| debug.err("Failed to execute action: {}", .{err});
    } else {
        debug.info("[KEY] no binding found for this key", .{});
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    const clicked_window = if (event.child != 0) event.child else event.event;

    if (clicked_window == 0 or clicked_window == wm.root) {
        // XCB_ALLOW_REPLAY_POINTER must carry the timestamp of the frozen event
        // so the server can identify which passive-grab event to replay.
        // XCB_CURRENT_TIME (0) does not match the stored timestamp and can cause
        // the click to be silently discarded rather than delivered to the window.
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
        utils.flush(wm.conn);
        return;
    }

    const managed_window = utils.findManagedWindow(wm.conn, clicked_window, workspaces.isManaged);

    if (managed_window == 0 or managed_window == wm.root or workspaces.getWorkspaceForWindow(managed_window) == null) {
        _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, event.time);
        utils.flush(wm.conn);
        return;
    }

    if ((event.state & defs.MOD_SUPER) != 0 and
        (event.detail == MOUSE_BUTTON_LEFT or event.detail == MOUSE_BUTTON_RIGHT)) {
        drag.startDrag(wm, managed_window, event.detail, event.root_x, event.root_y);
    } else {
        focus.setFocus(wm, managed_window, .mouse_click);
    }

    // Release the SYNC grab so events are not permanently frozen.
    // Both calls must carry the original event timestamp — XCB_ALLOW_REPLAY_POINTER
    // uses it to identify which frozen button-press event should be replayed to the
    // target window.  XCB_CURRENT_TIME (0) does not match the server's stored event
    // timestamp, which can cause the click to be silently dropped.
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER,  event.time);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, event.time);
    utils.flush(wm.conn);
}

pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    if (drag.isDragging(wm)) drag.stopDrag(wm);
}

pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    wm.last_event_time = event.time;
    if (drag.isDragging(wm)) {
        drag.updateDrag(wm, event.root_x, event.root_y);
        return;
    }
    // Real mouse movement lifts window-spawn focus suppression.
    if (wm.suppress_focus_reason == .window_spawn) wm.suppress_focus_reason = .none;
    // POINTER_MOTION_HINT delivers only one event per gesture; re-arm by querying
    // the pointer so the next movement generates a new MotionNotify.
    if (xcb.xcb_query_pointer_reply(wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root), null)) |reply|
        std.c.free(reply);
}

// Window close

/// Ask `win` to close itself politely, or forcibly destroy it if it doesn't
/// support WM_DELETE_WINDOW.  The WM_PROTOCOLS property was scanned at map
/// time and cached, so this path never blocks on an X11 round-trip.
fn closeWindow(wm: *WM, win: u32) void {
    if (win == wm.root) { debug.err("Attempted to close ROOT window!", .{}); return; }

    if (utils.supportsWMDeleteCached(wm.conn, win)) {
        sendDeleteEvent(wm, win);
    } else {
        forceDestroyWindow(wm, win);
    }
}

/// Send a WM_DELETE_WINDOW client message (ICCCM §4.1.2.7).
/// Uses wm.last_event_time as the timestamp — ICCCM §4.1.7 requires the
/// timestamp of the user action that triggered the close, not XCB_CURRENT_TIME.
fn sendDeleteEvent(wm: *WM, win: u32) void {
    const protocols_atom = utils.getAtomCached("WM_PROTOCOLS")    catch return;
    const delete_atom    = utils.getAtomCached("WM_DELETE_WINDOW") catch return;
    var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
    event.response_type  = xcb.XCB_CLIENT_MESSAGE;
    event.format         = 32;
    event.window         = win;
    event.type           = protocols_atom;
    event.data.data32[0] = delete_atom;
    event.data.data32[1] = wm.last_event_time;
    _ = xcb.xcb_send_event(wm.conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
    utils.flush(wm.conn);
}

fn forceDestroyWindow(wm: *WM, win: u32) void {
    _ = xcb.xcb_destroy_window(wm.conn, win);
    utils.flush(wm.conn);
}

// Action dispatch 

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .toggle_fullscreen      => fullscreen.toggleFullscreen(wm),
        .close_window           => { if (wm.focused_window) |win| closeWindow(wm, win); },
        .reload_config          => {
            debug.info("[RELOAD] flag set by keybinding", .{});
            lifecycle.reload();
        },
        .toggle_layout          => { tiling.toggleLayout(wm);        bar.redrawImmediate(wm); },
        .toggle_layout_reverse  => { tiling.toggleLayoutReverse(wm); bar.redrawImmediate(wm); },
        .toggle_bar_visibility  => bar.setBarState(wm, .toggle),
        .toggle_bar_position    => bar.toggleBarPosition(wm) catch |err|
            debug.warn("Failed to toggle bar position: {}", .{err}),
        .increase_master        => tiling.increaseMasterWidth(),
        .decrease_master        => tiling.decreaseMasterWidth(),
        .increase_master_count  => tiling.increaseMasterCount(wm),
        .decrease_master_count  => tiling.decreaseMasterCount(wm),
        .toggle_tiling          => tiling.toggleTiling(wm),
        .swap_master            => tiling.swapWithMaster(wm),
        .cycle_layout_variation => tiling.cycleLayoutVariation(wm),
        .dump_state             => dumpState(wm),
        .emergency_recover      => emergencyRecover(wm),
        .minimize_window        => minimize.minimizeWindow(wm),
        .unminimize_lifo        => minimize.unminimizeLifo(wm),
        .unminimize_fifo        => minimize.unminimizeFifo(wm),
        .unminimize_all         => minimize.unminimizeAll(wm),
        .exec                   => |cmd| try executeShellCommand(wm, cmd),
        .switch_workspace       => |ws| workspaces.switchTo(wm, ws),
        .move_to_workspace      => |ws| { if (wm.focused_window) |win| workspaces.moveWindowTo(wm, win, ws) catch |e| debug.warnOnErr(e, "move_to_workspace"); },
    }
}

// Shell execution 

/// Spawns `cmd` via a double-fork so the child is re-parented to init and
/// the WM never needs to reap it.
///
/// Two pipes are used to give the WM reliable information about what happened:
///
/// exec_pipe  — the write end has FD_CLOEXEC set.  If execvp succeeds the
///              kernel closes it automatically; the WM's blocking read gets
///              EOF.  If execvp fails the grandchild writes a sentinel byte
///              before exiting, and the WM's read returns that byte.  This
///              means registerSpawn() is only called when we know the program
///              actually started — failed execs never enter the spawn queue and
///              can never be incorrectly consumed by an unrelated window later.
///
/// pid_pipe   — the intermediate child writes the grandchild's PID before it
///              exits.  The WM stores this alongside the workspace so that
///              handleMapRequest can match the arriving window by _NET_WM_PID
///              rather than by queue position.  This makes workspace assignment
///              independent of how long the program takes to show its window.
fn executeShellCommand(wm: *WM, cmd: []const u8) !void {
    const cmd_z = try wm.allocator.dupeZ(u8, cmd);
    defer wm.allocator.free(cmd_z);

    // exec_pipe: grandchild write end is CLOEXEC — closes on successful exec,
    // written to on failure.  pid_pipe: intermediate child writes grandchild PID.
    var exec_pipe: [2]c_int = undefined;
    var pid_pipe:  [2]c_int = undefined;
    if (c.pipe(&exec_pipe) != 0 or c.pipe(&pid_pipe) != 0) {
        debug.err("pipe() failed for command: {s}", .{cmd});
        return error.PipeFailed;
    }
    // FD_CLOEXEC on exec_pipe write end: exec success silently closes it.
    _ = c.fcntl(exec_pipe[1], c.F_SETFD, c.FD_CLOEXEC);

    const pid = c.fork();
    if (pid == 0) {
        // ── Intermediate child ──────────────────────────────────────────────
        // Close the WM-side (read) ends and the pid_pipe write end we don't
        // own yet; we'll write to pid_pipe after forking the grandchild.
        _ = c.close(exec_pipe[0]);
        _ = c.close(pid_pipe[0]);

        const pid2 = c.fork();
        if (pid2 == 0) {
            // ── Grandchild ──────────────────────────────────────────────────
            // pid_pipe is no longer needed in this process.
            _ = c.close(pid_pipe[1]);
            _ = c.setsid();
            const result = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null }));
            if (result == -1) {
                // exec failed: write a sentinel byte so the WM knows not to
                // register a spawn entry.  exec_pipe[1] is not CLOEXEC-closed
                // on failure, so this write reaches the WM.
                const sentinel: u8 = 1;
                _ = c.write(exec_pipe[1], &sentinel, 1);
                debug.err("execvp failed for command: {s}", .{cmd});
            }
            std.process.exit(1);
        } else if (pid2 < 0) {
            debug.err("Second fork failed for command: {s}", .{cmd});
            std.process.exit(1);
        }
        // Forward grandchild PID to WM, then close our write ends and exit.
        // Closing exec_pipe[1] here is essential: without it the WM would be
        // waiting for *this* process to release the write end too, preventing
        // it from ever seeing EOF on a successful exec.
        _ = c.write(pid_pipe[1], &pid2, @sizeOf(c_int));
        _ = c.close(pid_pipe[1]);
        _ = c.close(exec_pipe[1]);
        std.process.exit(0);
    } else if (pid > 0) {
        // ── WM ──────────────────────────────────────────────────────────────
        // Close write ends we don't own; holding them open would prevent the
        // blocking reads below from ever returning.
        _ = c.close(exec_pipe[1]);
        _ = c.close(pid_pipe[1]);

        var status: c_int = 0;
        if (c.waitpid(pid, &status, 0) == -1) {
            _ = c.close(exec_pipe[0]);
            _ = c.close(pid_pipe[0]);
            debug.err("waitpid failed", .{});
            return error.WaitpidFailed;
        }

        // Read the grandchild PID.  The intermediate child writes it before
        // exiting, so by the time waitpid returns it is already in the buffer.
        var grandchild_pid: c_int = -1;
        _ = c.read(pid_pipe[0], &grandchild_pid, @sizeOf(c_int));
        _ = c.close(pid_pipe[0]);

        // Blocking read on exec_pipe: returns immediately because by the time
        // waitpid returns the grandchild has either exec'd (CLOEXEC closed the
        // write end → EOF, n==0) or written a sentinel byte and exited (n==1).
        // The intermediate child also closed its copy of exec_pipe[1] before
        // exiting, so the WM's read end sees exactly one writer: the grandchild.
        var sentinel: u8 = 0;
        const n = c.read(exec_pipe[0], &sentinel, 1);
        _ = c.close(exec_pipe[0]);

        if (n > 0) {
            // exec failed — do not register a spawn entry; nothing will map.
            return;
        }

        // exec succeeded: register the spawn so handleMapRequest can assign
        // the right workspace.  grandchild_pid may be -1 if the intermediate
        // child's write to pid_pipe failed for some reason; passing 0 in that
        // case degrades gracefully to the FIFO fallback in handleMapRequest.
        if (workspaces.getCurrentWorkspace()) |ws| {
            const pid_u32: u32 = if (grandchild_pid > 0) @intCast(grandchild_pid) else 0;
            window.registerSpawn(ws, pid_u32);
        }
    } else {
        debug.err("First fork failed for command: {s}", .{cmd});
        return error.ForkFailed;
    }
}

// Diagnostics

fn dumpState(wm: *WM) void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused: {?x}",         .{wm.focused_window});
    const win_count = if (workspaces.getState()) |s| s.window_to_workspace.count() else 0;
    debug.info("Total windows: {}",     .{win_count});
    debug.info("Suppress focus: {s}",   .{@tagName(wm.suppress_focus_reason)});

    var fs_it = wm.fullscreen.per_workspace.iterator();
    var fs_count: u8 = 0;
    while (fs_it.next()) |entry| {
        debug.info("Fullscreen on workspace {}: {x}", .{ entry.key_ptr.*, entry.value_ptr.window });
        fs_count += 1;
    }
    if (fs_count == 0) debug.info("Fullscreen: none", .{});
    debug.info("Drag active: {}", .{wm.drag_state.active});

    if (workspaces.getState()) |ws_state| {
        debug.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |*ws, i| {
            debug.info("  WS{}: {} windows", .{ i + 1, ws.windows.items().len });
        }
    }

    if (tiling.getState()) |t_state| {
        debug.info("Tiling enabled: {}",  .{t_state.enabled});
        debug.info("Tiling layout: {s}", .{@tagName(t_state.layout)});
        debug.info("Tiled windows: {}",  .{t_state.windows.items().len});
        debug.info("Master count: {}",   .{t_state.master_count});
        debug.info("Master width: {d:.2}", .{t_state.master_width});
    }
    debug.info("================================", .{});
}

fn emergencyRecover(wm: *WM) void {
    debug.warn("========== EMERGENCY RECOVERY ==========", .{});

    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces) |*ws| {
            for (ws.windows.items()) |win| _ = xcb.xcb_map_window(wm.conn, win);
        }
    }

    if (tiling.getState()) |t_state| {
        t_state.enabled = false;
        debug.warn("Tiling disabled", .{});
    }

    wm.fullscreen.clear();
    debug.warn("Fullscreen cleared", .{});

    if (wm.drag_state.active) {
        wm.drag_state.active = false;
        debug.warn("Drag stopped", .{});
    }

    utils.flush(wm.conn);
    debug.warn("Recovery complete — all windows mapped, special modes disabled", .{});
}
