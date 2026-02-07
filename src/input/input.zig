// Input handling - IMPROVED: Pointer tracking, no event counters

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const utils = @import("utils");
const focus = @import("focus");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const drag = @import("drag");
const debug = @import("debug");
const xcb = defs.xcb;
const WM = defs.WM;

const c = @cImport(@cInclude("unistd.h"));
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

const MOUSE_BUTTONS = [_]u8{ 1, 3 }; // Button1 (move), Button3 (resize)

const KeybindState = struct {
    map: std.AutoHashMap(u64, *const defs.Action),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) KeybindState {
        return .{
            .map = std.AutoHashMap(u64, *const defs.Action).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *KeybindState) void {
        self.map.deinit();
    }

    inline fn get(self: *KeybindState, key: u64) ?*const defs.Action {
        return self.map.get(key);
    }

    fn rebuild(self: *KeybindState, wm: *WM) !void {
        self.map.clearRetainingCapacity();
        try self.map.ensureTotalCapacity(@intCast(wm.config.keybindings.items.len));
        for (wm.config.keybindings.items) |*kb| {
            const key = makeHash(kb.modifiers, kb.keysym);
            self.map.putAssumeCapacity(key, &kb.action);
        }
    }
};

var keybind_state: ?*KeybindState = null;

pub fn init(wm: *WM) void {
    const state = wm.allocator.create(KeybindState) catch {
        debug.err("Failed to allocate keybind state", .{});
        return;
    };
    state.* = KeybindState.init(wm.allocator);

    state.rebuild(wm) catch |err| {
        debug.err("Failed to build keybind map: {}", .{err});
        state.deinit();
        wm.allocator.destroy(state);
        return;
    };
    keybind_state = state;
}

pub fn deinit(wm: *WM) void {
    if (keybind_state) |state| {
        state.deinit();
        wm.allocator.destroy(state);
        keybind_state = null;
    }
}

pub fn rebuildKeybindMap(wm: *WM) !void {
    if (keybind_state) |state| {
        try state.rebuild(wm);
    } else {
        return error.KeybindStateNotInitialized;
    }
}

inline fn makeHash(mods: u16, keysym: u32) u64 {
    return (@as(u64, mods) << 32) | keysym;
}

pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    // Grab Super+Button1 (move) and Super+Button3 (resize)
    for (MOUSE_BUTTONS) |button| {
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

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    const state = keybind_state orelse return;
    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));

    const mods = utils.normalizeModifiers(event.state);
    const keysym = xkb_ptr.keycodeToKeysym(event.detail);
    const key = makeHash(mods, keysym);

    if (state.get(key)) |action| {
        // REMOVED: No longer need to reset event counters
        // The new approach doesn't use counters - it uses context-aware suppression
        executeAction(action, wm) catch |err| {
            debug.err("Failed to execute action: {}", .{err});
        };
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    if (event.child == 0) return;
    const has_super = (event.state & defs.MOD_SUPER) != 0;
    if (has_super and (event.detail == 1 or event.detail == 3)) {
        drag.startDrag(wm, event.child, event.detail, event.root_x, event.root_y);
    } else {
        focus.setFocus(wm, event.child, .mouse_click);
        tiling.updateWindowFocus(wm, null, event.child);
    }
}

pub fn handleButtonRelease(_: *const xcb.xcb_button_release_event_t, wm: *WM) void {
    if (drag.isDragging(wm)) {
        drag.stopDrag(wm);
    }
}

pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    if (drag.isDragging(wm)) {
        drag.updateDrag(wm, event.root_x, event.root_y);
    }
    // Pointer position tracking removed - only update on EnterNotify
    // This prevents MotionNotify from "racing" EnterNotify and making it think
    // the pointer didn't move when hovering between windows
}

fn closeWindow(wm: *WM, win: u32) void {
    if (win == wm.root) {
        debug.err("CRITICAL: Attempted to close ROOT window!", .{});
        return;
    }

    const wm_protocols_atom = utils.getAtomCached("WM_PROTOCOLS") catch {
        forceDestroyWindow(wm, win);
        return;
    };

    const wm_delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") catch {
        forceDestroyWindow(wm, win);
        return;
    };

    const prop_cookie = xcb.xcb_get_property(wm.conn, 0, win, wm_protocols_atom, xcb.XCB_ATOM_ATOM, 0, 1024);
    const prop_reply = xcb.xcb_get_property_reply(wm.conn, prop_cookie, null);

    if (prop_reply) |reply| {
        defer std.c.free(reply);
        const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
        const atom_count: usize = @intCast(@divExact(xcb.xcb_get_property_value_length(reply), @as(c_int, @sizeOf(u32))));

        for (0..atom_count) |i| {
            if (atoms[i] == wm_delete_atom) {
                sendDeleteEvent(wm, win, wm_protocols_atom, wm_delete_atom);
                return;
            }
        }
    }
    forceDestroyWindow(wm, win);
}

fn sendDeleteEvent(wm: *WM, win: u32, protocols_atom: u32, delete_atom: u32) void {
    var event: xcb.xcb_client_message_event_t = undefined;
    event.response_type = xcb.XCB_CLIENT_MESSAGE;
    event.format = 32;
    event.sequence = 0;
    event.window = win;
    event.type = protocols_atom;
    event.data.data32[0] = delete_atom;
    event.data.data32[1] = xcb.XCB_CURRENT_TIME;
    event.data.data32[2] = 0;
    event.data.data32[3] = 0;
    event.data.data32[4] = 0;
    _ = xcb.xcb_send_event(wm.conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
    utils.flush(wm.conn);
}

fn forceDestroyWindow(wm: *WM, win: u32) void {
    _ = xcb.xcb_destroy_window(wm.conn, win);
    utils.flush(wm.conn);
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .toggle_fullscreen => @import("fullscreen").toggleFullscreen(wm),
        .close_window => {
            if (wm.focused_window) |win| closeWindow(wm, win);
        },
        .reload_config => wm.should_reload_config.store(true, .release),
        .toggle_layout => tiling.toggleLayout(wm),
        .toggle_layout_reverse => tiling.toggleLayoutReverse(wm),
        .toggle_bar_visibility => @import("bar").setBarState(wm, .toggle),
        .toggle_bar_position => {
            @import("bar").toggleBarPosition(wm) catch |err| {
                debug.warn("Failed to toggle bar position: {}", .{err});
            };
        },
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
            const result = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null }));
            if (result == -1) {
                debug.err("execvp failed for command: {s}", .{cmd});
            }
            std.process.exit(1);
        } else if (pid2 < 0) {
            debug.err("Second fork failed for command: {s}", .{cmd});
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        var status: c_int = 0;
        const wait_result = waitpid(pid, &status, 0);
        if (wait_result == -1) {
            debug.err("waitpid failed", .{});
            return error.WaitpidFailed;
        }
    } else {
        debug.err("First fork failed for command: {s}", .{cmd});
        return error.ForkFailed;
    }
}

fn dumpState(wm: *WM) void {
    debug.info("========== STATE DUMP ==========", .{});
    debug.info("Focused: {?x}", .{wm.focused_window});
    debug.info("Total windows: {}", .{wm.windows.count()});
    debug.info("Suppress focus: {s}", .{@tagName(wm.suppress_focus_reason)});
    debug.info("Pointer: ({}, {})", .{wm.last_pointer_x, wm.last_pointer_y});

    var fs_it = wm.fullscreen.per_workspace.iterator();
    var fs_count: usize = 0;
    while (fs_it.next()) |entry| {
        debug.info("Fullscreen on workspace {}: {x}", .{ entry.key_ptr.*, entry.value_ptr.window });
        fs_count += 1;
    }
    if (fs_count == 0) debug.info("Fullscreen: none", .{});
    debug.info("Drag active: {}", .{wm.drag_state.active});

    if (workspaces.getState()) |ws_state| {
        debug.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |*ws, i| {
            debug.info("  WS{}: {} windows", .{ i + 1, ws.windows.list.items.len });
        }
    }

    if (tiling.getState()) |t_state| {
        debug.info("Tiling enabled: {}", .{t_state.enabled});
        debug.info("Tiling layout: {s}", .{@tagName(t_state.layout)});
        debug.info("Tiled windows: {}", .{t_state.windows.list.items.len});
        debug.info("Master count: {}", .{t_state.master_count});
        debug.info("Master width: {d:.2}", .{t_state.master_width});
    }
    debug.info("================================", .{});
}

fn emergencyRecover(wm: *WM) void {
    debug.warn("========== EMERGENCY RECOVERY ==========", .{});

    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces) |*ws| {
            for (ws.windows.list.items) |win| {
                _ = xcb.xcb_map_window(wm.conn, win);
            }
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
    debug.warn("Recovery complete - all windows mapped, special modes disabled", .{});
}
