//! The bar config fragment: `Config` (the [bar] subtree), its knob table,
//! the `[bar.properties]` segment decoder, and the parse/validate entry
//! points the generated `composed` dispatcher calls.

const std = @import("std");
const log = std.log.scoped(.bar_config);
const parser = @import("parser");
const scaling = @import("scaling");
const types = @import("types");
const knob = @import("knob");
const color = @import("color");
const bar_sections = @import("bar_sections");

/// Where in the workspace cell the activity indicator is drawn. TOML spelling:
/// cardinal names verbatim; diagonals with hyphens or underscores in either order.
pub const IndicatorLocation = enum {
    up,
    down,
    left,
    right,
    up_left,
    up_right,
    down_left,
    down_right,

    pub const string_map = std.StaticStringMap(IndicatorLocation).initComptime(.{
        .{ "up", .up },                 .{ "down", .down },
        .{ "left", .left },             .{ "right", .right },
        .{ "up-left", .up_left },       .{ "up_left", .up_left },
        .{ "left-up", .up_left },       .{ "left_up", .up_left },
        .{ "up-right", .up_right },     .{ "up_right", .up_right },
        .{ "right-up", .up_right },     .{ "right_up", .up_right },
        .{ "down-left", .down_left },   .{ "down_left", .down_left },
        .{ "left-down", .down_left },   .{ "left_down", .down_left },
        .{ "down-right", .down_right }, .{ "down_right", .down_right },
        .{ "right-down", .down_right }, .{ "right_down", .down_right },
    });
};

/// Vertical placement of the bar on screen.
pub const BarScreenPosition = enum {
    top,
    bottom,

    pub const string_map = std.StaticStringMap(BarScreenPosition).initComptime(.{
        .{ "top", .top },
        .{ "bottom", .bottom },
    });
};

pub const BarSegmentAnchor = enum {
    left,
    center,
    right,
};

/// One column of the bar: an anchor + ordered segment-name list. Names resolve
/// against the generated `bar_modules` registry; unknown names draw nothing.
pub const BarLayout = struct {
    position: BarSegmentAnchor,
    segments: std.ArrayList([]const u8),

    pub inline fn deinit(self: *BarLayout, allocator: std.mem.Allocator) void {
        for (self.segments.items) |s| allocator.free(s);
        self.segments.deinit(allocator);
    }
};

/// Per-segment text style flags from `[bar.properties].<segment>` (Pango
/// attributes); all default to false.
pub const SegmentProps = struct {
    underline: bool = false,
    bold: bool = false,
    italic: bool = false,
    /// Absolute text size for the whole segment from a `size=N` token; null =
    /// configured font size. Same sized font-description path keeps measure/draw agreeing.
    size: ?u16 = null,

    pub fn isDefault(self: SegmentProps) bool {
        return std.meta.eql(self, .{});
    }
};

/// Composite `[bar.properties]` keys for the workspaces segment: a base entry
/// styling every tag and a `_selected` overlay for the current tag.
pub const seg_workspaces = "workspaces";
pub const seg_workspaces_selected = "workspaces_selected";

pub inline fn freeBarLayouts(
    list: *std.ArrayList(BarLayout),
    allocator: std.mem.Allocator,
    retain_capacity: bool,
) void {
    for (list.items) |*item| item.deinit(allocator);
    if (retain_capacity) list.clearRetainingCapacity() else list.deinit(allocator);
}

/// Frees the owned segment-name keys of a [bar.properties] segment map, then
/// deinits the map itself. Values are scalars; only keys need freeing. Zig 0.16
/// HashMapUnmanaged.deinit leaves `undefined`, so reset to `.empty` for reload.
pub fn freeSegmentMap(comptime V: type, map: *std.StringHashMapUnmanaged(V), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    map.deinit(allocator);
    map.* = .empty;
}

/// Frees every `?[]const u8` field of `Config`. Type-driven: a new string
/// field is freed with no edit here; no name is written down to go stale.
inline fn freeOwnedStrings(self: *Config, allocator: std.mem.Allocator) void {
    inline for (std.meta.fields(Config)) |f| {
        if (f.type != ?[]const u8) continue;
        if (@field(self, f.name)) |s| allocator.free(s);
    }
}

pub const Config = struct {
    enabled: bool = true,

    bar_position: BarScreenPosition = .top,
    // null = auto from font metrics
    height: ?types.ScalableValue = null,
    fonts: std.ArrayList([]const u8) = .empty,
    font_size: types.ScalableValue = types.ScalableValue.percentage(10.0),
    spacing: types.ScalableValue = types.ScalableValue.absolute(12.0),

    // Bar color scheme; all values 0xRRGGBB (see types.Color).
    bg: types.Color = types.default_bar_bg,
    fg: types.Color = types.default_bar_fg,
    selected_bg: types.Color = types.default_bar_selected_bg,
    selected_fg: types.Color = types.default_bar_selected_fg,

    // Palette canon; the rest are first-class config consumed through the
    // title/run chains.
    primary_color: types.Color = types.default_accent,
    secondary_color: types.Color = types.default_accent,
    alternative_color: types.Color = types.default_accent,
    text_color: types.Color = types.default_accent,
    title_accent_color: types.Color = types.default_accent,
    title_unfocused_accent: types.Color = types.default_bar_bg,
    title_minimized_accent: types.Color = types.default_accent,

    workspace_icons: std.ArrayList([]const u8) = .empty,
    indicator_size: types.ScalableValue = types.ScalableValue.percentage(30.0),
    workspace_tag_width: types.ScalableValue = types.ScalableValue.percentage(100.0),

    indicator_location: IndicatorLocation = .up_left,
    indicator_padding: f32 = 0.1,
    indicator_focused: ?[]const u8 = null,
    indicator_unfocused: ?[]const u8 = null,
    indicator_color: ?types.Color = null,
    /// Indicator glyph color when its tag is the CURRENT one -- set independently
    /// of the icon text color. Unset follows `indicator_color`, then tag text color.
    selected_indicator_color: ?types.Color = null,

    clock_format: ?[]const u8 = null,

    /// Volume slider sub display templates (null = built-in strings). `{pct}` =
    /// 0-100 level; `{state}` = mute glyph. Muted sink prefers volume_muted_format.
    volume_format: ?[]const u8 = null,
    volume_muted_format: ?[]const u8 = null,
    /// Brightness slider sub display template (null = "BRT {pct}%").
    /// `{pct}` = 0-100 level; no muted second state.
    brightness_format: ?[]const u8 = null,
    /// Brightness device pin: a `/sys/class/backlight/*` name, or with a `led:`
    /// prefix an LED-class device under `/sys/class/leds/*`. "" = auto-discovery.
    brightness_device: ?[]const u8 = null,

    /// Scroll the focused window's title through its slot on overflow
    /// (marquee) instead of truncating with an ellipsis.
    carousel_enabled: bool = true,
    // px per second / gap between repeating copies
    carousel_speed_px_s: u16 = 125,
    carousel_gap_px: u16 = 48,

    /// Systatus poll cadence (ms). Absent readouts back off to the module's
    /// own slow re-probe regardless of this value.
    systatus_interval_ms: i64 = 2000,
    /// Volume live-read cadence (ms); the 5 s reconcile also corrects an
    /// optimistic commit.
    volume_read_interval_ms: i64 = 5000,
    /// Cap on redraw-settle rounds per event batch. Bounds keep a typo from
    /// disabling settling (min 1) or turning one batch into a long redraw loop (max 64).
    max_batched_redraws: u8 = 4,

    // run segment colors and prompt; all nullable, falling back to bar-wide
    run_bg: ?types.Color = null, // falls back to bg
    run_fg: ?types.Color = null, // typed text color; falls back to fg
    run_prompt_color: ?types.Color = null, // falls back to primary_color
    run_prompt: ?[]const u8 = null, // prefix left of the input cursor

    /// Per-segment text-color overrides, keyed by segment registry name. From
    /// `[bar.properties].<segment>`; a segment with no entry paints in `fg`.
    segment_fg: std.StringHashMapUnmanaged(types.Color) = .empty,
    /// Per-segment NUMBER-color overrides from `[bar.properties].<segment>_value`;
    /// no entry falls back to the segment color (`segmentValueFg`). Keys owned once.
    segment_value_fg: std.StringHashMapUnmanaged(types.Color) = .empty,
    /// Per-segment style flags from the same `[bar.properties].<segment>` entry;
    /// no entry draws plain text (`segmentProps`). Keys owned once.
    segment_props: std.StringHashMapUnmanaged(SegmentProps) = .empty,

    layout: std.ArrayList(BarLayout) = .empty,

    transparency: f32 = 1.0,

    // NOTE: indicator_focused/unfocused are always independently owned (each set
    // via knob.assignStr which dupes) -- a mirror yields two allocations; do not bypass assignStr.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        types.freeStrings(&self.workspace_icons, allocator, types.free_storage);
        types.freeStrings(&self.fonts, allocator, types.free_storage);
        freeBarLayouts(&self.layout, allocator, types.free_storage);
        freeSegmentMap(types.Color, &self.segment_fg, allocator);
        freeSegmentMap(types.Color, &self.segment_value_fg, allocator);
        freeSegmentMap(SegmentProps, &self.segment_props, allocator);
        freeOwnedStrings(self, allocator);
    }

    pub inline fn runBg(self: *const Config) types.Color {
        return self.run_bg orelse self.bg;
    }
    pub inline fn runFg(self: *const Config) types.Color {
        return self.run_fg orelse self.fg;
    }
    pub inline fn runPromptColor(self: *const Config) types.Color {
        return self.run_prompt_color orelse self.primary_color;
    }

    /// Text color for bar segment `name`: its override, or bar-wide `fg`.
    pub inline fn segmentFg(self: *const Config, name: []const u8) types.Color {
        return self.segment_fg.get(name) orelse self.fg;
    }

    /// Number text color for `name`: its `<name>_value` override, else the
    /// segment color so a segment without `_value` colors number like label.
    pub inline fn segmentValueFg(self: *const Config, name: []const u8) types.Color {
        return self.segment_value_fg.get(name) orelse self.segmentFg(name);
    }

    /// Style flags for `name`: its underline/bold/italic overrides, or plain.
    pub inline fn segmentProps(self: *const Config, name: []const u8) SegmentProps {
        return self.segment_props.get(name) orelse .{};
    }

    /// Indicator glyph color for tag `is_current`: selected-state override
    /// (current only), else `indicator_color`, else the tag's text color.
    pub inline fn workspaceIndicatorColor(self: *const Config, is_current: bool) types.Color {
        if (is_current) {
            if (self.selected_indicator_color) |c| return c;
            if (self.indicator_color) |c| return c;
            return self.workspaceTextFg(true);
        }
        if (self.indicator_color) |c| return c;
        return self.workspaceTextFg(false);
    }

    /// Text color for workspace icon label `is_current`: the per-state composite
    /// entry -- `workspaces_selected` on current, base `workspaces` elsewhere.
    pub inline fn workspaceTextFg(self: *const Config, is_current: bool) types.Color {
        if (is_current)
            return self.segment_fg.get(seg_workspaces_selected) orelse self.segment_fg.get(seg_workspaces) orelse self.selected_fg;
        return self.segment_fg.get(seg_workspaces) orelse self.fg;
    }

    /// Pango style flags for workspace label `is_current`: base `workspaces`
    /// flags for every tag, overlaid with non-default flags of `workspaces_selected`.
    pub inline fn workspaceIconProps(self: *const Config, is_current: bool) SegmentProps {
        var props = self.segmentProps(seg_workspaces);
        if (!is_current) return props;
        const sel = self.segmentProps(seg_workspaces_selected);
        inline for (std.meta.fields(SegmentProps)) |f| {
            if (f.type != bool) continue;
            @field(props, f.name) = @field(props, f.name) or @field(sel, f.name);
        }
        return props;
    }

    /// Margin = (bar_height - font_px) / 2; the percentage path resolves
    /// `font_size` against the bar height first (`scaling`).
    pub inline fn scaledSegmentPadding(self: *const Config, bar_height: u16) u16 {
        const h: f32 = @floatFromInt(bar_height);
        return scaleToU16((h - scaling.scaleToPixels(self.font_size, h)) / 2.0);
    }

    /// Resolves a ScalableValue to pixels (canonical formula in
    /// `core/display/scaling`).
    inline fn scaleValue(sv: types.ScalableValue, bar_height: u16, factor: f32) f32 {
        return scaling.scaleToPixels(sv, @as(f32, @floatFromInt(bar_height)) * factor);
    }

    inline fn scaleToU16(val: f32) u16 {
        return scaling.roundToU16(val, 0.0);
    }
    /// Scale factor for the spacing percentage path (`spacing` widens with
    /// the bar); absolute-px path used verbatim.
    const spacing_scale_factor: f32 = 5.0;
    pub inline fn scaledSpacing(self: *const Config, bar_height: u16) u16 {
        return scaleToU16(scaleValue(self.spacing, bar_height, spacing_scale_factor));
    }
    /// Scales one size ScalableValue against the bar height, floor 1.
    inline fn scaledUnit(sv: types.ScalableValue, bar_height: u16) u16 {
        return @max(1, scaleToU16(scaleValue(sv, bar_height, 1.0)));
    }
    pub inline fn scaledIndicatorSize(self: *const Config, bar_height: u16) u16 {
        return scaledUnit(self.indicator_size, bar_height);
    }
    pub inline fn scaledWorkspaceWidth(self: *const Config, bar_height: u16) u16 {
        return scaledUnit(self.workspace_tag_width, bar_height);
    }

    /// The 16-bit alpha ceiling: `transparency` (0.0-1.0) maps into 0x0000-0xFFFF.
    const alpha16_ceiling: f32 = 0xFFFF;

    /// Returns the bar's alpha in 16-bit format (0x0000-0xFFFF).
    pub inline fn getAlpha16(self: *const Config) u16 {
        return @intFromFloat(@round(std.math.clamp(self.transparency, 0.0, 1.0) * alpha16_ceiling));
    }
};
/// The knob table: every bar scalar knob, exactly once. Targets are relative to
/// THIS Config. The `needs` ordering is enforced by validateTable.
fn barBool(key: []const u8, reader: []const u8) knob.Knob {
    return readerOr(knob.knob(&.{knob.place(types.section_bar, key)}, key, .b), reader);
}

fn barScalable(key: []const u8, target: []const u8, reader: []const u8) knob.Knob {
    return readerOr(knob.knob(&.{knob.place(types.section_bar, key)}, target, .{ .scalable = 0.0 }), reader);
}

fn barPlainColor(key: []const u8, reader: []const u8) knob.Knob {
    return readerOr(knob.knob(&.{knob.place(types.section_bar, key)}, key, .color), reader);
}

/// Stamp a module-owned reader onto an otherwise plain knob (empty = none).
fn readerOr(k_in: knob.Knob, reader: []const u8) knob.Knob {
    var k = k_in;
    if (reader.len != 0) k.reader = reader;
    return k;
}

/// [bar.properties] color_from chain: reads a sibling bar field as fallback,
/// gated on "bar". `copy_when_absent` (title variant) also assigns the fallback
/// when the section is absent; the run variant keeps null (`reader` = module stem).
fn barColor(key: []const u8, target: []const u8, sibling: []const u8, copy_when_absent: bool, reader: []const u8) knob.Knob {
    return readerOr(.{
        .places = &.{knob.place(types.section_bar_properties, key)},
        .target = target,
        .kind = .{ .color_from = sibling },
        .requires = types.section_bar,
        .copy_when_absent = copy_when_absent,
        .needs = &.{sibling},
    }, reader);
}

/// Same dependency, declared the same way, for the `color_opt` kind.
fn barColorOpt(key: []const u8, target: []const u8, sibling: []const u8, reader: []const u8) knob.Knob {
    return readerOr(.{
        .places = &.{knob.place(types.section_bar, key)},
        .target = target,
        .kind = .{ .color_opt = sibling },
        .needs = &.{sibling},
    }, reader);
}

pub const knobs = [_]knob.Knob{
    barBool("enabled", ""),
    // carousel_* : title module only (Knob.reader drops with it).
    barBool("carousel_enabled", "title"),
    barScalable("font_size", "font_size", ""),
    // feeds Config.spacing
    barScalable("per_segment_padding", "spacing", ""),
    barScalable("indicator_size", "indicator_size", ""),
    barScalable("workspace_tag_width", "workspace_tag_width", ""),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "height")}, "height", .auto_scalable), ""),
    // Case-insensitive enum; unrecognized spellings warn and keep .top.
    readerOr(knob.knob(&.{knob.place(types.section_bar, "position")}, "bar_position", .{ .enum_read = .{ .T = BarScreenPosition, .ci = true, .warn = true, .default_label = "top" } }), ""),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "carousel_speed_px_s")}, "carousel_speed_px_s", .{ .int = .{ .T = u16, .min = 1, .max = 1000 } }), "title"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "carousel_gap_px")}, "carousel_gap_px", .{ .int = .{ .T = u16, .min = 0, .max = 1000 } }), "title"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "systatus_interval_ms")}, "systatus_interval_ms", .{ .int = .{ .T = i64, .min = 250, .max = 3_600_000 } }), "systatus"),
    // volume read cadence via the slider's optional read-cadence hook
    // (brightness keeps its static 1000 ms).
    readerOr(knob.knob(&.{knob.place(types.section_bar, "volume_read_interval_ms")}, "volume_read_interval_ms", .{ .int = .{ .T = i64, .min = 250, .max = 3_600_000 } }), "volume"),
    // max_batched_redraws: bar.zig's settle loop (core).
    readerOr(knob.knob(&.{knob.place(types.section_bar, "max_batched_redraws")}, "max_batched_redraws", .{ .int = .{ .T = u8, .min = 1, .max = 64 } }), ""),

    // Base palette: read before every color_from consumer below. The window-state
    // colors plus text_color are also document-global palette variables.
    barPlainColor("bg", ""),
    barPlainColor("fg", ""),
    barPlainColor("selected_bg", "tags"),
    barPlainColor("selected_fg", "title"),
    barPlainColor(types.palette_primary_color, ""),
    barPlainColor(types.palette_secondary_color, ""),
    barPlainColor(types.palette_alternative_color, ""),
    barPlainColor(types.palette_text_color, ""),

    // clock_format: read by clock.zig AND core render/drawing.zig
    // (formatString), so it stays tree-read.
    readerOr(knob.knob(&.{knob.place(types.section_bar, "clock_format")}, "clock_format", .str), ""),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "run_prompt")}, "run_prompt", .str), "prompt"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "volume_format")}, "volume_format", .str), "volume"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "volume_muted_format")}, "volume_muted_format", .str), "volume"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "brightness_format")}, "brightness_format", .str), "brightness"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "brightness_device")}, "brightness_device", .str), "brightness"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "indicator_location")}, "indicator_location", .{ .enum_read = .{ .T = IndicatorLocation, .ci = true, .warn = true, .default_label = "up-left" } }), "tags"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "indicator_padding")}, "indicator_padding", .ratio), "tags"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "transparency")}, "transparency", .ratio_strict), ""),
    // Falls back to bar-wide fg only when the key is present; absent keeps
    // the field null. Read via Config helpers, inlined into tags.zig.
    barColorOpt("indicator_color", "indicator_color", "fg", "tags"),
    // Selected-tag indicator glyph color: falls back at read time to
    // indicator_color, then the tag's text color. The selected tag's icon TEXT
    // color/styles use the [bar.properties] composite path, not a scalar knob.
    barColorOpt("selected_indicator_color", "selected_indicator_color", "fg", "tags"),

    // [bar.properties] chain, gated on [bar] (parseBar returned before these
    // when the section was missing). Title accents additionally COPY their fallback
    // when the section is absent; the run trio stay null for Config's read-time fallbacks.
    barColor("title", "title_accent_color", types.palette_primary_color, true, "title"),
    barColor("title_unfocused", "title_unfocused_accent", types.palette_secondary_color, true, "title"),
    barColor("title_minimized", "title_minimized_accent", types.palette_alternative_color, true, "title"),
    barColor("run_bg", "run_bg", "bg", false, "prompt"),
    barColor("run_fg", "run_fg", "fg", false, "prompt"),
    barColor("run_prompt_color", "run_prompt_color", types.palette_primary_color, false, "prompt"),

    // Legacy `drun_*` aliases for the run segment: ALIASES, not a second set of
    // fields -- each maps onto the same target as its canonical knob. A config
    // that used the old keys keeps working with no edit, which is why this is a
    // rename-with-alias. Aliases share the canonical knob's Knob.reader ownership.
    readerOr(knob.knob(&.{knob.place(types.section_bar, "drun_prompt")}, "run_prompt", .str), "prompt"),
    barColor("drun_bg", "run_bg", "bg", false, "prompt"),
    barColor("drun_fg", "run_fg", "fg", false, "prompt"),
    barColor("drun_prompt_color", "run_prompt_color", types.palette_primary_color, false, "prompt"),
};

/// Module ownership for knobs whose only reader lives in an OPTIONAL module.
/// Each entry is `.{ "target", "module_stem" }`: when the tree lacks that module
/// the knob is legitimately unread, and the build's knob-reader scan excuses it
/// (see Knob.reader). Plain data because the build needs a stable shape to text-
/// scan; `validateOwnership` pins every pair to the knobs table's `reader` fields
/// so a typo is a build error. Closed under alias: `drun_*` share `run_*` targets.
pub const knob_reader_modules = [_][2][]const u8{
    .{ "carousel_enabled", "title" },
    .{ "carousel_speed_px_s", "title" },
    .{ "carousel_gap_px", "title" },
    .{ "systatus_interval_ms", "systatus" },
    .{ "volume_read_interval_ms", "volume" },
    .{ "selected_bg", "tags" },
    .{ "selected_fg", "title" },
    .{ "run_prompt", "prompt" },
    .{ "volume_format", "volume" },
    .{ "volume_muted_format", "volume" },
    .{ "brightness_format", "brightness" },
    .{ "brightness_device", "brightness" },
    .{ "indicator_location", "tags" },
    .{ "indicator_padding", "tags" },
    .{ "indicator_color", "tags" },
    .{ "selected_indicator_color", "tags" },
    .{ "title_accent_color", "title" },
    .{ "title_unfocused_accent", "title" },
    .{ "title_minimized_accent", "title" },
    .{ "run_bg", "prompt" },
    .{ "run_fg", "prompt" },
    .{ "run_prompt_color", "prompt" },
};

/// Config fields that are legitimately NOT knobs: the pair-interaction bespoke
/// in parseBar (if only one of indicator_focused/unfocused is set, the other mirrors it).
const bespoke_fields = [_][]const u8{
    "indicator_focused",
    "indicator_unfocused",
};

comptime {
    knob.validateTable(Config, &knobs, &bespoke_fields);
    knob.validateOwnership(&knobs, &knob_reader_modules, "bar");
}

/// Sections the bar subsystem owns (D13/P2-50); the composed facade unions
/// every fragment's list into the mis-case lint's inventory.
pub const sections = &[_][]const u8{
    types.section_bar,
    types.section_bar_properties,
    types.section_prefix_bar_layout ++ "left",
    types.section_prefix_bar_layout ++ "center",
    types.section_prefix_bar_layout ++ "right",
    types.section_bar_modules_workspaces,
};

/// Section HEADS whose presence in the embedded fallback TOML is gated on
/// this fragment's owner module (P2-50).
pub const fallback_sections = &[_][]const u8{"bar"};

/// Inert family (D13/P2-50): `[bar.properties]` is read only when bare `[bar]`
/// is present; without the parent the property maps would parse and do nothing.
pub const inert_families = &[_]types.InertFamily{
    .{
        .parent = types.section_bar,
        .child_exact = types.section_bar_properties,
    },
    // [bar.layout.*] is read only inside parseBar, which returns without
    // [bar]: the columns would otherwise be customized into silence.
    .{
        .parent = types.section_bar,
        .child_prefix = types.section_prefix_bar_layout,
    },
};

/// The fragment parse entry: self-seed the owned defaults, apply the scalar knobs,
/// then parse the non-scalar structures and the [bar.properties] segment maps.
pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);
    try bar_sections.padWorkspaceIcons(allocator, doc, &cfg);
    try bar_sections.initDefaultBarLayout(allocator, &cfg);
    try knob.applyAll(Config, doc, allocator, &cfg, &knobs);
    try bar_sections.parseBar(allocator, doc, &cfg);
    try applyBarProperties(allocator, doc, &cfg);
    return cfg;
}

/// Warn-only checks: values legal but almost certainly not intended. Never
/// fails the load.
pub fn validate(cfg: *const Config) !void {
    // font_size 0 is a typo: text metrics compute a zero height and the bar
    // draws as a bare strip. (A NEGATIVE size is impossible: barScalable floor 0.)
    if (cfg.font_size.is_percentage) {
        if (scaling.asRatio(cfg.font_size) == 0.0)
            log.warn("bar.font_size is 0%; the bar will have no readable text", .{});
    } else if (cfg.font_size.value == 0.0) {
        log.warn("bar.font_size is {d}px; the bar will have no readable text", .{cfg.font_size.value});
    }
}
/// The `[bar.properties]` segment decoder: segment-name keys the scalar knobs do
/// not own. The knob-key test stays bound to the very table the knob loop reads,
/// so a future `[bar.properties]` knob can never desync the map pass.
///
/// `_value` suffix (`cpu_value`) = the segment's NUMBER color (the numeric
/// readout); color-only. A plain `<segment>` entry is a composite: optional color
/// + optional style flags. Flag spellings: `underline=true|false`, `underline true`,
/// `underline 1`, or bare `underline` (true). Color is the first color-carrying item;
/// a whole-array `+` color-mix resolves as a unit first, else warn-and-skipped.
/// Style-only keeps `fg`. Runs after the knob loop; gated on [bar].
pub fn applyBarProperties(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *Config,
) !void {
    freeSegmentMap(types.Color, &cfg.segment_fg, allocator);
    freeSegmentMap(types.Color, &cfg.segment_value_fg, allocator);
    freeSegmentMap(SegmentProps, &cfg.segment_props, allocator);
    if (doc.getSection(types.section_bar) == null) return;
    const sec = doc.getSection(types.section_bar_properties) orelse return;
    var it = sec.orderedIterator();
    while (it.next()) |pair| {
        if (isBarPropertiesKnobKey(pair.key)) continue;
        const is_value = std.mem.endsWith(u8, pair.key, "_value");
        const seg_key = if (is_value) pair.key[0 .. pair.key.len - "_value".len] else pair.key;
        try applySegmentEntry(allocator, cfg, pair.key, seg_key, is_value, pair.value, &doc.palette);
    }
}

/// True when `key` is a [bar.properties] scalar knob; every OTHER key in that
/// table is a bar segment name. Scanned from this file's knob table (no desync).
fn isBarPropertiesKnobKey(key: []const u8) bool {
    inline for (knobs) |k| {
        for (k.places) |pl| {
            if (std.mem.eql(u8, pl.section, types.section_bar_properties) and
                std.mem.eql(u8, pl.key, key)) return true;
        }
    }
    return false;
}

/// Sets one style flag (`underline`/`bold`/`italic`); true when recognized.
fn setStyleFlag(props: *SegmentProps, name: []const u8, val: bool) bool {
    inline for (std.meta.fields(SegmentProps)) |f| {
        if (f.type != bool) continue;
        if (std.mem.eql(u8, name, f.name)) {
            @field(props, f.name) = val;
            return true;
        }
    }
    return false;
}

/// Parses one `=value` bool spelling (`underline=true`, `underline=1`,
/// `underline=false`), or null when `token` is not a `name=bool` form.
fn boolFromEqualsToken(token: []const u8) ?struct { name: []const u8, value: bool } {
    const eq = std.mem.indexOfScalar(u8, token, '=') orelse return null;
    const name = token[0..eq];
    const raw = token[eq + 1 ..];
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "1"))
        return .{ .name = name, .value = true };
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "0"))
        return .{ .name = name, .value = false };
    return null;
}

/// Bounds for `size=N` absolute text size in px: a segment smaller than a legible
/// glyph or larger than the bar is a typo; unsupported spellings warn normally.
const size_px_min: u16 = 1;
const size_px_max: u16 = 255;

/// Parses `size=<int in 1..=255>` or null.
fn sizeFromEqualsToken(token: []const u8) ?u16 {
    const eq = std.mem.indexOfScalar(u8, token, '=') orelse return null;
    if (!std.mem.eql(u8, token[0..eq], "size")) return null;
    const n = std.fmt.parseInt(u16, token[eq + 1 ..], 10) catch return null;
    if (n < size_px_min or n > size_px_max) return null;
    return n;
}

/// The first color-carrying item of a composite array value.
fn firstColorInItems(
    items: []const parser.Value,
    palette: *const std.StringHashMap(u32),
) ?struct { color: u32, consumed: usize } {
    for (items, 0..) |item, i| {
        if (color.colorFromValue(item)) |c| return .{ .color = c, .consumed = i };
        if (item.asScalar([]const u8)) |s| {
            if (palette.get(s)) |c| return .{ .color = c, .consumed = i };
        }
    }
    return null;
}

/// Inserts one segment-keyed entry: dupes `seg_key`, hands ownership to `map` on
/// success, rolls the key back on OOM so the map never holds a dangling key.
fn putSegmentEntry(
    comptime V: type,
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(V),
    seg_key: []const u8,
    item: V,
) !void {
    const k = try allocator.dupe(u8, seg_key);
    errdefer allocator.free(k);
    try map.put(allocator, k, item);
}

/// The color map a segment entry writes to: `_value` keys own the number
/// color, everything else the plain color override.
inline fn segmentColorMap(cfg: *Config, is_value: bool) *std.StringHashMapUnmanaged(types.Color) {
    return if (is_value) &cfg.segment_value_fg else &cfg.segment_fg;
}

/// Applies one [bar.properties] segment entry: `_value` keys are color-only;
/// base keys take the composite color+style decoding.
fn applySegmentEntry(
    allocator: std.mem.Allocator,
    cfg: *Config,
    key: []const u8,
    seg_key: []const u8,
    is_value: bool,
    raw: parser.Value,
    palette: *const std.StringHashMap(u32),
) !void {
    if (raw != .array) {
        // Style-only single-token spellings: `<flag>` (true) and `<flag>=<bool>`.
        // A non-default result is stored; a cleared flag is a no-op, as an absent entry.
        if (raw == .string) {
            const s = raw.asScalar([]const u8).?;
            var props = SegmentProps{};
            var recognized = false;
            if (!is_value) {
                if (sizeFromEqualsToken(s)) |px| {
                    props.size = px;
                    recognized = true;
                } else if (boolFromEqualsToken(s)) |eq| {
                    if (setStyleFlag(&props, eq.name, eq.value)) recognized = true;
                } else if (setStyleFlag(&props, s, true)) {
                    recognized = true;
                }
            }
            if (recognized) {
                if (!props.isDefault()) {
                    try putSegmentEntry(SegmentProps, allocator, &cfg.segment_props, seg_key, props);
                }
                return;
            }
        }
        // Plain scalar: color only, exactly as the pre-properties behavior.
        const map = segmentColorMap(cfg, is_value);
        const c = color.getColorFromValue(key, raw, cfg.fg, palette);
        try putSegmentEntry(types.Color, allocator, map, seg_key, c);
        return;
    }

    const items = raw.asArray().?;
    // A satisfying color-mix expression spans the whole array; resolve it as a
    // unit first, so `a + (weight:40%) b` compounds aren't misread as stray tokens
    // (the per-item scan below would grab just the head operand).
    if (color.resolveColorExpr(raw, palette)) |mix| {
        try putSegmentEntry(types.Color, allocator, segmentColorMap(cfg, is_value), seg_key, mix);
        return;
    }

    var props = SegmentProps{};
    const found = firstColorInItems(items, palette);
    if (!is_value) {
        var i: usize = 0;
        while (i < items.len) {
            if (found) |f| if (i == f.consumed) {
                i += 1;
                continue;
            };
            const token = items[i].asScalar([]const u8) orelse {
                log.warn("Invalid token for '{s}': expected a color or underline/bold/italic flag, skipping", .{key});
                i += 1;
                continue;
            };
            // `size=N` is numeric, not a bool spelling: parsed before the
            // bool path so a valid size never falls through to the style warn.
            if (sizeFromEqualsToken(token)) |px| {
                props.size = px;
                i += 1;
                continue;
            }
            // `name=true|false`, `name true`, `name 1|0`, or bare `name`
            // (true by default). Unified so the invalid-style warning lives once.
            const eq = boolFromEqualsToken(token);
            var set: bool = if (eq) |e| e.value else true;
            var consumed_next = false;
            if (eq == null and i + 1 < items.len) {
                if (items[i + 1].asScalar(bool)) |b| {
                    set = b;
                    consumed_next = true;
                } else if (items[i + 1].asScalar(i64)) |iv| {
                    if (iv == 0 or iv == 1) {
                        set = iv == 1;
                        consumed_next = true;
                    }
                }
            }
            const flag = if (eq) |e| e.name else token;
            if (setStyleFlag(&props, flag, set)) {
                if (consumed_next) i += 1;
            } else {
                log.warn("Invalid style for '{s}': '{s}' is not underline/bold/italic, skipping", .{ key, token });
            }
            i += 1;
        }
    }

    if (found) |f| {
        try putSegmentEntry(types.Color, allocator, segmentColorMap(cfg, is_value), seg_key, f.color);
    } else if (is_value) {
        // A `_value` key is color-only: an array with no color is invalid.
        const c = color.getColorFromValue(key, raw, cfg.fg, palette);
        try putSegmentEntry(types.Color, allocator, &cfg.segment_value_fg, seg_key, c);
    }
    // Else: style-only base entry; the segment color stays default fg (no
    // map entry), so segmentFg's orelse fallback yields exactly that.

    if (!is_value and !props.isDefault()) {
        try putSegmentEntry(SegmentProps, allocator, &cfg.segment_props, seg_key, props);
    }
}
