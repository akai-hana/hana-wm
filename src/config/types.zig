//! Config type definitions
//! Defines all types used to represent the WM configuration schema.

const std = @import("std");
const parser = @import("parser");
const xkbcommon = @import("xkbcommon");
const debug = @import("debug");
const constants = @import("constants");

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
    grow_stack_top, // grow the topmost stack slave's share of the column, shrinking the rest evenly (mod+n)
    grow_stack_bottom, // grow the bottommost stack slave's share of the column, shrinking the rest evenly (mod+o)
    toggle_floating_window,
    toggle_fullscreen,
    swap_master,
    swap_master_focus_swap,
    switch_workspace: u8,
    move_to_workspace: u8,
    toggle_tag: u8,
    sequence: []Action, // ordered list of actions executed left-to-right (owned slice)
    dump_state,
    minimize_window,
    unminimize_lifo,
    unminimize_fifo,
    unminimize_all,
    cycle_layout_variants,
    toggle_prompt,
    all_workspaces, // shows all windows from every workspace at once; toggled on/off
    move_to_all_workspaces, // pin focused window to every workspace
    toggle_tag_all, // flip between pinned-to-all and current-workspace-only
    focus_next_window, // cycle focus forward / right
    focus_prev_window, // cycle focus backward / left
    move_window_next, // move focused window forward
    move_window_prev, // move focused window backward
    scroll_view_left, // shift scroll-layout viewport left by one slot
    scroll_view_right, // shift scroll-layout viewport right by one slot

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

/// Owns the (modifiers, keysym) -> Action dispatch map resolved from a
/// Config's keybindings, plus the keycode-resolution step that feeds it.
/// Embedded in Config (not a global) so its lifetime tracks that Config;
/// deinit tears it down before freeing the Actions its entries point into.
pub const KeybindResolver = struct {
    map: std.AutoHashMapUnmanaged(u64, *const Action) = .empty,

    inline fn dispatchKey(modifiers: u16, keysym: u32) u64 {
        return (@as(u64, modifiers) << 32) | keysym;
    }

    /// Resolves each keybinding's keysym to a keycode via `xkb_state`, then
    /// rebuilds the dispatch map (see rebuildDispatchMap). Call once at
    /// startup (config.load) and again on every config reload
    /// (events.applyConfig).
    pub fn build(self: *KeybindResolver, keybindings: []Keybind, xkb_state: *xkbcommon.XkbState, allocator: std.mem.Allocator) void {
        for (keybindings) |*kb| {
            kb.keycode = xkb_state.keysymToKeycode(kb.keysym);
            if (kb.keycode == null) {
                var name_buf: [64]u8 = undefined;
                const name = xkbcommon.keysymGetName(kb.keysym, &name_buf);
                debug.warn("Keybinding mods=0x{x:0>4} keysym={s} (0x{x}) resolves to no base keycode and will NOT be grabbed, shifted symbols such as \"@\" must be bound via their unshifted key name (e.g. \"2\")", .{ kb.modifiers, name, kb.keysym });
            }
        }
        self.rebuildDispatchMap(keybindings, allocator);
    }

    /// Warns about conflicting bindings (same effective mods+keysym the map
    /// is keyed on) and rebuilds the dispatch map from scratch. Split out
    /// from `build` so it can be exercised without a live XkbState/X
    /// connection.
    pub fn rebuildDispatchMap(self: *KeybindResolver, keybindings: []Keybind, allocator: std.mem.Allocator) void {
        self.map.clearRetainingCapacity();
        for (keybindings, 0..) |*kb, i| {
            const key = dispatchKey(kb.modifiers, kb.keysym);
            if (self.map.get(key)) |_| {
                const first_idx = for (keybindings[0..i], 0..) |other, j| {
                    if (dispatchKey(other.modifiers, other.keysym) == key) break j;
                } else unreachable;
                debug.warn("Keybinding conflict: #{} and #{} share mods=0x{x:0>4} keysym=0x{x}, second wins", .{ first_idx + 1, i + 1, kb.modifiers, kb.keysym });
            }
            self.map.put(allocator, key, &kb.action) catch |e| debug.warnOnErr(e, "keybind map build");
        }
    }

    /// O(1) keybinding lookup for use on the hot key-press path.
    /// Returns a pointer into the current config's keybindings slice, or null.
    pub inline fn lookup(self: *const KeybindResolver, mods: u16, keysym: u32) ?*const Action {
        return self.map.get(dispatchKey(mods, keysym));
    }

    /// Releases the dispatch map. Called from Config.deinit, before the
    /// keybindings whose Actions this map's entries point into are freed.
    pub fn deinit(self: *KeybindResolver, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.map = .empty;
    }
};

// Tiling layout types

/// Result of lowerStringCI: the lowercased string is embedded *by value*
/// (copied into `buf`, not borrowed from the caller's stack frame), so it's
/// safe to return this from a function and keep using it afterward.
pub fn LowerResult(comptime max_len: usize) type {
    return union(enum) {
        ok: struct {
            buf: [max_len]u8,
            len: usize,

            pub fn slice(self: *const @This()) []const u8 {
                return self.buf[0..self.len];
            }
        },
        too_long,
    };
}

/// Lowercases `str` into a `max_len`-byte stack buffer if it fits, or reports
/// `.too_long` (distinct from "not found", so callers can warn on overlong
/// values). Shared by the layout-name and string_map lookups; keyNameToKeysym
/// bypasses it: the C API needs a verbatim NUL-terminated copy.
pub fn lowerStringCI(comptime max_len: usize, str: []const u8) LowerResult(max_len) {
    if (str.len > max_len) return .too_long;
    var result: LowerResult(max_len) = .{ .ok = .{ .buf = undefined, .len = str.len } };
    _ = std.ascii.lowerString(result.ok.buf[0..str.len], str);
    return result;
}

/// Case-insensitive enum lookup shared by enums that expose a `string_map` decl.
/// Lowercases `str` into a 32-byte stack buffer and probes the map.
/// Returns null when `str` exceeds the buffer or the key is not found.
fn fromStringCI(comptime T: type, str: []const u8) ?T {
    const map = T.string_map;
    return switch (lowerStringCI(32, str)) {
        .too_long => null,
        .ok => |r| map.get(r.slice()),
    };
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

    /// Lowercases str into a stack buffer and looks it up in string_map.
    /// Returns null if str exceeds 32 bytes or is unrecognized.
    pub inline fn fromString(str: []const u8) ?MasterSide {
        return fromStringCI(MasterSide, str);
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
    gaps, // honor gap settings like every other layout
};

pub const GridVariant = enum {
    rigid, // strict grid: leave empty cells in incomplete last row (default)
    relaxed, // last window in incomplete row expands to fill the row
};

/// Combined layout variant state, matching the per-layout defaults.
pub const LayoutVariants = struct {
    master: MasterVariant = .lifo,
    monocle: MonocleVariant = .gapless,
    grid: GridVariant = .rigid,
};

/// The tiling layout algorithm.
/// Defined here (not tiling.zig) to avoid a circular import; tiling.zig
/// re-exports this as `tiling.Layout`.
pub const Layout = enum {
    master,
    monocle,
    grid,
    fibonacci,
    leaf,
    scroll,
    /// Windows keep their current positions. Configurable via
    /// `tiling.layout = "floating"` (resolved via stringToEnum, not
    /// LAYOUT_TABLE) but never cyclable: excluded from LAYOUT_TABLE, so
    /// toggleLayout can't select it and the cycle skips it.
    floating,
};

/// One entry per cyclable layout: every `Layout` tag except `.floating`.
/// Single source of truth for the name<->tag mapping used across tiling.zig,
/// workspaces.zig, and config.zig. Table order is also cycle order for
/// toggleLayout/toggleLayoutReverse.
pub const LayoutInfo = struct {
    tag: Layout,
    /// Canonical name: what gets stored in cfg.tiling.layouts and shown in
    /// the bar's layout indicator.
    name: []const u8,
    /// Alternate spellings accepted when parsing config, folded to `name`
    /// before storage/comparison.
    aliases: []const []const u8 = &.{},
};

pub const LAYOUT_TABLE = [_]LayoutInfo{
    .{ .tag = .master, .name = "master-stack", .aliases = &.{ "master", "master_stack" } },
    .{ .tag = .monocle, .name = "monocle" },
    .{ .tag = .grid, .name = "grid" },
    .{ .tag = .fibonacci, .name = "fibonacci" },
    .{ .tag = .leaf, .name = "leaf" },
    .{ .tag = .scroll, .name = "scroll" },
};

/// Tagged union pairing a variant value with its owning layout type.
pub const LayoutVariantOverride = union(enum) {
    master: MasterVariant,
    monocle: MonocleVariant,
    grid: GridVariant,
};

/// Single source of truth mapping a variant-owning layout's config name to
/// its variant enum type, the `LayoutVariantOverride` tag, and the field on
/// `TilingConfig` that stores the parsed value.
pub const VARIANT_LAYOUTS = [_]struct { name: []const u8, variant: type, tag: []const u8, field: []const u8 }{
    .{ .name = "master-stack", .variant = MasterVariant, .tag = "master", .field = "master_variant" },
    .{ .name = "monocle", .variant = MonocleVariant, .tag = "monocle", .field = "monocle_variant" },
    .{ .name = "grid", .variant = GridVariant, .tag = "grid", .field = "grid_variant" },
};

/// Per-workspace startup layout assignment, overriding the global default.
/// variant is null -> use the per-layout section default.
pub const WorkspaceLayoutOverride = struct {
    workspace_idx: u8, // 0-indexed workspace number
    layout_idx: u8, // index into TilingConfig.layouts
    variant: ?LayoutVariantOverride, // null = use per-layout section default
};

/// Per-workspace master count override, parsed from [tiling.layouts.master-stack.counts].
pub const WorkspaceMasterCountOverride = struct {
    workspace_idx: u8, // 0-indexed workspace number
    count: u8,
};

pub const TilingConfig = struct {
    enabled: bool = true,
    layout: []const u8 = "master-stack",
    layouts: std.ArrayList([]const u8) = .empty, // Available layouts in cycle order
    master_side: MasterSide = .left,
    master_width: parser.ScalableValue = parser.ScalableValue.percentage(50.0),
    master_count: u8 = 1,
    gap_width: parser.ScalableValue = parser.ScalableValue.absolute(10.0),
    border_width: parser.ScalableValue = parser.ScalableValue.absolute(2.0),
    border_focused: Color = 0x5294E2,
    border_unfocused: Color = 0x383C4A,
    /// Smallest on-screen width/height a tiled window (and floating drag
    /// resize) is allowed to reach, in pixels.
    min_window_dim: u16 = constants.MIN_WINDOW_DIM,

    // Per-layout variant preferences, stored as parsed enums (not raw
    // strings) to avoid dangling slices after the config document is freed.
    master_variant: MasterVariant = .lifo,
    monocle_variant: MonocleVariant = .gapless,
    grid_variant: GridVariant = .rigid,

    /// Per-workspace layout assignments parsed from the layouts array.
    workspace_layout_overrides: std.ArrayList(WorkspaceLayoutOverride) = .empty,

    /// Per-workspace master count overrides parsed from [tiling.layouts.master-stack.counts].
    /// Only applied when global_layout = false.
    workspace_master_count_overrides: std.ArrayList(WorkspaceMasterCountOverride) = .empty,

    /// When true, layout changes apply globally across all workspaces instead
    /// of per workspace.
    global_layout: bool = false,

    pub fn deinit(self: *TilingConfig, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |layout| allocator.free(layout);
        self.layouts.deinit(allocator);
        self.workspace_layout_overrides.deinit(allocator);
        self.workspace_master_count_overrides.deinit(allocator);
    }
};

// Bar types

/// Default accent color used by several BarConfig fields.
/// Declared once here so every field referencing it has a single source of truth;
/// changing the theme default is a one-line edit.
const DEFAULT_ACCENT: Color = 0x61AFEF;

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
    // StaticStringMap.initComptime is a compile-time perfect hash, O(1), no runtime cost.
    const string_map = std.StaticStringMap(IndicatorLocation).initComptime(.{
        .{ "up", .up },
        .{ "down", .down },
        .{ "left", .left },
        .{ "right", .right },
        .{ "up-left", .up_left },
        .{ "up_left", .up_left },
        .{ "left-up", .up_left },
        .{ "left_up", .up_left },
        .{ "up-right", .up_right },
        .{ "up_right", .up_right },
        .{ "right-up", .up_right },
        .{ "right_up", .up_right },
        .{ "down-left", .down_left },
        .{ "down_left", .down_left },
        .{ "left-down", .down_left },
        .{ "left_down", .down_left },
        .{ "down-right", .down_right },
        .{ "down_right", .down_right },
        .{ "right-down", .down_right },
        .{ "right_down", .down_right },
    });
    /// Case-insensitive parse. Returns null if str exceeds 32 bytes or is unrecognized.
    pub inline fn fromString(str: []const u8) ?IndicatorLocation {
        return fromStringCI(IndicatorLocation, str);
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

/// Type-level defaults for optional string fields in BarConfig.
/// When a field is `null`, the corresponding default is used at read time.
pub const DEFAULT_CLOCK_FORMAT: []const u8 = "%Y-%m-%d %H:%M:%S";
pub const DEFAULT_DRUN_PROMPT: []const u8 = "run: ";
pub const DEFAULT_INDICATOR_FOCUSED: []const u8 = "■";
pub const DEFAULT_INDICATOR_UNFOCUSED: []const u8 = "□";

/// Frees every owned string in `list`, then either deinits or clears the
/// list depending on `retain_capacity`. Shared by `BarConfig.deinit`
/// (full teardown) and config reload (reuse backing storage).
pub inline fn freeStrings(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, retain_capacity: bool) void {
    for (list.items) |s| allocator.free(s);
    if (retain_capacity) list.clearRetainingCapacity() else list.deinit(allocator);
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
    // Resolved pixel value cached after DPI scaling, derived from font_size
    // at startup. This is runtime state, not raw config, mixed into
    // BarConfig for convenience.
    scaled_font_size: u16 = 10, // Can exceed 255 on high DPI - u16 is correct
    spacing: parser.ScalableValue = parser.ScalableValue.absolute(12.0),

    // Bar color scheme; all values are 0xRRGGBB (see Color type alias).
    bg: Color = 0x222222,
    fg: Color = 0xBBBBBB,
    selected_bg: Color = 0x005577,
    selected_fg: Color = 0xEEEEEE,

    accent_color: Color = DEFAULT_ACCENT,
    title_accent_color: Color = DEFAULT_ACCENT,
    title_unfocused_accent: Color = 0x222222,
    title_minimized_accent: Color = DEFAULT_ACCENT,

    workspace_icons: std.ArrayList([]const u8) = .empty,
    indicator_size: parser.ScalableValue = parser.ScalableValue.percentage(30.0),
    workspace_tag_width: parser.ScalableValue = parser.ScalableValue.percentage(100.0),

    indicator_location: IndicatorLocation = .up_left,
    indicator_padding: f32 = 0.1,
    indicator_focused: ?[]const u8 = null,
    indicator_unfocused: ?[]const u8 = null,
    indicator_color: ?Color = null,

    clock_format: ?[]const u8 = null,

    // drun segment colors and prompt; all nullable, falling back to bar-wide defaults.
    drun_bg: ?Color = null, // Background; falls back to bg
    drun_fg: ?Color = null, // Typed text color; falls back to fg
    drun_prompt_color: ?Color = null, // Prompt text color; falls back to accent_color
    drun_prompt: ?[]const u8 = null, // Prefix rendered left of the text input cursor

    layout: std.ArrayList(BarLayout) = .empty,

    transparency: f32 = 1.0,

    /// Carousel scroll settings, staged here so they reach the carousel's
    /// live globals only after a config has been validated and swapped in
    /// (config.applyCarouselSettings), writing them at parse time (the old
    /// behaviour) leaked them into effect for a rejected config.
    carousel_enabled: bool = true,
    /// Scroll speed in px/s (config `scroll_speed`, min 1).
    scroll_speed: u16 = 125,
    /// Refresh-rate override in Hz (config `carousel_refresh_rate`); 0 = auto.
    carousel_refresh_rate: u16 = 0,

    pub fn deinit(self: *BarConfig, allocator: std.mem.Allocator) void {
        freeStrings(&self.workspace_icons, allocator, false);
        freeStrings(&self.fonts, allocator, false);
        for (self.layout.items) |*item| item.deinit(allocator);
        self.layout.deinit(allocator);
        if (self.clock_format) |s| allocator.free(s);
        if (self.drun_prompt) |s| allocator.free(s);
        if (self.indicator_focused) |s| allocator.free(s);
        if (self.indicator_unfocused) |s| allocator.free(s);
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
    pub inline fn scaledSpacing(self: *const BarConfig, bar_height: u16) u16 {
        return scaleToU16(scaleValue(self.spacing, bar_height, 5.0));
    }
    pub inline fn scaledIndicatorSize(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, scaleToU16(scaleValue(self.indicator_size, bar_height, 1.0)));
    }
    pub inline fn scaledWorkspaceWidth(self: *const BarConfig, bar_height: u16) u16 {
        return @max(1, scaleToU16(scaleValue(self.workspace_tag_width, bar_height, 1.0)));
    }

    /// Returns the bar's alpha in 16-bit format (0x0000-0xFFFF).
    pub inline fn getAlpha16(self: *const BarConfig) u16 {
        return @intFromFloat(@round(std.math.clamp(self.transparency, 0.0, 1.0) * 0xFFFF));
    }
};

// Workspace types

pub const Rule = struct {
    class_name: []const u8,
    workspace: u8,
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

    /// Persistent (modifiers, keysym) -> Action dispatch map, built from
    /// `keybindings` by config.load() (startup) and events.applyConfig()
    /// (reload). See KeybindResolver's doc comment for why this lives here
    /// rather than as a module-level global.
    keybind_resolver: KeybindResolver = .{},

    /// Each subsystem is always fully compiled in; these flags just gate
    /// whether its behavior (and keybindings/actions that drive it) is active.
    fullscreen_enabled: bool = true,
    minimize_enabled: bool = true,
    drag_enabled: bool = true,

    /// How close (in px or %) a window edge must be to a monitor/bar boundary
    /// before it snaps. Set to 0 to disable. Percentage is relative to screen width.
    snap_distance: parser.ScalableValue = parser.ScalableValue.absolute(8.0),

    pub fn deinit(self: *Config, a: std.mem.Allocator) void {
        // Must precede `self.keybindings.deinit(a)`: the map holds `*const
        // Action` pointers borrowed from self.keybindings' elements, so it
        // must be torn down before those Actions are freed.
        self.keybind_resolver.deinit(a);

        for (self.keybindings.items) |*kb| kb.action.deinit(a);
        self.keybindings.deinit(a);

        for (self.mouse_bindings.items) |*mb| mb.action.deinit(a);
        self.mouse_bindings.deinit(a);

        self.workspaces.deinit(a);

        self.bar.deinit(a);
        self.tiling.deinit(a);
    }
};
