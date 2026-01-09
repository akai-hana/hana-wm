// Core type definitions

const std = @import("std");

// Centralized XCB import - all modules must use this
pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

// X11 uses bit 7 to mark synthetic events
pub const X11_SYNTHETIC_EVENT_FLAG: u8 = 0x80;

// Modifier key masks (from X11)
pub const MOD_SHIFT: u16 = 1 << 0;
pub const MOD_CONTROL: u16 = 1 << 2;
pub const MOD_ALT: u16 = 1 << 3;      // Mod1
pub const MOD_SUPER: u16 = 1 << 6;     // Mod4

// Keybinding action
pub const Action = union(enum) {
    exec: []const u8,           // Execute command
    close_window: void,         // Close focused window
    reload_config: void,        // Reload configuration
    focus_next: void,           // Focus next window
    focus_prev: void,           // Focus previous window

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exec => |cmd| allocator.free(cmd),
            else => {},
        }
    }
};

// Keybinding definition
pub const Keybind = struct {
    modifiers: u16,
    keycode: u8,
    action: Action,

    pub fn matches(self: *const Keybind, modifiers: u16, keycode: u8) bool {
        return self.modifiers == modifiers and self.keycode == keycode;
    }
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
        if (self.name) |name| allocator.free(name);
        if (self.class) |class| allocator.free(class);
    }
};

// Managed window state
pub const Window = struct {
    id: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    is_focused: bool,
    properties: WindowProperties,
};

// Window manager configuration loaded from config.toml
pub const Config = struct {
    border_width: u12,
    border_focused: u24,
    border_unfocused: u24,
    gap_inner: u16,
    gap_outer: u16,
    keybindings: std.ArrayList(Keybind),

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| {
            kb.action.deinit(allocator);
        }
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
    windows: std.ArrayList(Window),
    focused_window: ?u32 = null,

    pub fn deinit(self: *WM) void {
        for (self.windows.items) |*win| {
            win.properties.deinit(self.allocator);
        }
        self.windows.deinit(self.allocator);
        self.config.deinit(self.allocator);
    }
};

// Modular event handler - each module registers events it wants to handle
pub const Module = struct {
    name: []const u8,
    // XCB event type codes this module handles (e.g. XCB_KEY_PRESS, XCB_BUTTON_PRESS)
    // Used to filter events before calling handle_fn (performance optimization)
    event_types: []const u8,
    init_fn: *const fn (*WM) void,
    // Handles events - event_data is a pointer to the XCB event struct (cast as needed)
    handle_fn: *const fn (u8, *anyopaque, *WM) void,
    // Optional cleanup function
    deinit_fn: ?*const fn (*WM) void = null,
};
