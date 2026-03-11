//! User input handling
//!
//! Handles keyboard, mouse buttons, pointer motion and drag operations.

const std        = @import("std");
const constants  = @import("constants");
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
const prompt     = @import("prompt");
const xcb        = defs.xcb;
const WM         = defs.WM;

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

// Keybind state
// TODO: move KeybindState into WM to eliminate module-level mutable global.

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

var keybind_state: ?KeybindState     = null;
var xkb_state:     ?*xkbcommon.XkbState = null;

/// Returns the XkbState pointer. Used by events.zig for config reload.
pub fn getXkbState() *xkbcommon.XkbState {
    return xkb_state.?;
}

pub fn init(wm: *WM, xkb: *xkbcommon.XkbState) !void {
    var state = KeybindState.init(wm.allocator);
    errdefer state.deinit();
    try state.rebuild(wm);
    keybind_state = state;
    xkb_state     = xkb;
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

/// Grabs Super+Button1/2/3 on the root window.
/// Button1 = move, Button3 = resize, Button2 = config-driven binds (e.g. toggle_float).
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

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    focus.setLastEventTime(event.time);

    const state  = &(keybind_state orelse return);
    const mods   = utils.normalizeModifiers(event.state);
    const keysym = xkb_state.?.keycodeToKeysym(event.detail);
    const key    = makeHash(mods, keysym);

    // When prompt is active it owns all key input — with one exception: if the
    // pressed key is bound to close_window, dismiss prompt instead of either
    // closing a window or swallowing the keystroke silently.
    if (prompt.isActive()) {
        if (state.map.get(key)) |action| {
            if (action.* == .close_window) {
                prompt.toggle(wm);
                bar.scheduleRedraw();
                return;
            }
        }
        if (prompt.handleKeyPress(event, wm)) bar.scheduleRedraw();
        return;
    }

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
    focus.setLastEventTime(event.time);
    const clicked_window = if (event.child != 0) event.child else event.event;

    if (clicked_window == 0 or clicked_window == wm.root) {
        // Use event.time, not XCB_CURRENT_TIME — server matches by timestamp.
        replayPointer(wm, event.time);
        return;
    }

    const managed_window = utils.findManagedWindow(wm.conn, clicked_window, workspaces.isManaged);
    if (managed_window == 0) {
        replayPointer(wm, event.time);
        return;
    }

    // Check config-driven mouse binds (e.g. Super+MiddleClick = "toggle_float").
    // These take priority over the default drag behaviour so a bind is never
    // swallowed by the drag handler.
    if ((event.state & constants.MOD_SUPER) != 0) {
        const mods = utils.normalizeModifiers(event.state);
        for (wm.config.mouse_bindings.items) |*mb| {
            if (mb.modifiers == mods and mb.button == event.detail) {
                executeMouseAction(&mb.action, wm, managed_window)
                    catch |err| debug.err("mouse bind error: {}", .{err});
                _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER,  event.time);
                _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, event.time);
                _ = xcb.xcb_flush(wm.conn);
                return;
            }
        }
    }

    if ((event.state & constants.MOD_SUPER) != 0 and
        (event.detail == MOUSE_BUTTON_LEFT or event.detail == MOUSE_BUTTON_RIGHT)) {
        drag.startDrag(wm, managed_window, event.detail, event.root_x, event.root_y);
    } else {
        focus.setFocus(wm, managed_window, .mouse_click);
    }

    // Release the SYNC grab; use event.time not XCB_CURRENT_TIME to avoid silent drop.
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER,  event.time);
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, event.time);
    _ = xcb.xcb_flush(wm.conn);
}

pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t, _: *WM) void {
    focus.setLastEventTime(event.time);
    if (drag.isDragging()) drag.stopDrag();
}

pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    focus.setLastEventTime(event.time);
    if (drag.isDragging()) {
        drag.updateDrag(wm, event.root_x, event.root_y);
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
    xcb.xcb_discard_reply(wm.conn, xcb.xcb_query_pointer(wm.conn, wm.root).sequence);
}

// Window close

fn closeWindow(wm: *WM, win: u32) void {
    // If the window supports the `WM_DELETE_WINDOW` signal,
    if (utils.supportsWMDeleteCached(wm.conn, win)) {
        // Ask window to close politely
        const protocols_atom = utils.getAtomCached("WM_PROTOCOLS")     catch return;
        const delete_atom    = utils.getAtomCached("WM_DELETE_WINDOW") catch return;

        var event = std.mem.zeroes(xcb.xcb_client_message_event_t); //TODO: what does this do?

        event.response_type  = xcb.XCB_CLIENT_MESSAGE;
        event.format         = 32;
        event.window         = win;
        event.type           = protocols_atom;
        event.data.data32[0] = delete_atom;
        event.data.data32[1] = focus.getLastEventTime(); // ICCCM §4.1.7

        // Send a WM_DELETE_WINDOW client message (ICCCM §4.1.2.7)
        _ = xcb.xcb_send_event(wm.conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
        _ = xcb.xcb_flush(wm.conn);
    } else {
        // Fallback: Destroy window entirely, through a raw xcb signal.
        _ = xcb.xcb_destroy_window(wm.conn, win);
        _ = xcb.xcb_flush(wm.conn);
    }
}

// Action dispatch

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .toggle_fullscreen      => fullscreen.toggleFullscreen(wm),
        .close_window           => { if (focus.getFocused()) |win| closeWindow(wm, win); },
        .reload_config          => { utils.reload(); },
        //TODO: add comment here
        .sequence               => |acts| { for (acts) |*a| try executeAction(a, wm); },
        .exec                   => |cmd| try executeShellCommand(wm, cmd),
        .dump_state             => dumpState(wm),

        .toggle_tiling          => tiling.toggleTiling(wm),
        .toggle_float           => { if (focus.getFocused()) |win| tiling.toggleWindowFloat(wm, win); },
        .toggle_layout          => { tiling.toggleLayout(wm);        bar.scheduleRedraw(); },
        .toggle_layout_reverse  => { tiling.toggleLayoutReverse(wm); bar.scheduleRedraw(); },
        .cycle_layout_variation => tiling.cycleLayoutVariation(wm),

        .toggle_bar_visibility  => bar.setBarState(wm, .toggle),
        .toggle_bar_position    => bar.toggleBarPosition(wm),

        .increase_master        => tiling.increaseMasterWidth(wm),
        .decrease_master        => tiling.decreaseMasterWidth(wm),
        .increase_master_count  => tiling.increaseMasterCount(wm),
        .decrease_master_count  => tiling.decreaseMasterCount(wm),

        .swap_master            => { tiling.swapWithMaster(wm);          focus.setSuppressReason(.tiling_operation); bar.scheduleRedraw(); },
        .swap_master_focus_swap => { tiling.swapWithMasterFocusSwap(wm); focus.setSuppressReason(.tiling_operation); bar.scheduleRedraw(); },

        .minimize_window        => minimize.minimizeWindow(wm),
        .unminimize_lifo        => minimize.unminimize(wm, .lifo),
        .unminimize_fifo        => minimize.unminimize(wm, .fifo),
        .unminimize_all         => minimize.unminimizeAll(wm),

        .switch_workspace       => |ws| workspaces.switchTo(wm, ws),
        .move_to_workspace      => |ws| { if (focus.getFocused()) |win| workspaces.moveWindowTo(wm, win, ws) catch |e| debug.warnOnErr(e, "move_to_workspace"); },
        .move_window            => |ws| { if (focus.getFocused()) |win| workspaces.moveWindowExclusive(wm, win, ws); },

        .tag_toggle             => |ws| { if (focus.getFocused()) |win| workspaces.tagToggle(wm, win, ws, true); },
        .prompt_toggle          => { prompt.toggle(wm); bar.scheduleRedraw(); },
    }
}

/// Like executeAction but carries the specific window that was clicked.
/// Used by the mouse bind dispatcher so toggle_float acts on the clicked
/// window rather than the keyboard-focused one (they may differ).
fn executeMouseAction(action: *const defs.Action, wm: *WM, clicked_win: u32) !void {
    switch (action.*) {
        .toggle_float => tiling.toggleWindowFloat(wm, clicked_win),
        else          => try executeAction(action, wm),
    }
}

// Shell execution

/// Spawns `cmd` via double-fork so the grandchild is re-parented to init.
///
/// exec_pipe: write end is FD_CLOEXEC; EOF on success, sentinel byte on exec failure.
/// pid_pipe:  intermediate child writes grandchild PID before exiting.
/// registerSpawn() is only called when exec is confirmed to have succeeded.
fn executeShellCommand(wm: *WM, cmd: []const u8) !void {
    const cmd_z = try wm.allocator.dupeZ(u8, cmd);
    defer wm.allocator.free(cmd_z);

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
    if (pid == 0) {
        // Intermediate child: fork grandchild, forward its PID, then exit.
        _ = c.close(exec_pipe[0]);
        _ = c.close(pid_pipe[0]);

        const pid2 = c.fork();
        if (pid2 == 0) {
            // Grandchild: exec the command.
            _ = c.close(pid_pipe[1]);
            _ = c.setsid();
            const result = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null }));
            if (result == -1) {
                // exec failed: write sentinel so WM skips registerSpawn.
                const sentinel: u8 = 1;
                _ = c.write(exec_pipe[1], &sentinel, 1);
                debug.err("execvp failed for command: {s}", .{cmd});
            }
            std.process.exit(1);
        } else if (pid2 < 0) {
            debug.err("Second fork failed for command: {s}", .{cmd});
            std.process.exit(1);
        }
        // Write grandchild PID, then close write ends and exit.
        // Closing exec_pipe[1] here is required: without it the WM read would block.
        _ = c.write(pid_pipe[1], &pid2, @sizeOf(c_int));
        _ = c.close(pid_pipe[1]);
        _ = c.close(exec_pipe[1]);
        std.process.exit(0);
    } else if (pid > 0) {
        // WM: close write ends we don't own to allow reads to complete.
        _ = c.close(exec_pipe[1]);
        _ = c.close(pid_pipe[1]);

        var status: c_int = 0;
        if (c.waitpid(pid, &status, 0) == -1) {
            _ = c.close(exec_pipe[0]);
            _ = c.close(pid_pipe[0]);
            debug.err("waitpid failed", .{});
            return error.WaitpidFailed;
        }

        // pid_pipe: intermediate child writes grandchild PID before exiting,
        // so by the time waitpid returns the value is already buffered.
        var grandchild_pid: c_int = -1;
        _ = c.read(pid_pipe[0], &grandchild_pid, @sizeOf(c_int));
        _ = c.close(pid_pipe[0]);

        // exec_pipe: EOF (n==0) means exec succeeded; sentinel byte (n==1) means failure.
        var sentinel: u8 = 0;
        const n = c.read(exec_pipe[0], &sentinel, 1);
        _ = c.close(exec_pipe[0]);

        if (n > 0) return; // exec failed — skip spawn registration.

        if (workspaces.getCurrentWorkspace()) |ws| {
            const pid_u32: u32 = if (grandchild_pid > 0) @intCast(grandchild_pid) else 0;
            window.registerSpawn(ws, pid_u32);
        }
    } else {
        closePipe(exec_pipe);
        closePipe(pid_pipe);
        debug.err("First fork failed for command: {s}", .{cmd});
        return error.ForkFailed;
    }
}

// Diagnostics

fn dumpState(_: *WM) void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused: {?x}",         .{focus.getFocused()});
    const win_count = if (workspaces.getState()) |s| s.window_to_workspaces.count() else 0;
    debug.info("Total windows: {}",     .{win_count});
    debug.info("Suppress focus: {s}",   .{@tagName(focus.getSuppressReason())});

    var fs_opt_it = fullscreen.perWorkspaceIterator();
    var fs_count: u8 = 0;
    if (fs_opt_it) |*fs_it| while (fs_it.next()) |entry| {
        debug.info("Fullscreen on workspace {}: {x}", .{ entry.key_ptr.*, entry.value_ptr.window });
        fs_count += 1;
    };
    if (fs_count == 0) debug.info("Fullscreen: none", .{});
    debug.info("Drag active: {}", .{drag.isDragging()});

    if (workspaces.getState()) |ws_state| {
        debug.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |*ws, i| {
            debug.info("  WS{}: {} windows", .{ i + 1, ws.windows.count() });
        }
    }

    if (tiling.getStateOpt()) |t_state| {
        debug.info("Tiling enabled: {}",  .{t_state.enabled});
        debug.info("Tiling layout: {s}", .{@tagName(t_state.layout)});
        debug.info("Tiled windows: {}",  .{t_state.windows.count()});
        debug.info("Master count: {}",   .{t_state.master_count});
        debug.info("Master width: {d:.2}", .{t_state.master_width});
    }
    debug.info("================================", .{});
}

// Helpers

/// Replays a frozen pointer event and flushes. Always pass `event.time`, never XCB_CURRENT_TIME.
inline fn replayPointer(wm: *WM, time: u32) void {
    _ = xcb.xcb_allow_events(wm.conn, xcb.XCB_ALLOW_REPLAY_POINTER, time);
    _ = xcb.xcb_flush(wm.conn);
}

/// Closes both ends of a pipe pair.
inline fn closePipe(p: [2]c_int) void {
    _ = c.close(p[0]);
    _ = c.close(p[1]);
}
