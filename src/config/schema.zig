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

/// [bar.properties] color_from chain: reads a sibling bar field as fallback,
/// gated on "bar". `copy_when_absent` (title variant) also assigns the
/// fallback when [bar.properties] is absent; the drun variant keeps null so
/// the read-time fallbacks in BarConfig apply (R2).
fn barColor(key: []const u8, target: []const u8, sibling: []const u8, copy_when_absent: bool) Knob {
    return .{ .places = &.{place(types.section_bar_properties, key)}, .target = target, .kind = .{ .color_from = sibling }, .requires = types.section_bar, .copy_when_absent = copy_when_absent };
}

/// Title accent color: copies `sibling` when [bar.properties] is absent (R2).
fn barTitleColor(key: []const u8, target: []const u8, sibling: []const u8) Knob {
    return barColor(key, target, sibling, true);
}

/// Drun accent color: stays null when [bar.properties] is absent (R2).
fn barDrunColor(key: []const u8, target: []const u8, sibling: []const u8) Knob {
    return barColor(key, target, sibling, false);
}

/// Every scalar knob, exactly once. ORDER MATTERS twice: workspaces.count
/// precedes icon-padding (config.zig pads icons to the count), and base bar
/// colors precede the color_from chain that borrows them as fallbacks.
pub const knobs = [_]Knob{
    // [drag]
    knob(&.{place(types.section_drag, "enabled")}, "drag_enabled", .b),
    knob(&.{place(types.section_drag, "snap_distance")}, "snap_distance", .{ .scalable = 0.0 }),

    // [fullscreen]
    knob(&.{place(types.section_fullscreen, "enabled")}, "fullscreen_enabled", .b),

    // [bar.modules.workspaces] | [workspaces]
    knob(&.{ place(types.section_bar_modules_workspaces, "count"), place(types.section_workspaces, "count") }, "workspaces.count", .{ .int = .{ .T = u8, .min = 1, .max = constants.max_workspaces } }),
    knob(&.{ place(types.section_bar_modules_workspaces, "enabled"), place(types.section_workspaces, "enabled") }, "workspaces.enabled", .b),

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

    // [bar.properties] chain. Gated on [bar] because parseBar always returned
    // before reaching these when the section was missing entirely. The
    // title accents additionally COPY their fallback when [bar.properties] is
    // absent (they were unconditionally assigned); the drun trio stay null
    // so the read-time fallbacks in BarConfig apply.
    barTitleColor("title", "bar.title_accent_color", types.palette_primary_color),
    barTitleColor("title_unfocused", "bar.title_unfocused_accent", types.palette_secondary_color),
    barTitleColor("title_minimized", "bar.title_minimized_accent", types.palette_alternative_color),
    barDrunColor("drun_bg", "bar.drun_bg", "bg"),
    barDrunColor("drun_fg", "bar.drun_fg", "fg"),
    barDrunColor("drun_prompt_color", "bar.drun_prompt_color", types.palette_primary_color),
};

/// Keys the [bar.properties] scalar knobs own; every OTHER key in that table
/// is a bar segment name (a per-segment color + style override, see
/// `applyBarProperties`). Derived from `knobs` so a future [bar.properties]
/// knob can never desync the map pass.
const bar_properties_knob_keys_len = blk: {
    var n: usize = 0;
    for (knobs) |k| {
        for (k.places) |pl| {
            if (std.mem.eql(u8, pl.section, types.section_bar_properties)) n += 1;
        }
    }
    break :blk n;
};
const bar_properties_knob_keys: [bar_properties_knob_keys_len][]const u8 = blk: {
    var keys: [bar_properties_knob_keys_len][]const u8 = undefined;
    var i: usize = 0;
    for (knobs) |k| {
        for (k.places) |pl| {
            if (std.mem.eql(u8, pl.section, types.section_bar_properties)) {
                keys[i] = pl.key;
                i += 1;
            }
        }
    }
    break :blk keys;
};

fn isBarPropertiesKnobKey(key: []const u8) bool {
    for (bar_properties_knob_keys) |k| {
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
            if (i > std.math.maxInt(T))
                return reject(i64, key, i, "above maximum", std.math.maxInt(T), default);
            break :blk @as(T, @intCast(i));
        },
        else => @compileError("Unsupported type"),
    };
    if (comptime min) |m| if (val < m) return reject(T, key, val, "below minimum", m, default);
    if (comptime max) |m| if (val > m) return reject(T, key, val, "above maximum", m, default);
    return val;
}

/// True when an accumulated value is (or contains) a `+`/weight color-mix
/// attempt. Such an array that failed resolveColorExpr is an INVALID mix, and
/// the last-scalar fallback below must not swallow it (descending to its
/// final operand silently resolves the bad mix instead of reverting).
fn isMixAttempt(val: parser.Value) bool {
    if (val != .array) return false;
    for (val.asArray().?) |item| {
        if (item.asScalar([]const u8)) |s| {
            if (std.mem.indexOfScalar(u8, s, '+') != null) return true;
        }
        if (parser.isWeightToken(item.asScalar([]const u8) orelse "")) return true;
    }
    return false;
}

/// Resolves a color from a pre-fetched Value, accepting `#RRGGBB`,
/// `0xRRGGBB`, an integer, a full-name reference to a collected palette
/// variable (e.g. `border_focused = primary_color`), or a `+` color-mix
/// expression of any of those (e.g. `primary_color + (weight:75%)
/// secondary_color`). The value-decoding forms share parser.colorFromValue
/// (the single decoder); this layer adds the palette-reference lookup and the
/// warn-and-default policy on top.
fn getColorFromValue(
    key: []const u8,
    val: parser.Value,
    default: u32,
    palette: *const std.StringHashMap(u32),
) u32 {
    if (parser.colorFromValue(val)) |c| return c;
    if (parser.resolveColorExpr(val, palette)) |c| return c;
    if (isMixAttempt(val)) {
        debug.warn("Invalid color mix for '{s}': coalesced + weights may not exceed 100 and the head operand cannot carry a weight (using default)", .{key});
        return default;
    }
    if (val.asScalar([]const u8)) |s| {
        if (palette.get(s)) |c| return c;
        debug.warn("Invalid color for {s}: '{s}' (not a hex code, palette reference, or + mix)", .{ key, s });
        return default;
    }
    // Unresolvable value (boolean, size, bare float, out-of-range int, ...)
    // would otherwise silently use the default without a trace.
    debug.warn("Value for '{s}' is not a color (expected '#RRGGBB', '0xRRGGBB', an integer, a palette reference, or a + mix), using default", .{key});
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
    default: ?types.ScalableValue,
    min: f32,
    comptime fallback_label: []const u8,
) ?types.ScalableValue {
    const val = section.getAsOrWarn(types.ScalableValue, key) orelse return default;
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
    if (val.asScalar(types.ScalableValue)) |s| {
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
    else if (val != .array) // a non-string, non-number scalar (boolean, ...)
        debug.warn(
            "{s} expects a number or ratio, got an unreadable value; using default",
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
                if (h.sec.getAsOrWarn(types.ScalableValue, h.key)) |v| p.* = v;
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
    try applyBarProperties(allocator, doc, cfg);
}

/// Reads `[bar.properties]` segment-name entries (any key not owned by the
/// scalar knobs above) into `cfg.bar.segment_fg` / `segment_value_fg` /
/// `segment_props`.
///
/// A key with the `_value` suffix (`cpu_value`) is that segment's NUMBER
/// color: the numeric readout ("42%" in "Cpu 42%") is painted with it while
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
/// Runs after the knob loop so the known keys (title, drun_*, ...) are
/// distinguishable. Gated on [bar] exactly like the [bar.properties] chain;
/// an absent table or section leaves the maps empty, so segment text falls
/// back to `fg`. Keys are duped for the Config's lifetime.
fn applyBarProperties(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    types.freeSegmentColors(&cfg.bar.segment_fg, allocator);
    types.freeSegmentColors(&cfg.bar.segment_value_fg, allocator);
    types.freeSegmentProps(&cfg.bar.segment_props, allocator);
    if (doc.getSection(types.section_bar) == null) return;
    const sec = doc.getSection(types.section_bar_properties) orelse return;
    var it = sec.orderedIterator();
    while (it.next()) |pair| {
        sec.markConsumed(pair.key);
        if (isBarPropertiesKnobKey(pair.key)) continue;
        const is_value = std.mem.endsWith(u8, pair.key, "_value");
        const seg_key = if (is_value) pair.key[0 .. pair.key.len - "_value".len] else pair.key;
        try applySegmentEntry(allocator, cfg, pair.key, seg_key, is_value, pair.value, &doc.palette);
    }
}

/// Sets one style flag (`underline`/`bold`/`italic`) on `props`. Returns
/// true when `name` was a recognized flag.
fn setStyleFlag(props: *types.SegmentProps, name: []const u8, val: bool) bool {
    if (std.mem.eql(u8, name, "underline")) {
        props.underline = val;
        return true;
    }
    if (std.mem.eql(u8, name, "bold")) {
        props.bold = val;
        return true;
    }
    if (std.mem.eql(u8, name, "italic")) {
        props.italic = val;
        return true;
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
        if (parser.colorFromValue(item)) |c| return .{ .color = c, .consumed = i };
        if (item.asScalar([]const u8)) |s| {
            if (palette.get(s)) |c| return .{ .color = c, .consumed = i };
        }
    }
    return null;
}

/// Applies one [bar.properties] segment entry: `_value` keys are color-only
/// (unchanged decoding); base keys take the composite color+style decoding.
fn applySegmentEntry(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
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
            var props = types.SegmentProps{};
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
                    const k = try allocator.dupe(u8, seg_key);
                    errdefer allocator.free(k);
                    try cfg.bar.segment_props.put(allocator, k, props);
                }
                return;
            }
        }
        // Plain scalar: color only, exactly as the pre-properties behavior.
        const color = getColorFromValue(key, raw, cfg.bar.fg, palette);
        const map = if (is_value) &cfg.bar.segment_value_fg else &cfg.bar.segment_fg;
        const k = try allocator.dupe(u8, seg_key);
        errdefer allocator.free(k);
        try map.put(allocator, k, color);
        return;
    }

    const items = raw.asArray().?;
    // A satisfying color-mix expression spans the whole array; resolve it as a
    // unit first, so `a + (weight:40%) b` compounds aren't misread as stray
    // tokens (the per-item scan below would grab just the head operand).
    // Pure mixes are color-only, exactly as the pre-properties decoding.
    if (parser.resolveColorExpr(raw, palette)) |mix| {
        const map = if (is_value) &cfg.bar.segment_value_fg else &cfg.bar.segment_fg;
        const k = try allocator.dupe(u8, seg_key);
        errdefer allocator.free(k);
        try map.put(allocator, k, mix);
        return;
    }

    var props = types.SegmentProps{};
    const found = firstColorInItems(items, palette);
    if (!is_value) {
        var i: usize = 0;
        while (i < items.len) {
            if (found) |f| if (i == f.consumed) {
                i += 1;
                continue;
            };
            const token = items[i].asScalar([]const u8) orelse {
                debug.warn("Invalid token for '{s}': expected a color or underline/bold/italic flag, skipping", .{key});
                i += 1;
                continue;
            };
            if (boolFromEqualsToken(token)) |eq| {
                if (!setStyleFlag(&props, eq.name, eq.value))
                    debug.warn("Invalid style for '{s}': '{s}' is not underline/bold/italic, skipping", .{ key, token });
                i += 1;
                continue;
            }
            // Bare `name` spelling: true by default; a following boolean or
            // 0/1 integer item sets the value instead.
            var set: bool = true;
            var consumed_next = false;
            if (i + 1 < items.len) {
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
            if (setStyleFlag(&props, token, set)) {
                if (consumed_next) i += 1;
            } else {
                debug.warn("Invalid style for '{s}': '{s}' is not underline/bold/italic, skipping", .{ key, token });
            }
            i += 1;
        }
    }

    if (found) |f| {
        const map = if (is_value) &cfg.bar.segment_value_fg else &cfg.bar.segment_fg;
        const k = try allocator.dupe(u8, seg_key);
        errdefer allocator.free(k);
        try map.put(allocator, k, f.color);
    } else if (is_value) {
        // A `_value` key is color-only: an array with no color is invalid.
        const color = getColorFromValue(key, raw, cfg.bar.fg, palette);
        const k = try allocator.dupe(u8, seg_key);
        errdefer allocator.free(k);
        try cfg.bar.segment_value_fg.put(allocator, k, color);
    }
    // Else: style-only base entry; the segment color stays default fg (no
    // map entry), so segmentFg's orelse fallback yields exactly that.

    if (!is_value and !props.isDefault()) {
        const k = try allocator.dupe(u8, seg_key);
        errdefer allocator.free(k);
        try cfg.bar.segment_props.put(allocator, k, props);
    }
}
