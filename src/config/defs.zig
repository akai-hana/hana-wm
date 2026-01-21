//! Core type definitions for window manager state and configuration.

const std = @import("std");

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const xkbcommon = @import("xkbcommon");

// Modifier key masks
pub const MOD_SHIFT: u16 = xcb.XCB_MOD_MASK_SHIFT;
pub const MOD_LOCK: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const MOD_CONTROL: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT: u16 = xcb.XCB_MOD_MASK_1;
pub const MOD_2: u16 = xcb.XCB_MOD_MASK_2;
pub const MOD_SUPER: u16 = xcb.XCB_MOD_MASK_4;

pub const MOD_MASK_RELEVANT: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

pub const Action = union(enum) {
    exec: []const u8,
    close_window,
    reload_config,
    focus_next,
    focus_prev,
    toggle_layout,
    increase_master,
    decrease_master,
    increase_master_count,
    decrease_master_count,
    toggle_tiling,
    switch_workspace: usize,
    move_to_workspace: usize,
    dump_state,
    emergency_recover,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exec => |cmd| allocator.free(cmd),
            else => {},
        }
    }
};

pub const Keybind = struct {
    modifiers: u16,
    keysym: u32,
    keycode: ?u8 = null,
    action: Action,
};

pub const TilingConfig = struct {
    enabled: bool = true,
    layout: []const u8 = "master_left",
    master_width_factor: f32 = 0.50,
    master_count: usize = 1,
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2,
    border_normal: u32 = 0x383C4A,
};

pub const Rule = struct {
    class_name: []const u8,
    workspace: usize,

    pub fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.class_name);
    }
};

pub const WorkspaceConfig = struct {
    count: usize = 9,
    rules: std.ArrayListUnmanaged(Rule) = .{},
};

pub const WindowProperties = std.StringHashMap([]const u8);

pub const Window = struct {
    id: u32,
    properties: WindowProperties,

    pub fn init(allocator: std.mem.Allocator, id: u32) Window {
        return .{
            .id = id,
            .properties = WindowProperties.init(allocator),
        };
    }
};

pub const Config = struct {
    keybindings: std.ArrayListUnmanaged(Keybind) = .{},
    tiling: TilingConfig = .{},
    workspaces: WorkspaceConfig = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| {
            kb.action.deinit(allocator);
        }
        self.keybindings.deinit(allocator);

        for (self.workspaces.rules.items) |*rule| {
            rule.deinit(allocator);
        }
        self.workspaces.rules.deinit(allocator);
    }
};

pub const WM = struct {
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: u32,
    config: Config,
    windows: std.AutoHashMap(u32, Window),
    focused_window: ?u32 = null,
    xkb_state: ?*xkbcommon.XkbState,
    should_reload_config: *std.atomic.Value(bool),

    pub fn deinit(self: *WM) void {
        var iter = self.windows.valueIterator();
        while (iter.next()) |win| {
            var w = win.*;
            w.properties.deinit();
        }
        self.windows.deinit();
        self.config.deinit(self.allocator);
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
            win.properties.deinit();
        }
    }

    pub fn getFocusedWindow(self: *WM) ?*Window {
        return if (self.focused_window) |id| self.getWindow(id) else null;
    }
};

pub const Module = struct {
    name: []const u8,
    event_types: []const u8,
    init_fn: *const fn (*WM) void,
    handle_fn: *const fn (u8, *anyopaque, *WM) void,
    deinit_fn: ?*const fn (*WM) void,
};

pub fn generateModule(comptime module: type) Module {
    return Module{
        .name = @typeName(module),
        .event_types = &module.EVENT_TYPES,
        .init_fn = module.init,
        .handle_fn = module.handleEvent,
        .deinit_fn = if (@hasDecl(module, "deinit")) module.deinit else null,
    };
}
