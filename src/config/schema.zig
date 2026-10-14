//! Comptime config schema.
//! Declares each scalar knob once, driving defaults, interpretation, and the schema tests.
//! Note: `knobs` itself and `value` stay pub as read-only test seams pinned by
//! schema_test; nothing in the runtime config-loading path names them.

const std = @import("std");
const constants = @import("constants");
const log = @import("log");
const parser = @import("parser");
const types = @import("types");
const scaling = @import("scaling");
const color = @import("color");
const bar_properties = @import("bar_properties");

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
/// of them is checked: workspaces.count precedes icon-padding (config.zig pads
/// icons to the count) is a comment-only convention, while the base-bar-colors
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

    // [tiling]: functional knobs gated on the section exactly as
    // parseTiling always was -- a lone [tiling] carrying only the
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

    // (27.7) Legacy spellings, kept working. The `drun_*` keys were named for
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

/// Resolves a dotted path from `types.Config` to the FIELD TYPE it names, or
/// null when any step is missing. Comptime only -- the path is always a
/// comptime string built by the knob builders, never a runtime value.
fn fieldTypeAt(comptime root: type, comptime path: []const u8) ?type {
    comptime {
        var cur = root;
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |seg| {
            const fields = @typeInfo(cur).@"struct".fields;
            var next: ?type = null;
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, seg)) {
                    next = f.type;
                    break;
                }
            }
            const t = next orelse return null;
            // The last segment is the answer, even when its type is a struct:
            // ScalableValue IS a struct, and treating it as a waypoint made every
            // size/percentage knob look like a dangling path.
            if (it.peek() == null) return t;
            // Otherwise a struct continues the walk (tiling., workspaces.) and
            // anything else means the path went deeper than the type allows.
            if (@typeInfo(t) == .@"struct" and t != f64) {
                cur = t;
            } else return null;
        }
        return null;
    }
}

/// The config subtrees a knob target may address, as prefix + type. A target is
/// written relative to its subtree (`gap_width`, `bar.bg`) EXCEPT for the
/// handful of top-level Config knobs (`snap_distance`, `fullscreen_enabled`),
/// which carry no prefix -- hence the empty-prefix entry.
const target_roots = [_]struct { prefix: []const u8, ty: type }{
    .{ .prefix = "", .ty = types.Config },
    .{ .prefix = "tiling.", .ty = types.TilingConfig },
    .{ .prefix = "bar.", .ty = types.BarConfig },
    .{ .prefix = "workspaces.", .ty = types.WorkspaceConfig },
};

/// Resolves a knob target against the subtrees above, returning the field type.
fn resolveTarget(comptime target: []const u8) ?type {
    inline for (target_roots) |r| {
        if (std.mem.startsWith(u8, target, r.prefix)) {
            return fieldTypeAt(r.ty, target[r.prefix.len..]);
        }
    }
    return null;
}

/// True when `path` names a field whose value is a plain scalar the schema
/// knobs are expected to own: bool, int, float, or one of the config value
/// types. Containers (ArrayList, maps) and nested structs are excluded -- they
/// are the bespoke cases, declared below.
fn isScalarLeaf(comptime t: type) bool {
    if (t == types.ScalableValue or t == types.Color) return true;
    return switch (@typeInfo(t)) {
        // Owned string leaves: the shape that leaks (see
        // types.bar_owned_str_fields) and that `copy_when_absent` knobs set.
        .optional => |o| o.child == []const u8,
        .pointer => |p| p.size == .slice and p.child == u8,
        // Enums are config-visible leaves too: a layout/gap enum nobody parses
        // is dead in exactly the same way an int nobody parses is.
        .@"enum", .bool, .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

/// Config fields that are legitimately NOT schema knobs: the containers and
/// the fields a bespoke parser owns. Each entry is a contract, not an
/// exemption -- the reason is why the schema table must not claim it.
pub const bespoke_fields = [_][]const u8{
    "tiling.layout",
    "bar.indicator_focused",
    "bar.indicator_unfocused",
};

comptime {
    // 55 knobs x 4 subtrees x field walks, plus the coverage pass below.
    @setEvalBranchQuota(400_000);
    // Every knob target must name a REAL field. A renamed field, or a typo in
    // a builder's target string, previously produced a knob that parsed,
    // validated and assigned into nothing at all -- the config key worked, the
    // value went nowhere, and no build failed.
    for (knobs) |k| {
        if (resolveTarget(k.target) == null) @compileError(
            "schema.knobs: target '" ++ k.target ++ "' does not name a field of Config, " ++
                "TilingConfig, BarConfig or WorkspacesConfig",
        );
    }

    // The reverse: a scalar field of the four config structs that no knob
    // targets and that `bespoke_fields` does not claim is a DEAD FIELD -- it
    // compiles, it parses, and it is always at its initializer. Reported as
    // ONE error listing all of them, so a big addition is a single fix list.
    //
    // Plain comptime string accumulation, not an ArrayList: this runs in a
    // container-scope `comptime` block where a method call on a local list
    // resolves to the UNBOUND `append(list, item)` and reports a bogus arity
    // error only once a dead field actually makes the line reachable.
    var unclaimed: []const u8 = "";
    var unclaimed_n: usize = 0;
    for (target_roots) |r| {
        for (std.meta.fields(r.ty)) |f| {
            if (!isScalarLeaf(f.type)) continue;
            const path = r.prefix ++ f.name;
            var covered = false;
            for (knobs) |k| {
                if (std.mem.eql(u8, k.target, path)) covered = true;
            }
            for (bespoke_fields) |b| {
                if (std.mem.eql(u8, b, path)) covered = true;
            }
            if (!covered) {
                unclaimed = unclaimed ++ path ++ ", ";
                unclaimed_n += 1;
            }
        }
    }
    if (unclaimed_n != 0) @compileError(
        "schema: " ++ std.fmt.comptimePrint("{d}", .{unclaimed_n}) ++
            " config fields are neither a knob target nor listed in bespoke_fields, " ++
            "so no code path would ever write them (they would be dead): " ++ unclaimed,
    );
    // A bespoke entry that names nothing is a stale exemption, which would
    // quietly let a future rename escape the check above.
    for (bespoke_fields) |b| {
        if (resolveTarget(b) == null) @compileError(
            "schema.bespoke_fields: '" ++ b ++ "' does not name a field of Config, " ++
                "TilingConfig, BarConfig or WorkspacesConfig",
        );
    }
}

comptime {
    // `needs` is a topological order: every target a knob reads must be
    // supplied by a knob EARLIER in the table. This is what the table comment
    // used to assert by hand ("base bar colors precede the color_from chain"),
    // minus the checking. A future knob inserted above a `barPlainColor` it
    // depends on, or a renamed sibling, fails here instead of silently
    // resolving the DEFAULT color.
    @setEvalBranchQuota(40_000);
    for (knobs, 0..) |k, i| {
        for (k.needs) |needed| {
            var found: bool = false;
            for (knobs, 0..) |producer, j| {
                if (j < i and std.mem.eql(u8, producer.target, needed)) found = true;
            }
            if (!found) @compileError(
                "schema.knobs: knob '" ++ k.target ++ "' reads '" ++ needed ++
                    "', which no EARLIER knob supplies; move that knob above it " ++
                    "(or fix the sibling name)",
            );
        }
    }
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
    /// (the [bar]-colors gates mirror parseBar's old early return; the
    /// tiling family mirrors parseTiling's).
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

// Type-level access into Config by dotted path.

/// Splits a dotted "group.leaf" target path at its first '.'. With no dot the
/// whole path is the `leaf` and `group` is empty (a top-level Config field).
/// Shared by every dotted-path accessor so their splitting cannot drift.
const PathParts = struct { group: []const u8, leaf: []const u8 };
inline fn splitPath(comptime path: []const u8) PathParts {
    @setEvalBranchQuota(2000);
    if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
        return .{ .group = path[0..dot], .leaf = path[dot + 1 ..] };
    }
    return .{ .group = "", .leaf = path };
}

/// Resolves a dotted "group.leaf" (or bare root-level) target path to its
/// field type. Groups are exactly one level deep on types.Config.
fn PathType(comptime path: []const u8) type {
    @setEvalBranchQuota(2000);
    const parts = comptime splitPath(path);
    if (parts.group.len == 0) return @TypeOf(@field(@as(types.Config, undefined), path));
    const Group = @TypeOf(@field(@as(types.Config, undefined), parts.group));
    return @TypeOf(@field(@as(Group, undefined), parts.leaf));
}

/// Mutable pointer to a knob's target field.
fn ptr(cfg: *types.Config, comptime path: []const u8) *PathType(path) {
    @setEvalBranchQuota(2000);
    const parts = comptime splitPath(path);
    if (parts.group.len == 0) return &@field(cfg, path);
    return &@field(@field(cfg, parts.group), parts.leaf);
}

/// Read-only view of a knob's target field.
pub fn value(cfg: *const types.Config, comptime path: []const u8) PathType(path) {
    @setEvalBranchQuota(2000);
    const parts = comptime splitPath(path);
    if (parts.group.len == 0) return @field(cfg, path);
    return @field(@field(cfg, parts.group), parts.leaf);
}

// Generic readers.

/// Warn-and-return-default for an out-of-range value, shared by getInRange's
/// integer path so the warning wording lives once.
fn reject(
    comptime T: type,
    key: []const u8,
    value_: T,
    comptime verb: []const u8,
    bound: T,
    default: anytype,
) @TypeOf(default) {
    log.warn(
        "Value for '{s}' ({any}) " ++ verb ++ " ({any}), using default",
        .{ key, value_, bound },
    );
    return default;
}

/// Returns `default` when the key is absent, the wrong type, or out of range
/// (values are warn-and-revert, not clamped).
fn getInRange(
    comptime T: type,
    section: *parser.Section,
    key: []const u8,
    default: T,
    comptime min: ?T,
    comptime max: ?T,
) T {
    const val = switch (T) {
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
        log.warn(
            "Value for '{s}' ({d}) below minimum ({d}), using {s}",
            .{ key, val.value, min, fallback_label },
        );
        return default;
    }
    return val;
}

/// Reads `section.key` into a [0.0, 1.0] ratio, falling back to `default`
/// when the key is absent or out of range. Decimals and `%`-suffixed
/// values are ratios directly; quoted values fall to the default, warned.
///
/// `ints_are_percent` selects the bare-integer policy. The legacy one
/// (`.ratio`) reads a bare integer as a percentage 0-100 (`= 1`
/// resolving to 1% with a warning). The strict one (`.ratio_strict`)
/// rejects bare integers outright, so `transparency = 1` reverts to the
/// default instead of being misread as 1% while `= 1.0` means 100%.
fn getRatio(comptime ints_are_percent: bool, section: *parser.Section, key: []const u8, default: f32) f32 {
    const val = section.get(key) orelse return default;
    if (val.asScalar(i64)) |i| {
        if (comptime ints_are_percent) {
            if (i == 0) return 0.0;
            if (i >= 2 and i <= 100) return @as(f32, @floatFromInt(i)) / 100.0;
            if (i == 1) {
                // `= 1` is ambiguous (1% or 1.0); per the "bare integers are
                // percentages" rule it resolves to 1%, but we warn so a user who
                // meant the full value writes `1.0` or `100%`.
                log.warn("{s} value 1 is ambiguous (1% or 1.0 ratio?); " ++
                    "treating as 1%. Use '1.0' or '100%' for 100%.", .{key});
                return 0.01;
            }
            log.warn("Invalid {s} value {} (must be 0-100), using default", .{ key, i });
            return default;
        }
        log.warn(
            "{s} value {d} is a bare integer; write a ratio (0.0-1.0) or a percentage (0-100%), using default",
            .{ key, i },
        );
        return default;
    }
    if (val.asScalar(types.ScalableValue)) |s| {
        const f = scaling.asRatio(s);
        if (f < 0.0 or f > 1.0) {
            log.warn(
                "Invalid {s} value {d} (must be 0.0-1.0 or 0-100%), using default",
                .{ key, f },
            );
            return default;
        }
        return f;
    }
    if (val.asScalar([]const u8)) |str|
        log.warn(
            "{s} value '{s}' is quoted; write it unquoted (e.g. {s} = 0.5), using default",
            .{ key, str, key },
        )
    else if (val != .array) // a non-string, non-number scalar (boolean, ...)
        log.warn(
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
    color.collectPalette(doc);
    const palette: *const std.StringHashMap(u32) = &doc.palette;
    inline for (knobs) |k| knob: {
        if (comptime k.requires.len > 0) {
            if (doc.getSection(k.requires) == null) break :knob;
        }
        var hit: ?struct { sec: *parser.Section, key: []const u8 } = null;
        for (k.places) |pl| {
            // Places probe in order; the FIRST section present in the document
            // wins and only its paired key spelling is read. Presence of
            // `[tiling.layouts.master-stack]` therefore makes flat `[tiling]`
            // master_count unrecognized, matching the old orelse chains.
            if (doc.getSection(pl.section)) |sec| {
                hit = .{ .sec = sec, .key = pl.key };
                break;
            }
        }
        const p = ptr(cfg, k.target);
        switch (k.kind) {
            .b => if (hit) |h| {
                if (h.sec.getAsOrWarn(bool, h.key)) |v| p.* = v;
            },
            .int => |spec| if (hit) |h| {
                p.* = getInRange(spec.T, h.sec, h.key, p.*, if (spec.min) |m| @as(spec.T, m) else null, if (spec.max) |m| @as(spec.T, m) else null);
            },
            .scalable => |min| if (hit) |h| {
                if (getScalableInRange(h.sec, h.key, p.*, min, "default")) |v| p.* = v;
            },
            .scalable_free => if (hit) |h| {
                if (h.sec.getAsOrWarn(types.ScalableValue, h.key)) |v| p.* = v;
            },
            .auto_scalable => if (hit) |h| {
                p.* = getScalableInRange(h.sec, h.key, null, 0, "auto");
            },
            .color => if (hit) |h| {
                if (h.sec.get(h.key)) |val|
                    p.* = color.getColorFromValue(h.key, val, p.*, palette);
            },
            .color_from => |sibling| {
                const fallback = @field(cfg.bar, sibling);
                if (hit) |h| {
                    p.* = if (h.sec.get(h.key)) |val|
                        color.getColorFromValue(h.key, val, fallback, palette)
                    else
                        fallback;
                } else if (comptime k.copy_when_absent) {
                    p.* = fallback;
                }
            },
            .color_opt => |sibling| if (hit) |h| {
                if (h.sec.get(h.key)) |val|
                    p.* = color.getColorFromValue(h.key, val, @field(cfg.bar, sibling), palette);
            },
            .ratio => if (hit) |h| {
                p.* = getRatio(true, h.sec, h.key, p.*);
            },
            .ratio_strict => if (hit) |h| {
                p.* = getRatio(false, h.sec, h.key, p.*);
            },
            .str => if (hit) |h| {
                if (h.sec.getAsOrWarn([]const u8, h.key)) |val| try assignStr(allocator, p, val);
            },
            .opt_float => |spec| if (hit) |h| {
                if (h.sec.getAsOrWarn(f32, h.key)) |v| {
                    // Out of range warns and leaves the field null, i.e. the
                    // user gets detection rather than a silent absurd value.
                    if (v < spec.min or v > spec.max) {
                        log.warn(
                            "{s}.{s} = {d} is outside {d}..{d}; ignoring and detecting instead",
                            .{ h.sec.name, h.key, v, spec.min, spec.max },
                        );
                    } else p.* = v;
                }
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
                        log.warn(
                            "Unknown {s} '{s}', using default '{s}'",
                            .{ h.key, s, er.default_label },
                        );
                    }
                }
            },
        }
    }
    try bar_properties.applyBarProperties(knobs, allocator, doc, cfg);
}
