// Core type definitions

const std = @import("std");
const dpi = @import("dpi");
const parser = @import("parser");

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const xkbcommon = @import("xkbcommon");

// Modifier masks - must be u16 (XCB API requirement)
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

// Tiling constraints
pub const MIN_MASTER_WIDTH: f32 = 0.05;

pub const Action = union(enum) {
    exec: []const u8,
    close_window,
    reload_config,
    toggle_layout,
    toggle_layout_reverse,
    toggle_bar_visibility,
    toggle_bar_position,
    increase_master,
    decrease_master,
    increase_master_count,
    decrease_master_count,
    toggle_tiling,
    toggle_fullscreen,
    swap_master,
    switch_workspace: u8,
    move_to_workspace: u8,
    dump_state,
    emergency_recover,
    minimize_window,
    unminimize_lifo,
    unminimize_fifo,
    unminimize_all,
    cycle_layout_variation,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exec => |cmd| allocator.free(cmd),
            else => {},
        }
    }
};

pub const Keybind = struct {
    modifiers: u16, // XCB API requirement
    keysym: u32, // X11 keysym - must be u32
    keycode: ?u8 = null,
    action: Action,
};

pub const MasterSide = enum {
    left,
    right,

    pub fn fromString(str: []const u8) ?MasterSide { return std.meta.stringToEnum(MasterSide, str); }
    pub fn toString(value: MasterSide) []const u8 { return @tagName(value); }

    // Support 'L'/'R' aliases in addition to full names
    pub fn fromStringWithAlias(str: []const u8) ?MasterSide {
        var buf: [16]u8 = undefined;
        if (str.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, str);
        if (std.mem.eql(u8, lower, "l") or std.mem.eql(u8, lower, "left")) return .left;
        if (std.mem.eql(u8, lower, "r") or std.mem.eql(u8, lower, "right")) return .right;
        return null;
    }
};

/// Per-layout behavioral variations — defined here (not in tiling.zig) so that
/// config.zig can parse them without creating a circular import.
pub const MasterVariation = enum {
    lifo, // new window → stack, existing master stays (default)
    fifo, // new window → master, existing master → stack
};

pub const MonocleVariation = enum {
    gapless, // true fullscreen — ignore gap settings (default)
    gaps,    // honor gap settings like every other layout
};

pub const GridVariation = enum {
    rigid,   // strict grid: leave empty cells in incomplete last row (default)
    relaxed, // last window in incomplete row expands to fill the row
};

pub const TilingConfig = struct {
    enabled: bool = true,
    layout: []const u8 = "master_left",
    layouts: std.ArrayList([]const u8), // Available layouts in cycle order
    master_side: MasterSide = .left,
    master_width: parser.ScalableValue = parser.ScalableValue.percentage(50.0),
    master_count: u8 = 1,
    gaps: parser.ScalableValue = parser.ScalableValue.absolute(10.0),
    border_width: parser.ScalableValue = parser.ScalableValue.absolute(2.0),
    border_focused: u32 = 0x5294E2, // RGB color - must be u32
    border_unfocused: u32 = 0x383C4A, // RGB color - must be u32

    // Per-layout variation preferences — stored as parsed enums (not raw strings)
    // to avoid dangling slices after the config document is freed.
    master_variation:  MasterVariation  = .lifo,
    monocle_variation: MonocleVariation = .gapless,
    grid_variation:    GridVariation    = .rigid,
    // 3-char label shown in bar for fibonacci (which has no variations).
    // Stored as a fixed-size array so it never needs to be freed.
    fibonacci_indicator: [3]u8 = "NUL".*,

    /// When true, layout changes apply globally across all workspaces (legacy behavior).
    /// When false (default), each workspace independently remembers its own layout.
    global_layout: bool = false,

    pub fn deinit(self: *TilingConfig, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |layout| allocator.free(layout);
        self.layouts.deinit(allocator);
    }
};

pub const BarVerticalPosition = enum {
    top,
    bottom,

    pub fn fromString(str: []const u8) ?BarVerticalPosition { return std.meta.stringToEnum(BarVerticalPosition, str); }
};

pub const BarPosition = enum {
    left,
    center,
    right,

    pub fn fromString(str: []const u8) ?BarPosition { return std.meta.stringToEnum(BarPosition, str); }
};

pub const BarSegment = enum {
    workspaces,
    title,
    clock,
    layout,
    variations,

    pub fn fromString(str: []const u8) ?BarSegment { return std.meta.stringToEnum(BarSegment, str); }
};

pub const BarLayout = struct {
    position: BarPosition,
    segments: std.ArrayList(BarSegment),

    pub inline fn deinit(self: *BarLayout, allocator: std.mem.Allocator) void {
        self.segments.deinit(allocator);
    }
};

pub const BarConfig = struct {
    enabled: bool = true,
    vertical_position: BarVerticalPosition = .top,
    height: ?u16 = null,
    font: []const u8 = "monospace:size=10",
    fonts: std.ArrayList([]const u8),
    font_size: parser.ScalableValue = parser.ScalableValue.percentage(10.0),
    scaled_font_size: u16 = 10, // Can exceed 255 on high DPI - u16 is correct
    padding: u8 = 8,
    spacing: u8 = 12,

    // RGB colors - must be u32
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
    title_unfocused_accent: ?u32 = null,
    title_minimized_accent: ?u32 = null,
    clock_accent: ?u32 = null,

    workspace_icons: std.ArrayList([]const u8),
    // Workspace indicator size - ScalableValue (100% = 4px base)
    indicator_size: parser.ScalableValue = parser.ScalableValue.percentage(100.0),
    // Workspace width - ScalableValue (100% = 40px base)
    workspace_width: parser.ScalableValue = parser.ScalableValue.percentage(100.0),

    clock_format: []const u8 = "%Y-%m-%d %H:%M:%S",

    layout: std.ArrayList(BarLayout),

    // DPI scaling
    scale_factor: f32 = 1.0,

    // Bar transparency (0.0 = fully transparent, 1.0 = fully opaque)
    transparency: f32 = 1.0,

    pub fn deinit(self: *BarConfig, allocator: std.mem.Allocator) void {
        freeStringList(&self.workspace_icons, allocator);
        freeStringList(&self.fonts, allocator);
        for (self.layout.items) |*item| item.deinit(allocator);
        self.layout.deinit(allocator);
    }

    pub inline fn getWorkspaceAccent(self: *const BarConfig) u32 {
        return self.workspaces_accent orelse self.accent_color;
    }

    pub inline fn getTitleAccent(self: *const BarConfig) u32 {
        return self.title_accent_color orelse self.accent_color;
    }

    pub inline fn getTitleUnfocusedAccent(self: *const BarConfig) u32 {
        return self.title_unfocused_accent orelse self.accent_color;
    }

    pub inline fn getTitleMinimizedAccent(self: *const BarConfig) u32 {
        return self.title_minimized_accent orelse self.bg;
    }

    pub inline fn getClockAccent(self: *const BarConfig) u32 {
        return self.clock_accent orelse self.accent_color;
    }

    pub inline fn scaledFontSize(self: *const BarConfig) u16 { return self.scaled_font_size; }

    pub inline fn scaledPadding(self: *const BarConfig) u16 { return scaleU8(self.padding, self.scale_factor); }
    pub inline fn scaledSpacing(self: *const BarConfig) u16 { return scaleU8(self.spacing, self.scale_factor); }

    pub inline fn scaledIndicatorSize(self: *const BarConfig) u16 {
        // Base indicator size is 5px when percentage is 100%
        return scaleScalable(self.indicator_size, 5.0, self.scale_factor, 2);
    }

    pub inline fn scaledWorkspaceWidth(self: *const BarConfig) u16 {
        // Base workspace width is 40px when percentage is 100%
        return scaleScalable(self.workspace_width, 40.0, self.scale_factor, 0);
    }

    // Get alpha value in 16-bit format (0x0000-0xFFFF)
    pub inline fn getAlpha16(self: *const BarConfig) u16 {
        return @intFromFloat(@round(std.math.clamp(self.transparency, 0.0, 1.0) * 0xFFFF));
    }
};

// Private helpers for BarConfig

inline fn scaleU8(value: u8, factor: f32) u16 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(value)) * factor));
}

inline fn scaleScalable(sv: parser.ScalableValue, base_px: f32, factor: f32, min_px: u16) u16 {
    const px: f32 = if (sv.is_percentage)
        base_px * (sv.value / 100.0) * factor
    else
        sv.value * factor;
    return @max(min_px, @as(u16, @intFromFloat(@round(px))));
}

fn freeStringList(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) void {
    for (list.items) |s| allocator.free(s);
    list.deinit(allocator);
}

pub const Rule = struct {
    class_name: []const u8,
    workspace: u8,

    pub inline fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.class_name);
    }
};

pub const WorkspaceConfig = struct {
    count: u8 = 9,
    rules: std.ArrayListUnmanaged(Rule) = .{},
};

pub const Config = struct {
    keybindings: std.ArrayListUnmanaged(Keybind) = .{},
    tiling: TilingConfig,
    workspaces: WorkspaceConfig = .{},
    bar: BarConfig,
    allocator: std.mem.Allocator,

    allocated_font: ?[]const u8 = null,
    allocated_layout: ?[]const u8 = null,
    allocated_clock_format: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Config {
        // Only fields without struct-level defaults need explicit init here.
        // All TilingConfig scalar fields (master_side, master_width, etc.)
        // use their declared defaults; only the ArrayList fields must be
        // zero-initialised explicitly so they are safe to deinit.
        return .{
            .tiling    = TilingConfig{ .layouts = std.ArrayList([]const u8){} },
            .bar       = BarConfig{
                .workspace_icons = std.ArrayList([]const u8){},
                .fonts           = std.ArrayList([]const u8){},
                .layout          = std.ArrayList(BarLayout){},
            },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| kb.action.deinit(allocator);
        self.keybindings.deinit(allocator);

        for (self.workspaces.rules.items) |*rule| rule.deinit(allocator);
        self.workspaces.rules.deinit(allocator);

        self.bar.deinit(allocator);
        self.tiling.deinit(allocator);

        if (self.allocated_font) |f| allocator.free(f);
        if (self.allocated_layout) |l| allocator.free(l);
        if (self.allocated_clock_format) |f| allocator.free(f);
    }
};

pub const FullscreenInfo = struct {
    window: u32, // XCB window ID - must be u32
    workspace: u8,
    saved_geometry: struct {
        x: i16, // Screen coordinates can be negative
        y: i16,
        width: u16, // Dimensions are always positive
        height: u16,
        border_width: u16,
    },
};

pub const FullscreenState = struct {
    per_workspace: std.AutoHashMap(u8, FullscreenInfo),
    window_to_workspace: std.AutoHashMap(u32, u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FullscreenState {
        var per_ws = std.AutoHashMap(u8, FullscreenInfo).init(allocator);
        per_ws.ensureTotalCapacity(4) catch {};
        var win_to_ws = std.AutoHashMap(u32, u8).init(allocator);
        win_to_ws.ensureTotalCapacity(4) catch {};
        return .{
            .per_workspace = per_ws,
            .window_to_workspace = win_to_ws,
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

    pub inline fn getForWorkspace(self: *const FullscreenState, ws: u8) ?FullscreenInfo {
        return self.per_workspace.get(ws);
    }

    pub fn setForWorkspace(self: *FullscreenState, ws: u8, info: FullscreenInfo) !void {
        try self.per_workspace.put(ws, info);
        try self.window_to_workspace.put(info.window, ws);
    }

    pub fn removeForWorkspace(self: *FullscreenState, ws: u8) void {
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
    window: u32 = 0, // XCB window ID - must be u32
    mode: enum { move, resize } = .move,
    // Screen coordinates can be negative
    start_x: i16 = 0,
    start_y: i16 = 0,
    start_win_x: i16 = 0,
    start_win_y: i16 = 0,
    // Dimensions are always positive
    start_win_width: u16 = 0,
    start_win_height: u16 = 0,
};

/// Focus suppression reason for context-aware behavior
pub const FocusSuppressReason = enum {
    none, // Normal operation - focus follows mouse
    window_spawn, // Just spawned a window - don't let cursor steal focus
    tiling_operation, // Currently tiling - don't let cursor steal focus
};

pub const WM = struct {
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: u32, // XCB window ID - must be u32
    config: Config,
    windows: std.AutoHashMap(u32, void), // u32 for XCB window IDs
    focused_window: ?u32 = null,
    fullscreen: FullscreenState,
    xkb_state: ?*xkbcommon.XkbState,
    should_reload_config: *std.atomic.Value(bool),
    running: *std.atomic.Value(bool),
    dpi_info: dpi.DpiInfo,
    drag_state: DragState = .{},
    // Timestamp of the last processed X event; used for ICCCM-compliant
    // focus requests — xcb_set_input_focus and WM_TAKE_FOCUS messages must
    // carry the triggering event's timestamp, not XCB_CURRENT_TIME (0).
    last_event_time: u32 = 0,
    suppress_focus_reason: FocusSuppressReason = .none,
    /// Cursor position (root coordinates) recorded the moment a window spawns.
    /// EnterNotify / LeaveNotify events whose root_x/root_y still match these
    /// coordinates are retile side-effects from a stationary cursor and are
    /// suppressed.  The first crossing event with different coords means the
    /// cursor genuinely moved, so suppression lifts unconditionally — regardless
    /// of how many spurious events the X server generates on slow hardware.
    spawn_cursor_x: i16 = 0,
    spawn_cursor_y: i16 = 0,

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
