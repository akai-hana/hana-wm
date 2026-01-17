//! Core type definitions for Hana window manager.
//!
//! This module defines all shared data structures including:
//! - Window manager state (WM)
//! - Configuration structures
//! - Action and keybinding types
//! - Module system
//! - XCB/X11 bindings

const std = @import("std");

/// XCB bindings for X11 protocol
pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

/// Re-export xkbcommon for convenience
pub const xkbcommon = @import("xkbcommon");

// === Modifier Key Masks ===

pub const MOD_SHIFT: u16 = xcb.XCB_MOD_MASK_SHIFT;
pub const MOD_LOCK: u16 = xcb.XCB_MOD_MASK_LOCK;      // CapsLock
pub const MOD_CONTROL: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT: u16 = xcb.XCB_MOD_MASK_1;          // Alt/Meta
pub const MOD_2: u16 = xcb.XCB_MOD_MASK_2;            // NumLock
pub const MOD_SUPER: u16 = xcb.XCB_MOD_MASK_4;        // Super/Windows key

/// Mask for relevant modifiers (excludes locks for matching)
pub const MOD_MASK_RELEVANT: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

// === Action System ===

/// Actions that can be bound to keybindings
pub const Action = union(enum) {
    /// Execute a shell command
    exec: []const u8,

    /// Close the focused window
    close_window,

    /// Reload configuration from disk
    reload_config,

    /// Focus next window (not yet implemented)
    focus_next,

    /// Focus previous window (not yet implemented)
    focus_prev,

    /// Cycle through tiling layouts
    toggle_layout,

    /// Increase master area width
    increase_master,

    /// Decrease master area width
    decrease_master,

    /// Increase number of master windows
    increase_master_count,

    /// Decrease number of master windows
    decrease_master_count,

    /// Toggle tiling on/off
    toggle_tiling,

    /// Switch to workspace N (0-indexed)
    switch_workspace: usize,

    /// Move focused window to workspace N (0-indexed)
    move_to_workspace: usize,

    /// Dump current WM state for debugging
    dump_state,

    /// Emergency recovery - map all windows and disable tiling
    emergency_recover,

    /// Free allocated memory (for exec commands)
    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exec => |cmd| allocator.free(cmd),
            else => {},
        }
    }
};

/// A keybinding mapping key combination to action
pub const Keybind = struct {
    /// Modifier keys (Shift, Control, Alt, Super)
    modifiers: u16,

    /// X11 keysym (symbolic key identifier)
    keysym: u32,

    /// Physical keycode (resolved at runtime from keysym)
    keycode: ?u8 = null,

    /// Action to execute when triggered
    action: Action,
};

// === Configuration ===

/// Tiling system configuration
pub const TilingConfig = struct {
    /// Enable/disable tiling
    enabled: bool = true,

    /// Default layout name
    layout: []const u8 = "master_left",

    /// Master area width as fraction (0.05 - 0.95)
    master_width_factor: f32 = 0.50,

    /// Number of windows in master area
    master_count: usize = 1,

    /// Gap size in pixels
    gaps: u16 = 10,

    /// Border width in pixels
    border_width: u16 = 2,

    /// Focused window border color (RGB hex)
    border_focused: u32 = 0x5294E2,

    /// Unfocused window border color (RGB hex)
    border_normal: u32 = 0x383C4A,
};

/// Window placement rule
pub const Rule = struct {
    /// WM_CLASS class or instance name to match
    class_name: []const u8,
    
    /// Target workspace (0-indexed)
    workspace: usize,
    
    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.class_name);
    }
};

/// Virtual desktop configuration
pub const WorkspaceConfig = struct {
    /// Number of workspaces to create
    count: usize = 9,
    
    /// Window placement rules
    rules: std.ArrayListUnmanaged(Rule) = .{},
};

/// Window metadata storage
pub const WindowProperties = std.StringHashMap([]const u8);

/// Managed window state
pub const Window = struct {
    /// X11 window ID
    id: u32,

    /// Custom properties (extensible)
    properties: WindowProperties,

    pub fn init(allocator: std.mem.Allocator, id: u32) Window {
        return .{
            .id = id,
            .properties = WindowProperties.init(allocator),
        };
    }
};

/// Complete window manager configuration
pub const Config = struct {
    /// All configured keybindings
    keybindings: std.ArrayListUnmanaged(Keybind) = .{},

    /// Tiling settings
    tiling: TilingConfig = .{},

    /// Workspace settings
    workspaces: WorkspaceConfig = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| {
            kb.action.deinit(allocator);
        }
        self.keybindings.deinit(allocator);
        
        // Clean up workspace rules
        for (self.workspaces.rules.items) |*rule| {
            rule.deinit(allocator);
        }
        self.workspaces.rules.deinit(allocator);
    }
};

// === Window Manager State ===

/// Main window manager state and resources
pub const WM = struct {
    /// Memory allocator
    allocator: std.mem.Allocator,

    /// XCB connection to X server
    conn: *xcb.xcb_connection_t,

    /// Default screen
    screen: *xcb.xcb_screen_t,

    /// Root window ID
    root: u32,

    /// Current configuration
    config: Config,

    /// All managed windows
    windows: std.AutoHashMap(u32, Window),

    /// Currently focused window ID
    focused_window: ?u32 = null,

    /// XKB keyboard state
    xkb_state: ?*xkbcommon.XkbState,

    /// Flag to trigger config reload on next event loop iteration
    should_reload_config: *std.atomic.Value(bool),

    pub fn deinit(self: *WM) void {
        // Clean up all window properties
        var iter = self.windows.valueIterator();
        while (iter.next()) |win| {
            var w = win.*;
            w.properties.deinit();
        }
        self.windows.deinit();
        self.config.deinit(self.allocator);
    }

    /// Get mutable reference to a window
    pub fn getWindow(self: *WM, window_id: u32) ?*Window {
        return self.windows.getPtr(window_id);
    }

    /// Add or update a window
    pub fn putWindow(self: *WM, window: Window) !void {
        try self.windows.put(window.id, window);
    }

    /// Remove a window and clean up its resources
    pub fn removeWindow(self: *WM, window_id: u32) void {
        if (self.windows.fetchRemove(window_id)) |kv| {
            var win = kv.value;
            win.properties.deinit();
        }
    }

    /// Get currently focused window
    pub fn getFocusedWindow(self: *WM) ?*Window {
        return if (self.focused_window) |id| self.getWindow(id) else null;
    }
};

// === Module System ===

/// A module that handles specific X11 events
pub const Module = struct {
    /// Module name for debugging
    name: []const u8,

    /// Event types this module handles
    event_types: []const u8,

    /// Initialization function
    init_fn: *const fn (*WM) void,

    /// Event handler function
    handle_fn: *const fn (u8, *anyopaque, *WM) void,

    /// Optional cleanup function
    deinit_fn: ?*const fn (*WM) void,
};

/// Generate a Module from a type with init, handleEvent, deinit functions
pub fn generateModule(comptime module: type) Module {
    return Module{
        .name = @typeName(module),
        .event_types = &module.EVENT_TYPES,
        .init_fn = module.init,
        .handle_fn = module.handleEvent,
        .deinit_fn = if (@hasDecl(module, "deinit")) module.deinit else null,
    };
}
