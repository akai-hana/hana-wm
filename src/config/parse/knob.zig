//! Knob vocabulary + the generic reflection engine + the comptime coverage
//! helper. Every scalar config knob is declared once, as data, in the fragment
//! table that owns its field; this module owns the shared vocab and the engine
//! that applies any table onto its fragment root (targets relative to that
//! root: a bar knob reads `target = "bg"`, not `"bar.bg"`).
//!
//! `validateTable` turns three schema-wide requirements into per-fragment
//! comptime checks: every target names a real field, every scalar leaf is
//! either a knob target or listed bespoke, and every `needs` dependency is
//! supplied by an earlier knob in the same table.

const std = @import("std");
const log = std.log.scoped(.knob);
const parser = @import("parser");
const types = @import("types");
const scaling = @import("scaling");
const color = @import("color");

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

/// Knob whose only reader is the optional module `reader`: the build may
/// delete the module, and the knob goes with it rather than looking dead.
pub fn readerOf(places: []const Placement, target: []const u8, kind: Kind, reader: []const u8) Knob {
    return .{ .places = places, .target = target, .kind = kind, .reader = reader };
}

/// Knob both gated on `requires` and owned by the optional module `reader`.
pub fn readerOfGated(places: []const Placement, target: []const u8, kind: Kind, requires: []const u8, reader: []const u8) Knob {
    return .{ .places = places, .target = target, .kind = kind, .requires = requires, .reader = reader };
}

/// How an enum-valued knob is parsed.
pub const EnumRead = struct {
    T: type,
    /// true = case-insensitive lookup through types.enumFromString (the alias
    /// map, e.g. MasterSide's "l"/"left"); false = exact-case stringToEnum.
    ci: bool = false,
    /// Warn (mentioning `default_label`) when the value doesn't parse;
    /// otherwise fall back silently. Either way the field keeps its default.
    warn: bool = false,
    default_label: []const u8 = "",
};

/// What kind of value a knob accepts, and which reader enforces it.
///
/// Flat on purpose: each variant is ONE read-and-warn policy, dispatched in
/// one arm of applyAll's switch. Folding the near-neighbours together would
/// trade those arms for a flag apiece and push the branching back inside
/// them -- more to read at the call site, not less.
pub const Kind = union(enum) {
    b,
    /// Integer with optional inclusive bounds (warn-and-revert outside).
    int: struct { T: type, min: ?comptime_int = null, max: ?comptime_int = null },
    /// ScalableValue (px or %) rejecting negative raw .value with a warning.
    scalable: f32,
    /// Assigned whenever present, NO local bound (master_width: validate()
    /// owns the ratio/negative policy).
    scalable_free,
    /// Optional ScalableValue; absent means "auto", a negative warns back to auto.
    auto_scalable,
    /// Color accepting #RRGGBB / 0xRRGGBB / integer.
    color,
    /// Color defaulting to the CURRENT value of a named sibling field of the
    /// SAME fragment root (e.g. run_bg->bg); `copy_when_absent` also assigns
    /// it when the knob's section is absent.
    color_from: []const u8,
    /// Like color_from, but assigned only when the KEY itself exists.
    color_opt: []const u8,
    /// [0,1] ratio: bare integers are percentages, `1` resolves to 1% with a warning.
    ratio,
    /// [0,1] ratio that rejects bare integers (only a decimal or `%` parses);
    /// `transparency` uses this so `= 1` can never be misread as 1%.
    ratio_strict,
    /// Optional heap-dup'd string; absent leaves the field untouched.
    str,
    /// Optional float; absent = null ("auto"). Out-of-range warns and reverts
    /// to absent, matching `int`.
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
    /// When non-empty the whole knob is skipped unless this section exists.
    requires: []const u8 = "",
    /// Assign the fallback default even when no placement matched.
    copy_when_absent: bool = false,
    /// Module stem whose source reads this target (e.g. "tags"). Non-empty
    /// means the knob's only reader lives in that OPTIONAL module: the build
    /// excuses it when the tree lacks the module. Pinned to the fragment's
    /// `knob_reader_modules` entry by `validateOwnership`, so a typo in
    /// either table is a build error. Empty means "a reader must exist".
    reader: []const u8 = "",
    /// Targets this knob READS to resolve its value (the sibling a
    /// `color_from` falls back to), by dotted path. The ORDERING constraint
    /// as data: without it a knob moved up would silently read the DEFAULT
    /// instead of the configured sibling. `validateTable` makes it a build
    /// failure.
    needs: []const []const u8 = &.{},
};

/// Resolves a dotted path from `root` to the FIELD TYPE it names, or null
/// when any step is missing. Comptime only.
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
            // Last segment is the answer even when its type is a struct
            // (ScalableValue IS one); treating it as a waypoint would make
            // every size knob look like a dangling path.
            if (it.peek() == null) return t;
            if (@typeInfo(t) == .@"struct" and t != f64) {
                cur = t;
            } else return null;
        }
        return null;
    }
}

/// The field type at the dotted `path`, or a build failure when it names
/// nothing: declaration-time validity is established by `validateTable`.
pub fn FieldType(comptime T: type, comptime path: []const u8) type {
    comptime {
        // Ceiling on comptime work, not depth: one instantiation per target.
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

/// Read-only view of a fragment's target field (a read-only test seam, the
/// mirror of applyAll's assignment).
pub fn value(comptime CfgT: type, cfg: *const CfgT, comptime path: []const u8) FieldType(CfgT, path) {
    return walkVal(CfgT, cfg, path);
}

/// True when `t` names a field a knob table may own: bool, int, float, a
/// config value type, a string slice, or an enum. Containers and nested
/// structs are excluded -- they are the bespoke cases, declared per fragment.
fn isScalarLeaf(comptime t: type) bool {
    if (t == types.ScalableValue or t == types.Color) return true;
    return switch (@typeInfo(t)) {
        .optional => |o| o.child == []const u8,
        .pointer => |p| p.size == .slice and p.child == u8,
        .@"enum", .bool, .int, .float, .comptime_int, .comptime_float => true,
        else => false,
    };
}

/// The comptime contract every fragment runs on its OWN table, with its OWN
/// Config as the root:
///   1. every knob target names a real field (a typo otherwise parses and
///      assigns into nothing -- no build fails);
///   2. every scalar leaf is either a knob target or listed `bespoke`
///      (otherwise it stays at its initializer forever -- a DEAD field);
///   3. every bespoke entry names a real field (a stale exemption would let
///      a future rename escape check 2);
///   4. every `needs` dependency is supplied by an EARLIER knob in the same
///      table (the base-colors-before-the-color_from-chain rule).
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
        // Plain comptime string accumulation, not an ArrayList: a method call
        // on a local list resolves to the UNBOUND `append` in a
        // container-scope comptime block and reports a bogus arity error.
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

/// The comptime contract between a fragment's knob table and its
/// `knob_reader_modules` ownership pairs (the build's text scan reads the
/// pairs to excuse a module-owned knob when the tree lacks the module):
///   1. every pair names a target of the same fragment's knob table;
///   2. the pair's stem equals the `reader` the knob entry declares, so a
///      typo in EITHER table fails the build;
///   3. every knob with a non-empty `reader` has a pair, so the excusal
///      table can never lag the knob table.
pub fn validateOwnership(
    comptime knobs: []const Knob,
    comptime pairs: []const [2][]const u8,
    comptime frag: []const u8,
) void {
    comptime {
        @setEvalBranchQuota(100_000);
        for (pairs) |pair| {
            const target = pair[0];
            const stem = pair[1];
            var matched = false;
            for (knobs) |k| {
                if (!std.mem.eql(u8, k.target, target)) continue;
                matched = true;
                if (!std.mem.eql(u8, k.reader, stem)) @compileError(
                    frag ++ ": knob_reader_modules owns '" ++ target ++ "' to '" ++ stem ++
                        "', but the knob table declares reader '" ++ k.reader ++
                        "'; one of the two is a typo",
                );
            }
            if (!matched) @compileError(
                frag ++ ": knob_reader_modules names '" ++ target ++
                    "', which is not a target of the knob table; a stale entry " ++
                    "would excuse a knob that is now dead",
            );
        }
        for (knobs) |k| {
            if (k.reader.len == 0) continue;
            var claimed = false;
            for (pairs) |pair| {
                if (std.mem.eql(u8, pair[0], k.target)) claimed = true;
            }
            if (!claimed) @compileError(
                frag ++ ": knob '" ++ k.target ++ "' is owned by module '" ++ k.reader ++
                    "' but has no knob_reader_modules entry, so the build cannot " ++
                    "excuse it when that module is deleted",
            );
        }
    }
}

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
    comptime {
        switch (@typeInfo(T)) {
            .int => |i| if (i.bits > 64) @compileError(
                "int knob wider than 64 bits: " ++ @typeName(T),
            ),
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        }
    }
    const i = section.getAsOrWarn(i64, key) orelse return default;
    // The type's own span, checked BEFORE the cast so no @intCast trap is
    // reachable: minInt fits i64 for every int (unsigned minInt is 0);
    // maxInt is clamped because u64's does not. Then the knob's min/max.
    const lo: i64 = std.math.minInt(T);
    const hi: i64 = @min(std.math.maxInt(T), std.math.maxInt(i64));
    if (i < lo) return reject(i64, key, i, "below minimum", lo, default);
    if (i > hi) return reject(i64, key, i, "above maximum", hi, default);
    const val: T = @intCast(i);
    if (comptime min) |m| if (val < m) return reject(T, key, val, "below minimum", m, default);
    if (comptime max) |m| if (val > m) return reject(T, key, val, "above maximum", m, default);
    return val;
}

/// Reads `section.key` as a ScalableValue, warn-and-return-`default` below
/// `min`. `fallback_label` names the fallback in the warning ("default" or
/// "auto"). Only a lower bound on the raw `.value` is enforced (no meaningful
/// ceiling), enough to reject a negative like `gap_width = -50`.
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
/// when the key is absent or out of range.
///
/// `ints_are_percent` selects the bare-integer policy: the legacy one
/// (`.ratio`) reads a bare integer as a percentage 0-100 (`= 1` resolving to
/// 1% with a warning); the strict one (`.ratio_strict`) rejects bare integers
/// outright, so `transparency = 1` reverts to the default instead of being
/// misread as 1% while `= 1.0` means 100%.
fn getRatio(comptime ints_are_percent: bool, section: *parser.Section, key: []const u8, default: f32) f32 {
    const val = section.get(key) orelse return default;
    if (val.asScalar(i64)) |i| {
        if (comptime ints_are_percent) {
            if (i < 0 or i > 100) {
                log.warn("Invalid {s} value {} (must be 0-100), using default", .{ key, i });
                return default;
            }
            if (i == 1) {
                // Ambiguous (1% or 1.0); resolves to 1% per the percentages
                // rule, but warn so a user who meant 1.0 writes `1.0`/`100%`.
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
/// owned string unconditionally. Dupe BEFORE free: the key-absent fallback
/// passes `view.*` as `val`.
pub fn assignStr(allocator: std.mem.Allocator, view: *?[]const u8, val: []const u8) !void {
    const copy = try allocator.dupe(u8, val);
    if (view.*) |old| allocator.free(old);
    view.* = copy;
}

/// Applies every knob of `knobs` from a parsed Document onto `cfg` (a
/// fragment root). The single table-driven scalar pass; OOM from string dupes
/// propagates; everything else warns-and-reverts in place. The
/// document-global palette must already be collected before color knobs read.
/// Does NOT lint the document or run any bespoke tail -- the caller's job.
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
            // First section present wins; only its paired key spelling is read
            // (presence of `[tiling.layouts.master-stack]` makes flat
            // `[tiling]` master_count unrecognized).
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
                    // Out of range warns and leaves the field null (auto).
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

// ---------------------------------------------------------------------------
// The knob schema dump backing `hana --dump-config-schema`.
//
// The tables are comptime data with a validated contract; this renders them
// -- plus each field's default, which lives in the fragment root's field
// initializers rather than in the table -- to a machine-readable JSON array
// at COMPILE time. The flag is then a print of one constant string: no
// config is loaded, no file is read, no display or diagnostics are needed,
// and every build mode sees the identical inventory.
// ---------------------------------------------------------------------------

/// One knob's schema row. `places` are the accepted `section.key` spellings
/// (first-present-wins at parse time); `default`, `range` and `values` are
/// pre-rendered JSON (null/number/bool bare, strings quoted+escaped).
pub const SchemaEntry = struct {
    places: []const []const u8,
    target: []const u8,
    type_label: []const u8,
    default: []const u8,
    range: []const u8,
    values: []const []const u8,
    requires: []const u8,
    reader: []const u8,
};

/// A fragment's knob table paired with the root type that owns the field
/// defaults the dump reports (the table itself carries no defaults).
pub const SchemaTable = struct {
    root: type,
    knobs: []const Knob,
};

/// Collects every table's entries in declaration order -- core first, then
/// the discovered fragments in owner order; the generated composed module
/// passes exactly that list. A fragment without a `knobs` decl contributes
/// none, so deleting an optional subsystem shortens the inventory with the
/// rest of its config trace.
pub fn collectSchema(comptime tables: []const SchemaTable) []const SchemaEntry {
    comptime {
        @setEvalBranchQuota(400_000);
        var out: []const SchemaEntry = &.{};
        for (tables) |t| {
            for (t.knobs) |k| {
                out = out ++ &[_]SchemaEntry{schemaEntry(t.root, k)};
            }
        }
        return out;
    }
}

/// The inventory as a pretty JSON array, one object per knob. Comptime, so
/// the flag's runtime cost is a single write of a constant string.
pub fn schemaJson(comptime entries: []const SchemaEntry) []const u8 {
    comptime {
        @setEvalBranchQuota(400_000);
        var s: []const u8 = "[\n";
        for (entries, 0..) |e, i| {
            s = s ++ "  {\"places\":[";
            for (e.places, 0..) |p, pi| {
                if (pi != 0) s = s ++ ",";
                s = s ++ jsonString(p);
            }
            s = s ++ "],\"target\":" ++ jsonString(e.target) ++
                ",\"type\":" ++ jsonString(e.type_label) ++
                ",\"default\":" ++ e.default ++
                ",\"range\":" ++ jsonString(e.range) ++
                ",\"values\":[";
            for (e.values, 0..) |v, vi| {
                if (vi != 0) s = s ++ ",";
                s = s ++ jsonString(v);
            }
            s = s ++ "],\"requires\":" ++ jsonString(e.requires) ++
                ",\"reader\":" ++ jsonString(e.reader) ++ "}";
            if (i + 1 != entries.len) s = s ++ ",";
            s = s ++ "\n";
        }
        return s ++ "]";
    }
}

/// One row: every accepted spelling, the value family, the rendered default,
/// the local range, and the enum's allowed spellings (empty otherwise).
fn schemaEntry(comptime root: type, comptime k: Knob) SchemaEntry {
    comptime {
        var places: []const []const u8 = &.{};
        for (k.places) |p| {
            places = places ++ &[_][]const u8{
                if (p.section.len == 0) p.key else p.section ++ "." ++ p.key,
            };
        }
        var proto: root = .{};
        const v = value(root, &proto, k.target);
        return .{
            .places = places,
            .target = k.target,
            .type_label = typeLabel(k.kind),
            .default = fmtDefault(k.kind, @TypeOf(v), v),
            .range = rangeOf(k.kind),
            .values = valueLabels(k.kind),
            .requires = k.requires,
            .reader = k.reader,
        };
    }
}

/// The TOML-level value family: what the user may spell for this knob.
fn typeLabel(comptime kind: Kind) []const u8 {
    return switch (kind) {
        .b => "bool",
        .int => "int",
        .str => "string",
        .opt_float => "float",
        .scalable, .scalable_free, .auto_scalable => "scalable",
        .color, .color_from, .color_opt => "color",
        .ratio, .ratio_strict => "ratio",
        .enum_read => "enum",
    };
}

/// Inclusive bounds as "min..max" (absent side omitted), "" when the kind
/// has no local bound (the policy lives in validate() instead).
fn rangeOf(comptime kind: Kind) []const u8 {
    return switch (kind) {
        .int => |i| if (i.min != null and i.max != null)
            std.fmt.comptimePrint("{d}..{d}", .{ i.min.?, i.max.? })
        else if (i.min != null)
            std.fmt.comptimePrint("{d}..", .{i.min.?})
        else if (i.max != null)
            std.fmt.comptimePrint("..{d}", .{i.max.?})
        else
            "",
        .opt_float => |f| std.fmt.comptimePrint("{d}..{d}", .{ f.min, f.max }),
        .ratio, .ratio_strict => "0..1",
        else => "",
    };
}

/// The enum type's variant names, the spellings an `enum_read` knob accepts
/// (exact-case spelling; `ci` aliases resolve case-insensitively on top).
/// Empty for every non-enum kind.
fn valueLabels(comptime kind: Kind) []const []const u8 {
    return switch (kind) {
        .enum_read => |er| comptime blk: {
            var out: []const []const u8 = &.{};
            for (std.meta.fields(er.T)) |f| out = out ++ &[_][]const u8{f.name};
            break :blk out;
        },
        else => &.{},
    };
}

/// One default as a JSON token: strings quoted+escaped, null/bool/numbers
/// bare, enums by tag, ScalableValue in its TOML spelling ("24" / "50%"),
/// colors as "0xRRGGBB" (the spelling the knob itself accepts).
fn fmtDefault(comptime kind: Kind, comptime T: type, comptime v: T) []const u8 {
    comptime {
        const is_color = switch (kind) {
            .color, .color_from, .color_opt => true,
            else => false,
        };
        return switch (@typeInfo(T)) {
            .bool => if (v) "true" else "false",
            .int => if (is_color)
                std.fmt.comptimePrint("\"0x{x:0>6}\"", .{v})
            else
                std.fmt.comptimePrint("{d}", .{v}),
            .float => std.fmt.comptimePrint("{d}", .{v}),
            .optional => if (v) |inner| fmtDefault(kind, @TypeOf(inner), inner) else "null",
            .@"enum" => jsonString(@tagName(v)),
            .pointer => jsonString(v),
            .@"struct" => if (T == types.ScalableValue)
                jsonString(if (v.is_percentage)
                    std.fmt.comptimePrint("{d}%", .{v.value})
                else
                    std.fmt.comptimePrint("{d}", .{v.value}))
            else
                @compileError("knob schema: unsupported default type " ++ @typeName(T)),
            else => @compileError("knob schema: unsupported default type " ++ @typeName(T)),
        };
    }
}

/// A JSON string token: quoted, with the escapes a config value can need.
fn jsonString(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "\"";
        for (s) |c| {
            const piece: []const u8 = switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => if (c < 0x20) std.fmt.comptimePrint("\\u{x:0>4}", .{c}) else &[_]u8{c},
            };
            out = out ++ piece;
        }
        return out ++ "\"";
    }
}
