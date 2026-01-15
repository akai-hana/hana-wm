// Core type definitions
const std = @import("std");

const xkbcommon = @import("xkbcommon");

// Centralized XCB import - all modules must use this
pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

// X11 uses bit 7 to mark synthetic events
pub const X11_SYNTHETIC_EVENT_FLAG: u8 = 0x80;

// Default no-op deinit for modules that don't need cleanup
pub fn defaultModuleDeinit(_: *WM) void {}

// Modifier key masks (from X11)
pub const MOD_SHIFT:   u16 = 1 << 0;
pub const MOD_CONTROL: u16 = 1 << 2;
pub const MOD_ALT:     u16 = 1 << 3; // Mod1
pub const MOD_SUPER:   u16 = 1 << 6; // Mod4

pub const MOD_LOCK: u16 = 1 << 1; // CapsLock
pub const MOD_2:    u16 = 1 << 4; // NumLock
pub const MOD_3:    u16 = 1 << 5; // ScrollLock (rarely used)
pub const MOD_5:    u16 = 1 << 7;

// Mask to filter out lock keys - only keep modifiers we care about
pub const MOD_MASK_RELEVANT: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

// Keybinding action
pub const Action = union(enum) {
    exec:          []const u8, // Execute command
    reload_config: void,       // Reload configuration

    // Window
    close_window: void, // Close focused window
    focus_next:   void, // Focus next window
    focus_prev:   void, // Focus previous window

    // Tiling
    toggle_layout:         void,
    increase_master:       void,
    decrease_master:       void,
    increase_master_count: void,
    decrease_master_count: void,
    toggle_tiling:         void,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        if (self.* == .exec) allocator.free(self.exec);
    }
};

// Keybinding definition
pub const Keybind = struct {
    modifiers: u16,
    keysym:    u32,
    keycode:   ?u8 = null, // Cached keycode for X11 grabbing (populated at runtime)
    action:    Action,
};

// Window type hints from _NET_WM_WINDOW_TYPE
pub const WindowType = enum {
    normal,
    dialog,
    dock,
    toolbar,
    menu,
    splash,
    utility,
};

// Window properties from X11
pub const WindowProperties = struct {
    name: ?[]const u8 = null,
    class: ?[]const u8 = null,
    window_type: WindowType = .normal,

    pub fn deinit(self: *WindowProperties, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        if (self.class) |c| allocator.free(c);
    }
};

pub const Window = struct {
    id:         u32,
    width:      u16,
    height:     u16,
    x:          i16,
    y:          i16,
    is_focused: bool,
    properties: WindowProperties,
};

// Tiling configuration
pub const TilingConfig = struct {
    enabled: bool = true,
    layout: []const u8 = "master_left",  // "master_left", "monocle", or "grid"
    master_width_factor: f32 = 0.55,
    master_count: usize = 1,
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2,
    border_normal: u32 = 0x383C4A,
};

// Window manager configuration loaded from config.toml
pub const Config = struct {
    keybindings: std.ArrayList(Keybind) = .{},
    tiling: TilingConfig = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| kb.action.deinit(allocator);
        self.keybindings.deinit(allocator);
    }
};

// Window manager state and resources
pub const WM = struct {
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: u32,
    config: Config,
    windows: std.AutoHashMap(u32, Window),
    focused_window: ?u32 = null,
    previous_focused: ?u32 = null,
    xkb_state: ?*xkbcommon.XkbState,

    pub fn deinit(self: *WM) void {
        var iter = self.windows.valueIterator();
        while (iter.next()) |win| {
            var w = win.*;
            w.properties.deinit(self.allocator);
        }
        self.windows.deinit();
        self.config.deinit(self.allocator);
        
        if (self.xkb_state) |state| {
            const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(state));
            xkb_ptr.deinit();
            self.allocator.destroy(xkb_ptr);
        }
    }

    pub fn getWindow(self: *WM, window_id: u32) ?*Window {
        return self.windows.getPtr(window_id);
    }

    pub fn putWindow(self: *WM, window: Window) !void {
        try self.windows.put(window.id, window);
    }

    pub fn removeWindow(self: *WM, window_id: u32) void {
        if (self.windows.fetchRemove(window_id)) |kv| {
            var win = kv.value;
            win.properties.deinit(self.allocator);
        }
    }

    pub fn getFocusedWindow(self: *WM) ?*Window {
        return if (self.focused_window) |id| self.getWindow(id) else null;
    }
};

// Modular event handler - each module registers events it wants to handle
pub const Module = struct {
    name:        []const u8,
    event_types: []const u8,
    init_fn:     *const fn (*WM) void,
    handle_fn:   *const fn (u8, *anyopaque, *WM) void,
    deinit_fn:   ?*const fn (*WM) void = null,
};

/// Extract the module name at comptime using @typeName
pub fn generateModule(comptime T: type) Module {
    const name = comptime n: {
        const full_name = @typeName(T);
        // @typeName(T) usually returns "input" or "core.input"
        const last_dot = std.mem.lastIndexOfScalar(u8, full_name, '.');
        break :n if (last_dot) |idx| full_name[idx + 1 ..] else full_name;
    };

    return .{
        .name = name,
        .event_types = &T.EVENT_TYPES,
        .init_fn = T.init,
        .handle_fn = T.handleEvent,
        .deinit_fn = if (@hasDecl(T, "deinit")) T.deinit else null,
    };
}
