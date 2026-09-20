//! Config type definitions
//! Defines all types used to represent the WM configuration schema.

const std = @import("std");
const constants = @import("constants");
const model = @import("model");
const parser = @import("parser");

/// X11 color value packed as 0x00RRGGBB into 32 bits.
/// The high byte is unused; values match what XCB expects for pixel/color fields.
pub const Color = u32;

/// Ceiling of a valid 24-bit color (0x000000-0xFFFFFF). Shared by the
/// in-range-integer color checks in the parser's single color decoder.
pub const max_color: u32 = 0xFF_FF_FF;

/// Config-file section names shared by the parser, the schema's placement
/// tables, and the config interpreter's sweeps. Single-sourced so a spelling
/// change (and the case-typo sweep that keys on these) updates one place.
pub const section_tiling = "tiling";
pub const section_bar = "bar";
pub const section_bar_colors = "bar.colors";
pub const section_rules = "rules";
pub const section_workspace_rules = "workspace.rules";
pub const section_tiling_aesthetics = "tiling.aesthetics";
pub const section_tiling_layouts_master_stack = "tiling.layouts.master-stack";

/// Section-name prefixes for the family sweeps (inert-family warnings,
/// numbered-rule sections, tiling layout subtables).
pub const section_prefix_tiling = "tiling.";
pub const section_prefix_tiling_layouts = "tiling.layouts.";
pub const section_prefix_workspace_rules = "workspace.rules.";
pub const section_prefix_rules = "rules.";
pub const section_prefix_bar_layout = "bar.layout.";

/// Document-global color-palette variable names declared once and referenced
/// by any color knob (schema's color_from chain and the parser's collectPalette).
pub const palette_primary_color = "primary_color";
pub const palette_secondary_color = "secondary_color";
pub const palette_alternative_color = "alternative_color";
pub const palette_text_color = "text_color";

// Keybinding and action types

pub const Dir = enum { forward, reverse };
pub const SwapMode = enum { normal, focus_swap };
/// Single source: the model owns the restore-order vocabulary (its enum is
/// what minimize/actions dispatch on); config aliases it so the Action knob
/// and the runtime share one type and one definition.
pub const RestoreOrder = model.RestoreOrder;

pub const Action = union(enum) {
    exec: []const u8,
    close_window,
    /// In-place config reload: re-reads config.toml and applies the diff to
    /// the live model, without restarting the process (proc.reload flag).
    reload_config,
    /// Unconditional in-place re-exec of the current binary at the resolved
    /// executable path (restart.requestReexec): reloads the whole process,
    /// no binary-change check.
    reload_hana,
    cycle_layout: Dir,
    toggle_bar_visibility,
    toggle_bar_position,
    set_master_width: Dir,
    set_master_count: Dir,
    /// Grow the topmost/bottommost stack slave's share of the column (mod+n/o).
    grow_stack: Dir,
    toggle_floating_window,
    toggle_fullscreen,
    swap_master: SwapMode,
    switch_workspace: u8,
    move_to_workspace: u8,
    toggle_tag: u8,
    /// Ordered list of actions executed left-to-right (owned slice).
    sequence: []Action,
    dump_state,
    minimize_window,
    unminimize: RestoreOrder,
    unminimize_all,
    cycle_variants: Dir,
    toggle_prompt,
    /// Shows all windows from every workspace at once; toggled on/off.
    all_workspaces,
    /// Pin/unpin focused window to every workspace.
    pin_window,
    /// Cycle focus forward/right or backward/left.
    cycle_focus: Dir,
    /// Move focused window forward.
    move_window_next,
    /// Move focused window backward.
    move_window_prev,
    /// Shift scroll-layout viewport left/right by one slot.
    scroll_view: Dir,

    pub fn deinit(self: *Action, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .exec => |cmd| allocator.free(cmd),
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
    keysym: u32, // xcb_keysym_t is u32 by X11 protocol spec; never narrowed
    keycode: ?u8 = null,
    action: Action,
};

/// A binding triggered by a mouse button press with modifier keys held.
pub const MouseBind = struct {
    modifiers: u16,
    button: u8,
    action: Action,
};

// The (modifiers, keysym) -> Action dispatch map and its keysym->keycode
// resolution live in the input layer (`input/keybind.zig`): resolving a keysym
// needs a live XkbState, which the pure config layer must not depend on.
// Keeping it out of this file also breaks the types -> xkbcommon -> core ->
// types import cycle.

// Tiling layout types

/// Maximum bytes any lowered config name (layout names, string_map keys) may
/// occupy. Single home for the 32-byte buffers that config lookups lower into;
/// config.zig's layout-name parser derives from this so the two can't drift.
pub const max_config_name = 32;

/// Lowercases `str` into a `max_len`-byte stack buffer if it fits; returns
/// null when `str` is too long. Shared by the layout-name and string_map
/// lookups; keyNameToKeysym bypasses it: the C API needs a verbatim
/// NUL-terminated copy.
pub inline fn lowerSlice(comptime max_len: usize, buf: *[max_len]u8, str: []const u8) ?[]const u8 {
    if (str.len > max_len) return null;
    _ = std.ascii.lowerString(buf[0..str.len], str);
    return buf[0..str.len];
}

/// Case-insensitive enum lookup shared by enums that expose a `string_map` decl.
/// Lowercases `str` into a stack buffer and probes the map.
/// Returns null when `str` exceeds the buffer or the key is not found.
pub fn enumFromString(comptime T: type, str: []const u8) ?T {
    const map = T.string_map;
    var buf: [max_config_name]u8 = undefined;
    return map.get(lowerSlice(max_config_name, &buf, str) orelse return null);
}

pub const MasterSide = enum {
    left,
    right,

    const string_map = std.StaticStringMap(MasterSide).initComptime(.{
        .{ "l", .left },
        .{ "left", .left },
        .{ "r", .right },
        .{ "right", .right },
    });
};

/// Window placement policy for the master-stack layout is now expressed as
/// VALUE-STRINGS in the registry-driven `variants` map (see TilingConfig).
/// Each layout module binds its own `variant_parse` to interpret those
/// strings; there are no closed per-layout variant enums here anymore (the
/// former MasterVariant/MonocleVariant/GridVariant and the
/// LayoutVariantOverride union were deleted in Stage 3).
/// Per-workspace startup layout assignment, overriding the global default.
/// variant is null -> use the per-layout map default ([tiling].variants).
pub const WorkspaceLayoutOverride = struct {
    workspace_idx: u8, // 0-indexed workspace number
    layout_idx: u8, // index into TilingConfig.layouts
    variant: ?[]const u8, // null = use per-layout variants-map default
};

/// Per-workspace master count override, parsed from [tiling.layouts.master-stack.counts].
pub const WorkspaceMasterCountOverride = struct {
    workspace_idx: u8, // 0-indexed workspace number
    count: u8,
};

pub const TilingConfig = struct {
    enabled: bool = true,
    /// Canonical default layout name (resolved at seed time against the
    /// `tiling_modules` registry). The "master-stack"/"master_stack" alias
    /// spellings in config are canonicalized onto "master" by the config
    /// boundary, so the stored value is always canonical.
    layout: []const u8 = "master",
    layouts: std.ArrayList([]const u8) = .empty, // Available layouts in cycle order
    master_side: MasterSide = .left,
    master_width: parser.ScalableValue = parser.ScalableValue.percentage(50.0),
    master_count: u8 = 1,
    gap_width: parser.ScalableValue = parser.ScalableValue.absolute(10.0),
    border_width: parser.ScalableValue = parser.ScalableValue.absolute(2.0),
    border_focused: Color = default_focused_border,
    border_unfocused: Color = default_unfocused_border,
    /// Smallest on-screen width/height a tiled window (and floating drag
    /// resize) is allowed to reach, in pixels.
    min_window_dim: u16 = constants.min_window_dim,

    // Per-layout variant preferences, stored generically as a canonical
    // layout-name -> VALUE-STRING map. Both the key and the value-string are
    // heap-duped at parse time (setTilingVariant) so they outlive the parsed
    // document; deinit frees every key and value via freeStringMap.
    variants: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Per-workspace layout assignments parsed from the layouts array.
    workspace_layout_overrides: std.ArrayList(WorkspaceLayoutOverride) = .empty,

    /// Per-workspace master count overrides parsed from [tiling.layouts.master-stack.counts].
    /// Only applied when global_layout = false.
    workspace_master_count_overrides: std.ArrayList(WorkspaceMasterCountOverride) = .empty,

    /// When true, layout changes apply globally across all workspaces instead
    /// of per workspace.
    global_layout: bool = false,

    /// Resolves the per-workspace master-count overrides into a fixed-size,
    /// workspace-indexed lookup with last-wins semantics (a duplicate entry
    /// for one workspace overrides its predecessor). `null` at an index means
    /// no override for that workspace (use the global default). Shared by the
    /// core seed path (actions.seedParamsFromConfig) and the workspaces addon
    /// (applyWorkspaceOverrides) so the last-wins rule lives in one place.
    pub fn masterCountLookup(self: *const TilingConfig) [constants.max_workspaces]?u8 {
        var lookup: [constants.max_workspaces]?u8 = .{null} ** constants.max_workspaces;
        for (self.workspace_master_count_overrides.items) |o| {
            if (o.workspace_idx < constants.max_workspaces)
                lookup[o.workspace_idx] = o.count;
        }
        return lookup;
    }

    /// Resolves the per-workspace layout overrides into a fixed-size,
    /// workspace-indexed lookup of override indices with last-wins semantics
    /// (a duplicate entry for one workspace overrides its predecessor).
    /// `null` at an index means no override for that workspace. Shared by the
    /// core seed path (actions.seedParamsFromConfig) and the workspaces addon
    /// (applyWorkspaceOverrides) so the last-wins rule lives in one place.
    pub fn workspaceLayoutLookup(self: *const TilingConfig) [constants.max_workspaces]?usize {
        var lookup: [constants.max_workspaces]?usize = .{null} ** constants.max_workspaces;
        for (self.workspace_layout_overrides.items, 0..) |o, oi| {
            if (o.workspace_idx < constants.max_workspaces)
                lookup[o.workspace_idx] = oi;
        }
        return lookup;
    }

    pub fn deinit(self: *TilingConfig, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |layout| allocator.free(layout);
        self.layouts.deinit(allocator);
        freeStringMap(&self.variants, allocator, false);
        for (self.workspace_layout_overrides.items) |o| {
            if (o.variant) |v| allocator.free(v);
        }
        self.workspace_layout_overrides.deinit(allocator);
        self.workspace_master_count_overrides.deinit(allocator);
    }
};

// Bar types

// Default color scheme for the focused/unfocused tiling borders.
const default_focused_border: Color = 0x5294E2;
const default_unfocused_border: Color = 0x383C4A;

/// Default accent color; declared once so every referencing field has a single source of truth.
const default_accent: Color = 0x61AFEF;

// Default bar background/foreground scheme. Kept in one place so the bar's
// color defaults read as a palette rather than scattered hex literals.
const default_bar_bg: Color = 0x222222;
const default_bar_fg: Color = 0xBBBBBB;
const default_bar_selected_bg: Color = 0x005577;
const default_bar_selected_fg: Color = 0xEEEEEE;

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

    // Accepts hyphens or underscores and both orderings of diagonal names
    // (e.g. "left-up" == "up-left"). Cardinal entries + diagonal entries are
    // generated at comptime from a compact table.
    const string_map = blk: {
        @setEvalBranchQuota(2000);
        const cardinals = [_]struct { []const u8, IndicatorLocation }{
            .{ "up", .up }, .{ "down", .down }, .{ "left", .left }, .{ "right", .right },
        };
        const diags = [_]struct { []const u8, []const u8, IndicatorLocation }{
            .{ "up", "left", .up_left },     .{ "up", "right", .up_right },
            .{ "down", "left", .down_left }, .{ "down", "right", .down_right },
        };
        var kvs: [cardinals.len + diags.len * 4]struct { []const u8, IndicatorLocation } = undefined;
        var n: usize = 0;
        for (cardinals) |c| {
            kvs[n] = c;
            n += 1;
        }
        for (diags) |d| for (.{ "-", "_" }) |sep| {
            kvs[n] = .{ d[0] ++ sep ++ d[1], d[2] };
            n += 1;
            kvs[n] = .{ d[1] ++ sep ++ d[0], d[2] };
            n += 1;
        };
        break :blk std.StaticStringMap(IndicatorLocation).initComptime(kvs[0..n]);
    };
};

/// Vertical placement of the bar on screen: top or bottom edge.
pub const BarScreenPosition = enum {
    top,
    bottom,

    // Case-insensitive alias map for types.enumFromString, so `bar.position`
    // accepts any-case "top"/"bottom" (C8).
    const string_map = std.StaticStringMap(BarScreenPosition).initComptime(.{
        .{ "top", .top },
        .{ "bottom", .bottom },
    });
};

/// Horizontal anchor for a BarLayout column within the bar.
pub const BarSegmentAnchor = enum {
    left,
    center,
    right,
};

/// One column of the bar: an anchor position and an ordered list of segment
/// names (registry names) to display. Names are resolved against the generated
/// `bar_modules` registry at layout time; unknown/removed names draw nothing.
pub const BarLayout = struct {
    position: BarSegmentAnchor,
    segments: std.ArrayList([]const u8),

    pub inline fn deinit(self: *BarLayout, allocator: std.mem.Allocator) void {
        for (self.segments.items) |s| allocator.free(s);
        self.segments.deinit(allocator);
    }
};

/// Type-level defaults for optional string fields in BarConfig.
/// When a field is `null`, the corresponding default is used at read time.
pub const default_clock_format: []const u8 = "%Y-%m-%d %H:%M:%S";
pub const default_drun_prompt: []const u8 = "run: ";
pub const default_indicator_focused: []const u8 = "■";
pub const default_indicator_unfocused: []const u8 = "□";

/// Frees every owned string in `list`, then either deinits or clears the
/// list depending on `retain_capacity`. Shared by `BarConfig.deinit`
/// (full teardown) and config reload (reuse backing storage).
pub inline fn freeStrings(
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    retain_capacity: bool,
) void {
    for (list.items) |s| allocator.free(s);
    if (retain_capacity) list.clearRetainingCapacity() else list.deinit(allocator);
}

/// Frees every heap-dup'd key/value in a tiling.variants-style string map,
/// then either deinits or clears it depending on `retain_capacity`.
pub fn freeStringMap(
    map: *std.StringHashMapUnmanaged([]const u8),
    allocator: std.mem.Allocator,
    retain_capacity: bool,
) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    if (retain_capacity) map.clearRetainingCapacity() else map.deinit(allocator);
}

pub inline fn freeBarLayouts(
    list: *std.ArrayList(BarLayout),
    allocator: std.mem.Allocator,
    retain_capacity: bool,
) void {
    for (list.items) |*item| item.deinit(allocator);
    if (retain_capacity) list.clearRetainingCapacity() else list.deinit(allocator);
}

/// Frees the owned segment-name keys of a [bar.colors] segment-color map,
/// then deinits the map itself. Values are scalars (colors); only keys need
/// freeing.
pub fn freeSegmentColors(
    map: *std.StringHashMapUnmanaged(Color),
    allocator: std.mem.Allocator,
) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    map.deinit(allocator);
    // Zig 0.16's HashMapUnmanaged.deinit leaves the struct `undefined` rather
    // than reusable; reset so a later freeSegmentColors/put on the same map
    // (config reload reuses the field) stays safe.
    map.* = .empty;
}

pub const BarConfig = struct {
    enabled: bool = true,

    /// true = full vim modal editing in the prompt; false = basic
    /// single-line editing (arrows, Home/End, Backspace/Delete) via the
    /// existing fallback path.
    vim_mode: bool = true,

    bar_position: BarScreenPosition = .top,
    // Configured bar height: absolute pixel value or percentage of screen height.
    // null = auto-calculate from font metrics alone.
    height: ?parser.ScalableValue = null,
    fonts: std.ArrayList([]const u8) = .empty,
    font_size: parser.ScalableValue = parser.ScalableValue.percentage(10.0),
    spacing: parser.ScalableValue = parser.ScalableValue.absolute(12.0),

    // Bar color scheme; all values are 0xRRGGBB (see Color type alias).
    bg: Color = default_bar_bg,
    fg: Color = default_bar_fg,
    selected_bg: Color = default_bar_selected_bg,
    selected_fg: Color = default_bar_selected_fg,

    // Palette canon (the former `accent_color` renamed primary). Declared in
    // the theme's palette section; the other three exist so the palette is
    // first-class config even though rendering consumes them through the
    // title/drun chains below.
    primary_color: Color = default_accent,
    secondary_color: Color = default_accent,
    alternative_color: Color = default_accent,
    text_color: Color = default_accent,
    title_accent_color: Color = default_accent,
    title_unfocused_accent: Color = default_bar_bg,
    title_minimized_accent: Color = default_accent,

    workspace_icons: std.ArrayList([]const u8) = .empty,
    indicator_size: parser.ScalableValue = parser.ScalableValue.percentage(30.0),
    workspace_tag_width: parser.ScalableValue = parser.ScalableValue.percentage(100.0),

    indicator_location: IndicatorLocation = .up_left,
    indicator_padding: f32 = 0.1,
    indicator_focused: ?[]const u8 = null,
    indicator_unfocused: ?[]const u8 = null,
    indicator_color: ?Color = null,

    clock_format: ?[]const u8 = null,

    /// Volume slider sub display templates (bar.modules... the volume sub
    /// falls back to its built-in strings when null). `{pct}` is replaced by
    /// the 0-100 level; `{state}` by the mute glyph ("mute"/"unmute" words by
    /// default -- override just the format to restyle). When the sink is
    /// muted the volume_muted_format wins.
    volume_format: ?[]const u8 = null,
    volume_muted_format: ?[]const u8 = null,
    /// Brightness slider sub display template (bar.modules... falls back to
    /// "BRT {pct}%" when null). `{pct}` is replaced by the 0-100 level; there
    /// is no muted-style second state so no `{state}`.
    brightness_format: ?[]const u8 = null,
    /// Brightness slider sub device pin: names a `/sys/class/backlight/*`
    /// device, or -- with a `led:` prefix -- an LED-class device under
    /// `/sys/class/leds/*`. Absent ("") = auto-discovery picks the first
    /// usable backlight.
    brightness_device: ?[]const u8 = null,

    /// Scroll the focused window's title through its slot when it overflows
    /// (marquee) instead of truncating it with an ellipsis.
    carousel_enabled: bool = true,
    /// Marquee scroll speed in pixels per second.
    carousel_speed_px_s: u16 = 125,

    // drun segment colors and prompt; all nullable, falling back to bar-wide defaults.
    drun_bg: ?Color = null, // Background; falls back to bg
    drun_fg: ?Color = null, // Typed text color; falls back to fg
    drun_prompt_color: ?Color = null, // Prompt text color; falls back to primary_color
    drun_prompt: ?[]const u8 = null, // Prefix rendered left of the text input cursor

    /// Per-segment text-color overrides, keyed by bar segment registry name
    /// ("cpu", "mem", "volume", "brightness", ...). Populated from
    /// `[bar.colors].<segment>` entries; a segment with no entry paints its
    /// text in `fg` (see `segmentFg`). Colors for absent segments are
    /// tolerated and simply never match a live segment, so a theme may carry
    /// a full readout palette up front. Keys are owned (duped) once; freed
    /// in deinit.
    segment_fg: std.StringHashMapUnmanaged(Color) = .empty,

    layout: std.ArrayList(BarLayout) = .empty,

    transparency: f32 = 1.0,

    // NOTE: indicator_focused/unfocused are always independently owned
    // (each set via schema.assignStr which always dupes). If one mirrors
    // the other, both point to separate allocations. Do not bypass assignStr.
    pub fn deinit(self: *BarConfig, allocator: std.mem.Allocator) void {
        freeStrings(&self.workspace_icons, allocator, false);
        freeStrings(&self.fonts, allocator, false);
        freeBarLayouts(&self.layout, allocator, false);
        freeSegmentColors(&self.segment_fg, allocator);
        inline for (.{ &self.clock_format, &self.drun_prompt, &self.indicator_focused, &self.indicator_unfocused, &self.volume_format, &self.volume_muted_format, &self.brightness_format, &self.brightness_device }) |f| if (f.*) |s| allocator.free(s);
    }

    pub inline fn drunBg(self: *const BarConfig) Color {
        return self.drun_bg orelse self.bg;
    }
    pub inline fn drunFg(self: *const BarConfig) Color {
        return self.drun_fg orelse self.fg;
    }
    pub inline fn drunPromptColor(self: *const BarConfig) Color {
        return self.drun_prompt_color orelse self.primary_color;
    }

    /// Text color for bar segment `name`: its [bar.colors] override, or the
    /// bar-wide `fg` when none is set.
    pub inline fn segmentFg(self: *const BarConfig, name: []const u8) Color {
        return self.segment_fg.get(name) orelse self.fg;
    }

    /// Derives horizontal segment padding from font_size.
    /// Percentage path: margin = (bar_height - font_height) / 2, scaled.
    /// Absolute path:   margin = (bar_height - font_px) / 2.
    pub inline fn scaledSegmentPadding(self: *const BarConfig, bar_height: u16) u16 {
        const h: f32 = @floatFromInt(bar_height);
        if (self.font_size.is_percentage) {
            const margin_ratio = (1.0 - self.font_size.value / 100.0) / 2.0;
            return scaleToU16(h * margin_ratio);
        }
        const font_px = self.font_size.value;
        return scaleToU16((h - font_px) / 2.0);
    }

    /// Scales a ScalableValue to pixels. `factor` multiplies the percentage path.
    inline fn scaleValue(sv: parser.ScalableValue, bar_height: u16, factor: f32) f32 {
        const h: f32 = @floatFromInt(bar_height);
        return if (sv.is_percentage) h * factor * (sv.value / 100.0) else sv.value;
    }

    inline fn scaleToU16(val: f32) u16 {
        const clamped = std.math.clamp(val, 0.0, @as(f32, std.math.maxInt(u16)));
        return @as(u16, @intFromFloat(@round(clamped)));
    }
    /// Scale factor applied to the spacing percentage path (`spacing` widens
    /// with the bar); the absolute-px path is used verbatim.
    const spacing_scale_factor: f32 = 5.0;
    pub inline fn scaledSpacing(self: *const BarConfig, bar_height: u16) u16 {
        return scaleToU16(scaleValue(self.spacing, bar_height, spacing_scale_factor));
    }
    pub inline fn scaledIndicatorSize(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, scaleToU16(scaleValue(self.indicator_size, bar_height, 1.0)));
    }
    pub inline fn scaledWorkspaceWidth(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, scaleToU16(scaleValue(self.workspace_tag_width, bar_height, 1.0)));
    }

    /// The 16-bit alpha ceiling: `transparency` (0.0-1.0) maps into 0x0000-0xFFFF.
    const alpha16_ceiling: f32 = 0xFFFF;

    /// Returns the bar's alpha in 16-bit format (0x0000-0xFFFF).
    pub inline fn getAlpha16(self: *const BarConfig) u16 {
        return @intFromFloat(@round(std.math.clamp(self.transparency, 0.0, 1.0) * alpha16_ceiling));
    }
};

// Workspace types

pub const Rule = struct {
    class_name: []const u8,
    /// Target workspace (0-based) for workspace rules; unused when `float`.
    workspace: u8,
    /// "float" class rules: windows matching `class_name` are admitted
    /// floating on the current workspace instead of being tiled on `workspace`.
    float: bool = false,
};

pub const WorkspaceConfig = struct {
    /// When false, every window lives on a single implicit workspace and
    /// all workspace-switching keybindings/actions are no-ops.
    enabled: bool = true,
    count: u8 = 9,
    rules: std.ArrayList(Rule) = .empty,

    pub fn deinit(self: *WorkspaceConfig, allocator: std.mem.Allocator) void {
        for (self.rules.items) |rule| allocator.free(rule.class_name);
        self.rules.deinit(allocator);
    }
};

// Top-level config

pub const Config = struct {
    keybindings: std.ArrayList(Keybind) = .empty,
    mouse_bindings: std.ArrayList(MouseBind) = .empty,
    tiling: TilingConfig = .{},
    workspaces: WorkspaceConfig = .{},
    bar: BarConfig = .{},

    /// Each subsystem is always fully compiled in; these flags just gate
    /// whether its behavior (and keybindings/actions that drive it) is active.
    fullscreen_enabled: bool = true,
    drag_enabled: bool = true,

    /// How close (in px or %) a window edge must be to a monitor/bar boundary
    /// before it snaps. Set to 0 to disable. Percentage is relative to screen width.
    snap_distance: parser.ScalableValue = parser.ScalableValue.absolute(8.0),

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.keybindings.items) |*kb| kb.action.deinit(allocator);
        self.keybindings.deinit(allocator);

        for (self.mouse_bindings.items) |*mb| mb.action.deinit(allocator);
        self.mouse_bindings.deinit(allocator);

        self.workspaces.deinit(allocator);

        self.bar.deinit(allocator);
        self.tiling.deinit(allocator);
    }
};
