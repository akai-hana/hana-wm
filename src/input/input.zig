// Input handling (OPTIMIZED)

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const utils = @import("utils");
const focus = @import("focus");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const drag = @import("drag");
const xcb = defs.xcb;
const WM = defs.WM;

const c = @cImport(@cInclude("unistd.h"));
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

const MOUSE_BUTTONS = [_]u8{ 1, 3 }; // Button1 (move), Button3 (resize)

// OPTIMIZATION: Simpler keybind state with better cache locality
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
        std.log.err("[input] Failed to allocate keybind state", .{});
        return;
    };
    state.* = KeybindState.init(wm.allocator);

    state.rebuild(wm) catch |err| {
        std.log.err("[input] Failed to build keybind map: {}", .{err});
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

// OPTIMIZATION: Inline hash function for better performance
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
        executeAction(action, wm) catch |err| {
            std.log.err("[input] Failed to execute action: {}", .{err});
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
}

// OPTIMIZATION: Streamlined window closing with early returns
fn closeWindow(wm: *WM, win: u32) void {
    if (win == wm.root) {
        std.log.err("[CRITICAL] Attempted to close ROOT window!", .{});
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

// OPTIMIZATION: Streamlined action execution with inline switch
fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .toggle_fullscreen => @import("fullscreen").toggleFullscreen(wm),
        .close_window => {
            if (wm.focused_window) |win| closeWindow(wm, win);
        },
        .reload_config => wm.should_reload_config.store(true, .release),
        .toggle_layout => tiling.toggleLayout(wm),
        .toggle_layout_reverse => tiling.toggleLayoutReverse(wm),
        .toggle_bar => @import("bar").setBarState(wm, .toggle),
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

// OPTIMIZATION: Double-fork pattern for clean process spawning
fn executeShellCommand(wm: *WM, cmd: []const u8) !void {
    const cmd_z = try wm.allocator.dupeZ(u8, cmd);
    defer wm.allocator.free(cmd_z);

    const pid = c.fork();
    if (pid == 0) {
        // First child - fork again to avoid zombie
        const pid2 = c.fork();
        if (pid2 == 0) {
            // Second child - execute command
            _ = c.setsid();
            const result = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null }));
            if (result == -1) {
                std.log.err("[input] execvp failed for command: {s}", .{cmd});
            }
            std.process.exit(1);
        } else if (pid2 < 0) {
            std.log.err("[input] Second fork failed for command: {s}", .{cmd});
            std.process.exit(1);
        }
        std.process.exit(0);
    } else if (pid > 0) {
        // Parent - wait for first child
        var status: c_int = 0;
        const wait_result = waitpid(pid, &status, 0);
        if (wait_result == -1) {
            std.log.err("[input] waitpid failed", .{});
            return error.WaitpidFailed;
        }
    } else {
        std.log.err("[input] First fork failed for command: {s}", .{cmd});
        return error.ForkFailed;
    }
}

fn dumpState(wm: *WM) void {
    std.log.info("========== STATE DUMP ==========", .{});
    std.log.info("Focused: {?x}", .{wm.focused_window});
    std.log.info("Total windows: {}", .{wm.windows.count()});

    // List fullscreen windows per workspace
    var fs_it = wm.fullscreen.per_workspace.iterator();
    var fs_count: usize = 0;
    while (fs_it.next()) |entry| {
        std.log.info("Fullscreen on workspace {}: {x}", .{ entry.key_ptr.*, entry.value_ptr.window });
        fs_count += 1;
    }
    if (fs_count == 0) std.log.info("Fullscreen: none", .{});
    std.log.info("Drag active: {}", .{wm.drag_state.active});

    if (workspaces.getState()) |ws_state| {
        std.log.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |*ws, i| {
            std.log.info("  WS{}: {} windows", .{ i + 1, ws.windows.list.items.len });
        }
    }

    if (tiling.getState()) |t_state| {
        std.log.info("Tiling enabled: {}", .{t_state.enabled});
        std.log.info("Tiling layout: {s}", .{@tagName(t_state.layout)});
        std.log.info("Tiled windows: {}", .{t_state.windows.list.items.len});
        std.log.info("Master count: {}", .{t_state.master_count});
        std.log.info("Master width: {d:.2}", .{t_state.master_width});
    }
    std.log.info("================================", .{});
}

fn emergencyRecover(wm: *WM) void {
    std.log.warn("========== EMERGENCY RECOVERY ==========", .{});

    // Map all windows
    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces) |*ws| {
            for (ws.windows.list.items) |win| {
                _ = xcb.xcb_map_window(wm.conn, win);
            }
        }
    }

    // Disable tiling
    if (tiling.getState()) |t_state| {
        t_state.enabled = false;
        std.log.warn("Tiling disabled", .{});
    }

    // Exit fullscreen on all workspaces
    wm.fullscreen.clear();
    std.log.warn("Fullscreen cleared", .{});

    // Stop any drag
    if (wm.drag_state.active) {
        wm.drag_state.active = false;
        std.log.warn("Drag stopped", .{});
    }

    utils.flush(wm.conn);
    std.log.warn("Recovery complete - all windows mapped, special modes disabled", .{});
}
