//! Comptime config schema.
//! Declares each scalar knob once, driving defaults, interpretation, and the schema tests.

const std = @import("std");
const constants = @import("constants");
const debug = @import("debug");
const parser = @import("parser");
const types = @import("types");
const utils = @import("utils");

/// One accepted location for a knob: a section name and the key spelling
/// used inside it.
pub const Placement = struct {
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

/// The [tiling.aesthetics]/flat [tiling] quartet: same key spells both,
/// target is tiling.<key>. UNGATED: the aesthetics are visual, so a theme
/// file may carry only `[tiling.aesthetics]` (no `[tiling]` functional
/// marker) and still apply border/gap styling. The place probe already
/// no-ops when neither section exists.
fn tilingAesthetics(key: []const u8, kind: Kind) Knob {
    return .{ .places = &.{ place(types.section_tiling_aesthetics, key), place(types.section_tiling, key) }, .target = "tiling." ++ key, .kind = kind };
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

/// [bar.colors] color_from chain: reads a sibling bar field as fallback,
/// gated on "bar". `copy_when_absent` (title variant) also assigns the
/// fallback when [bar.colors] is absent; the drun variant keeps null so the
/// read-time fallbacks in BarConfig apply (R2).
fn barColor(key: []const u8, target: []const u8, sibling: []const u8, copy_when_absent: bool) Knob {
    return .{ .places = &.{place(types.section_bar_colors, key)}, .target = target, .kind = .{ .color_from = sibling }, .requires = types.section_bar, .copy_when_absent = copy_when_absent };
}

/// Title accent color: copies `sibling` when [bar.colors] is absent (R2).
fn barTitleColor(key: []const u8, target: []const u8, sibling: []const u8) Knob {
    return barColor(key, target, sibling, true);
}

/// Drun accent color: stays null when [bar.colors] is absent (R2).
fn barDrunColor(key: []const u8, target: []const u8, sibling: []const u8) Knob {
    return barColor(key, target, sibling, false);
}

/// Every scalar knob, exactly once. ORDER MATTERS twice: workspaces.count
/// precedes icon-padding (config.zig pads icons to the count), and base bar
/// colors precede the color_from chain that borrows them as fallbacks.
pub const knobs = [_]Knob{
    // [drag]
    knob(&.{place("drag", "enabled")}, "drag_enabled", .b),
    knob(&.{place("drag", "snap_distance")}, "snap_distance", .{ .scalable = 0.0 }),

    // [fullscreen]
    knob(&.{place("fullscreen", "enabled")}, "fullscreen_enabled", .b),

    // [bar.modules.workspaces] | [workspaces]
    knob(&.{ place("bar.modules.workspaces", "count"), place("workspaces", "count") }, "workspaces.count", .{ .int = .{ .T = u8, .min = 1, .max = constants.max_workspaces } }),
    knob(&.{ place("bar.modules.workspaces", "enabled"), place("workspaces", "enabled") }, "workspaces.enabled", .b),

    // [tiling]: functional knobs gated on the section exactly as
    // parseTiling always was -- a lone [tiling.aesthetics] without [tiling]
    // never fed these knobs. (The aesthetics quartet below is UNGATED: it's
    // visual, so themes may ship it without the functional marker.)
    knobGated(&.{place(types.section_tiling, "enabled")}, "tiling.enabled", .b, types.section_tiling),
    knobGated(&.{place(types.section_tiling, "global_layout")}, "tiling.global_layout", .b, types.section_tiling),
    knobGated(&.{place(types.section_tiling, "min_window_dim")}, "tiling.min_window_dim", .{ .int = .{ .T = u16, .min = 1 } }, types.section_tiling),

    // Aesthetics quartet: [tiling.aesthetics] preferred, flat [tiling]
    // fallback (same key spellings in both).
    tilingAesthetics("gap_width", .{ .scalable = 0.0 }),
    tilingAesthetics("border_width", .{ .scalable = 0.0 }),
    tilingAesthetics("border_focused", .color),
    tilingAesthetics("border_unfocused", .color),

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
    // segment_spacing feeds BarConfig.spacing.
    barScalable("segment_spacing", "bar.spacing"),
    barScalable("indicator_size", "bar.indicator_size"),
    barScalable("workspace_tag_width", "bar.workspace_tag_width"),
    // height: null = auto-calculate from font metrics alone.
    knob(&.{place(types.section_bar, "height")}, "bar.height", .auto_scalable),
    // Case-insensitive enum (types.enumFromString over BarScreenPosition's
    // string_map); unrecognized spellings warn and keep .top (C8).
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
    knob(&.{place(types.section_bar, "drun_prompt")}, "bar.drun_prompt", .str),
    knob(&.{place(types.section_bar, "volume_format")}, "bar.volume_format", .str),
    knob(&.{place(types.section_bar, "volume_muted_format")}, "bar.volume_muted_format", .str),
    knob(&.{place(types.section_bar, "brightness_format")}, "bar.brightness_format", .str),
    knob(&.{place(types.section_bar, "brightness_device")}, "bar.brightness_device", .str),
    knob(&.{place(types.section_bar, "indicator_location")}, "bar.indicator_location", .{ .enum_read = .{ .T = types.IndicatorLocation, .ci = true, .warn = true, .default_label = "up-left" } }),
    knob(&.{place(types.section_bar, "indicator_padding")}, "bar.indicator_padding", .ratio),
    knob(&.{place(types.section_bar, "transparency")}, "bar.transparency", .ratio),
    // Falls back to the bar-wide fg (its historical default) -- but only
    // when the key is present; absent keeps the field null.
    knob(&.{place(types.section_bar, "indicator_color")}, "bar.indicator_color", .{ .color_opt = "fg" }),

    // [bar.colors] chain. Gated on [bar] because parseBar always returned
    // before reaching these when the section was missing entirely. The
    // title accents additionally COPY their fallback when [bar.colors] is
    // absent (they were unconditionally assigned); the drun trio stay null
    // so the read-time fallbacks in BarConfig apply.
    barTitleColor("title", "bar.title_accent_color", types.palette_primary_color),
    barTitleColor("title_unfocused", "bar.title_unfocused_accent", types.palette_secondary_color),
    barTitleColor("title_minimized", "bar.title_minimized_accent", types.palette_alternative_color),
    barDrunColor("drun_bg", "bar.drun_bg", "bg"),
    barDrunColor("drun_fg", "bar.drun_fg", "fg"),
    barDrunColor("drun_prompt_color", "bar.drun_prompt_color", types.palette_primary_color),
};

/// Keys the [bar.colors] scalar knobs own; every OTHER key in that table is a
/// bar segment name (a per-segment text-color override, see
/// `applySegmentColors`). Derived from `knobs` so a future [bar.colors] knob
/// can never desync the map pass.
const bar_colors_knob_keys_len = blk: {
    var n: usize = 0;
    for (knobs) |k| {
        for (k.places) |pl| {
            if (std.mem.eql(u8, pl.section, types.section_bar_colors)) n += 1;
        }
    }
    break :blk n;
};
const bar_colors_knob_keys: [bar_colors_knob_keys_len][]const u8 = blk: {
    var keys: [bar_colors_knob_keys_len][]const u8 = undefined;
    var i: usize = 0;
    for (knobs) |k| {
        for (k.places) |pl| {
            if (std.mem.eql(u8, pl.section, types.section_bar_colors)) {
                keys[i] = pl.key;
                i += 1;
            }
        }
    }
    break :blk keys;
};

fn isBarColorsKnobKey(key: []const u8) bool {
    for (bar_colors_knob_keys) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

/// How an enum-valued knob is parsed.
pub const EnumRead = struct {
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
pub const Kind = union(enum) {
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
    /// field (e.g. drun_bg->bg, title->primary_color); `copy_when_absent`
    /// also assigns it when the knob's section is absent.
    color_from: []const u8,
    /// Like color_from, but assigned only when the KEY itself exists.
    color_opt: []const u8,
    /// [0,1] ratio: bare integers are percentages, `1` resolves to 1% with
    /// a warning.
    ratio,
    /// Optional heap-dup'd string; absent leaves the field untouched.
    str,
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
    /// (the [bar]-colors gates mirror parseBar's old early return; the
    /// tiling family mirrors parseTiling's).
    requires: []const u8 = "",
    /// Assign the fallback default even when no placement matched.
    copy_when_absent: bool = false,
};

// Type-level access into Config by dotted path.

/// Splits a dotted "group.leaf" target path at its first '.'. With no dot the
/// whole path is the `leaf` and `group` is empty (a top-level Config field).
/// Shared by every dotted-path accessor so their splitting cannot drift.
const PathParts = struct { group: []const u8, leaf: []const u8 };
inline fn splitPath(comptime path: []const u8) PathParts {
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return .{ .group = path[0..dot], .leaf = path[dot + 1 ..] };
    }
    return .{ .group = "", .leaf = path };
}

/// Resolves a dotted "group.leaf" (or bare root-level) target path to its
/// field type. Groups are exactly one level deep on types.Config.
fn PathType(comptime path: []const u8) type {
    const parts = comptime splitPath(path);
    if (parts.group.len == 0) return @TypeOf(@field(@as(types.Config, undefined), path));
    const Group = @TypeOf(@field(@as(types.Config, undefined), parts.group));
    return @TypeOf(@field(@as(Group, undefined), parts.leaf));
}

/// Mutable pointer to a knob's target field.
fn ptr(cfg: *types.Config, comptime path: []const u8) *PathType(path) {
    const parts = comptime splitPath(path);
    if (parts.group.len == 0) return &@field(cfg, path);
    return &@field(@field(cfg, parts.group), parts.leaf);
}

/// Read-only view of a knob's target field.
pub fn value(cfg: *const types.Config, comptime path: []const u8) PathType(path) {
    const parts = comptime splitPath(path);
    if (parts.group.len == 0) return @field(cfg, path);
    return @field(@field(cfg, parts.group), parts.leaf);
}

// Generic readers.

/// Warn-and-return-default for an out-of-range value, shared by getInRange
/// and getScalableInRange so the warning wording (and its boilerplate) lives once.
fn reject(
    comptime T: type,
    key: []const u8,
    value_: T,
    comptime verb: []const u8,
    bound: T,
    default: anytype,
) @TypeOf(default) {
    debug.warn(
        "Value for '{s}' ({any}) " ++ verb ++ " ({any}), using default",
        .{ key, value_, bound },
    );
    return default;
}

/// Returns `default` when the key is absent, the wrong type, or out of range
/// (values are warn-and-revert, not clamped).
pub fn getInRange(
    comptime T: type,
    section: *parser.Section,
    key: []const u8,
    default: T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    const val = switch (T) {
        bool => section.getAsOrWarn(bool, key) orelse return default,
        []const u8 => section.getAsOrWarn([]const u8, key) orelse return default,
        u8, u16 => blk: {
            const i = section.getAsOrWarn(i64, key) orelse return default;
            // A negative int would trap on the @intCast below; warn-and-default
            // it here so the out-of-range contract holds for negatives too.
            if (i < 0) return reject(i64, key, i, "below minimum", 0, default);
            // Guard the type's own range before the cast: an int larger than T
            // can hold would trap on @intCast even when no explicit max is set.
            // (For u64/usize the comparison is comptime-folded away.)
            if (std.math.maxInt(T) < std.math.maxInt(i64) and i > std.math.maxInt(T))
                return reject(i64, key, i, "above maximum", std.math.maxInt(T), default);
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };
    if (comptime min) |m| if (val < m) return reject(T, key, val, "below minimum", m, default);
    if (comptime max) |m| if (val > m) return reject(T, key, val, "above maximum", m, default);
    return val;
}

/// Resolves a color from a pre-fetched Value, accepting `#RRGGBB`,
/// `0xRRGGBB`, an integer, or a full-name reference to a collected palette
/// variable (e.g. `border_focused = primary_color`). The value-decoding forms
/// share parser.colorFromValue (the single decoder); this layer adds the
/// palette-reference lookup and the warn-and-default policy on top.
fn getColorFromValue(
    key: []const u8,
    val: parser.Value,
    default: u32,
    palette: *const std.StringHashMap(u32),
) u32 {
    if (parser.colorFromValue(val)) |c| return c;
    if (val.asScalar([]const u8)) |s| {
        if (palette.get(s)) |c| return c;
        debug.warn("Invalid color for {s}: '{s}' (not a hex code or palette reference)", .{ key, s });
        return default;
    }
    // Unresolvable value (boolean, size, bare float, out-of-range int, ...)
    // would otherwise silently use the default without a trace.
    debug.warn("Value for '{s}' is not a color (expected '#RRGGBB', '0xRRGGBB', an integer, or a palette reference), using default", .{key});
    return default;
}

/// Reads `section.key` as a ScalableValue, warn-and-return-`default` below
/// `min`. `fallback_label` names the fallback in the warning ("default" for
/// ordinary scalables, "auto" for bar.height); callers remap null to their
/// own default. Only enforces a lower bound on the raw `.value` (percentages
/// and absolute pixels share no meaningful ceiling): enough to reject a
/// negative like `gap_width = -50`, matching getInRange.
fn getScalableInRange(
    section: *parser.Section,
    key: []const u8,
    default: ?parser.ScalableValue,
    min: f32,
    comptime fallback_label: []const u8,
) ?parser.ScalableValue {
    const val = section.getAsOrWarn(parser.ScalableValue, key) orelse return default;
    if (val.value < min) {
        debug.warn(
            "Value for '{s}' ({d}) below minimum ({d}), using {s}",
            .{ key, val.value, min, fallback_label },
        );
        return default;
    }
    return val;
}

/// Reads `section.key` into a [0.0, 1.0] ratio, falling back to `default`
/// when the key is absent or out of range. Bare integers are always
/// percentages (0-100, `= 1` resolving to 1% with a warning); decimals and
/// `%`-suffixed values are ratios directly; quoted values fall to the
/// default, warned.
fn getRatio(section: *parser.Section, key: []const u8, default: f32) f32 {
    const val = section.get(key) orelse return default;
    if (val.asScalar(i64)) |i| {
        if (i == 0) return 0.0;
        if (i >= 2 and i <= 100) return @as(f32, @floatFromInt(i)) / 100.0;
        if (i == 1) {
            // `= 1` is ambiguous (1% or 1.0); per the "bare integers are
            // percentages" rule it resolves to 1%, but we warn so a user who
            // meant the full value writes `1.0` or `100%`.
            debug.warn("{s} value 1 is ambiguous (1% or 1.0 ratio?); " ++
                "treating as 1%. Use '1.0' or '100%' for 100%.", .{key});
            return 0.01;
        }
        debug.warn("Invalid {s} value {} (must be 0-100), using default", .{ key, i });
        return default;
    }
    if (val.asScalar(parser.ScalableValue)) |s| {
        const f = utils.scaling.asRatio(s);
        if (f < 0.0 or f > 1.0) {
            debug.warn(
                "Invalid {s} value {d} (must be 0.0-1.0 or 0-100%), using default",
                .{ key, f },
            );
            return default;
        }
        return f;
    }
    if (val.asScalar([]const u8)) |str|
        debug.warn(
            "{s} value '{s}' is quoted; write it unquoted (e.g. {s} = 0.5), using default",
            .{ key, str, key },
        )
    else if (val != .array) // something else entirely (boolean, ...)
        debug.warn(
            "{s} expects a number or ratio, got a union/other value; using default",
            .{key},
        );
    return default;
}

/// Dupes `val` into `*view`, freeing the previous value first. `*view` must
/// already hold a heap allocation (or null), so Config.deinit frees every
/// owned string unconditionally. The dupe comes BEFORE the free because the
/// key-absent fallback passes `view.*` as `val`.
pub fn assignStr(allocator: std.mem.Allocator, view: *?[]const u8, val: []const u8) !void {
    const copy = try allocator.dupe(u8, val);
    if (view.*) |old| allocator.free(old);
    view.* = copy;
}

/// Applies every knob from a parsed Document: the schema-driven replacement
/// for the hand-written per-section scalar interpreters (parseDrag,
/// parseWorkspaces, parseEnabledFlag, parseTiling's scalar reads,
/// parseBar's scalar reads, parseBarColors). OOM from string dupes
/// propagates; everything else warns-and-reverts in place.
pub fn applyAll(doc: *parser.Document, allocator: std.mem.Allocator, cfg: *types.Config) !void {
    // Resolve the document-global palette (four reserved variable names)
    // before the knobs read: color knobs may reference them by full name.
    parser.collectPalette(doc);
    const palette: *const std.StringHashMap(u32) = &doc.palette;
    inline for (knobs) |k| knob: {
        if (comptime k.requires.len > 0) {
            if (doc.getSection(k.requires) == null) break :knob;
        }
        // Places probe in order; the FIRST section present in the document
        // wins and only its paired key spelling is read. Presence of
        // `[tiling.layouts.master-stack]` therefore makes flat `[tiling]
        // master_count` unrecognized, matching the old orelse chains.
        var hit: ?struct { sec: *parser.Section, key: []const u8 } = null;
        inline for (k.places) |pl| {
            if (hit == null) {
                if (doc.getSection(pl.section)) |sec| hit = .{ .sec = sec, .key = pl.key };
            }
        }
        const p = ptr(cfg, k.target);
        switch (k.kind) {
            .b => if (hit) |h| {
                p.* = h.sec.getAsOrWarn(bool, h.key) orelse p.*;
            },
            .int => |spec| if (hit) |h| {
                p.* = getInRange(spec.T, h.sec, h.key, p.*, if (spec.min) |m| @as(spec.T, m) else null, if (spec.max) |m| @as(spec.T, m) else null);
            },
            .scalable => |min| if (hit) |h| {
                p.* = getScalableInRange(h.sec, h.key, p.*, min, "default") orelse p.*;
            },
            .scalable_free => if (hit) |h| {
                if (h.sec.getAsOrWarn(parser.ScalableValue, h.key)) |v| p.* = v;
            },
            .auto_scalable => if (hit) |h| {
                p.* = getScalableInRange(h.sec, h.key, null, 0, "auto");
            },
            .color => if (hit) |h| {
                if (h.sec.get(h.key)) |val|
                    p.* = getColorFromValue(h.key, val, p.*, palette);
            },
            .color_from => |sibling| {
                const fallback = @field(cfg.bar, sibling);
                if (hit) |h| {
                    p.* = if (h.sec.get(h.key)) |val|
                        getColorFromValue(h.key, val, fallback, palette)
                    else
                        fallback;
                } else if (comptime k.copy_when_absent) {
                    p.* = fallback;
                }
            },
            .color_opt => |sibling| if (hit) |h| {
                if (h.sec.get(h.key)) |val|
                    p.* = getColorFromValue(h.key, val, @field(cfg.bar, sibling), palette);
            },
            .ratio => if (hit) |h| {
                p.* = getRatio(h.sec, h.key, p.*);
            },
            .str => if (hit) |h| {
                if (h.sec.getAsOrWarn([]const u8, h.key)) |val| try assignStr(allocator, p, val);
            },
            .enum_read => |er| if (hit) |h| {
                if (h.sec.getAsOrWarn([]const u8, h.key)) |s| {
                    const parsed = if (er.ci)
                        types.enumFromString(er.T, s)
                    else
                        std.meta.stringToEnum(er.T, s);
                    if (parsed) |v| {
                        p.* = v;
                    } else if (er.warn) {
                        debug.warn(
                            "Unknown {s} '{s}', using default '{s}'",
                            .{ h.key, s, er.default_label },
                        );
                    }
                }
            },
        }
    }
    try applySegmentColors(allocator, doc, cfg);
}

/// Reads `[bar.colors]` segment-name -> text-color pairs (any key not owned
/// by the scalar knobs above) into `cfg.bar.segment_fg`. Runs after the knob
/// loop so the known keys (title, drun_*, ...) are distinguishable. Gated on
/// [bar] exactly like the [bar.colors] chain; an absent table or section
/// leaves the map empty, so segment text falls back to `fg`. Keys are duped
/// for the Config's lifetime; palette references resolve like every color
/// knob.
pub fn applySegmentColors(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    types.freeSegmentColors(&cfg.bar.segment_fg, allocator);
    if (doc.getSection(types.section_bar) == null) return;
    const sec = doc.getSection(types.section_bar_colors) orelse return;
    var it = sec.orderedIterator();
    while (it.next()) |pair| {
        sec.markConsumed(pair.key);
        if (isBarColorsKnobKey(pair.key)) continue;
        const color = getColorFromValue(pair.key, pair.value, cfg.bar.fg, &doc.palette);
        const key = try allocator.dupe(u8, pair.key);
        cfg.bar.segment_fg.put(allocator, key, color) catch |err| {
            allocator.free(key);
            return err;
        };
    }
}
