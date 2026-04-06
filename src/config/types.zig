
//! Config type definitions — structs, enums, and unions that model the WM configuration schema.
//!
//! This file is the single source of truth for all config-related types.
//! - parser.zig  handles TOML tokenisation and document building
//! - config.zig  reads a parsed Document and populates these structs
//! - fallback.zig provides auto-detection defaults
//!
//! Keeping type definitions here avoids pulling parser or xcb into config.zig
//! while still letting core.zig re-export everything through `pub usingnamespace`.

const std = @import("std");
const parser = @import("parser");

/// X11 color value packed as 0x00RRGGBB into 32 bits.
/// The high byte is unused; values match what XCB expects for pixel/color fields.
pub const Color = u32;

// Keybinding and action types

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
    toggle_floating_window,
    toggle_fullscreen,
    swap_master,
    swap_master_focus_swap,
    switch_workspace:  u8,
    move_to_workspace: u8,
    move_window:       u8, // exclusive move — clears all tags, sets only target
    toggle_tag:        u8, // pure toggle — flips bit N, never moves
    sequence:          []Action, // ordered list of actions executed left-to-right; owned slice
    dump_state,
    minimize_window,
    unminimize_lifo,
    unminimize_fifo,
    unminimize_all,
    cycle_layout_variants,
    toggle_prompt,
    all_workspaces,          // shows all windows from every workspace at once; toggled on/off
    move_to_all_workspaces,  // pin focused window to every workspace
    toggle_tag_all,          // flip between pinned-to-all and current-workspace-only
    focus_next_window,       // cycle focus forward / right  (dwm-style Mod+k)
    focus_prev_window,       // cycle focus backward / left  (dwm-style Mod+j)
    move_window_next,        // move focused window forward  (dwm-style Mod+Shift+k)
    move_window_prev,        // move focused window backward (dwm-style Mod+Shift+j)

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exec     => |cmd|  allocator.free(cmd),
            .sequence => |acts| {
                for (acts) |*a| a.deinit(allocator);
                allocator.free(acts);
            },
            else => {},
        }
    }
};

pub const Keybind = struct {
    modifiers: u16, // u16 per XCB spec; xcb_grab_key rejects wider types
    keysym:    u32, // xcb_keysym_t is u32 by X11 protocol spec; never narrowed
    keycode:   ?u8 = null,
    action:    Action,
};

/// A binding triggered by a mouse button press with modifier keys held.
pub const MouseBind = struct {
    modifiers: u16,
    button:    u8,
    action:    Action,
};

// Tiling layout types

pub const MasterSide = enum {
    left,
    right,

    // Both orderings of diagonal names and both separators are pre-listed in string_map;
    // fromString is the canonical parse entry point.
    const string_map = std.StaticStringMap(MasterSide).initComptime(.{
        .{ "l",     .left  },
        .{ "left",  .left  },
        .{ "r",     .right },
        .{ "right", .right },
    });

    /// Lowercases str into a stack buffer and looks it up in string_map.
    /// Returns null if str exceeds 16 bytes or is unrecognized.
    pub inline fn fromString(str: []const u8) ?MasterSide {
        var buf: [16]u8 = undefined;
        if (str.len > buf.len) return null;
        return string_map.get(std.ascii.lowerString(&buf, str));
    }
};

/// Window placement policy for the master-stack layout.
///
/// Defined here and not in tiling.zig so that config.zig
/// can parse it without creating a circular import.
pub const MasterVariant = enum {
    lifo, // new window -> stack, existing master stays (default)
    fifo, // new window -> master, existing master -> stack
};

pub const MonocleVariant = enum {
    gapless, // true fullscreen; ignore gap settings (default)
    gaps,    // honor gap settings like every other layout
};

pub const GridVariant = enum {
    rigid,   // strict grid: leave empty cells in incomplete last row (default)
    relaxed, // last window in incomplete row expands to fill the row
};

/// Tagged union pairing a variant value with its owning layout type.
pub const LayoutVariantOverride = union(enum) {
    master:  MasterVariant,
    monocle: MonocleVariant,
    grid:    GridVariant,
};

/// Per-workspace startup layout assignment, overriding the global default.
/// variant is null -> use the per-layout section default.
pub const WorkspaceLayoutOverride = struct {
    workspace_idx: u8,                   // 0-indexed workspace number
    layout_idx:    u8,                   // index into TilingConfig.layouts
    variant:     ?LayoutVariantOverride, // null = use per-layout section default
};

/// Per-workspace master count override, parsed from [tiling.layouts.master-stack.counts].
pub const WorkspaceMasterCountOverride = struct {
    workspace_idx: u8, // 0-indexed workspace number
    count:         u8,
};

pub const TilingConfig = struct {
    enabled:      bool           = true,
    layout:       []const u8     = "master_left",
    layouts:      std.ArrayList([]const u8) = .empty, // Available layouts in cycle order
    master_side:  MasterSide     = .left,
    master_width: parser.ScalableValue = parser.ScalableValue.percentage(50.0),
    master_count: u8             = 1,
    gap_width:    parser.ScalableValue = parser.ScalableValue.absolute(10.0),
    border_width: parser.ScalableValue = parser.ScalableValue.absolute(2.0),
    border_focused:   Color = 0x5294E2,
    border_unfocused: Color = 0x383C4A,

    // Per-layout variant preferences
    //
    // Stored as parsed enums (not raw strings) to avoid
    // dangling slices after the config document is freed.
    master_variant:  MasterVariant  = .lifo,
    monocle_variant: MonocleVariant = .gapless,
    grid_variant:    GridVariant    = .rigid,

    // Per-layout 3-character indicator overrides (null = derive from active variant).
    // Stored as fixed-size arrays: no allocation, no dangling pointers.
    // Set via `indicator = "XYZ"` (3 chars) in the corresponding [tiling.layouts.*] section.
    master_indicator:    ?[3]u8 = null,
    monocle_indicator:   ?[3]u8 = null,
    grid_indicator:      ?[3]u8 = null,

    /// Per-workspace layout assignments parsed from the layouts array.
    workspace_layout_overrides: std.ArrayList(WorkspaceLayoutOverride) = .empty,

    /// Per-workspace master count overrides parsed from [tiling.layouts.master-stack.counts].
    /// Only applied when global_layout = false.
    workspace_master_count_overrides: std.ArrayList(WorkspaceMasterCountOverride) = .empty,

    /// When true, layout changes apply globally across all workspaces (legacy behavior).
    global_layout: bool = false,

    pub fn deinit(self: *TilingConfig, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |layout| allocator.free(layout);
        self.layouts.deinit(allocator);
        self.workspace_layout_overrides.deinit(allocator);
        self.workspace_master_count_overrides.deinit(allocator);
    }
};

// Bar types

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

    // Accepts hyphens or underscores and both orderings of diagonal names (e.g. "left-up" == "up-left").
    // StaticStringMap.initComptime is a compile-time perfect hash — O(1), no runtime cost.
    const string_map = std.StaticStringMap(IndicatorLocation).initComptime(.{
        .{ "up",         .up         },
        .{ "down",       .down       },
        .{ "left",       .left       },
        .{ "right",      .right      },
        .{ "up-left",    .up_left    },
        .{ "up_left",    .up_left    },
        .{ "left-up",    .up_left    },
        .{ "left_up",    .up_left    },
        .{ "up-right",   .up_right   },
        .{ "up_right",   .up_right   },
        .{ "right-up",   .up_right   },
        .{ "right_up",   .up_right   },
        .{ "down-left",  .down_left  },
        .{ "down_left",  .down_left  },
        .{ "left-down",  .down_left  },
        .{ "left_down",  .down_left  },
        .{ "down-right", .down_right },
        .{ "down_right", .down_right },
        .{ "right-down", .down_right },
        .{ "right_down", .down_right },
    });
    /// Case-insensitive parse. Returns null if str exceeds 16 bytes or is unrecognized.
    pub inline fn fromString(str: []const u8) ?IndicatorLocation {
        var buf: [16]u8 = undefined;
        if (str.len > buf.len) return null;
        return string_map.get(std.ascii.lowerString(&buf, str));
    }
};

// Content segments that can be placed into a BarLayout column.
pub const BarSegment = enum {
    workspaces,
    title,
    clock,
    layout,
    variants,
};

/// Vertical placement of the bar on screen: top or bottom edge.
pub const BarScreenPosition = enum {
    top,
    bottom,
};

/// Horizontal anchor for a BarLayout column within the bar.
pub const BarSegmentAnchor = enum {
    left,
    center,
    right,
};

/// One column of the bar: an anchor position and an ordered list of segments to display.
pub const BarLayout = struct {
    position: BarSegmentAnchor,
    segments: std.ArrayList(BarSegment),

    pub inline fn deinit(self: *BarLayout, allocator: std.mem.Allocator) void {
        self.segments.deinit(allocator);
    }
};

pub const BarConfig = struct {
    enabled: bool = true,

    bar_position: BarScreenPosition = .top,
    // Configured bar height: absolute pixel value or percentage of screen height.
    // null = auto-calculate from font metrics alone.
    height:            ?parser.ScalableValue  = null,
    font:              []const u8             = "monospace:size=10",
    fonts:             std.ArrayList([]const u8)  = .empty,
    font_size:         parser.ScalableValue   = parser.ScalableValue.percentage(10.0),
    // Resolved pixel value cached after DPI scaling; derived from font_size at startup.
    // NOTE: this is runtime state, not a raw config value — consider moving it to a
    // separate resolved-config struct if BarConfig is ever serialised or diffed.
    scaled_font_size:  u16                    = 10, // Can exceed 255 on high DPI - u16 is correct
    spacing:           parser.ScalableValue   = parser.ScalableValue.absolute(12.0),

    // Bar color scheme; all values are 0xRRGGBB (see Color type alias).
    bg:          Color = 0x222222,
    fg:          Color = 0xBBBBBB,
    selected_bg: Color = 0x005577,
    selected_fg: Color = 0xEEEEEE,
    occupied_fg: Color = 0xEEEEEE,
    urgent_bg:   Color = 0xFF0000,
    urgent_fg:   Color = 0xFFFFFF,

    accent_color:           Color = 0x61AFEF,
    workspaces_accent:      Color = 0x61AFEF,
    title_accent_color:     Color = 0x61AFEF,
    title_unfocused_accent: Color = 0x222222,
    title_minimized_accent: Color = 0x61AFEF,
    clock_accent:           Color = 0x61AFEF,

    workspace_icons:     std.ArrayList([]const u8) = .empty,
    indicator_size:      parser.ScalableValue = parser.ScalableValue.percentage(30.0),
    workspace_tag_width: parser.ScalableValue = parser.ScalableValue.percentage(100.0),

    indicator_location:  IndicatorLocation = .up_left,
    indicator_padding:   f32               = 0.1,
    indicator_focused:   []const u8        = "■",
    indicator_unfocused: []const u8        = "□",
    indicator_color:     ?Color             = null,

    clock_format: []const u8 = "%Y-%m-%d %H:%M:%S",

    // drun segment colors and prompt; all nullable, falling back to bar-wide defaults.
    drun_bg:           ?Color     = null,    // Background; falls back to bg
    drun_fg:           ?Color     = null,    // Typed text color; falls back to fg
    drun_prompt_color: ?Color     = null,    // Prompt text color; falls back to accent_color
    drun_prompt:       []const u8 = "run: ", // Prefix rendered left of the text input cursor

    layout: std.ArrayList(BarLayout)           = .empty,

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

    pub inline fn drunBg(self: *const BarConfig) Color {
        return self.drun_bg orelse self.bg;
    }
    pub inline fn drunFg(self: *const BarConfig) Color {
        return self.drun_fg orelse self.fg;
    }
    pub inline fn drunPromptColor(self: *const BarConfig) Color {
        return self.drun_prompt_color orelse self.accent_color;
    }

    /// Derives horizontal segment padding from font_size.
    /// Percentage path: margin = (bar_height - font_height) / 2, scaled.
    /// Absolute path:   margin = (bar_height - font_px * scale_factor) / 2.
    pub inline fn scaledSegmentPadding(self: *const BarConfig, bar_height: u16) u16 {
        const h: f32 = @floatFromInt(bar_height);
        // Percentage path: margin = (bar_height - font_height) / 2, scaled.
        if (self.font_size.is_percentage) {
            const margin_ratio = (1.0 - self.font_size.value / 100.0) / 2.0;
            return @as(u16, @intFromFloat(@round(@max(0.0, h * margin_ratio * self.scale_factor))));
        }
        // Absolute path: margin = (bar_height - font_px * scale_factor) / 2.
        const font_px = self.font_size.value * self.scale_factor;
        return @as(u16, @intFromFloat(@round(@max(0.0, (h - font_px) / 2.0))));
    }

    /// Scales a ScalableValue to pixels. `factor` multiplies the percentage path;
    /// `scale` is applied on both paths (pass 1.0 to skip).
    inline fn scaleValue(sv: parser.ScalableValue, bar_height: u16, factor: f32, scale: f32) f32 {
        const h: f32 = @floatFromInt(bar_height);
        return if (sv.is_percentage) h * factor * (sv.value / 100.0) * scale else sv.value * scale;
    }

    inline fn scaleToU16(val: f32) u16 {
        return @as(u16, @intFromFloat(@round(@max(0.0, val))));
    }
    pub inline fn scaledSpacing(self: *const BarConfig, bar_height: u16) u16 {
        return scaleToU16(scaleValue(self.spacing, bar_height, 5.0, self.scale_factor));
    }
    pub inline fn scaledIndicatorSize(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, scaleToU16(scaleValue(self.indicator_size, bar_height, 1.0, self.scale_factor)));
    }
    pub inline fn scaledWorkspaceWidth(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, scaleToU16(scaleValue(self.workspace_tag_width, bar_height, 1.0, self.scale_factor)));
    }

    /// Returns the bar's alpha in 16-bit format (0x0000–0xFFFF).
    pub inline fn getAlpha16(self: *const BarConfig) u16 {
        return @intFromFloat(@round(std.math.clamp(self.transparency, 0.0, 1.0) * 0xFFFF));
    }
};

// Workspace types

pub const Rule = struct {
    class_name: []const u8,
    workspace:  u8,
};

pub const WorkspaceConfig = struct {
    count: u8 = 9,
    rules: std.ArrayList(Rule) = .empty,

    pub fn deinit(self: *WorkspaceConfig, allocator: std.mem.Allocator) void {
        for (self.rules.items) |rule| allocator.free(rule.class_name);
        self.rules.deinit(allocator);
    }
};

// Top-level config

pub const Config = struct {
    keybindings:    std.ArrayList(Keybind)   = .empty,
    mouse_bindings: std.ArrayList(MouseBind) = .empty,
    tiling:      TilingConfig    = .{},
    workspaces:  WorkspaceConfig = .{},
    bar:         BarConfig       = .{},

    /// How close (in px or %) a window edge must be to a monitor/bar boundary
    /// before it snaps. Set to 0 to disable. Percentage is relative to screen width.
    snap_distance: parser.ScalableValue = parser.ScalableValue.absolute(8.0),

    // Ownership sentinels for string fields that have static defaults.
    //
    // Some fields (e.g. bar.font, bar.clock_format) point to string literals by default
    // and to heap-allocated slices when the user overrides them in the config file.
    // These nullable fields track which case applies so deinit knows what to free.
    //
    // NOTE: `tiling.layout` is intentionally absent here — it always points into
    // `tiling.layouts.items[0]`, which is freed by `TilingConfig.deinit`.  A
    // separate sentinel would create a redundant allocation and a double-free risk.
    allocated_font:                ?[]const u8 = null,
    allocated_clock_format:        ?[]const u8 = null,
    allocated_indicator_focused:   ?[]const u8 = null,
    allocated_indicator_unfocused: ?[]const u8 = null,
    allocated_drun_prompt:         ?[]const u8 = null,

    pub fn deinit(self: *Config, a: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| kb.action.deinit(a);
        self.keybindings.deinit(a);

        for (self.mouse_bindings.items) |*mb| mb.action.deinit(a);
        self.mouse_bindings.deinit(a);

        self.workspaces.deinit(a);

        self.bar.deinit(a);
        self.tiling.deinit(a);

        inline for (.{
            "allocated_font", "allocated_clock_format",
            "allocated_indicator_focused", "allocated_indicator_unfocused",
            "allocated_drun_prompt",
        }) |field| if (@field(self, field)) |s| a.free(s);
    }
};
