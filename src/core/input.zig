// Input handling - ONLY keyboard, mouse is handled in main.zig

const std            = @import("std");
const defs           = @import("defs");
const xkbcommon      = @import("xkbcommon");
const logging        = @import("logging");

const c = @cImport({
    @cInclude("unistd.h");
});

const xcb = defs.xcb;
const WM = defs.WM;
const Module = defs.Module;

// Only keyboard events - mouse is TinyWM-style in main.zig
pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
};

var keybind_map: std.AutoHashMap(u64, *const defs.Action) = undefined;
var keybind_initialized = false;

pub fn init(wm: *WM) void {
    keybind_map = std.AutoHashMap(u64, *const defs.Action).init(wm.allocator);
    buildKeybindMap(wm) catch |err| {
        std.log.err("Failed to build keybind map: {}", .{err});
        return;
    };
    keybind_initialized = true;
    logging.debugInputModuleInit(keybind_map.count());
}

pub fn deinit(_: *WM) void {
    if (keybind_initialized) {
        keybind_map.deinit();
        keybind_initialized = false;
    }
}

fn buildKeybindMap(wm: *WM) !void {
    keybind_map.clearRetainingCapacity();
    
    for (wm.config.keybindings.items) |*keybind| {
        const key = makeKeybindKey(keybind.modifiers, keybind.keysym);
        try keybind_map.put(key, &keybind.action);
    }
}

inline fn makeKeybindKey(modifiers: u16, keysym: u32) u64 {
    return (@as(u64, modifiers) << 32) | keysym;
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const response_type = event_type & ~defs.X11_SYNTHETIC_EVENT_FLAG;

    if (response_type == xcb.XCB_KEY_PRESS) {
        const ev = @as(*const xcb.xcb_key_press_event_t, @alignCast(@ptrCast(event)));
        handleKeyPress(ev, wm);
    }
}

fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    const keycode = event.detail;
    const raw_modifiers: u16 = @intCast(event.state);
    const modifiers = raw_modifiers & defs.MOD_MASK_RELEVANT;

    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));
    const keysym = xkb_ptr.keycodeToKeysym(keycode);

    const key = makeKeybindKey(modifiers, keysym);
    
    if (keybind_map.get(key)) |action| {
        logging.debugKeybindingMatched(modifiers, keysym);
        executeAction(action, wm) catch |err| {
            std.log.err("Failed to execute keybinding action: {}", .{err});
        };
        return;
    }

    logging.debugUnboundKey(keycode, keysym, modifiers, raw_modifiers);
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| {
            logging.debugExecutingCommand(cmd);

            const pid = c.fork();
            if (pid == 0) {
                _ = c.setsid();
                
                const cmd_z = try wm.allocator.dupeZ(u8, cmd);
                defer wm.allocator.free(cmd_z);

                const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null };
                _ = c.execvp("/bin/sh", @ptrCast(&argv));
                
                std.log.err("Failed to exec: {s}", .{cmd});
                std.process.exit(1);
            } else if (pid < 0) {
                std.log.err("Fork failed for command: {s}", .{cmd});
            }
        },
        .close_window => {
            if (wm.focused_window) |win_id| {
                logging.debugClosingWindow(win_id);
                _ = xcb.xcb_destroy_window(wm.conn, win_id);
                _ = xcb.xcb_flush(wm.conn);
            }
        },
        .reload_config => {
            logging.debugConfigReloadTriggered();
            buildKeybindMap(wm) catch |err| {
                std.log.err("Failed to rebuild keybind map: {}", .{err});
            };
        },
        .focus_next, .focus_prev => {
            logging.debugFocusNotImplemented();
        },
    }
}

pub fn createModule() Module {
    return Module{
        .name = "input",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
    };
}
