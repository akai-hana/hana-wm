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
/// target is tiling.<key>, gated on "tiling" (mirrors parseTiling's gate).
fn tilingAesthetics(key: []const u8, kind: Kind) Knob {
    return .{ .places = &.{ place("tiling.aesthetics", key), place("tiling", key) },
        .target = "tiling." ++ key, .kind = kind, .requires = "tiling" };
}

/// Master-stack trio: dedicated-section short spelling wins over the flat
/// [tiling] spelling (section presence, not key presence, picks the spelling).
fn masterStack(dedicated_key: []const u8, flat_key: []const u8, kind: Kind) Knob {
    return .{ .places = &.{ place("tiling.layouts.master-stack", dedicated_key), place("tiling", flat_key) },
        .target = "tiling." ++ flat_key, .kind = kind, .requires = "tiling" };
}

/// Plain [bar] boolean.
fn barBool(key: []const u8) Knob {
    return .{ .places = &.{place("bar", key)}, .target = "bar." ++ key, .kind = .b };
}

/// Plain [bar] scalable (px or %), rejecting negative raw values.
fn barScalable(key: []const u8, target: []const u8) Knob {
    return .{ .places = &.{place("bar", key)}, .target = target, .kind = .{ .scalable = 0.0 } };
}

/// Plain [bar] color (base palette, no gate).
fn barPlainColor(key: []const u8) Knob {
    return .{ .places = &.{place("bar", key)}, .target = "bar." ++ key, .kind = .color };
}

/// [bar.colors] color_from chain: reads a sibling bar field as fallback,
/// gated on "bar"; `copy` also assigns the fallback when [bar.colors] is absent.
fn barColor(key: []const u8, target: []const u8, sibling: []const u8, copy: bool) Knob {
    return .{ .places = &.{place("bar.colors", key)}, .target = target,
        .kind = .{ .color_from = sibling }, .requires = "bar", .copy_when_absent = copy };
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
    knob(&.{ place("bar.modules.workspaces", "count"), place("workspaces", "count") },
        "workspaces.count", .{ .int = .{ .T = u8, .min = 1, .max = constants.max_workspaces } }),
    knob(&.{ place("bar.modules.workspaces", "enabled"), place("workspaces", "enabled") },
        "workspaces.enabled", .b),

    // [tiling]: gated on the section exactly as parseTiling always was --
    // a lone [tiling.aesthetics] without [tiling] never fed these knobs.
    knobGated(&.{place("tiling", "enabled")}, "tiling.enabled", .b, "tiling"),
    knobGated(&.{place("tiling", "global_layout")}, "tiling.global_layout", .b, "tiling"),
    knobGated(&.{place("tiling", "min_window_dim")}, "tiling.min_window_dim",
        .{ .int = .{ .T = u16, .min = 1 } }, "tiling"),

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
    knob(&.{place("bar", "height")}, "bar.height", .auto_scalable),
    // Exact-case enum; an unrecognized spelling silently keeps .top.
    knob(&.{place("bar", "position")}, "bar.bar_position",
        .{ .enum_read = .{ .T = types.BarScreenPosition } }),
    knob(&.{place("bar", "carousel_speed_px_s")}, "bar.carousel_speed_px_s",
        .{ .int = .{ .T = u16, .min = 1, .max = 1000 } }),

    // Base palette: read before every color_from consumer below.
    barPlainColor("bg"),
    barPlainColor("fg"),
    barPlainColor("selected_bg"),
    barPlainColor("selected_fg"),
    barPlainColor("accent_color"),

    knob(&.{place("bar", "clock_format")}, "bar.clock_format", .str),
    knob(&.{place("bar", "drun_prompt")}, "bar.drun_prompt", .str),
    knob(&.{place("bar", "indicator_location")}, "bar.indicator_location",
        .{ .enum_read = .{ .T = types.IndicatorLocation, .ci = true, .warn = true, .default_label = "up-left" } }),
    knob(&.{place("bar", "indicator_padding")}, "bar.indicator_padding", .ratio),
    knob(&.{place("bar", "transparency")}, "bar.transparency", .ratio),
    // Falls back to the bar-wide fg (its historical default) -- but only
    // when the key is present; absent keeps the field null.
    knob(&.{place("bar", "indicator_color")}, "bar.indicator_color", .{ .color_opt = "fg" }),

    // [bar.colors] chain. Gated on [bar] because parseBar always returned
    // before reaching these when the section was missing entirely. The
    // title accents additionally COPY their fallback when [bar.colors] is
    // absent (they were unconditionally assigned); the drun trio stay null
    // so the read-time fallbacks in BarConfig apply.
    barColor("title", "bar.title_accent_color", "accent_color", true),
    barColor("title_unfocused", "bar.title_unfocused_accent", "bg", true),
    barColor("title_minimized", "bar.title_minimized_accent", "accent_color", true),
    barColor("drun_bg", "bar.drun_bg", "bg", false),
    barColor("drun_fg", "bar.drun_fg", "fg", false),
    barColor("drun_prompt_color", "bar.drun_prompt_color", "accent_color", false),
};

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
    /// field (e.g. drun_bg->bg, title->accent_color); `copy_when_absent`
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

/// Resolves a dotted "group.leaf" (or bare root-level) target path to its
/// field type. Groups are exactly one level deep on types.Config.
pub fn PathType(comptime path: []const u8) type {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        const Group = @TypeOf(@field(@as(types.Config, undefined), path[0..dot]));
        return @TypeOf(@field(@as(Group, undefined), path[dot + 1 ..]));
    }
    return @TypeOf(@field(@as(types.Config, undefined), path));
}

/// Mutable pointer to a knob's target field.
pub fn ptr(cfg: *types.Config, comptime path: []const u8) *PathType(path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return &@field(@field(cfg, path[0..dot]), path[dot + 1 ..]);
    }
    return &@field(cfg, path);
}

/// Read-only view of a knob's target field.
pub fn value(cfg: *const types.Config, comptime path: []const u8) PathType(path) {
    if (comptime std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return @field(@field(cfg, path[0..dot]), path[dot + 1 ..]);
    }
    return @field(cfg, path);
}

// Generic readers. Bodies are verbatim ports of the pre-schema config.zig
// interpreters.

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
        bool => section.getAs(bool, key) orelse return default,
        []const u8 => section.getAs([]const u8, key) orelse return default,
        u8, u16, u32, usize => blk: {
            const i = section.getAs(i64, key) orelse return default;
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

/// Resolves a color from a pre-fetched Value, accepting `#RRGGBB`, `0xRRGGBB`, or an integer.
/// Split from `getColor` so callers that already have the Value avoid a redundant hashmap lookup.
fn getColorFromValue(key: []const u8, val: parser.Value, default: u32) u32 {
    if (val.asScalar(u32)) |c| return c;
    if (val.asScalar([]const u8)) |s| return parser.parseColor(s) catch {
        debug.warn("Invalid color for {s}: '{s}'", .{ key, s });
        return default;
    };
    if (val.asScalar(i64)) |i| if (i >= 0 and i <= 0xFFFFFF) return @intCast(i);
    return default;
}

/// Resolves a color from a section key, accepting `#RRGGBB`, `0xRRGGBB`, or an integer.
fn getColor(section: *parser.Section, key: []const u8, default: u32) u32 {
    const val = section.get(key) orelse return default;
    return getColorFromValue(key, val, default);
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
    const val = section.getAs(parser.ScalableValue, key) orelse return default;
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
            .b => if (hit) |h| { p.* = h.sec.getAs(bool, h.key) orelse p.*; },
            .int => |spec| if (hit) |h| {
                p.* = getInRange(spec.T, h.sec, h.key, p.*,
                    if (spec.min) |m| @as(spec.T, m) else null,
                    if (spec.max) |m| @as(spec.T, m) else null);
            },
            .scalable => |min| if (hit) |h| {
                p.* = getScalableInRange(h.sec, h.key, p.*, min, "default") orelse p.*;
            },
            .scalable_free => if (hit) |h| {
                if (h.sec.getAs(parser.ScalableValue, h.key)) |v| p.* = v;
            },
            .auto_scalable => if (hit) |h| {
                p.* = getScalableInRange(h.sec, h.key, null, 0, "auto");
            },
            .color => if (hit) |h| { p.* = getColor(h.sec, h.key, p.*); },
            .color_from => |sibling| {
                const fallback = @field(cfg.bar, sibling);
                if (hit) |h| {
                    p.* = getColor(h.sec, h.key, fallback);
                } else if (comptime k.copy_when_absent) {
                    p.* = fallback;
                }
            },
            .color_opt => |sibling| if (hit) |h| {
                if (h.sec.get(h.key)) |val|
                    p.* = getColorFromValue(h.key, val, @field(cfg.bar, sibling));
            },
            .ratio => if (hit) |h| { p.* = getRatio(h.sec, h.key, p.*); },
            .str => if (hit) |h| {
                if (h.sec.getAs([]const u8, h.key)) |val| try assignStr(allocator, p, val);
            },
            .enum_read => |er| if (hit) |h| {
                if (h.sec.getAs([]const u8, h.key)) |s| {
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
}
