// Core type definitions - IMPROVED: Pointer tracking instead of event counters

const std = @import("std");
const dpi = @import("dpi");
const parser = @import("parser");

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const xkbcommon = @import("xkbcommon");

/// Generic compile-time enum <-> string conversion helper
pub fn EnumStringHelper(comptime T: type) type {
    return struct {
        const Self = @This();
        
        const map = blk: {
            const fields = @typeInfo(T).@"enum".fields;
            var entries: [fields.len]struct { []const u8, T } = undefined;
            for (fields, 0..) |field, i| {
                entries[i] = .{ field.name, @enumFromInt(field.value) };
            }
            break :blk std.StaticStringMap(T).initComptime(entries);
        };
        
        pub inline fn fromString(str: []const u8) ?T {
            return map.get(str);
        }
        
        pub inline fn toString(value: T) []const u8 {
            return @tagName(value);
        }
    };
}

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

// XKB initialization retry parameters
pub const XKB_RETRY_DELAY_MS: u64 = 20;

// Workspace limits
pub const MIN_WORKSPACES: usize = 1;

// Tiling constraints
pub const MIN_MASTER_WIDTH: f32 = 0.05;

// REMOVED: Event counter-based focus protection (replaced with intelligent filtering)
// pub const FOCUS_PROTECTION_EVENT_COUNT: u16 = 50;

pub const Action = union(enum) {
    exec: []const u8,
    close_window,
    reload_config,
    toggle_layout,
    toggle_layout_reverse,
    toggle_bar_visibility,
    toggle_bar_position,  // NEW: toggle bar between top and bottom
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

    const Helper = EnumStringHelper(MasterSide);
    pub const fromString = Helper.fromString;
    pub const toString = Helper.toString;
};

pub const TilingConfig = struct {
    enabled: bool = true,
    layout: []const u8 = "master_left",
    master_side: MasterSide = .left,
    master_width: parser.ScalableValue = parser.ScalableValue.percentage(50.0),
    master_count: usize = 1,
    gaps: parser.ScalableValue = parser.ScalableValue.absolute(10.0),
    border_width: parser.ScalableValue = parser.ScalableValue.absolute(2.0),
    border_focused: u32 = 0x5294E2,
    border_unfocused: u32 = 0x383C4A,
};

pub const BarVerticalPosition = enum {
    top,
    bottom,

    const Helper = EnumStringHelper(BarVerticalPosition);
    pub const fromString = Helper.fromString;
};

pub const BarPosition = enum {
    left,
    center,
    right,

    const Helper = EnumStringHelper(BarPosition);
    pub const fromString = Helper.fromString;
};

pub const BarSegment = enum {
    workspaces,
    title,
    clock,
    layout,

    const Helper = EnumStringHelper(BarSegment);
    pub const fromString = Helper.fromString;
};

pub const BarLayout = struct {
    position: BarPosition,
    segments: std.ArrayList(BarSegment),

    pub inline fn deinit(self: *BarLayout, allocator: std.mem.Allocator) void {
        self.segments.deinit(allocator);
    }
};

pub const BarConfig = struct {
    show: bool = true,
    vertical_position: BarVerticalPosition = .top,
    height: ?u16 = null,
    font: []const u8 = "monospace:size=10",
    fonts: std.ArrayList([]const u8),
    font_size: parser.ScalableValue = parser.ScalableValue.percentage(10.0),
    scaled_font_size: u16 = 10, // Computed value after DPI scaling
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
    
    // DPI scaling
    scale_factor: f32 = 1.0,
    
    // NEW: Bar transparency (0.0 = fully transparent, 1.0 = fully opaque)
    // Accepts both 0-1 (e.g., 0.9) and 0-100 (e.g., 90) formats in config
    transparency: f32 = 1.0,

    pub fn deinit(self: *BarConfig, allocator: std.mem.Allocator) void {
        for (self.workspace_icons.items) |icon| {
            allocator.free(icon);
        }
        self.workspace_icons.deinit(allocator);
        
        for (self.fonts.items) |font| {
            allocator.free(font);
        }
        self.fonts.deinit(allocator);

        for (self.layout.items) |*item| {
            item.deinit(allocator);
        }
        self.layout.deinit(allocator);
    }

    pub inline fn getWorkspaceAccent(self: *const BarConfig) u32 {
        return self.workspaces_accent orelse self.accent_color;
    }

    pub inline fn getTitleAccent(self: *const BarConfig) u32 {
        return self.title_accent_color orelse self.accent_color;
    }

    pub inline fn getClockAccent(self: *const BarConfig) u32 {
        return self.clock_accent orelse self.accent_color;
    }
    
    // DPI-aware scaling helpers
    pub inline fn scaledFontSize(self: *const BarConfig) u16 {
        return self.scaled_font_size;
    }
    
    pub inline fn scaledPadding(self: *const BarConfig) u16 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.padding)) * self.scale_factor));
    }
    
    pub inline fn scaledSpacing(self: *const BarConfig) u16 {
        return @intFromFloat(@round(@as(f32, @floatFromInt(self.spacing)) * self.scale_factor));
    }
    
    pub inline fn scaledIndicatorSize(self: *const BarConfig) u16 {
        const scaled: f32 = @as(f32, @floatFromInt(self.indicator_size)) * self.scale_factor;
        return @max(2, @as(u16, @intFromFloat(@round(scaled))));
    }
    
    pub inline fn scaledWorkspaceWidth(self: *const BarConfig) u16 {
        // Base workspace width from bar.zig is 50
        const base_width: f32 = 50.0;
        return @intFromFloat(@round(base_width * self.scale_factor));
    }
    
    // Get alpha value in 16-bit format (0x0000-0xFFFF)
    pub inline fn getAlpha16(self: *const BarConfig) u16 {
        const clamped = std.math.clamp(self.transparency, 0.0, 1.0);
        return @intFromFloat(@round(clamped * 0xFFFF));
    }
};

pub const Rule = struct {
    class_name: []const u8,
    workspace: usize,

    pub inline fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
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
                .fonts = std.ArrayList([]const u8){},
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

pub const FullscreenInfo = struct {
    window: u32,
    workspace: usize,
    saved_geometry: struct {
        x: i16,
        y: i16,
        width: u16,
        height: u16,
        border_width: u16,
    },
};

pub const FullscreenState = struct {
    per_workspace: std.AutoHashMap(usize, FullscreenInfo),
    window_to_workspace: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FullscreenState {
        return .{
            .per_workspace = std.AutoHashMap(usize, FullscreenInfo).init(allocator),
            .window_to_workspace = std.AutoHashMap(u32, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FullscreenState) void {
        self.per_workspace.deinit();
        self.window_to_workspace.deinit();
    }

    pub inline fn isFullscreen(self: *const FullscreenState, win: u32) bool {
        return self.window_to_workspace.contains(win);
    }

    pub inline fn getForWorkspace(self: *const FullscreenState, ws: usize) ?FullscreenInfo {
        return self.per_workspace.get(ws);
    }

    pub fn setForWorkspace(self: *FullscreenState, ws: usize, info: FullscreenInfo) !void {
        try self.per_workspace.put(ws, info);
        try self.window_to_workspace.put(info.window, ws);
    }

    pub fn removeForWorkspace(self: *FullscreenState, ws: usize) void {
        if (self.per_workspace.get(ws)) |info| {
            _ = self.window_to_workspace.remove(info.window);
        }
        _ = self.per_workspace.remove(ws);
    }

    pub inline fn clear(self: *FullscreenState) void {
        self.per_workspace.clearRetainingCapacity();
        self.window_to_workspace.clearRetainingCapacity();
    }
};

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

/// IMPROVED: Focus suppression reason for context-aware behavior
pub const FocusSuppressReason = enum {
    none,              // Normal operation - focus follows mouse
    window_spawn,      // Just spawned a window - don't let cursor steal focus
    tiling_operation,  // Currently tiling - don't let cursor steal focus
};

pub const WM = struct {
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: u32,
    config: Config,
    windows: std.AutoHashMap(u32, void),
    focused_window: ?u32 = null,
    fullscreen: FullscreenState,
    xkb_state: ?*xkbcommon.XkbState,
    should_reload_config: *std.atomic.Value(bool),
    running: *std.atomic.Value(bool),
    dpi_info: dpi.DpiInfo,
    drag_state: DragState = .{},
    
    // IMPROVED: Intelligent focus control without event counters
    // Track last known pointer position to detect actual movement vs window repositioning
    last_pointer_x: i16 = 0,
    last_pointer_y: i16 = 0,
    
    // Context-aware focus suppression (replaces event counters)
    // Only suppress when we know cursor shouldn't steal focus (spawn, tiling)
    // Automatically clears on significant mouse movement
    suppress_focus_reason: FocusSuppressReason = .none,
    
    // REMOVED: Event counter-based approach (unreliable, causes sluggishness)
    // events_since_programmatic_action: u16 = 999,
    // last_spawned_window: ?u32 = null,
    // events_since_last_spawn: u16 = 999,

    pub fn deinit(self: *WM) void {
        self.fullscreen.deinit();
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
