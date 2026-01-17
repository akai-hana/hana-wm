//! Input event handling for keyboard and mouse.
//!
//! Handles:
//! - Keybinding matching and action execution
//! - Mouse button events for window dragging/resizing
//! - Focus changes on mouse enter
//! - Configuration-based keybinding map

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const log = @import("logging");
const tiling = @import("tiling");
const workspaces = @import("workspaces");
const cursor_drag = @import("cursor-window-drag");
const focus = @import("focus");

const c = @cImport({
    @cInclude("unistd.h");
});

// Declare waitpid explicitly - it's from sys/wait.h
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;

const xcb = defs.xcb;
const WM = defs.WM;

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_BUTTON_PRESS,
    xcb.XCB_BUTTON_RELEASE,
    xcb.XCB_MOTION_NOTIFY,
};

/// Fast lookup table: (modifiers << 32 | keysym) -> Action
var keybind_map: std.AutoHashMap(u64, *const defs.Action) = undefined;
var keybind_initialized = false;

pub fn init(wm: *WM) void {
    keybind_map = std.AutoHashMap(u64, *const defs.Action).init(wm.allocator);
    buildKeybindMap(wm) catch |err| {
        log.errorKeybindMapBuildFailed(err);
        return;
    };
    keybind_initialized = true;
    log.debugInputModuleInit(keybind_map.count());
}

pub fn deinit(_: *WM) void {
    if (keybind_initialized) {
        keybind_map.deinit();
        keybind_initialized = false;
    }
}

/// Build hashmap for O(1) keybinding lookups
fn buildKeybindMap(wm: *WM) !void {
    keybind_map.clearRetainingCapacity();
    for (wm.config.keybindings.items) |*keybind| {
        const key = (@as(u64, keybind.modifiers) << 32) | keybind.keysym;
        try keybind_map.put(key, &keybind.action);
    }
}

/// Rebuild keybind map after config reload
pub fn rebuildKeybindMap(wm: *WM) !void {
    try buildKeybindMap(wm);
    log.debugInputModuleInit(keybind_map.count());
}

/// Setup mouse button grabs for window manipulation
/// Super+Button1 = move window, Super+Button3 = resize window
pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    inline for ([_]u8{ 1, 3 }) |button| {
        _ = xcb.xcb_grab_button(
            conn, 0, root,
            xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE | xcb.XCB_EVENT_MASK_POINTER_MOTION,
            xcb.XCB_GRAB_MODE_ASYNC, xcb.XCB_GRAB_MODE_ASYNC,
            root, xcb.XCB_NONE, button, defs.MOD_SUPER,
        );
    }
    _ = xcb.xcb_flush(conn);
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    switch (event_type & 0x7F) {
        xcb.XCB_KEY_PRESS => handleKeyPress(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_BUTTON_PRESS => handleButtonPress(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_MOTION_NOTIFY => {
            if (cursor_drag.isDragging()) {
                const e: *const xcb.xcb_motion_notify_event_t = @ptrCast(@alignCast(event));
                cursor_drag.updateDrag(wm, e.root_x, e.root_y);
            }
        },
        xcb.XCB_BUTTON_RELEASE => {
            if (cursor_drag.isDragging()) cursor_drag.stopDrag(wm);
        },
        else => {},
    }
}

/// Handle key press events - lookup and execute actions
fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));

    // Extract relevant modifiers (ignore locks)
    const modifiers: u16 = @intCast(event.state & defs.MOD_MASK_RELEVANT);
    const keysym = xkb_ptr.keycodeToKeysym(event.detail);
    const key = (@as(u64, modifiers) << 32) | keysym;

    if (keybind_map.get(key)) |action| {
        log.debugKeybindingMatched(modifiers, keysym);
        executeAction(action, wm) catch |err| {
            log.errorActionExecutionFailed(err);
        };
    } else {
        log.debugUnboundKey(event.detail, keysym, modifiers, @intCast(event.state));
    }
}

/// Handle mouse button presses - window focus or drag
fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    if (event.child == 0) return; // Click on root window, ignore

    const has_super = (event.state & defs.MOD_SUPER) != 0;

    if (has_super and (event.detail == 1 or event.detail == 3)) {
        // Super+Button1/3: Start window drag/resize
        log.debugMouseButtonClick(event.detail, event.root_x, event.root_y, event.child);
        cursor_drag.startDrag(wm, event.child, event.detail, event.root_x, event.root_y);
    } else {
        // Normal click: Focus and raise window
        focus.setFocus(wm, event.child, .mouse_click);
        // Note: flush happens at end of event loop in main.zig
    }
}

/// Execute a keybinding action
fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| try executeShellCommand(wm, cmd),
        .close_window => closeWindow(wm),
        .reload_config => try reloadConfig(wm),
        .focus_next, .focus_prev => log.debugFocusNotImplemented(),
        .toggle_layout => tiling.toggleLayout(wm),
        .increase_master => tiling.increaseMasterWidth(wm),
        .decrease_master => tiling.decreaseMasterWidth(wm),
        .increase_master_count => tiling.increaseMasterCount(wm),
        .decrease_master_count => tiling.decreaseMasterCount(wm),
        .toggle_tiling => tiling.toggleTiling(wm),
        .switch_workspace => |ws| workspaces.switchTo(wm, ws),
        .move_to_workspace => |ws| workspaces.moveWindowTo(wm, ws),
        .dump_state => dumpState(wm),
        .emergency_recover => emergencyRecover(wm),
    }
}

/// Execute a shell command in a forked process
/// Uses double-fork to avoid zombie processes
fn executeShellCommand(wm: *WM, cmd: []const u8) !void {
    log.debugExecutingCommand(cmd);

    const pid = c.fork();
    if (pid == 0) {
        // Child process - fork again to avoid zombies
        const pid2 = c.fork();
        if (pid2 == 0) {
            // Grandchild process - actually runs the command
            _ = c.setsid();
            const cmd_z = try wm.allocator.dupeZ(u8, cmd);
            defer wm.allocator.free(cmd_z);
            _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null }));
            std.process.exit(1);
        } else if (pid2 < 0) {
            std.process.exit(1);
        }
        // First child exits immediately (grandchild orphaned and adopted by init)
        std.process.exit(0);
    } else if (pid > 0) {
        // Parent reaps first child to prevent zombie
        var status: c_int = 0;
        _ = waitpid(pid, &status, 0);
    } else {
        log.errorCommandForkFailed(cmd);
    }
}

/// Close the currently focused window
fn closeWindow(wm: *WM) void {
    if (wm.focused_window) |win_id| {
        log.debugClosingWindow(win_id);
        _ = xcb.xcb_destroy_window(wm.conn, win_id);
    } else {
        log.debugNoFocusedWindow();
    }
}

/// Trigger configuration reload
fn reloadConfig(wm: *WM) !void {
    log.debugConfigReloadTriggered();
    wm.should_reload_config.store(true, .release);
}

/// Dump current WM state for debugging
fn dumpState(wm: *WM) void {
    std.log.info("========== WM STATE DUMP ==========", .{});
    std.log.info("Focused: {?}", .{wm.focused_window});
    std.log.info("Total managed windows: {}", .{wm.windows.count()});

    // Dump workspace state
    if (workspaces.getState()) |ws_state| {
        std.log.info("Current workspace: {}", .{ws_state.current + 1});
        for (ws_state.workspaces, 0..) |*ws, i| {
            std.log.info("  WS{}: {} windows", .{i + 1, ws.windows.items.len});
            for (ws.windows.items) |win| {
                const is_mapped = checkIfMapped(wm, win);
                std.log.info("    0x{x}: mapped={}", .{win, is_mapped});
            }
        }
    }

    // Dump tiling state
    if (tiling.getState()) |t_state| {
        std.log.info("Tiling: {} ({} windows)",
            .{t_state.enabled, t_state.tiled_windows.items.len});
        std.log.info("Layout: {s}", .{@tagName(t_state.layout)});
    }
    std.log.info("===================================", .{});
}

/// Check if a window is currently mapped
fn checkIfMapped(wm: *WM, window: u32) bool {
    const cookie = xcb.xcb_get_window_attributes(wm.conn, window);
    if (xcb.xcb_get_window_attributes_reply(wm.conn, cookie, null)) |attrs| {
        defer std.c.free(attrs);
        return attrs.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
    }
    return false;
}

/// Emergency recovery - map all windows and disable tiling
fn emergencyRecover(wm: *WM) void {
    std.log.warn("========== EMERGENCY RECOVERY ==========", .{});

    // Map ALL windows from ALL workspaces
    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces) |*ws| {
            for (ws.windows.items) |win| {
                std.log.warn("Mapping window 0x{x}", .{win});
                _ = xcb.xcb_map_window(wm.conn, win);
            }
        }
    }

    // Disable tiling temporarily
    if (tiling.getState()) |t_state| {
        t_state.enabled = false;
        std.log.warn("Tiling disabled", .{});
    }

    _ = xcb.xcb_flush(wm.conn);
    std.log.warn("Recovery complete - all windows mapped, tiling disabled", .{});
    std.log.warn("Press Mod+Shift+d to see current state", .{});
}
