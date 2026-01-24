//! Input handling: keyboard, mouse, and motion event processing.

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const utils = @import("utils");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const focus = @import("focus");
const xcb = defs.xcb;
const WM = defs.WM;

const c = @cImport(@cInclude("unistd.h"));
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

// Keybind system with proper synchronization
const KeybindState = struct {
    map: std.AutoHashMap(u64, *const defs.Action),
    ready: std.atomic.Value(bool),
    mutex: std.Thread.Mutex,

    fn init(allocator: std.mem.Allocator) KeybindState {
        return .{
            .map = std.AutoHashMap(u64, *const defs.Action).init(allocator),
            .ready = std.atomic.Value(bool).init(false),
            .mutex = .{},
        };
    }

    fn deinit(self: *KeybindState) void {
        self.ready.store(false, .release);
        self.map.deinit();
    }

    fn setReady(self: *KeybindState, ready: bool) void {
        self.ready.store(ready, .release);
    }

    fn isReady(self: *const KeybindState) bool {
        return self.ready.load(.acquire);
    }

    fn get(self: *KeybindState, key: u64) ?*const defs.Action {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.get(key);
    }

    fn rebuild(self: *KeybindState, wm: *WM) !void {
        self.setReady(false);
        defer self.setReady(true);

        // Pre-allocate capacity before acquiring lock
        const needed_capacity: u32 = @intCast(wm.config.keybindings.items.len);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Ensure capacity (no allocation happens here if sufficient)
        try self.map.ensureTotalCapacity(needed_capacity);
        self.map.clearRetainingCapacity();

        // All insertions now guaranteed not to allocate
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
        std.log.err("[input] Failed to build initial keybind map: {}", .{err});
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

/// Setup mouse button grabs for window manipulation
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

// Event handlers

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    const state = keybind_state orelse return;
    if (!state.isReady()) return;

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

    // Coalesce motion events for smoother dragging
    if (hasQueuedMotionEvents(wm.conn)) return;

    @import("cursor-window-drag").updateDrag(wm, event.root_x, event.root_y);
}

fn hasQueuedMotionEvents(conn: *xcb.xcb_connection_t) bool {
    const queued = xcb.xcb_poll_for_event(conn);
    if (queued) |next_event| {
        defer std.c.free(next_event);
        const next_type = @as(*u8, @ptrCast(next_event)).* & 0x7F;
        return next_type == xcb.XCB_MOTION_NOTIFY;
    }
    return false;
}

// Action execution

/// Close a window using the ICCCM WM_DELETE_WINDOW protocol
fn closeWindow(wm: *WM, win: u32) void {
    if (win == wm.root) {
        std.log.err("[CRITICAL] Attempted to close ROOT window! Aborting.", .{});
        return;
    }

    // Get WM_PROTOCOLS atom
    const wm_protocols_cookie = xcb.xcb_intern_atom(wm.conn, 0, 12, "WM_PROTOCOLS");
    const wm_protocols_reply = xcb.xcb_intern_atom_reply(wm.conn, wm_protocols_cookie, null);
    if (wm_protocols_reply == null) {
        std.log.warn("[input] Failed to get WM_PROTOCOLS atom, force destroying window", .{});
        _ = xcb.xcb_destroy_window(wm.conn, win);
        utils.flush(wm.conn);
        return;
    }
    defer std.c.free(wm_protocols_reply);
    const wm_protocols_atom = wm_protocols_reply.*.atom;

    // Get WM_DELETE_WINDOW atom
    const wm_delete_cookie = xcb.xcb_intern_atom(wm.conn, 0, 16, "WM_DELETE_WINDOW");
    const wm_delete_reply = xcb.xcb_intern_atom_reply(wm.conn, wm_delete_cookie, null);
    if (wm_delete_reply == null) {
        std.log.warn("[input] Failed to get WM_DELETE_WINDOW atom, force destroying window", .{});
        _ = xcb.xcb_destroy_window(wm.conn, win);
        utils.flush(wm.conn);
        return;
    }
    defer std.c.free(wm_delete_reply);
    const wm_delete_atom = wm_delete_reply.*.atom;

    // Check if window supports WM_DELETE_WINDOW
    const prop_cookie = xcb.xcb_get_property(wm.conn, 0, win, wm_protocols_atom, xcb.XCB_ATOM_ATOM, 0, 1024);
    const prop_reply = xcb.xcb_get_property_reply(wm.conn, prop_cookie, null);
    
    if (prop_reply) |reply| {
        defer std.c.free(reply);
        
        const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
        const atom_count: usize = @intCast(@divExact(xcb.xcb_get_property_value_length(reply), @as(c_int, @sizeOf(u32))));
        
        // Check if WM_DELETE_WINDOW is in the protocols list
        var supports_delete = false;
        for (0..atom_count) |i| {
            if (atoms[i] == wm_delete_atom) {
                supports_delete = true;
                break;
            }
        }
        
        if (supports_delete) {
            // Send WM_DELETE_WINDOW client message
            var event: xcb.xcb_client_message_event_t = undefined;
            event.response_type = xcb.XCB_CLIENT_MESSAGE;
            event.format = 32;
            event.sequence = 0;
            event.window = win;
            event.type = wm_protocols_atom;
            event.data.data32[0] = wm_delete_atom;
            event.data.data32[1] = xcb.XCB_CURRENT_TIME;
            event.data.data32[2] = 0;
            event.data.data32[3] = 0;
            event.data.data32[4] = 0;
            
            _ = xcb.xcb_send_event(wm.conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
            utils.flush(wm.conn);
            std.log.debug("[input] Sent WM_DELETE_WINDOW to window 0x{x}", .{win});
            return;
        }
    }
    
    // Window doesn't support WM_DELETE_WINDOW, force destroy it
    std.log.debug("[input] Window 0x{x} doesn't support WM_DELETE_WINDOW, force destroying", .{win});
    _ = xcb.xcb_destroy_window(wm.conn, win);
    utils.flush(wm.conn);
}

inline fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .toggle_fullscreen => @import("fullscreen").toggleFullscreen(wm),
        .close_window => {
            if (wm.focused_window) |win| {
                closeWindow(wm, win);
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
    }
}

/// Execute shell command via double-fork to prevent zombies
fn executeShellCommand(wm: *WM, cmd: []const u8) !void {
    const cmd_z = try wm.allocator.dupeZ(u8, cmd);
    defer wm.allocator.free(cmd_z);

    const pid = c.fork();
    if (pid == 0) {
        // First child
        const pid2 = c.fork();
        if (pid2 == 0) {
            // Second child - actually run the command
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
    std.log.info("========== STATE ==========", .{});
    std.log.info("Focused: {?x}", .{wm.focused_window});
    std.log.info("Total windows: {}", .{wm.windows.count()});

    if (workspaces.getState()) |ws_state| {
        std.log.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |*ws, i| {
            std.log.info("  WS{}: {} windows", .{ i + 1, ws.windows.items.len });
        }
    }

    if (tiling.getState()) |t_state| {
        std.log.info("Tiling: {} ({} windows)", .{ t_state.enabled, t_state.tiled_windows.items.len });
    }
    std.log.info("===========================", .{});
}

fn emergencyRecover(wm: *WM) void {
    std.log.warn("========== RECOVERY ==========", .{});

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
    std.log.warn("Recovery complete", .{});
}
