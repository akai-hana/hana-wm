//! Input handling with motion AND enter event coalescing for maximum responsiveness
const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const focus = @import("focus");
const log = @import("logging");
const xcb = defs.xcb;
const WM = defs.WM;

const c = @cImport(@cInclude("unistd.h"));
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

// CONFIGURATION

/// Enable motion event coalescing for smoother window dragging
const COALESCE_MOTION_EVENTS = true;

// KEYBIND SYSTEM

var keybind_map: std.AutoHashMap(u64, *const defs.Action) = undefined;
var keybind_map_ready = std.atomic.Value(bool).init(false);
var initialized = false;

pub fn init(wm: *WM) void {
    keybind_map = std.AutoHashMap(u64, *const defs.Action).init(wm.allocator);
    buildKeybindMap(wm) catch return;
    keybind_map_ready.store(true, .release);
    initialized = true;
}

pub fn deinit(_: *WM) void {
    if (initialized) {
        keybind_map_ready.store(false, .release);
        keybind_map.deinit();
        initialized = false;
    }
}

fn buildKeybindMap(wm: *WM) !void {
    keybind_map.clearRetainingCapacity();
    for (wm.config.keybindings.items) |*kb| {
        const key = makeHash(kb.modifiers, kb.keysym);
        try keybind_map.put(key, &kb.action);
    }
}

pub fn rebuildKeybindMap(wm: *WM) !void {
    keybind_map_ready.store(false, .release);
    defer keybind_map_ready.store(true, .release);

    try buildKeybindMap(wm);
}

inline fn makeHash(mods: u16, keysym: u32) u64 {
    return (@as(u64, mods) << 32) | keysym;
}

pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    for ([_]u8{ 1, 3 }) |button| {
        _ = xcb.xcb_grab_button(
            conn,
            0,
            root,
            xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.XCB_EVENT_MASK_POINTER_MOTION,
            xcb.XCB_GRAB_MODE_ASYNC,
            xcb.XCB_GRAB_MODE_ASYNC,
            root,
            xcb.XCB_NONE,
            button,
            defs.MOD_SUPER,
        );
    }
    utils.flush(conn);
}

// EVENT HANDLERS

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    if (!keybind_map_ready.load(.acquire)) return;

    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));

    const mods = utils.normalizeModifiers(event.state);
    const keysym = xkb_ptr.keycodeToKeysym(event.detail);
    const key = makeHash(mods, keysym);

    if (keybind_map.get(key)) |action| {
        executeAction(action, wm) catch {};
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    if (event.child == 0) return;

    const has_super = (event.state & defs.MOD_SUPER) != 0;

    if (has_super and (event.detail == 1 or event.detail == 3)) {
        @import("cursor-window-drag").startDrag(wm, event.child, event.detail, event.root_x, event.root_y);
    } else {
        focus.setFocus(wm, event.child, .mouse_click);
    }
}

pub fn handleButtonRelease(_: *const xcb.xcb_button_release_event_t, wm: *WM) void {
    if (@import("cursor-window-drag").isDragging()) {
        @import("cursor-window-drag").stopDrag(wm);
    }
}

pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    if (!@import("cursor-window-drag").isDragging()) return;

    // OPTIMIZATION: Coalesce motion events
    if (COALESCE_MOTION_EVENTS) {
        if (hasQueuedMotionEvents(wm.conn)) {
            return;
        }
    }

    @import("cursor-window-drag").updateDrag(wm, event.root_x, event.root_y);
}

/// Check if there are more motion events queued
fn hasQueuedMotionEvents(conn: *xcb.xcb_connection_t) bool {
    const queued = xcb.xcb_poll_for_event(conn);
    if (queued) |next_event| {
        defer std.c.free(next_event);
        const next_type = @as(*u8, @ptrCast(next_event)).* & 0x7F;

        if (next_type == xcb.XCB_MOTION_NOTIFY) {
            return true;
        }
    }
    return false;
}

// ACTION EXECUTION

inline fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .close_window => {
            if (wm.focused_window) |win| {
                _ = xcb.xcb_destroy_window(wm.conn, win);
            }
        },
        .reload_config => wm.should_reload_config.store(true, .release),
        .toggle_layout => tiling.toggleLayout(wm),
        .increase_master => tiling.increaseMasterWidth(wm),
        .decrease_master => tiling.decreaseMasterWidth(wm),
        .increase_master_count => tiling.increaseMasterCount(wm),
        .decrease_master_count => tiling.decreaseMasterCount(wm),
        .toggle_tiling => tiling.toggleTiling(wm),
        .dump_state => dumpState(wm),
        .emergency_recover => emergencyRecover(wm),

        .exec => |cmd| try executeShellCommand(wm, cmd),
        .switch_workspace => |ws| workspaces.switchTo(wm, ws),
        .move_to_workspace => |ws| {
            if (wm.focused_window) |win| {
                workspaces.moveWindowTo(wm, win, ws);
            }
        },

        .focus_next, .focus_prev => {},
    }
}

fn executeShellCommand(wm: *WM, cmd: []const u8) !void {
    const cmd_z = try wm.allocator.dupeZ(u8, cmd);
    defer wm.allocator.free(cmd_z);

    const pid = c.fork();
    if (pid == 0) {
        const pid2 = c.fork();
        if (pid2 == 0) {
            _ = c.setsid();
            _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null }));
            std.process.exit(1);
        } else if (pid2 < 0) {
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        _ = waitpid(pid, &status, 0);
    }
}

fn dumpState(wm: *WM) void {
    log.dumpStateSeparator();
    log.dumpStateFocused(wm.focused_window);
    log.dumpStateTotalWindows(wm.windows.count());

    if (workspaces.getState()) |ws_state| {
        log.dumpStateCurrentWorkspace(ws_state.current);
        for (ws_state.workspaces, 0..) |*ws, i| {
            log.dumpStateWorkspace(i, ws.windows.items.len);
        }
    }

    if (tiling.getState()) |t_state| {
        log.dumpStateTiling(t_state.enabled, t_state.tiled_windows.items.len);
    }
    log.dumpStateEnd();
}

fn emergencyRecover(wm: *WM) void {
    log.emergencyRecoveryStart();

    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces) |*ws| {
            for (ws.windows.items) |win| {
                _ = xcb.xcb_map_window(wm.conn, win);
            }
        }
    }

    if (tiling.getState()) |t_state| {
        t_state.enabled = false;
    }

    utils.flush(wm.conn);
    log.emergencyRecoveryComplete();
}
