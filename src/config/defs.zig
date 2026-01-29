//! Core type definitions

const std = @import("std");

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const xkbcommon = @import("xkbcommon");

// Modifier masks
pub const MOD_SHIFT: u16 = xcb.XCB_MOD_MASK_SHIFT;
pub const MOD_LOCK: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const MOD_CONTROL: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT: u16 = xcb.XCB_MOD_MASK_1;
pub const MOD_2: u16 = xcb.XCB_MOD_MASK_2;
pub const MOD_SUPER: u16 = xcb.XCB_MOD_MASK_4;

pub const MOD_MASK_RELEVANT: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

// Window constraints
pub const MIN_WINDOW_DIM: u16 = 50;
pub const MAX_WINDOW_DIM: u16 = 65535;
pub const MAX_WINDOWS: usize = 128;  // For stack buffers

// XKB initialization
pub const XKB_RETRY_DELAY_MS: u64 = 20;
pub const XKB_MAX_RETRIES: usize = 50;

// Workspace limits
pub const MAX_WORKSPACES: usize = 20;
pub const MIN_WORKSPACES: usize = 1;

// Tiling constraints
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

pub const BarPosition = enum {
    left,
    center,
    right,

    pub fn fromString(str: []const u8) ?BarPosition {
        if (std.mem.eql(u8, str, "left")) return .left;
        if (std.mem.eql(u8, str, "center")) return .center;
        if (std.mem.eql(u8, str, "right")) return .right;
        return null;
    }
};

pub const BarSegment = enum {
    workspaces,
    title,
    clock,
    layout,

    pub fn fromString(str: []const u8) ?BarSegment {
        if (std.mem.eql(u8, str, "workspaces")) return .workspaces;
        if (std.mem.eql(u8, str, "title")) return .title;
        if (std.mem.eql(u8, str, "clock")) return .clock;
        if (std.mem.eql(u8, str, "layout")) return .layout;
        return null;
    }
};

pub const BarLayout = struct {
    position: BarPosition,
    segments: std.ArrayList(BarSegment),

    pub fn deinit(self: *BarLayout, allocator: std.mem.Allocator) void {
        self.segments.deinit(allocator);
    }
};

pub const BarConfig = struct {
    show: bool = true,
    height: ?u16 = null,
    font: []const u8 = "monospace:size=10",
    font_size: u16 = 10,
    padding: u16 = 8,
    spacing: u16 = 12,

    bg: u32 = 0x222222,
    fg: u32 = 0xBBBBBB,
    selected_bg: u32 = 0x005577,
    selected_fg: u32 = 0xEEEEEE,
    occupied_fg: u32 = 0xEEEEEE,
    urgent_bg: u32 = 0xFF0000,
    urgent_fg: u32 = 0xFFFFFF,

    accent_color: u32 = 0x61AFEF,
    workspaces_accent: ?u32 = null,
    title_accent_color: ?u32 = null,
    clock_accent: ?u32 = null,

    workspace_icons: std.ArrayList([]const u8),
    indicator_size: u16 = 4,
    title_accent: bool = true,

    clock_format: []const u8 = "%Y-%m-%d %H:%M:%S",

    layout: std.ArrayList(BarLayout),

    pub fn deinit(self: *BarConfig, allocator: std.mem.Allocator) void {
        for (self.workspace_icons.items) |icon| {
            allocator.free(icon);
        }
        self.workspace_icons.deinit(allocator);

        for (self.layout.items) |*item| {
            item.deinit(allocator);
        }
        self.layout.deinit(allocator);
    }

    pub fn getWorkspaceAccent(self: *const BarConfig) u32 {
        return self.workspaces_accent orelse self.accent_color;
    }

    pub fn getTitleAccent(self: *const BarConfig) u32 {
        return self.title_accent_color orelse self.accent_color;
    }

    pub fn getClockAccent(self: *const BarConfig) u32 {
        return self.clock_accent orelse self.accent_color;
    }
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

pub const Config = struct {
    keybindings: std.ArrayListUnmanaged(Keybind) = .{},
    tiling: TilingConfig = .{},
    workspaces: WorkspaceConfig = .{},
    bar: BarConfig,
    allocator: std.mem.Allocator,

    allocated_font: ?[]const u8 = null,
    allocated_layout: ?[]const u8 = null,
    allocated_clock_format: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .bar = BarConfig{
                .workspace_icons = std.ArrayList([]const u8){},
                .layout = std.ArrayList(BarLayout){},
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| {
            kb.action.deinit(allocator);
        }
        self.keybindings.deinit(allocator);

        for (self.workspaces.rules.items) |*rule| {
            rule.deinit(allocator);
        }
        self.workspaces.rules.deinit(allocator);

        self.bar.deinit(allocator);

        if (self.allocated_font) |f| allocator.free(f);
        if (self.allocated_layout) |l| allocator.free(l);
        if (self.allocated_clock_format) |f| allocator.free(f);
    }
};

/// Drag state - moved from drag.zig to avoid global mutable state
pub const DragState = struct {
    active: bool = false,
    window: u32 = 0,
    mode: enum { move, resize } = .move,
    start_x: i16 = 0,
    start_y: i16 = 0,
    start_win_x: i16 = 0,
    start_win_y: i16 = 0,
    start_win_width: u16 = 0,
    start_win_height: u16 = 0,
};

pub const WM = struct {
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: u32,
    config: Config,
    windows: std.AutoHashMap(u32, void),
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
    drag_state: DragState = .{},  // Moved from drag.zig

    pub fn deinit(self: *WM) void {
        self.windows.deinit();
        self.config.deinit(self.allocator);
    }

    pub inline fn hasWindow(self: *WM, window_id: u32) bool {
        return self.windows.contains(window_id);
    }

    pub fn addWindow(self: *WM, window_id: u32) !void {
        try self.windows.put(window_id, {});
    }

    pub fn removeWindow(self: *WM, window_id: u32) void {
        _ = self.windows.remove(window_id);
    }
};
