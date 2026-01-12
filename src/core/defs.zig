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
pub fn defaultModuleDeinit(_: *WM) void {
    // No cleanup needed
}

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
    keysym: u32,      // Changed from keycode: u8
    keycode: ?u8 = null,  // Cached keycode for X11 grabbing (populated at runtime)
    action: Action,

    /// Check if this keybinding matches given modifiers and keysym
    pub inline fn matches(self: *const Keybind, modifiers: u16, keysym: u32) bool {
        return self.modifiers == modifiers and self.keysym == keysym;
    }

    /// Check if this keybinding matches given modifiers and keycode (for X11 events)
    pub inline fn matchesKeycode(self: *const Keybind, modifiers: u16, keycode: u8) bool {
        return self.modifiers == modifiers and self.keycode == keycode;
    }

    /// Generate a hash key for fast HashMap lookups (if needed)
    pub inline fn hash(self: *const Keybind) u64 {
        return (@as(u64, self.modifiers) << 32) | self.keysym;
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

pub const Window = struct {
    id: u32,
    width: u16,
    height: u16,
    x: i16,
    y: i16,
    is_focused: bool,
    properties: WindowProperties,
    
    // Total: 4 + 2 + 2 + 2 + 2 + 1 + sizeof(WindowProperties) = better packing
};

// Window manager configuration loaded from config.toml
pub const Config = struct {
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
    // Changed to HashMap for O(1) window lookups by ID
    windows: std.AutoHashMap(u32, Window),
    focused_window: ?u32   = null,
    previous_focused: ?u32 = null,
    // XKB state for keyboard handling
    xkb_state: ?*xkbcommon.XkbState,

    pub fn deinit(self: *WM) void {
        // Clean up window properties
        var iter = self.windows.valueIterator();
        while (iter.next()) |win| {
            var mutable_win = win.*;
            mutable_win.properties.deinit(self.allocator);
        }
        self.windows.deinit();
        self.config.deinit(self.allocator);
        
        // Clean up XKB state
        if (self.xkb_state) |state| {
            const xkb_ptr: *xkbcommon.XkbState = @ptrCast(@alignCast(state));
            xkb_ptr.deinit();
            self.allocator.destroy(xkb_ptr);
        }
    }

    /// Get window by ID - O(1) lookup
    pub inline fn getWindow(self: *WM, window_id: u32) ?*Window {
        return self.windows.getPtr(window_id);
    }

    /// Add or update window - O(1) insertion
    pub inline fn putWindow(self: *WM, window: Window) !void {
        try self.windows.put(window.id, window);
    }

    /// Remove window - O(1) deletion
    pub inline fn removeWindow(self: *WM, window_id: u32) void {
        if (self.windows.fetchRemove(window_id)) |kv| {
            var win = kv.value;
            win.properties.deinit(self.allocator);
        }
    }

    /// Get focused window
    pub inline fn getFocusedWindow(self: *WM) ?*Window {
        const id = self.focused_window orelse return null;
        return self.getWindow(id);
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
