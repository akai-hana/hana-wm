//! The knob table: every scalar config knob declared exactly once, as data.
//! `Placement` (an accepted section/key spelling), the table-literal
//! builders, and the `Kind`/`Knob` vocabulary live here with the array.
//! The reflection engine that walks the table -- defaults, validation, the
//! coverage pass, `applyAll` -- stays in `schema.zig`, which re-exports
//! `knobs` so `schema.knobs` callers keep one import.

const constants = @import("constants");
const types = @import("types");

/// One accepted location for a knob: a section name and the key spelling
/// used inside it.
const Placement = struct {
    section: []const u8,
    key: []const u8,
};

/// Table-literal shorthand so entries stay one-liner-readable.
fn place(section: []const u8, key: []const u8) Placement {
    return .{ .section = section, .key = key };
}

/// Comptime builders collapsing the repeated multi-line Knob literals that
/// share a common shape (identical `places`/`target`/`kind`/`requires`
/// wiring), so each `knobs` entry reads as a compact one-liner. Every entry
/// keeps its exact `places`, `target`, `kind`, `requires`, and
/// `copy_when_absent` values.
/// Plain knob with no `requires` gate.
fn knob(places: []const Placement, target: []const u8, kind: Kind) Knob {
    return .{ .places = places, .target = target, .kind = kind };
}

/// Knob gated on `requires` (whole knob skipped unless that section exists).
fn knobGated(places: []const Placement, target: []const u8, kind: Kind, requires: []const u8) Knob {
    return .{ .places = places, .target = target, .kind = kind, .requires = requires };
}

/// Master-stack trio: dedicated-section short spelling wins over the flat
/// [tiling] spelling (section presence, not key presence, picks the spelling).
fn masterStack(dedicated_key: []const u8, flat_key: []const u8, kind: Kind) Knob {
    return .{ .places = &.{ place(types.section_tiling_layouts_master_stack, dedicated_key), place(types.section_tiling, flat_key) }, .target = "tiling." ++ flat_key, .kind = kind, .requires = types.section_tiling };
}

/// Plain [bar] boolean.
fn barBool(key: []const u8) Knob {
    return .{ .places = &.{place(types.section_bar, key)}, .target = "bar." ++ key, .kind = .b };
}

/// Plain [bar] scalable (px or %), rejecting negative raw values.
fn barScalable(key: []const u8, target: []const u8) Knob {
    return .{ .places = &.{place(types.section_bar, key)}, .target = target, .kind = .{ .scalable = 0.0 } };
}

/// Plain [bar] color (base palette, no gate).
fn barPlainColor(key: []const u8) Knob {
    return .{ .places = &.{place(types.section_bar, key)}, .target = "bar." ++ key, .kind = .color };
}

/// [bar.properties] color_from chain: reads a sibling bar field as fallback,
/// gated on "bar". `copy_when_absent` (title variant) also assigns the
/// fallback when [bar.properties] is absent; the run variant keeps null so
/// the read-time fallbacks in BarConfig apply.
fn barColor(key: []const u8, target: []const u8, sibling: []const u8, copy_when_absent: bool) Knob {
    return .{
        .places = &.{place(types.section_bar_properties, key)},
        .target = target,
        .kind = .{ .color_from = sibling },
        .requires = types.section_bar,
        .copy_when_absent = copy_when_absent,
        .needs = &.{"bar." ++ sibling},
    };
}

/// Same dependency, declared the same way, for the `color_opt` kind.
fn barColorOpt(places: []const Placement, target: []const u8, sibling: []const u8) Knob {
    return .{
        .places = places,
        .target = target,
        .kind = .{ .color_opt = sibling },
        .needs = &.{"bar." ++ sibling},
    };
}

/// Every scalar knob, exactly once. ORDER MATTERS in two places, and only one
/// of them is checked: workspaces.count precedes icon-padding (bar_sections
/// pads icons to the count) is a comment-only convention, while the base-bar-colors
/// precede the color_from chain ordering is ENFORCED below by each knob's
/// `needs` list.
pub const knobs = [_]Knob{
    // [drag]
    knob(&.{place(types.section_drag, "enabled")}, "drag_enabled", .b),
    knob(&.{place(types.section_drag, "snap_distance")}, "snap_distance", .{ .scalable = 0.0 }),

    // [fullscreen]
    knob(&.{place(types.section_fullscreen, "enabled")}, "fullscreen_enabled", .b),

    // [display]
    knob(&.{place(types.section_display, "dpi")}, "dpi", .{ .opt_float = .{ .min = 20.0, .max = 1000.0 } }),

    // [bar.modules.workspaces] | [workspaces]
    knob(&.{ place(types.section_bar_modules_workspaces, "count"), place(types.section_workspaces, "count") }, "workspaces.count", .{ .int = .{ .T = u8, .min = 1, .max = constants.max_workspaces } }),
    knob(&.{ place(types.section_bar_modules_workspaces, "enabled"), place(types.section_workspaces, "enabled") }, "workspaces.enabled", .b),

    // [tiling]: functional knobs gated on the section itself -- a lone
    // [tiling] carrying only the
    // aesthetics quartet (a theme file's shape) never fed these
    // knobs. (The aesthetics quartet below is UNGATED: it's
    // visual, so themes may ship it without any functional key.)
    knobGated(&.{place(types.section_tiling, "enabled")}, "tiling.enabled", .b, types.section_tiling),
    knobGated(&.{place(types.section_tiling, "global_layout")}, "tiling.global_layout", .b, types.section_tiling),
    knobGated(&.{place(types.section_tiling, "min_window_dim")}, "tiling.min_window_dim", .{ .int = .{ .T = u16, .min = 1 } }, types.section_tiling),

    // Aesthetics quartet: flat [tiling] spellings. UNGATED --
    // it's visual, so a theme file may ship only these in a
    // lone [tiling] with no functional key.
    knob(&.{place(types.section_tiling, "gap_width")}, "tiling.gap_width", .{ .scalable = 0.0 }),
    knob(&.{place(types.section_tiling, "border_width")}, "tiling.border_width", .{ .scalable = 0.0 }),
    knob(&.{place(types.section_tiling, "border_focused")}, "tiling.border_focused", .color),
    knob(&.{place(types.section_tiling, "border_unfocused")}, "tiling.border_unfocused", .color),

    // Master-stack trio: the dedicated section's shorter spellings win;
    // flat [tiling] keeps the flat spellings.
    masterStack("count", "master_count", .{ .int = .{ .T = u8, .min = 1 } }),
    masterStack("side", "master_side", .{ .enum_read = .{ .T = types.MasterSide, .ci = true } }),
    // No local bound: validate() owns master_width's ratio/negative policy.
    masterStack("width", "master_width", .scalable_free),

    // [bar]
    barBool("enabled"),
    barBool("vim_mode"),
    barBool("carousel_enabled"),
    barScalable("font_size", "bar.font_size"),
    // per_segment_padding feeds BarConfig.spacing.
    barScalable("per_segment_padding", "bar.spacing"),
    barScalable("indicator_size", "bar.indicator_size"),
    barScalable("workspace_tag_width", "bar.workspace_tag_width"),
    // height: null = auto-calculate from font metrics alone.
    knob(&.{place(types.section_bar, "height")}, "bar.height", .auto_scalable),
    // Case-insensitive enum (types.enumFromString over BarScreenPosition's
    // string_map); unrecognized spellings warn and keep .top.
    knob(&.{place(types.section_bar, "position")}, "bar.bar_position", .{ .enum_read = .{ .T = types.BarScreenPosition, .ci = true, .warn = true, .default_label = "top" } }),
    knob(&.{place(types.section_bar, "carousel_speed_px_s")}, "bar.carousel_speed_px_s", .{ .int = .{ .T = u16, .min = 1, .max = 1000 } }),

    // Base palette: read before every color_from consumer below. The three
    // window-state colors (primary/secondary/alternative) plus text_color are
    // also the document-global palette variables: color knobs may name them
    // by full reference from any section (resolved from parser.Document's
    // collected palette in getColorFromValue).
    barPlainColor("bg"),
    barPlainColor("fg"),
    barPlainColor("selected_bg"),
    barPlainColor("selected_fg"),
    barPlainColor(types.palette_primary_color),
    barPlainColor(types.palette_secondary_color),
    barPlainColor(types.palette_alternative_color),
    barPlainColor(types.palette_text_color),

    knob(&.{place(types.section_bar, "clock_format")}, "bar.clock_format", .str),
    knob(&.{place(types.section_bar, "run_prompt")}, "bar.run_prompt", .str),
    knob(&.{place(types.section_bar, "volume_format")}, "bar.volume_format", .str),
    knob(&.{place(types.section_bar, "volume_muted_format")}, "bar.volume_muted_format", .str),
    knob(&.{place(types.section_bar, "brightness_format")}, "bar.brightness_format", .str),
    knob(&.{place(types.section_bar, "brightness_device")}, "bar.brightness_device", .str),
    knob(&.{place(types.section_bar, "indicator_location")}, "bar.indicator_location", .{ .enum_read = .{ .T = types.IndicatorLocation, .ci = true, .warn = true, .default_label = "up-left" } }),
    knob(&.{place(types.section_bar, "indicator_padding")}, "bar.indicator_padding", .ratio),
    knob(&.{place(types.section_bar, "transparency")}, "bar.transparency", .ratio_strict),
    // Falls back to the bar-wide fg (its historical default) -- but only
    // when the key is present; absent keeps the field null.
    barColorOpt(&.{place(types.section_bar, "indicator_color")}, "bar.indicator_color", "fg"),
    // Selected workspace tag: an individually-set indicator glyph color for the
    // current tag. It falls back at read time to indicator_color, then the
    // tag's text color. The selected tag's icon TEXT color/styles are NOT a
    // scalar knob -- they use the same color+underline/bold/italic composite
    // path as any segment, via the [bar.properties] entry "workspaces_selected"
    // (see BarConfig.workspaceTextFg/workspaceIconProps).
    barColorOpt(&.{place(types.section_bar, "selected_indicator_color")}, "bar.selected_indicator_color", "fg"),

    // [bar.properties] chain. Gated on [bar] because parseBar always returned
    // before reaching these when the section was missing entirely. The
    // title accents additionally COPY their fallback when [bar.properties] is
    // absent (they were unconditionally assigned); the run trio stay null
    // so the read-time fallbacks in BarConfig apply.
    barColor("title", "bar.title_accent_color", types.palette_primary_color, true),
    barColor("title_unfocused", "bar.title_unfocused_accent", types.palette_secondary_color, true),
    barColor("title_minimized", "bar.title_minimized_accent", types.palette_alternative_color, true),
    barColor("run_bg", "bar.run_bg", "bg", false),
    barColor("run_fg", "bar.run_fg", "fg", false),
    barColor("run_prompt_color", "bar.run_prompt_color", types.palette_primary_color, false),

    // Legacy spellings, kept working. The `drun_*` keys were named for
    // a desktop-file launcher; the segment resolves a `$PATH` executable and
    // runs it, so `run_*` is the honest name. These are ALIASES, not a second
    // set of fields: each maps onto the same target as its canonical knob, so
    // setting one assigns exactly the field the other would. A config that
    // used the old keys keeps working with no edit, which is the whole reason
    // this is a rename-with-alias rather than a rename.
    knob(&.{place(types.section_bar, "drun_prompt")}, "bar.run_prompt", .str),
    barColor("drun_bg", "bar.run_bg", "bg", false),
    barColor("drun_fg", "bar.run_fg", "fg", false),
    barColor("drun_prompt_color", "bar.run_prompt_color", types.palette_primary_color, false),
};

/// How an enum-valued knob is parsed.
const EnumRead = struct {
    T: type,
    /// true = case-insensitive lookup through types.enumFromString (the alias
    /// map, e.g. MasterSide's "l"/"left"/"r"/"right"); false = exact-case
    /// std.meta.stringToEnum.
    ci: bool = false,
    /// Warn (mentioning `default_label`) when the value doesn't parse;
    /// otherwise fall back silently. Either way the field keeps its
    /// current (= default) value.
    warn: bool = false,
    default_label: []const u8 = "",
};

/// What kind of value a knob accepts, and which reader enforces it.
///
/// Flat on purpose: each variant is ONE read-and-warn policy, dispatched in
/// one arm of applyOne's switch. Folding the near-neighbours together (the
/// three color variants, `ratio`/`ratio_strict`, `scalable`/`scalable_free`)
/// would trade those arms for a flag apiece and push the branching back
/// inside them -- more to read at the call site, not less.
const Kind = union(enum) {
    /// Plain boolean flag.
    b,
    /// Integer with optional inclusive bounds (warn-and-revert outside).
    int: struct { T: type, min: ?comptime_int = null, max: ?comptime_int = null },
    /// ScalableValue (px or %) rejecting negative raw .value with a warning.
    scalable: f32,
    /// ScalableValue assigned whenever present, with NO local bound
    /// (master_width: validate() owns the ratio/negative policy).
    scalable_free,
    /// Optional ScalableValue; absent means "auto" (null), a negative
    /// warns back to auto.
    auto_scalable,
    /// Color accepting #RRGGBB / 0xRRGGBB / integer.
    color,
    /// Color defaulting to the CURRENT value of a named cfg.bar sibling
    /// field (e.g. run_bg->bg, title->primary_color); `copy_when_absent`
    /// also assigns it when the knob's section is absent.
    color_from: []const u8,
    /// Like color_from, but assigned only when the KEY itself exists.
    color_opt: []const u8,
    /// [0,1] ratio: bare integers are percentages, `1` resolves to 1% with
    /// a warning.
    ratio,
    /// [0,1] ratio that rejects bare integers: only a decimal (0.0-1.0)
    /// or a `%`-suffixed value parses; a bare integer warns and reverts
    /// to the default. `transparency` uses this so `= 1` can never be
    /// misread as 1% while `= 1.0` means 100%.
    ratio_strict,
    /// Optional heap-dup'd string; absent leaves the field untouched.
    str,
    /// Optional float; absent leaves the field at null (meaning "auto").
    /// Out-of-range values warn and revert to absent, matching `int`.
    opt_float: struct { min: f32, max: f32 },
    /// Enum parsed per EnumRead.
    enum_read: EnumRead,
};

pub const Knob = struct {
    /// Accepted locations, first-present-wins.
    places: []const Placement,
    /// Dotted path from types.Config to the field this knob feeds.
    target: []const u8,
    kind: Kind,
    /// When non-empty the whole knob is skipped unless this section exists
    /// (the gates mirror the parsers' own missing-section returns: parseBar
    /// for [bar], parseTilingStructures for [tiling]).
    requires: []const u8 = "",
    /// Assign the fallback default even when no placement matched.
    copy_when_absent: bool = false,
    /// Targets this knob READS to resolve its value (the sibling a
    /// `color_from`/`color_opt` kind falls back to), by dotted path. This is
    /// the ORDERING constraint stated as data: the dependency used to be a
    /// string embedded in `kind` plus a comment in the table saying "base
    /// colors precede the color_from chain", which nothing checked. A knob
    /// moved up or a sibling renamed would silently read the DEFAULT value
    /// instead of the configured one -- the knob still parsed, the color was
    /// just wrong, and only a visual diff of the bar would show it. The
    /// comptime assert below turns the ordering into a build failure.
    needs: []const []const u8 = &.{},
};
