//! Knob vocabulary + the generic reflection engine + the comptime coverage
//! helper. Every scalar config knob is declared exactly once, as data, in the
//! fragment table that owns its field (`tiling_config.knobs`, `bar_config.knobs`,
//! ...); this module owns the shared vocab (`Placement`/`Kind`/`Knob` and the
//! table-literal builders) and the engine that applies any such table onto
//! its fragment root. Targets are always relative to the fragment root the
//! table is applied to -- the fragment root IS the subsystem config struct,
//! so a bar knob reads `target = "bg"`, not `"bar.bg"`.
//!
//! The comptime contract each fragment runs on its own table (`validateTable`)
//! turns three schema-wide requirements into per-fragment checks: every target
//! names a real field, every scalar leaf is either a knob target or listed
//! bespoke, and every `needs` dependency is supplied by an earlier knob in the
//! same table.

const std = @import("std");
const log = std.log.scoped(.knob);
const parser = @import("parser");
const types = @import("types");
const scaling = @import("scaling");
const color = @import("color");

/// The knob table vocabulary: Placement, the table-literal builders, Kind, Knob.
/// One accepted location for a knob: a section name and the key spelling
/// used inside it.
pub const Placement = struct {
    section: []const u8,
    key: []const u8,
};

/// Table-literal shorthand so entries stay one-liner-readable.
pub fn place(section: []const u8, key: []const u8) Placement {
    return .{ .section = section, .key = key };
}

/// Plain knob with no `requires` gate.
pub fn knob(places: []const Placement, target: []const u8, kind: Kind) Knob {
    return .{ .places = places, .target = target, .kind = kind };
}

/// Knob gated on `requires` (whole knob skipped unless that section exists).
pub fn knobGated(places: []const Placement, target: []const u8, kind: Kind, requires: []const u8) Knob {
    return .{ .places = places, .target = target, .kind = kind, .requires = requires };
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
///
/// Flat on purpose: each variant is ONE read-and-warn policy, dispatched in
/// one arm of applyAll's switch. Folding the near-neighbours together (the
/// three color variants, `ratio`/`ratio_strict`, `scalable`/`scalable_free`)
/// would trade those arms for a flag apiece and push the branching back
/// inside them -- more to read at the call site, not less.
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
    /// Color defaulting to the CURRENT value of a named sibling field of the
    /// SAME fragment root (e.g. run_bg->bg, title->primary_color);
    /// `copy_when_absent` also assigns it when the knob's section is absent.
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
    /// Dotted path from the fragment root to the field this knob feeds.
    target: []const u8,
    kind: Kind,
    /// When non-empty the whole knob is skipped unless this section exists
    /// (the gates mirror the parsers' own missing-section returns).
    requires: []const u8 = "",
    /// Assign the fallback default even when no placement matched.
    copy_when_absent: bool = false,
    /// Targets this knob READS to resolve its value (the sibling a
    /// `color_from`/`color_opt` kind falls back to), by dotted path relative
    /// to the fragment root. This is the ORDERING constraint stated as data:
    /// without it, a knob moved up or a sibling renamed would silently read
    /// the DEFAULT value instead of the configured one -- the knob still
    /// parsed, the color was just wrong, and only a visual diff of the bar
    /// would show it. `validateTable` turns the ordering into a build
    /// failure.
    needs: []const []const u8 = &.{},
};

/// Type/value walks into a fragment root by dotted path.
/// Resolves a dotted path from `root` to the FIELD TYPE it names, or null
/// when any step is missing. Comptime only -- the path is always a comptime
/// string built by the knob builders, never a runtime value.
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
            // ScalableValue IS a struct, and treating it as a waypoint would
            // make every size/percentage knob look like a dangling path.
            if (it.peek() == null) return t;
            // Otherwise a struct continues the walk and anything else means
            // the path went deeper than the type allows.
            if (@typeInfo(t) == .@"struct" and t != f64) {
                cur = t;
            } else return null;
        }
        return null;
    }
}

/// The field type at the dotted `path`, or a build failure when it names
/// nothing: the declaration-time validity of a target is established by
/// `validateTable`; this is the same walk for a path whose validity the
/// table already established.
pub fn FieldType(comptime T: type, comptime path: []const u8) type {
    comptime {
        // One instantiation per distinct knob target, each walking the struct
        // fields per segment: the shared comptime budget has to cover them
        // all, so this is a ceiling on work, not on depth.
        @setEvalBranchQuota(50_000);
        return fieldTypeAt(T, path) orelse @compileError(
            "knob: '" ++ path ++ "' does not name a field of " ++ @typeName(T),
        );
    }
}

/// Mutable pointer to `base`'s field at the dotted `path`.
inline fn walkPtr(comptime T: type, base: *T, comptime path: []const u8) *FieldType(T, path) {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |d| {
        const head = path[0..d];
        const H = @TypeOf(@field(@as(T, undefined), head));
        return walkPtr(H, &@field(base, head), path[d + 1 ..]);
    }
    return &@field(base, path);
}

/// Read-only view of `base`'s field at the dotted `path`.
inline fn walkVal(comptime T: type, base: *const T, comptime path: []const u8) FieldType(T, path) {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    if (dot) |d| {
        const head = path[0..d];
        const H = @TypeOf(@field(@as(T, undefined), head));
        return walkVal(H, &@field(base, head), path[d + 1 ..]);
    }
    return @field(base, path);
}

/// Read-only view of a fragment's target field (a read-only test seam for
/// the per-fragment tables, the mirror of applyAll's assignment).
pub fn value(comptime CfgT: type, cfg: *const CfgT, comptime path: []const u8) FieldType(CfgT, path) {
    return walkVal(CfgT, cfg, path);
}

/// Comptime table contract.
/// True when `t` names a field whose value is a plain scalar the knob tables
/// are expected to own: bool, int, float, or one of the config value types.
/// Containers (ArrayList, maps) and nested structs are excluded -- they are
/// the bespoke cases, declared per fragment.
fn isScalarLeaf(comptime t: type) bool {
    if (t == types.ScalableValue or t == types.Color) return true;
    return switch (@typeInfo(t)) {
        // Owned string leaves: `[]const u8` slices (and their optionals)
        // count as scalars a knob may own.
        .optional => |o| o.child == []const u8,
        .pointer => |p| p.size == .slice and p.child == u8,
        // Enums are config-visible leaves too: a layout/gap enum nobody
        // parses is dead in exactly the same way an int nobody parses is.
        .@"enum", .bool, .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

/// The comptime contract every fragment runs on its OWN table, with its OWN
/// Config as the root:
///   1. every knob target names a real field (otherwise a typo in a builder's
///      target string produces a knob that parses, validates and assigns into
///      nothing at all -- the config key works, the value goes nowhere, and
///      no build fails);
///   2. every scalar leaf is either a knob target or listed `bespoke`
///      (otherwise it compiles, it parses, and it is always at its
///      initializer -- a DEAD field);
///   3. every bespoke entry names a real field (a stale exemption would
///      quietly let a future rename escape check 2);
///   4. every `needs` dependency is supplied by an EARLIER knob in the same
///      table (the base-colors-before-the-color_from-chain rule, checked).
pub fn validateTable(
    comptime CfgT: type,
    comptime knobs: []const Knob,
    comptime bespoke: []const []const u8,
) void {
    comptime {
        @setEvalBranchQuota(400_000);
        for (knobs) |k| {
            if (fieldTypeAt(CfgT, k.target) == null) @compileError(
                "knob table: target '" ++ k.target ++ "' does not name a field of " ++ @typeName(CfgT),
            );
        }
        // Plain comptime string accumulation, not an ArrayList: this runs in
        // a container-scope `comptime` block where a method call on a local
        // list resolves to the UNBOUND `append(list, item)` and reports a
        // bogus arity error only once a dead field actually makes the line
        // reachable.
        var unclaimed: []const u8 = "";
        var unclaimed_n: usize = 0;
        for (std.meta.fields(CfgT)) |f| {
            if (!isScalarLeaf(f.type)) continue;
            const path = f.name;
            var covered = false;
            for (knobs) |k| {
                if (std.mem.eql(u8, k.target, path)) covered = true;
            }
            for (bespoke) |b| {
                if (std.mem.eql(u8, b, path)) covered = true;
            }
            if (!covered) {
                unclaimed = unclaimed ++ path ++ ", ";
                unclaimed_n += 1;
            }
        }
        if (unclaimed_n != 0) @compileError(
            "knob table for " ++ @typeName(CfgT) ++ ": " ++
                std.fmt.comptimePrint("{d}", .{unclaimed_n}) ++
                " config fields are neither a knob target nor listed bespoke, " ++
                "so no code path would ever write them (they would be dead): " ++ unclaimed,
        );
        for (bespoke) |b| {
            if (fieldTypeAt(CfgT, b) == null) @compileError(
                "knob table bespoke entry: '" ++ b ++ "' does not name a field of " ++ @typeName(CfgT),
            );
        }
        for (knobs, 0..) |k, i| {
            for (k.needs) |needed| {
                var found: bool = false;
                for (knobs, 0..) |producer, j| {
                    if (j < i and std.mem.eql(u8, producer.target, needed)) found = true;
                }
                if (!found) @compileError(
                    "knob table: knob '" ++ k.target ++ "' reads '" ++ needed ++
                        "', which no EARLIER knob supplies; move that knob above it " ++
                        "(or fix the sibling name)",
                );
            }
        }
    }
}

/// Generic readers.
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
            if (i < 0 or i > 100) {
                log.warn("Invalid {s} value {} (must be 0-100), using default", .{ key, i });
                return default;
            }
            if (i == 1) {
                // `= 1` is ambiguous (1% or 1.0); per the "bare integers are
                // percentages" rule it resolves to 1%, but we warn so a user who
                // meant the full value writes `1.0` or `100%`.
                log.warn("{s} value 1 is ambiguous (1% or 1.0 ratio?); " ++
                    "treating as 1%. Use '1.0' or '100%' for 100%.", .{key});
                return 0.01;
            }
            return @as(f32, @floatFromInt(i)) / 100.0;
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

/// The engine: applies one fragment's knob table onto its root.
/// Applies every knob of `knobs` from a parsed Document onto `cfg` (a
/// fragment root). The single table-driven scalar pass; OOM from string
/// dupes propagates; everything else warns-and-reverts in place. The
/// document-global palette must already be collected (`color.collectPalette`)
/// before color knobs read. This does NOT lint the document and does NOT run
/// any bespoke tail -- those belong to the caller (composed.parse lints;
/// each fragment appends its own tables).
pub fn applyAll(
    comptime CfgT: type,
    doc: *parser.Document,
    allocator: std.mem.Allocator,
    cfg: *CfgT,
    comptime knobs: []const Knob,
) !void {
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
            // master_count unrecognized.
            if (doc.getSection(pl.section)) |sec| {
                hit = .{ .sec = sec, .key = pl.key };
                break;
            }
        }
        const p = walkPtr(CfgT, cfg, k.target);
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
                const fallback = walkVal(CfgT, cfg, sibling);
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
                    p.* = color.getColorFromValue(h.key, val, walkVal(CfgT, cfg, sibling), palette);
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
}
