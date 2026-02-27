// Core type definitions

const std = @import("std");
const dpi = @import("dpi");
const parser = @import("parser");

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const xkbcommon = @import("xkbcommon");

// Modifier masks - must be u16 (XCB API requirement)
pub const MOD_SHIFT: u16   = xcb.XCB_MOD_MASK_SHIFT;
pub const MOD_LOCK: u16    = xcb.XCB_MOD_MASK_LOCK;
pub const MOD_CONTROL: u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT: u16     = xcb.XCB_MOD_MASK_1;
pub const MOD_2: u16       = xcb.XCB_MOD_MASK_2;
pub const MOD_SUPER: u16   = xcb.XCB_MOD_MASK_4;

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
    switch_workspace:  u8,
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
            else  => {},
        }
    }
};

pub const Keybind = struct {
    modifiers: u16,    // XCB API requirement
    keysym:    u32,    // X11 keysym - must be u32
    keycode:   ?u8 = null,
    action:    Action,
};

pub const MasterSide = enum {
    left,
    right,

    pub fn fromString(str: []const u8) ?MasterSide { return std.meta.stringToEnum(MasterSide, str); }
    pub fn toString(value: MasterSide) []const u8   { return @tagName(value); }

    // Support 'L'/'R' aliases in addition to full names.
    const alias_map = std.StaticStringMap(MasterSide).initComptime(.{
        .{ "l", .left }, .{ "left", .left }, .{ "r", .right }, .{ "right", .right },
    });
    pub fn fromStringWithAlias(str: []const u8) ?MasterSide {
        var buf: [16]u8 = undefined;
        if (str.len > buf.len) return null;
        return alias_map.get(std.ascii.lowerString(&buf, str));
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

/// Fibonacci has no behavioral variations today; this enum is a placeholder
/// that lets the config and tiling systems treat all four layouts uniformly.
pub const FibonacciVariation = enum {
    default,
};

/// A layout variation discriminated by which layout it belongs to.
pub const LayoutVariationOverride = union(enum) {
    master:    MasterVariation,
    monocle:   MonocleVariation,
    grid:      GridVariation,
    fibonacci: FibonacciVariation,
};

/// Records that a specific workspace should start in a particular layout
/// (and optionally a variation), overriding the first-element default.
pub const WorkspaceLayoutOverride = struct {
    workspace_idx: u8,                       // 0-indexed workspace number
    layout_idx:    u8,                       // index into TilingConfig.layouts
    variation:     ?LayoutVariationOverride, // null = use per-layout section default
};

pub const TilingConfig = struct {
    enabled:      bool           = true,
    layout:       []const u8     = "master_left",
    layouts:      std.ArrayList([]const u8), // Available layouts in cycle order
    master_side:  MasterSide     = .left,
    master_width: parser.ScalableValue = parser.ScalableValue.percentage(50.0),
    master_count: u8             = 1,
    gaps:         parser.ScalableValue = parser.ScalableValue.absolute(10.0),
    border_width: parser.ScalableValue = parser.ScalableValue.absolute(2.0),
    border_focused:   u32 = 0x5294E2, // RGB color - must be u32
    border_unfocused: u32 = 0x383C4A, // RGB color - must be u32

    // Per-layout variation preferences — stored as parsed enums (not raw strings)
    // to avoid dangling slices after the config document is freed.
    master_variation:    MasterVariation    = .lifo,
    monocle_variation:   MonocleVariation   = .gapless,
    grid_variation:      GridVariation      = .rigid,
    fibonacci_variation: FibonacciVariation = .default,

    // Per-layout 3-character indicator overrides (null = derive from active variation).
    // Stored as fixed-size arrays — no allocation, no dangling pointers.
    // Set via `indicator = "XYZ"` in the corresponding [tiling.layouts.*] section.
    master_indicator:    ?[3]u8 = null,
    monocle_indicator:   ?[3]u8 = null,
    grid_indicator:      ?[3]u8 = null,
    // 3-char label displayed in the bar for fibonacci (which has no variations).
    // Defaults to "FIB"; override with `indicator = "..."` in [tiling.layouts.fibonacci].
    fibonacci_indicator: [3]u8 = "FIB".*,

    /// Per-workspace layout assignments parsed from the layouts array.
    workspace_layout_overrides: std.ArrayListUnmanaged(WorkspaceLayoutOverride) = .{},

    /// When true, layout changes apply globally across all workspaces (legacy behavior).
    global_layout: bool = false,

    pub fn deinit(self: *TilingConfig, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |layout| allocator.free(layout);
        self.layouts.deinit(allocator);
        self.workspace_layout_overrides.deinit(allocator);
    }
};

/// Where in the workspace cell the activity indicator is drawn.
pub const IndicatorLocation = enum {
    up,
    down,
    left,
    right,
    up_left,
    up_right,
    down_left,
    down_right,

    /// Case-insensitive parse. Accepts hyphens or underscores, and both
    /// orderings of diagonal names (e.g. "left-up" == "up-left").
    pub fn fromString(str: []const u8) ?IndicatorLocation {
        const map = std.StaticStringMap(IndicatorLocation).initComptime(.{
            .{ "up",          .up         },
            .{ "down",        .down       },
            .{ "left",        .left       },
            .{ "right",       .right      },
            .{ "up-left",     .up_left    },
            .{ "up_left",     .up_left    },
            .{ "left-up",     .up_left    },
            .{ "left_up",     .up_left    },
            .{ "up-right",    .up_right   },
            .{ "up_right",    .up_right   },
            .{ "right-up",    .up_right   },
            .{ "right_up",    .up_right   },
            .{ "down-left",   .down_left  },
            .{ "down_left",   .down_left  },
            .{ "left-down",   .down_left  },
            .{ "left_down",   .down_left  },
            .{ "down-right",  .down_right },
            .{ "down_right",  .down_right },
            .{ "right-down",  .down_right },
            .{ "right_down",  .down_right },
        });
        var buf: [16]u8 = undefined;
        if (str.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, str);
        return map.get(lower);
    }
};

pub const BarVerticalPosition = enum {
    top,
    bottom,

    pub fn fromString(str: []const u8) ?BarVerticalPosition {
        return std.meta.stringToEnum(BarVerticalPosition, str);
    }
};

pub const BarPosition = enum {
    left,
    center,
    right,

    pub fn fromString(str: []const u8) ?BarPosition {
        return std.meta.stringToEnum(BarPosition, str);
    }
};

pub const BarSegment = enum {
    workspaces,
    title,
    clock,
    layout,
    variations,

    pub fn fromString(str: []const u8) ?BarSegment {
        return std.meta.stringToEnum(BarSegment, str);
    }
};

pub const BarLayout = struct {
    position: BarPosition,
    segments: std.ArrayList(BarSegment),

    pub inline fn deinit(self: *BarLayout, allocator: std.mem.Allocator) void {
        self.segments.deinit(allocator);
    }
};

pub const BarConfig = struct {
    enabled:           bool                   = true,
    vertical_position: BarVerticalPosition    = .top,
    // Configured bar height: absolute pixel value or percentage of screen height.
    // null = auto-calculate from font metrics alone.
    height:            ?parser.ScalableValue  = null,
    font:              []const u8             = "monospace:size=10",
    fonts:             std.ArrayList([]const u8),
    font_size:         parser.ScalableValue   = parser.ScalableValue.percentage(10.0),
    scaled_font_size:  u16                    = 10, // Can exceed 255 on high DPI - u16 is correct
    spacing:           parser.ScalableValue   = parser.ScalableValue.absolute(12.0),

    // RGB colors - must be u32
    bg:          u32 = 0x222222,
    fg:          u32 = 0xBBBBBB,
    selected_bg: u32 = 0x005577,
    selected_fg: u32 = 0xEEEEEE,
    occupied_fg: u32 = 0xEEEEEE,
    urgent_bg:   u32 = 0xFF0000,
    urgent_fg:   u32 = 0xFFFFFF,

    accent_color:           u32  = 0x61AFEF,
    workspaces_accent:      ?u32 = null,
    title_accent_color:     ?u32 = null,
    title_unfocused_accent: ?u32 = null,
    title_minimized_accent: ?u32 = null,
    clock_accent:           ?u32 = null,

    workspace_icons:     std.ArrayList([]const u8),
    indicator_size:      parser.ScalableValue = parser.ScalableValue.percentage(30.0),
    workspace_tag_width: parser.ScalableValue = parser.ScalableValue.percentage(100.0),

    indicator_location:  IndicatorLocation = .up_left,
    indicator_padding:   f32               = 0.1,
    indicator_focused:   []const u8        = "■",
    indicator_unfocused: []const u8        = "□",
    indicator_color:     ?u32              = null,

    clock_format: []const u8 = "%Y-%m-%d %H:%M:%S",

    layout: std.ArrayList(BarLayout),

    scale_factor: f32 = 1.0,
    transparency: f32 = 1.0,

    pub fn deinit(self: *BarConfig, allocator: std.mem.Allocator) void {
        for (self.workspace_icons.items) |s| allocator.free(s);
        self.workspace_icons.deinit(allocator);
        for (self.fonts.items) |s| allocator.free(s);
        self.fonts.deinit(allocator);
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

    /// Derives horizontal segment padding from the font_size percentage.
    pub inline fn scaledSegmentPadding(self: *const BarConfig, bar_height: u16) u16 {
        if (!self.font_size.is_percentage) return 0;
        const margin_ratio = (1.0 - self.font_size.value / 100.0) / 2.0;
        const px = @as(f32, @floatFromInt(bar_height)) * margin_ratio * self.scale_factor;
        return @as(u16, @intFromFloat(@round(@max(0.0, px))));
    }

    /// Scales a ScalableValue to pixels. `factor` multiplies the percentage path;
    /// `scale` is applied on both paths (pass 1.0 to skip).
    fn scaleValue(sv: parser.ScalableValue, bar_height: u16, factor: f32, scale: f32) f32 {
        const h: f32 = @floatFromInt(bar_height);
        return if (sv.is_percentage) h * factor * (sv.value / 100.0) * scale else sv.value * scale;
    }

    pub inline fn scaledSpacing(self: *const BarConfig, bar_height: u16) u16 {
        return @as(u16, @intFromFloat(@round(@max(0.0, scaleValue(self.spacing, bar_height, 5.0, self.scale_factor)))));
    }
    pub inline fn scaledIndicatorSize(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, @as(u16, @intFromFloat(@round(scaleValue(self.indicator_size, bar_height, 1.0, 1.0)))));
    }
    pub inline fn scaledWorkspaceWidth(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, @as(u16, @intFromFloat(@round(scaleValue(self.workspace_tag_width, bar_height, 1.0, self.scale_factor)))));
    }

    /// Returns the bar's alpha in 16-bit format (0x0000–0xFFFF).
    pub inline fn getAlpha16(self: *const BarConfig) u16 {
        return @intFromFloat(@round(std.math.clamp(self.transparency, 0.0, 1.0) * 0xFFFF));
    }
};

pub const Rule = struct {
    class_name: []const u8,
    workspace:  u8,

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
    tiling:      TilingConfig,
    workspaces:  WorkspaceConfig = .{},
    bar:         BarConfig,
    allocator:   std.mem.Allocator,

    allocated_font:                ?[]const u8 = null,
    allocated_layout:              ?[]const u8 = null,
    allocated_clock_format:        ?[]const u8 = null,
    allocated_indicator_focused:   ?[]const u8 = null,
    allocated_indicator_unfocused: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Config {
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

    /// Uses self.allocator — the same allocator passed to Config.init and all
    /// subsequent config allocations — so callers do not need to pass it again.
    pub fn deinit(self: *Config) void {
        const a = self.allocator;
        for (self.keybindings.items) |*kb| kb.action.deinit(a);
        self.keybindings.deinit(a);

        for (self.workspaces.rules.items) |*rule| rule.deinit(a);
        self.workspaces.rules.deinit(a);

        self.bar.deinit(a);
        self.tiling.deinit(a);

        inline for (.{
            "allocated_font", "allocated_layout", "allocated_clock_format",
            "allocated_indicator_focused", "allocated_indicator_unfocused",
        }) |field| if (@field(self, field)) |s| a.free(s);
    }
};

/// Geometry snapshot used by both fullscreen and minimize.
pub const WindowGeometry = struct {
    x:            i16,
    y:            i16,
    width:        u16,
    height:       u16,
    border_width: u16,
};

pub const FullscreenInfo = struct {
    window:         u32, // XCB window ID - must be u32
    saved_geometry: WindowGeometry,
};

pub const FullscreenState = struct {
    per_workspace:       std.AutoHashMap(u8, FullscreenInfo),
    window_to_workspace: std.AutoHashMap(u32, u8),

    pub fn init(allocator: std.mem.Allocator) FullscreenState {
        var per_ws    = std.AutoHashMap(u8, FullscreenInfo).init(allocator);
        var win_to_ws = std.AutoHashMap(u32, u8).init(allocator);
        per_ws.ensureTotalCapacity(4)    catch {};
        win_to_ws.ensureTotalCapacity(4) catch {};
        return .{ .per_workspace = per_ws, .window_to_workspace = win_to_ws };
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
        if (self.per_workspace.get(ws)) |info|
            _ = self.window_to_workspace.remove(info.window);
        _ = self.per_workspace.remove(ws);
    }

    pub inline fn clear(self: *FullscreenState) void {
        self.per_workspace.clearRetainingCapacity();
        self.window_to_workspace.clearRetainingCapacity();
    }
};

pub const DragState = struct {
    active:           bool  = false,
    window:           u32   = 0, // XCB window ID - must be u32
    mode:             enum { move, resize } = .move,
    start_x:          i16   = 0,
    start_y:          i16   = 0,
    start_win_x:      i16   = 0,
    start_win_y:      i16   = 0,
    start_win_width:  u16   = 0,
    start_win_height: u16   = 0,
};

/// Focus suppression reason for context-aware behavior.
pub const FocusSuppressReason = enum {
    none,             // normal operation: focus follows mouse
    window_spawn,     // just spawned a window: don't let cursor steal focus
    tiling_operation, // currently tiling: don't let cursor steal focus
};

pub const SPAWN_QUEUE_CAP: u8 = 16;

pub const SpawnEntry = struct {
    workspace: u8,
    /// _NET_WM_PID of the grandchild; 0 for daemon-mode terminals.
    pid: u32,
};

/// Fixed-capacity circular FIFO for pending spawn-workspace assignments.
pub const SpawnQueue = struct {
    buf:  [SPAWN_QUEUE_CAP]SpawnEntry = undefined,
    head: u8 = 0,
    len:  u8 = 0,

    pub inline fn isEmpty(self: *const SpawnQueue) bool { return self.len == 0; }

    /// Push a spawn entry. Drops the oldest entry when the queue is full.
    pub fn push(self: *SpawnQueue, workspace: u8, pid: u32) void {
        if (self.len == SPAWN_QUEUE_CAP) {
            self.head = (self.head + 1) % SPAWN_QUEUE_CAP;
            self.len -= 1;
        }
        const tail = (self.head + self.len) % SPAWN_QUEUE_CAP;
        self.buf[tail] = .{ .workspace = workspace, .pid = pid };
        self.len += 1;
    }

    /// Remove and return the workspace for the entry matching `win_pid`, or null.
    /// Returns null immediately for pid=0 (use popOldestDaemon instead).
    pub fn popByPid(self: *SpawnQueue, win_pid: u32) ?u8 {
        if (win_pid == 0) return null;
        return self.popWhere(.by_pid, win_pid);
    }

    /// Remove and return the workspace of the oldest daemon (pid=0) entry, or null.
    pub fn popOldestDaemon(self: *SpawnQueue) ?u8 { return self.popWhere(.daemon, 0); }

    fn popWhere(self: *SpawnQueue, comptime mode: enum { by_pid, daemon }, target: u32) ?u8 {
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % SPAWN_QUEUE_CAP;
            if (if (mode == .by_pid) self.buf[idx].pid != target else self.buf[idx].pid != 0) continue;
            const ws = self.buf[idx].workspace;
            self.removeAt(i);
            return ws;
        }
        return null;
    }

    fn removeAt(self: *SpawnQueue, i: u8) void {
        var j: u8 = i;
        while (j + 1 < self.len) : (j += 1) {
            const cur  = (self.head + j)     % SPAWN_QUEUE_CAP;
            const next = (self.head + j + 1) % SPAWN_QUEUE_CAP;
            self.buf[cur] = self.buf[next];
        }
        self.len -= 1;
    }
};

/// Per-window minimize record.
pub const MinimizedEntry = struct {
    saved_fs:  ?WindowGeometry, // non-null iff the window was fullscreen when minimized
    workspace: u8,              // index into MinimizeState.per_workspace
};

/// Per-workspace minimization state, owned by WM.
pub const MinimizeState = struct {
    per_workspace:  []std.ArrayListUnmanaged(u32),
    minimized_info: std.AutoHashMap(u32, MinimizedEntry),
    allocator:      std.mem.Allocator,

    pub fn deinit(self: *MinimizeState) void {
        for (self.per_workspace) |*list| list.deinit(self.allocator);
        self.allocator.free(self.per_workspace);
        self.minimized_info.deinit();
    }
};

pub const WM = struct {
    allocator:      std.mem.Allocator,
    conn:           *xcb.xcb_connection_t,
    screen:         *xcb.xcb_screen_t,
    root:           u32, // XCB window ID - must be u32
    config:         Config,
    focused_window: ?u32 = null,
    fullscreen:     FullscreenState,
    xkb_state:      ?*xkbcommon.XkbState,
    dpi_info:       dpi.DpiInfo,
    drag_state:     DragState = .{},
    minimize:       ?MinimizeState = null,
    spawn_queue:    SpawnQueue = .{},
    last_event_time:        u32 = 0,
    suppress_focus_reason:  FocusSuppressReason = .none,
    spawn_cursor_x: i16 = 0,
    spawn_cursor_y: i16 = 0,

    pub fn deinit(self: *WM) void {
        if (self.minimize) |*m| m.deinit();
        self.fullscreen.deinit();
        self.config.deinit();
    }
};
