//! Comptime config schema.
//! Declares each scalar knob once, driving defaults, interpretation, and the schema tests.

const std = @import("std");
const parser = @import("parser");
const types = @import("types");
const constants = @import("constants");
const debug = @import("debug");
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

/// How an enum-valued knob is parsed.
pub const EnumRead = struct {
    T: type,
    /// true = case-insensitive lookup through T.fromString (the alias map,
    /// e.g. MasterSide's "l"/"left"/"r"/"right"); false = exact-case
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
    /// ScalableValue (px or %) rejecting negatives on the raw .value with
    /// the standard "below minimum" warning.
    scalable: f32,
    /// ScalableValue assigned whenever present, with NO local bound
    /// (master_width: validate() owns the ratio/negative policy).
    scalable_free,
    /// Optional ScalableValue where absent means "auto" (null); a negative
    /// warns back to auto rather than passing through to rendering.
    auto_scalable,
    /// Color accepting #RRGGBB / 0xRRGGBB / integer.
    color,
    /// Color whose default is the CURRENT value of the named cfg.bar
    /// sibling field (drun_bg->bg, title->accent_color, ...). With
    /// `copy_when_absent` the fallback is assigned even when the knob's
    /// section is missing (the accent trio's historical behavior).
    /// Assignment happens whenever the knob's SECTION resolves, copying the
    /// sibling for absent keys -- the [bar.colors] chain's behavior.
    color_from: []const u8,
    /// Like color_from but assigned only when the KEY itself exists;
    /// an absent key leaves the nullable field untouched (null), while an
    /// unparseable value reverts to the named sibling (indicator_color ->
    /// bar-wide fg).
    color_opt: []const u8,
    /// [0,1] ratio under getRatio semantics: bare integers are percentages,
    /// `1` is ambiguous and resolves to 1% with a warning.
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

/// Every scalar knob, exactly once. ORDER MATTERS twice: workspaces.count
/// precedes icon-padding (config.zig pads icons to the count), and base bar
/// colors precede the color_from chain that borrows them as fallbacks.
pub const knobs = [_]Knob{
    // [drag]
    .{ .places = &.{place("drag", "enabled")}, .target = "drag_enabled", .kind = .b },
    .{ .places = &.{place("drag", "snap_distance")}, .target = "snap_distance", .kind = .{ .scalable = 0.0 } },

    // [fullscreen]
    .{ .places = &.{place("fullscreen", "enabled")}, .target = "fullscreen_enabled", .kind = .b },

    // [bar.modules.workspaces] | [workspaces]
    .{ .places = &.{ place("bar.modules.workspaces", "count"), place("workspaces", "count") }, .target = "workspaces.count", .kind = .{ .int = .{ .T = u8, .min = 1, .max = constants.max_workspaces } } },
    .{ .places = &.{ place("bar.modules.workspaces", "enabled"), place("workspaces", "enabled") }, .target = "workspaces.enabled", .kind = .b },

    // [tiling]: gated on the section exactly as parseTiling always was --
    // a lone [tiling.aesthetics] without [tiling] never fed these knobs.
    .{ .places = &.{place("tiling", "enabled")}, .target = "tiling.enabled", .kind = .b, .requires = "tiling" },
    .{ .places = &.{place("tiling", "global_layout")}, .target = "tiling.global_layout", .kind = .b, .requires = "tiling" },
    .{ .places = &.{place("tiling", "min_window_dim")}, .target = "tiling.min_window_dim", .kind = .{ .int = .{ .T = u16, .min = 1 } }, .requires = "tiling" },

    // Aesthetics quartet: [tiling.aesthetics] preferred, flat [tiling]
    // fallback (same key spellings in both).
    .{ .places = &.{ place("tiling.aesthetics", "gap_width"), place("tiling", "gap_width") }, .target = "tiling.gap_width", .kind = .{ .scalable = 0.0 }, .requires = "tiling" },
    .{ .places = &.{ place("tiling.aesthetics", "border_width"), place("tiling", "border_width") }, .target = "tiling.border_width", .kind = .{ .scalable = 0.0 }, .requires = "tiling" },
    .{ .places = &.{ place("tiling.aesthetics", "border_focused"), place("tiling", "border_focused") }, .target = "tiling.border_focused", .kind = .color, .requires = "tiling" },
    .{ .places = &.{ place("tiling.aesthetics", "border_unfocused"), place("tiling", "border_unfocused") }, .target = "tiling.border_unfocused", .kind = .color, .requires = "tiling" },

    // Master-stack trio: the dedicated section's shorter spellings win;
    // flat [tiling] keeps the flat spellings. Section presence -- not key
    // presence -- picks the spelling.
    .{ .places = &.{ place("tiling.layouts.master-stack", "count"), place("tiling", "master_count") }, .target = "tiling.master_count", .kind = .{ .int = .{ .T = u8, .min = 1 } }, .requires = "tiling" },
    .{ .places = &.{ place("tiling.layouts.master-stack", "side"), place("tiling", "master_side") }, .target = "tiling.master_side", .kind = .{ .enum_read = .{ .T = types.MasterSide, .ci = true } }, .requires = "tiling" },
    // No local bound: validate() owns master_width's ratio/negative policy.
    .{ .places = &.{ place("tiling.layouts.master-stack", "width"), place("tiling", "master_width") }, .target = "tiling.master_width", .kind = .scalable_free, .requires = "tiling" },

    // [bar]
    .{ .places = &.{place("bar", "enabled")}, .target = "bar.enabled", .kind = .b },
    .{ .places = &.{place("bar", "vim_mode")}, .target = "bar.vim_mode", .kind = .b },
    .{ .places = &.{place("bar", "carousel_enabled")}, .target = "bar.carousel_enabled", .kind = .b },
    .{ .places = &.{place("bar", "font_size")}, .target = "bar.font_size", .kind = .{ .scalable = 0.0 } },
    // segment_spacing feeds BarConfig.spacing.
    .{ .places = &.{place("bar", "segment_spacing")}, .target = "bar.spacing", .kind = .{ .scalable = 0.0 } },
    .{ .places = &.{place("bar", "indicator_size")}, .target = "bar.indicator_size", .kind = .{ .scalable = 0.0 } },
    .{ .places = &.{place("bar", "workspace_tag_width")}, .target = "bar.workspace_tag_width", .kind = .{ .scalable = 0.0 } },
    // height: null = auto-calculate from font metrics alone.
    .{ .places = &.{place("bar", "height")}, .target = "bar.height", .kind = .auto_scalable },
    // Exact-case enum; an unrecognized spelling silently keeps .top.
    .{ .places = &.{place("bar", "position")}, .target = "bar.bar_position", .kind = .{ .enum_read = .{ .T = types.BarScreenPosition } } },
    .{ .places = &.{place("bar", "carousel_speed_px_s")}, .target = "bar.carousel_speed_px_s", .kind = .{ .int = .{ .T = u16, .min = 1, .max = 1000 } } },

    // Base palette: read before every color_from consumer below.
    .{ .places = &.{place("bar", "bg")}, .target = "bar.bg", .kind = .color },
    .{ .places = &.{place("bar", "fg")}, .target = "bar.fg", .kind = .color },
    .{ .places = &.{place("bar", "selected_bg")}, .target = "bar.selected_bg", .kind = .color },
    .{ .places = &.{place("bar", "selected_fg")}, .target = "bar.selected_fg", .kind = .color },
    .{ .places = &.{place("bar", "accent_color")}, .target = "bar.accent_color", .kind = .color },

    .{ .places = &.{place("bar", "clock_format")}, .target = "bar.clock_format", .kind = .str },
    .{ .places = &.{place("bar", "drun_prompt")}, .target = "bar.drun_prompt", .kind = .str },
    .{ .places = &.{place("bar", "indicator_location")}, .target = "bar.indicator_location", .kind = .{ .enum_read = .{ .T = types.IndicatorLocation, .ci = true, .warn = true, .default_label = "up-left" } } },
    .{ .places = &.{place("bar", "indicator_padding")}, .target = "bar.indicator_padding", .kind = .ratio },
    .{ .places = &.{place("bar", "transparency")}, .target = "bar.transparency", .kind = .ratio },
    // Falls back to the bar-wide fg (its historical default) -- but only
    // when the key is present; absent keeps the field null.
    .{ .places = &.{place("bar", "indicator_color")}, .target = "bar.indicator_color", .kind = .{ .color_opt = "fg" } },

    // [bar.colors] chain. Gated on [bar] because parseBar always returned
    // before reaching these when the section was missing entirely. The
    // title accents additionally COPY their fallback when [bar.colors] is
    // absent (they were unconditionally assigned); the drun trio stay null
    // so the read-time fallbacks in BarConfig apply.
    .{ .places = &.{place("bar.colors", "title")}, .target = "bar.title_accent_color", .kind = .{ .color_from = "accent_color" }, .requires = "bar", .copy_when_absent = true },
    .{ .places = &.{place("bar.colors", "title_unfocused")}, .target = "bar.title_unfocused_accent", .kind = .{ .color_from = "bg" }, .requires = "bar", .copy_when_absent = true },
    .{ .places = &.{place("bar.colors", "title_minimized")}, .target = "bar.title_minimized_accent", .kind = .{ .color_from = "accent_color" }, .requires = "bar", .copy_when_absent = true },
    .{ .places = &.{place("bar.colors", "drun_bg")}, .target = "bar.drun_bg", .kind = .{ .color_from = "bg" }, .requires = "bar" },
    .{ .places = &.{place("bar.colors", "drun_fg")}, .target = "bar.drun_fg", .kind = .{ .color_from = "fg" }, .requires = "bar" },
    .{ .places = &.{place("bar.colors", "drun_prompt_color")}, .target = "bar.drun_prompt_color", .kind = .{ .color_from = "accent_color" }, .requires = "bar" },
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
    debug.warn("Value for '{s}' ({any}) " ++ verb ++ " ({any}), using default", .{ key, value_, bound });
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
        bool => section.getBool(key) orelse return default,
        []const u8 => section.getString(key) orelse return default,
        u8, u16, u32, usize => blk: {
            const i = section.getInt(key) orelse return default;
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
    if (val.asColor()) |c| return c;
    if (val.asString()) |s| return parser.parseColor(s) catch {
        debug.warn("Invalid color for {s}: '{s}'", .{ key, s });
        return default;
    };
    if (val.asInt()) |i| if (i >= 0 and i <= 0xFFFFFF) return @intCast(i);
    return default;
}

/// Resolves a color from a section key, accepting `#RRGGBB`, `0xRRGGBB`, or an integer.
fn getColor(section: *parser.Section, key: []const u8, default: u32) u32 {
    const val = section.get(key) orelse return default;
    return getColorFromValue(key, val, default);
}

/// Like getInRange, but for ScalableValue fields. Only enforces a lower bound
/// on the raw `.value` (percentages and absolute pixels share no meaningful
/// ceiling): enough to reject a negative like `gap_width = -50`. Returns
/// `default` unclamped, with a warning, matching getInRange.
fn getScalableInRange(
    section: *parser.Section,
    key: []const u8,
    default: parser.ScalableValue,
    comptime min: f32,
) parser.ScalableValue {
    const val = section.getScalable(key) orelse return default;
    if (val.value < min) {
        debug.warn("Value for '{s}' ({d}) below minimum ({d}), using default", .{ key, val.value, min });
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
    if (val.asInt()) |i| {
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
    if (val.asScalable()) |s| {
        const f = utils.scaling.asRatio(s);
        if (f < 0.0 or f > 1.0) {
            debug.warn("Invalid {s} value {d} (must be 0.0-1.0 or 0-100%), using default", .{ key, f });
            return default;
        }
        return f;
    }
    if (val.asString()) |str|
        debug.warn("{s} value '{s}' is quoted; write it unquoted (e.g. {s} = 0.5), using default", .{ key, str, key });
    return default;
}

/// bar.height's reader: null means auto; an explicit negative warns back to
/// auto rather than reaching rendering code.
fn autoScalable(section: *parser.Section, key: []const u8) ?parser.ScalableValue {
    const h = section.getScalable(key) orelse return null;
    if (h.value < 0.0) {
        debug.warn("Value for '{s}' ({d}) below minimum (0), using auto", .{ key, h.value });
        return null;
    }
    return h;
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
        switch (k.kind) {
            .b => if (hit) |h| {
                ptr(cfg, k.target).* = h.sec.getBool(h.key) orelse ptr(cfg, k.target).*;
            },
            .int => |spec| if (hit) |h| {
                ptr(cfg, k.target).* = getInRange(
                    spec.T,
                    h.sec,
                    h.key,
                    ptr(cfg, k.target).*,
                    if (spec.min) |m| @as(spec.T, m) else null,
                    if (spec.max) |m| @as(spec.T, m) else null,
                );
            },
            .scalable => |min| if (hit) |h| {
                ptr(cfg, k.target).* = getScalableInRange(h.sec, h.key, ptr(cfg, k.target).*, min);
            },
            .scalable_free => if (hit) |h| {
                if (h.sec.getScalable(h.key)) |v| ptr(cfg, k.target).* = v;
            },
            .auto_scalable => if (hit) |h| {
                ptr(cfg, k.target).* = autoScalable(h.sec, h.key);
            },
            .color => if (hit) |h| {
                ptr(cfg, k.target).* = getColor(h.sec, h.key, ptr(cfg, k.target).*);
            },
            .color_from => |sibling| {
                const fallback = @field(cfg.bar, sibling);
                if (hit) |h| {
                    ptr(cfg, k.target).* = getColor(h.sec, h.key, fallback);
                } else if (comptime k.copy_when_absent) {
                    ptr(cfg, k.target).* = fallback;
                }
            },
            .color_opt => |sibling| if (hit) |h| {
                if (h.sec.get(h.key)) |val|
                    ptr(cfg, k.target).* = getColorFromValue(h.key, val, @field(cfg.bar, sibling));
            },
            .ratio => if (hit) |h| {
                ptr(cfg, k.target).* = getRatio(h.sec, h.key, ptr(cfg, k.target).*);
            },
            .str => if (hit) |h| {
                if (h.sec.getString(h.key)) |val| try assignStr(allocator, ptr(cfg, k.target), val);
            },
            .enum_read => |er| if (hit) |h| {
                if (h.sec.getString(h.key)) |s| {
                    const parsed = if (er.ci) er.T.fromString(s) else std.meta.stringToEnum(er.T, s);
                    if (parsed) |v| {
                        ptr(cfg, k.target).* = v;
                    } else if (er.warn) {
                        debug.warn("Unknown {s} '{s}', using default '{s}'", .{ h.key, s, er.default_label });
                    }
                }
            },
        }
    }
}
