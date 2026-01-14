// Input handling - keyboard and mouse events

// INITIALIZATION

const std = @import("std");
const defs = @import("defs");
const xkbcommon = @import("xkbcommon");
const logging = @import("logging");
const tiling = @import("tiling");

const c = @cImport({
    @cInclude("unistd.h");
});

const xcb = defs.xcb;
const WM = defs.WM;
const Module = defs.Module;

// BODY

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_KEY_PRESS,
    xcb.XCB_BUTTON_PRESS,
    xcb.XCB_BUTTON_RELEASE,
    xcb.XCB_MOTION_NOTIFY,
};

var keybind_map: std.AutoHashMap(u64, *const defs.Action) = undefined;
var keybind_initialized = false;

// Drag state
const DragState = struct {
    // Grouped for clarity
    button: u8 = 0,
    subwindow: u32 = 0,
    start_x: i16 = 0,
    start_y: i16 = 0,
    attr_x: i16 = 0,
    attr_y: i16 = 0,
    attr_width: u16 = 0,
    attr_height: u16 = 0,

    fn isDragging(self: *const DragState) bool {
        return self.subwindow != 0;
    }

    fn reset(self: *DragState) void {
        self.subwindow = 0;
    }
};

var drag: DragState = .{};

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
        try keybind_map.put((@as(u64, keybind.modifiers) << 32) | keybind.keysym, &keybind.action);
    }
}

pub fn setupGrabs(conn: *xcb.xcb_connection_t, root: u32) void {
    _ = conn;
    _ = root;
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    switch (event_type & 0x7F) {
        xcb.XCB_KEY_PRESS => handleKeyPress(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_BUTTON_PRESS => handleButtonPress(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_MOTION_NOTIFY => handleMotionNotify(@ptrCast(@alignCast(event)), wm),
        xcb.XCB_BUTTON_RELEASE => handleButtonRelease(@ptrCast(@alignCast(event))),
        else => {},
    }
}

fn handleKeyPress(event: *const xcb.xcb_key_press_event_t, wm: *WM) void {
    // Raise window on keypress
    if (event.child != 0) {
        _ = xcb.xcb_configure_window(wm.conn, event.child,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    // Check for keybinding match
    const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(wm.xkb_state.?));
    const modifiers: u16 = @intCast(event.state & defs.MOD_MASK_RELEVANT);
    const keysym = xkb_ptr.keycodeToKeysym(event.detail);
    const key = (@as(u64, modifiers) << 32) | keysym;

    if (keybind_map.get(key)) |action| {
        logging.debugKeybindingMatched(modifiers, keysym);
        executeAction(action, wm) catch |err| {
            std.log.err("Failed to execute keybinding action: {}", .{err});
        };
    } else {
        logging.debugUnboundKey(event.detail, keysym, modifiers, @intCast(event.state));
    }
}

fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *WM) void {
    if (event.child == 0) return;

    logging.debugMouseButtonClick(event.detail, event.root_x, event.root_y, event.child);

    // Get window geometry and save drag state
    const geom_cookie = xcb.xcb_get_geometry(wm.conn, event.child);
    if (xcb.xcb_get_geometry_reply(wm.conn, geom_cookie, null)) |g| {
        defer std.c.free(g);
        drag = .{
            .button = event.detail,
            .subwindow = event.child,
            .start_x = event.root_x,
            .start_y = event.root_y,
            .attr_x = g.*.x,
            .attr_y = g.*.y,
            .attr_width = g.*.width,
            .attr_height = g.*.height,
        };
    }
}

fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t, wm: *WM) void {
    if (!drag.isDragging()) return;

    logging.debugDragMotion(event.root_x, event.root_y);

    const dx: i32 = event.root_x - drag.start_x;
    const dy: i32 = event.root_y - drag.start_y;
    const is_move = drag.button == 1;

    const geometry = [_]u32{
        @intCast(if (is_move) drag.attr_x + @as(i16, @intCast(dx)) else drag.attr_x),
        @intCast(if (is_move) drag.attr_y + @as(i16, @intCast(dy)) else drag.attr_y),
        @intCast(if (is_move) drag.attr_width else @max(1, drag.attr_width + dx)),
        @intCast(if (is_move) drag.attr_height else @max(1, drag.attr_height + dy)),
    };

    _ = xcb.xcb_configure_window(
        wm.conn, drag.subwindow,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &geometry,
    );
}

fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    _ = event;
    logging.debugMouseButtonRelease(drag.button);
    drag.reset();
}

fn executeAction(action: *const defs.Action, wm: *WM) !void {
    switch (action.*) {
        .exec => |cmd| {
            logging.debugExecutingCommand(cmd);
            // Crazy shit (I barely understand any of this)
            const pid = c.fork();
            if (pid < 0) {
                std.log.err("Fork failed for command: {s}", .{cmd});
            } else if (pid == 0) {
                _ = c.setsid();
                const cmd_z = try wm.allocator.dupeZ(u8, cmd);
                defer wm.allocator.free(cmd_z);
                _ = c.execvp("/bin/sh", @ptrCast(&[_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd_z.ptr, null }));
                std.process.exit(1);
            }
        },
        .close_window => if (wm.focused_window) |win_id| {
            logging.debugClosingWindow(win_id);
            _ = xcb.xcb_destroy_window(wm.conn, win_id);
            _ = xcb.xcb_flush(wm.conn);
        },
        .reload_config => {
            logging.debugConfigReloadTriggered();
            buildKeybindMap(wm) catch |err| {
                std.log.err("Failed to rebuild keybind map: {}", .{err});
            };
        },
        .focus_next, .focus_prev => logging.debugFocusNotImplemented(),
        
        // Tiling actions
        .toggle_layout => tiling.toggleLayout(wm),
        .increase_master => tiling.increaseMasterWidth(wm),
        .decrease_master => tiling.decreaseMasterWidth(wm),
        .increase_master_count => tiling.increaseMasterCount(wm),
        .decrease_master_count => tiling.decreaseMasterCount(wm),
        .toggle_tiling => tiling.toggleTiling(wm),
    }
}
