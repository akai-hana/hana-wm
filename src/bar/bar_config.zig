//! The bar config fragment: `Config` (the [bar] subtree), its knob table,
//! the `[bar.properties]` segment decoder, and the parse/validate entry
//! points the generated `composed` dispatcher calls. Deleting this file
//! (with the rest of src/bar/) removes the `bar` field, every [bar] knob,
//! and all bar config vocabulary from the build with no trace elsewhere.

const std = @import("std");
const log = std.log.scoped(.bar_config);
const parser = @import("parser");
const scaling = @import("scaling");
const types = @import("types");
const knob = @import("knob");
const color = @import("color");
const bar_sections = @import("bar_sections");

/// Where in the workspace cell the activity indicator is drawn. The `string_map`
/// below is the accepted TOML spelling: cardinal names verbatim; diagonal names
/// with hyphens or underscores in either axis order ("left-up" == "up_left").
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

/// Vertical placement of the bar on screen: top or bottom edge.
pub const BarScreenPosition = enum {
    top,
    bottom,

    // Case-insensitive alias map for types.enumFromString, so `bar.position`
    // accepts any-case "top"/"bottom".
    pub const string_map = std.StaticStringMap(BarScreenPosition).initComptime(.{
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

/// Per-segment text style flags, settable in `[bar.properties].<segment>`
/// alongside (or without) a color override. Painted via Pango text attributes
/// (underline / bold weight / italic style); all default to false.
pub const SegmentProps = struct {
    underline: bool = false,
    bold: bool = false,
    italic: bool = false,

    pub fn isDefault(self: SegmentProps) bool {
        return std.meta.eql(self, .{});
    }
};

/// Composite `[bar.properties]` keys for the workspaces segment's icon text:
/// a base entry styling every tag and a `_selected` overlay applying only to
/// the CURRENT (selected) tag, each decoded by the same color+underline/
/// bold/italic composite path as any segment (`workspaces_selected = bold`).
/// The tags module reads them through `workspaceTextFg`/`workspaceIconProps`.
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
/// deinits the map itself. Values are scalars (Color / SegmentProps); only
/// the keys need freeing. Zig 0.16's HashMapUnmanaged.deinit leaves the struct
/// `undefined` rather than reusable, so reset to `.empty` — the config reload
/// reuses the field.
pub fn freeSegmentMap(comptime V: type, map: *std.StringHashMapUnmanaged(V), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    map.deinit(allocator);
    map.* = .empty;
}

/// Frees every `?[]const u8` field of `Config`. The TYPE is the whole
/// ownership rule: there is no list to fall out of sync with the struct. A
/// new `?[]const u8` field is freed with no edit here, and a renamed or
/// removed one cannot produce a confusing "not a field of Config" error,
/// because no name is written down at all.
inline fn freeOwnedStrings(self: *Config, allocator: std.mem.Allocator) void {
    inline for (std.meta.fields(Config)) |f| {
        if (f.type != ?[]const u8) continue;
        if (@field(self, f.name)) |s| allocator.free(s);
    }
}

pub const Config = struct {
    enabled: bool = true,

    bar_position: BarScreenPosition = .top,
    // Configured bar height: absolute pixel value or percentage of screen height.
    // null = auto-calculate from font metrics alone.
    height: ?types.ScalableValue = null,
    fonts: std.ArrayList([]const u8) = .empty,
    font_size: types.ScalableValue = types.ScalableValue.percentage(10.0),
    spacing: types.ScalableValue = types.ScalableValue.absolute(12.0),

    // Bar color scheme; all values are 0xRRGGBB (see types.Color).
    bg: types.Color = types.default_bar_bg,
    fg: types.Color = types.default_bar_fg,
    selected_bg: types.Color = types.default_bar_selected_bg,
    selected_fg: types.Color = types.default_bar_selected_fg,

    // Palette canon, declared in the theme's palette section; the other three
    // exist so the palette is first-class config even though rendering
    // consumes them through the title/run chains below.
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
    /// Indicator glyph color when its workspace tag is the CURRENT (selected)
    /// one -- set independently of the icon text color. Unset follows
    /// `indicator_color`, then the tag's text color (see
    /// `workspaceIndicatorColor`).
    selected_indicator_color: ?types.Color = null,

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

    // run segment colors and prompt; all nullable, falling back to bar-wide
    run_bg: ?types.Color = null, // Background; falls back to bg
    run_fg: ?types.Color = null, // Typed text color; falls back to fg
    run_prompt_color: ?types.Color = null, // Prompt text color; falls back to primary_color
    run_prompt: ?[]const u8 = null, // Prefix rendered left of the text input cursor

    /// Per-segment text-color overrides, keyed by bar segment registry name
    /// ("cpu", "ram", "volume", "brightness", ...). Populated from
    /// `[bar.properties].<segment>` entries; a segment with no entry paints its
    /// text in `fg` (see `segmentFg`). Colors for absent segments are
    /// tolerated and simply never match a live segment, so a theme may carry
    /// a full readout palette up front. Keys are owned (duped) once; freed
    /// in deinit.
    segment_fg: std.StringHashMapUnmanaged(types.Color) = .empty,
    /// Per-segment NUMBER-color overrides, keyed by bar segment registry
    /// name. Populated from `[bar.properties].<segment>_value` entries; a
    /// segment with no entry paints its number in the segment color
    /// (`segmentValueFg` falls back to `segmentFg`), so the
    /// readout/slider label-vs-number split is opt-in per theme. Keys are
    /// owned (duped) once; freed in deinit.
    segment_value_fg: std.StringHashMapUnmanaged(types.Color) = .empty,
    /// Per-segment style flags (underline/bold/italic), keyed by bar segment
    /// registry name. Populated from the `[bar.properties].<segment>` entry
    /// (the same entry that may carry the color override); a segment with no
    /// entry draws plain text (see `segmentProps`). The flags apply to the
    /// whole segment, label and number alike. Keys are owned (duped) once;
    /// freed in deinit.
    segment_props: std.StringHashMapUnmanaged(SegmentProps) = .empty,

    layout: std.ArrayList(BarLayout) = .empty,

    transparency: f32 = 1.0,

    // NOTE: indicator_focused/unfocused are always independently owned
    // (each set via knob.assignStr which always dupes). If one mirrors
    // the other, both point to separate allocations. Do not bypass assignStr.
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

    /// Text color for bar segment `name`: its [bar.properties] override, or
    /// the bar-wide `fg` when none is set.
    pub inline fn segmentFg(self: *const Config, name: []const u8) types.Color {
        return self.segment_fg.get(name) orelse self.fg;
    }

    /// Number text color for bar segment `name`: its [bar.properties]
    /// `<name>_value` override, else the segment color (`segmentFg`) so a
    /// segment without a `_value` entry colors its number like its label.
    pub inline fn segmentValueFg(self: *const Config, name: []const u8) types.Color {
        return self.segment_value_fg.get(name) orelse self.segmentFg(name);
    }

    /// Style flags for bar segment `name`: its [bar.properties] underline/
    /// bold/italic overrides, or all-false plain text when none is set.
    pub inline fn segmentProps(self: *const Config, name: []const u8) SegmentProps {
        return self.segment_props.get(name) orelse .{};
    }

    /// Indicator glyph color for workspace tag `is_current`: the selected-state
    /// override when set (current tag only), else the shared `indicator_color`,
    /// else the tag's text color (`workspaceTextFg`).
    pub inline fn workspaceIndicatorColor(self: *const Config, is_current: bool) types.Color {
        if (is_current) {
            if (self.selected_indicator_color) |c| return c;
            if (self.indicator_color) |c| return c;
            return self.workspaceTextFg(true);
        }
        if (self.indicator_color) |c| return c;
        return self.workspaceTextFg(false);
    }

    /// Text color for workspace icon label `is_current`: the per-state
    /// `[bar.properties]` composite entry -- `workspaces_selected` on the
    /// current tag, the base `workspaces` entry elsewhere -- or the tag's
    /// default (selected_fg on the current tag, the bar-wide fg otherwise).
    /// The base entry colors every tag; the selected overlay recolors the
    /// current one on top of it.
    pub inline fn workspaceTextFg(self: *const Config, is_current: bool) types.Color {
        if (is_current)
            return self.segment_fg.get(seg_workspaces_selected) orelse self.segment_fg.get(seg_workspaces) orelse self.selected_fg;
        return self.segment_fg.get(seg_workspaces) orelse self.fg;
    }

    /// Pango style flags for workspace icon label `is_current`: the base
    /// `[bar.properties] "workspaces"` entry for every tag, overlaid with any
    /// non-default flags of the `workspaces_selected` entry on the current tag
    /// (so the selected icon may render bold/italic/underlined on top of the
    /// shared styling, without new knob shapes).
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

    /// Derives horizontal segment padding from font_size.
    /// Margin = (bar_height - font_px) / 2 in both cases: the percentage path
    /// resolves `font_size` against the bar height first (`scaling`).
    pub inline fn scaledSegmentPadding(self: *const Config, bar_height: u16) u16 {
        const h: f32 = @floatFromInt(bar_height);
        return scaleToU16((h - scaling.scaleToPixels(self.font_size, h)) / 2.0);
    }

    /// Resolves a ScalableValue to pixels: the percentage path multiplies the
    /// reference dimension by `factor`, the absolute path is used verbatim
    /// (canonical formula lives in `core/display/scaling`).
    inline fn scaleValue(sv: types.ScalableValue, bar_height: u16, factor: f32) f32 {
        return scaling.scaleToPixels(sv, @as(f32, @floatFromInt(bar_height)) * factor);
    }

    inline fn scaleToU16(val: f32) u16 {
        return scaling.roundToU16(val, 0.0);
    }
    /// Scale factor applied to the spacing percentage path (`spacing` widens
    /// with the bar); the absolute-px path is used verbatim.
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
/// The knob table: every bar scalar knob, exactly once. Targets are relative
/// to THIS Config. The `needs` ordering (base palette before the
/// [bar.properties] color_from chain) is enforced by validateTable.
/// Plain [bar] boolean. `reader` names the optional module that reads it
/// (see Knob.reader) -- empty means a reader must exist in the tree.
fn barBool(key: []const u8, reader: []const u8) knob.Knob {
    return readerOr(knob.knob(&.{knob.place(types.section_bar, key)}, key, .b), reader);
}

/// Plain [bar] scalable (px or %), rejecting negative raw values.
fn barScalable(key: []const u8, target: []const u8, reader: []const u8) knob.Knob {
    return readerOr(knob.knob(&.{knob.place(types.section_bar, key)}, target, .{ .scalable = 0.0 }), reader);
}

/// Plain [bar] color (base palette, no gate).
fn barPlainColor(key: []const u8, reader: []const u8) knob.Knob {
    return readerOr(knob.knob(&.{knob.place(types.section_bar, key)}, key, .color), reader);
}

/// Stamp a module-owned reader onto an otherwise plain knob (`reader` empty
/// = no ownership). One place so every helper below can thread it without a
/// second family of constructors.
fn readerOr(k_in: knob.Knob, reader: []const u8) knob.Knob {
    var k = k_in;
    if (reader.len != 0) k.reader = reader;
    return k;
}

/// [bar.properties] color_from chain: reads a sibling bar field as fallback,
/// gated on "bar". `copy_when_absent` (title variant) also assigns the
/// fallback when [bar.properties] is absent; the run variant keeps null so
/// the read-time fallbacks in Config apply. `reader` = owning module stem.
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
    // [bar]
    barBool("enabled", ""),
    // carousel_enabled is read only by the title module (title.zig); deleting
    // title drops the knob with it (Knob.reader).
    barBool("carousel_enabled", "title"),
    barScalable("font_size", "font_size", ""),
    // per_segment_padding feeds Config.spacing (read via the Config helper
    // from every segment, so no single owning module).
    barScalable("per_segment_padding", "spacing", ""),
    barScalable("indicator_size", "indicator_size", ""),
    barScalable("workspace_tag_width", "workspace_tag_width", ""),
    // height: null = auto-calculate from font metrics alone.
    readerOr(knob.knob(&.{knob.place(types.section_bar, "height")}, "height", .auto_scalable), ""),
    // Case-insensitive enum (types.enumFromString over BarScreenPosition's
    // string_map); unrecognized spellings warn and keep .top.
    readerOr(knob.knob(&.{knob.place(types.section_bar, "position")}, "bar_position", .{ .enum_read = .{ .T = BarScreenPosition, .ci = true, .warn = true, .default_label = "top" } }), ""),
    // carousel_speed_px_s: title module only.
    readerOr(knob.knob(&.{knob.place(types.section_bar, "carousel_speed_px_s")}, "carousel_speed_px_s", .{ .int = .{ .T = u16, .min = 1, .max = 1000 } }), "title"),

    // Base palette: read before every color_from consumer below. The three
    // window-state colors (primary/secondary/alternative) plus text_color are
    // also the document-global palette variables: color knobs may name them
    // by full reference from any section (resolved from parser.Document's
    // collected palette in getColorFromValue).
    barPlainColor("bg", ""),
    barPlainColor("fg", ""),
    // tags.zig is the only consumer of selected_bg (Config.selectedTagBg is
    // inlined into it); deleting tags drops the knob with it.
    barPlainColor("selected_bg", "tags"),
    // selected_fg is read by title.zig (window-title colouring of the
    // selected workspace's tag).
    barPlainColor("selected_fg", "title"),
    barPlainColor(types.palette_primary_color, ""),
    barPlainColor(types.palette_secondary_color, ""),
    barPlainColor(types.palette_alternative_color, ""),
    barPlainColor(types.palette_text_color, ""),

    // clock_format is read by both clock.zig and the core render/drawing.zig
    // (formatString), so it stays tree-read: deleting the clock module leaves
    // a reader in core.
    readerOr(knob.knob(&.{knob.place(types.section_bar, "clock_format")}, "clock_format", .str), ""),
    // run_prompt: prompt/overlay.zig only (prompt package core).
    readerOr(knob.knob(&.{knob.place(types.section_bar, "run_prompt")}, "run_prompt", .str), "prompt"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "volume_format")}, "volume_format", .str), "volume"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "volume_muted_format")}, "volume_muted_format", .str), "volume"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "brightness_format")}, "brightness_format", .str), "brightness"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "brightness_device")}, "brightness_device", .str), "brightness"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "indicator_location")}, "indicator_location", .{ .enum_read = .{ .T = IndicatorLocation, .ci = true, .warn = true, .default_label = "up-left" } }), "tags"),
    // indicator_padding is read by tags.zig (via Config.indicatorPadding).
    readerOr(knob.knob(&.{knob.place(types.section_bar, "indicator_padding")}, "indicator_padding", .ratio), "tags"),
    readerOr(knob.knob(&.{knob.place(types.section_bar, "transparency")}, "transparency", .ratio_strict), ""),
    // Falls back to the bar-wide fg (its historical default) -- but only
    // when the key is present; absent keeps the field null. Read via the
    // Config.indicatorColor() helper, inlined into tags.zig.
    barColorOpt("indicator_color", "indicator_color", "fg", "tags"),
    // Selected workspace tag: an individually-set indicator glyph color for the
    // current tag. It falls back at read time to indicator_color, then the
    // tag's text color. The selected tag's icon TEXT color/styles are NOT a
    // scalar knob -- they use the same color+underline/bold/italic composite
    // path as any segment, via the [bar.properties] entry "workspaces_selected"
    // (see Config.workspaceTextFg/workspaceIconProps). Read via the
    // Config.selectedIndicatorColor() helper, inlined into tags.zig.
    barColorOpt("selected_indicator_color", "selected_indicator_color", "fg", "tags"),

    // [bar.properties] chain. Gated on [bar] because parseBar always returned
    // before reaching these when the section was missing entirely. The
    // title accents additionally COPY their fallback when [bar.properties] is
    // absent (they were unconditionally assigned); the run trio stay null
    // so the read-time fallbacks in Config apply.
    barColor("title", "title_accent_color", types.palette_primary_color, true, "title"),
    barColor("title_unfocused", "title_unfocused_accent", types.palette_secondary_color, true, "title"),
    barColor("title_minimized", "title_minimized_accent", types.palette_alternative_color, true, "title"),
    // run_bg/run_fg/run_prompt_color: read via Config.run*Color() helpers,
    // inlined into prompt/overlay.zig (the prompt package core).
    barColor("run_bg", "run_bg", "bg", false, "prompt"),
    barColor("run_fg", "run_fg", "fg", false, "prompt"),
    barColor("run_prompt_color", "run_prompt_color", types.palette_primary_color, false, "prompt"),

    // Legacy spellings, kept working. The `drun_*` keys were named for
    // a desktop-file launcher; the segment resolves a `$PATH` executable and
    // runs it, so `run_*` is the honest name. These are ALIASES, not a second
    // set of fields: each maps onto the same target as its canonical knob, so
    // setting one assigns exactly the field the other would. A config that
    // used the old keys keeps working with no edit, which is the whole reason
    // this is a rename-with-alias rather than a rename.
    // Aliases share the canonical knob's target, so each carries the same
    // Knob.reader ownership (a deleted module drops the field with it, and
    // no alias resurrects it).
    readerOr(knob.knob(&.{knob.place(types.section_bar, "drun_prompt")}, "run_prompt", .str), "prompt"),
    barColor("drun_bg", "run_bg", "bg", false, "prompt"),
    barColor("drun_fg", "run_fg", "fg", false, "prompt"),
    barColor("drun_prompt_color", "run_prompt_color", types.palette_primary_color, false, "prompt"),
};

/// Module ownership for knobs whose only reader lives in an OPTIONAL module.
/// Each entry is `.{ "target", "module_stem" }`: the target's reader is that
/// module, so when the tree has no such module the knob is legitimately
/// unread (the modularity matrix deletes a module together with its config
/// consumer -- see Knob.reader). The build's knob-reader scan reads these
/// pairs and excuses a target it owns whose stem is a module the tree simply
/// does not have, so a module-owned knob never trips DeadKnobTarget on a
/// tree that merely lacks the module.
///
/// These are plain data, not knob constructors, because the build needs a
/// stable `("target", "stem")` shape to text-scan; the comptime
/// `validateOwnership` call below pins every pair to the knobs table's own
/// `reader` fields, so a typo in either table is a build error rather than a
/// silent re-owning. A target absent from this table must have a reader
/// somewhere in the tree (the core check).
///
/// The set is closed under alias: `drun_*` keys share the canonical
/// `run_*` targets, so ownership is expressed once per target, not once per
/// key.
pub const knob_reader_modules = [_][2][]const u8{
    .{ "carousel_enabled", "title" },
    .{ "carousel_speed_px_s", "title" },
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

/// Config fields that are legitimately NOT knobs: the pair-interaction
/// bespoke in parseBar (if only one of indicator_focused/unfocused is set,
/// the other mirrors it). Each entry is a contract, not an exemption --
/// the reason is why the knob table must not claim it.
const bespoke_fields = [_][]const u8{
    "indicator_focused",
    "indicator_unfocused",
};

comptime {
    knob.validateTable(Config, &knobs, &bespoke_fields);
    knob.validateOwnership(&knobs, &knob_reader_modules, "bar");
}

/// The section names the bar subsystem owns (D13/P2-50): the composed
/// facade unions every fragment's list into the mis-case lint's inventory.
/// The layout-anchor and modules tables are consumed by bar_sections.zig
/// but belong to this subsystem, so they are listed here.
pub const sections = &[_][]const u8{
    types.section_bar,
    types.section_bar_properties,
    types.section_prefix_bar_layout ++ "left",
    types.section_prefix_bar_layout ++ "center",
    types.section_prefix_bar_layout ++ "right",
    types.section_bar_modules_workspaces,
};

/// The section HEADS whose presence in the embedded fallback TOML is gated
/// on this fragment's owner module (P2-50): the build's fallback filter
/// strips a `[head...]` block when the owner is absent from the tree.
pub const fallback_sections = &[_][]const u8{"bar"};

/// Inert family (D13/P2-50): `[bar.properties]` is read only when bare
/// `[bar]` is present; the property maps would otherwise parse and do
/// nothing, which the load warns about.
pub const inert_families = &[_]types.InertFamily{.{
    .parent = types.section_bar,
    .child_exact = types.section_bar_properties,
}};

/// The fragment parse entry: self-seed the owned defaults (icon padding to
/// the workspace count read straight off the document, plus the default
/// three-column layout), apply the scalar knobs, then parse the non-scalar
/// structures and the [bar.properties] segment maps.
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

/// Warn-only checks: values that are legal but almost certainly not what the
/// user meant. Called by composed.parse; never fails the load.
pub fn validate(cfg: *const Config) !void {
    // A font size of 0 is a typo, not a design: the bar's text metrics then
    // compute a zero height and the bar draws as a bare strip. (A NEGATIVE
    // size is impossible: the barScalable floor is 0.)
    if (cfg.font_size.is_percentage) {
        if (scaling.asRatio(cfg.font_size) == 0.0)
            log.warn("bar.font_size is 0%; the bar will have no readable text", .{});
    } else if (cfg.font_size.value == 0.0) {
        log.warn("bar.font_size is {d}px; the bar will have no readable text", .{cfg.font_size.value});
    }
}
/// The `[bar.properties]` segment decoder: segment-name keys the scalar knobs
/// do not own. The knob-key test stays bound to the very table the knob loop
/// reads (a future `[bar.properties]` knob can never desync the map pass) --
/// by being the same file.
/// Reads `[bar.properties]` segment-name entries (any key not owned by the
/// scalar knobs above) into `cfg.segment_fg` / `segment_value_fg` /
/// `segment_props`.
///
/// A key with the `_value` suffix (`cpu_value`) is that segment's NUMBER
/// color: the numeric readout ("42%" in "CPU 42%") is painted with it while
/// the rest of the segment keeps the plain entry (`cpu`) -- see
/// `segmentValueFg`. `_value` entries are color-only.
///
/// A plain `<segment>` entry is a composite: an optional color override plus
/// optional style flags, either of which may stand alone. Accepted spellings
/// for the flags are `underline=true|false`, space-separated `underline true`,
/// integer `underline 1`, or a bare `underline` (meaning true). The color is
/// the first color-carrying item (`#RRGGBB`, `0xRRGGBB`, integer, or a
/// palette reference by full name); a whole-array `+` color-mix is resolved
/// as a unit first; everything else must be a recognized style flag or it is
/// warn-and-skipped. A style-only entry keeps the
/// segment's default `fg` (no color map entry is added).
///
/// Runs after the knob loop so the known keys (title, run_*, ...) are
/// distinguishable. Gated on [bar] exactly like the [bar.properties] chain;
/// an absent table or section leaves the maps empty, so segment text falls
/// back to `fg`. Keys are duped for the Config's lifetime.
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

/// True when `key` is one of the [bar.properties] scalar knobs; every OTHER
/// key in that table is a bar segment name (a per-segment color + style
/// override, see `applyBarProperties`). Scanned from this file's knob table,
/// so a future [bar.properties] knob can never desync the map pass.
fn isBarPropertiesKnobKey(key: []const u8) bool {
    inline for (knobs) |k| {
        for (k.places) |pl| {
            if (std.mem.eql(u8, pl.section, types.section_bar_properties) and
                std.mem.eql(u8, pl.key, key)) return true;
        }
    }
    return false;
}

/// Sets one style flag (`underline`/`bold`/`italic`) on `props`. Returns
/// true when `name` was a recognized flag.
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

/// The first color-carrying item of a composite `[bar.properties]` array
/// value (`#RRGGBB`, `0xRRGGBB`, integer, or palette reference by full name).
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

/// Inserts one segment-keyed entry: dupes `seg_key`, hands ownership to `map`
/// on success, and rolls the key back on OOM so the map never holds a
/// dangling key. The six put sites in `applySegmentEntry` share this exact
/// contract.
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

/// The color map a segment entry writes to: `_value` keys own the segment's
/// number color, everything else the plain color override.
inline fn segmentColorMap(cfg: *Config, is_value: bool) *std.StringHashMapUnmanaged(types.Color) {
    return if (is_value) &cfg.segment_value_fg else &cfg.segment_fg;
}

/// Applies one [bar.properties] segment entry: `_value` keys are color-only
/// (unchanged decoding); base keys take the composite color+style decoding.
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
        // Style-only single-token spellings: `<flag>` (true) and
        // `<flag>=<bool>`. A non-default result is stored; a cleared flag
        // (all-false props) is a no-op, exactly as an absent entry.
        if (raw == .string) {
            const s = raw.asScalar([]const u8).?;
            var props = SegmentProps{};
            var recognized = false;
            if (!is_value) {
                if (boolFromEqualsToken(s)) |eq| {
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
    // unit first, so `a + (weight:40%) b` compounds aren't misread as stray
    // tokens (the per-item scan below would grab just the head operand).
    // Pure mixes are color-only, exactly as the pre-properties decoding.
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
