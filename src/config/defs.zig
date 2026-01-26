//! Core type definitions for window manager state and configuration.

const std = @import("std");

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const xkbcommon = @import("xkbcommon");

pub const MOD_SHIFT: u16 = xcb.XCB_MOD_MASK_SHIFT;
pub const MOD_LOCK: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const MOD_CONTROL: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT: u16 = xcb.XCB_MOD_MASK_1;
pub const MOD_2: u16 = xcb.XCB_MOD_MASK_2;
pub const MOD_SUPER: u16 = xcb.XCB_MOD_MASK_4;

pub const MOD_MASK_RELEVANT: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

pub const MIN_WINDOW_DIM: u16 = 50;
pub const MAX_WINDOW_DIM: u16 = 65535;

pub const FOCUS_PROTECTION_GRACE_NS: u64 = 50 * std.time.ns_per_ms;
pub const XKB_RETRY_DELAY_MS: u64 = 20;
pub const XKB_MAX_RETRIES: usize = 50;

pub const MAX_EVENT_BATCH_SIZE: usize = 10;
pub const EVENT_POLL_SLEEP_NS: u64 = 1 * std.time.ns_per_ms;
pub const ASYNC_JOBS_PER_ITERATION: usize = 5;

pub const IDLE_THRESHOLD_SHORT: usize = 10;
pub const IDLE_THRESHOLD_LONG: usize = 50;
pub const SLEEP_MULTIPLIER_MEDIUM: u64 = 2;
pub const SLEEP_MULTIPLIER_LONG: u64 = 5;

pub const MAX_WORKSPACES: usize = 20;
pub const MIN_WORKSPACES: usize = 1;
pub const MAX_BORDER_WIDTH: u16 = 100;
pub const MAX_GAPS: u16 = 200;
pub const MIN_MASTER_WIDTH: f32 = 0.05;
pub const MAX_MASTER_WIDTH: f32 = 0.95;

pub const Action = union(enum) {
    exec: []const u8,
    close_window,
    reload_config,
    toggle_layout,
    increase_master,
    decrease_master,
    increase_master_count,
    decrease_master_count,
    toggle_tiling,
    toggle_fullscreen,
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

pub const MasterSide = enum {
    left,
    right,

    pub fn fromString(str: []const u8) ?MasterSide {
        if (std.mem.eql(u8, str, "left")) return .left;
        if (std.mem.eql(u8, str, "right")) return .right;
        return null;
    }

    pub fn toString(self: MasterSide) []const u8 {
        return switch (self) {
            .left => "left",
            .right => "right",
        };
    }
};

pub const TilingConfig = struct {
    enabled: bool = true,
    layout: []const u8 = "master_left",
    master_side: MasterSide = .left,
    master_width_factor: f32 = 0.50,
    master_count: usize = 1,
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2,
    border_normal: u32 = 0x383C4A,
};

pub const BarConfig = struct {
    show: bool = true,
    height: u16 = 24,
    font: []const u8 = "monospace:size=10",
    font_size: u16 = 10,
    bg: u32 = 0x222222,
    fg: u32 = 0xBBBBBB,
    selected_bg: u32 = 0x005577,
    selected_fg: u32 = 0xEEEEEE,
    occupied_fg: u32 = 0xEEEEEE,
    urgent_bg: u32 = 0xFF0000,
    urgent_fg: u32 = 0xFFFFFF,
    workspace_chars: []const u8 = "123456789",
    indicator_size: u16 = 4,
    title_accent: bool = true,
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
    bar: BarConfig = .{},

    allocated_font: ?[]const u8 = null,
    allocated_layout: ?[]const u8 = null,
    allocated_workspace_chars: ?[]const u8 = null,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| {
            kb.action.deinit(allocator);
        }
        self.keybindings.deinit(allocator);

        for (self.workspaces.rules.items) |*rule| {
            rule.deinit(allocator);
        }
        self.workspaces.rules.deinit(allocator);

        if (self.allocated_font) |f| allocator.free(f);
        if (self.allocated_layout) |l| allocator.free(l);
        if (self.allocated_workspace_chars) |w| allocator.free(w);
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
    fullscreen_window: ?u32 = null,
    fullscreen_geometry: ?struct {
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
    } = null,
    xkb_state: ?*xkbcommon.XkbState,
    should_reload_config: *std.atomic.Value(bool),
    running: *std.atomic.Value(bool),

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
