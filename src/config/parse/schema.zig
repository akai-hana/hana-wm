//! Comptime config schema: the reflection engine over the knob table.
//! The table itself (plus the `Placement`/`Kind`/`Knob` vocabulary the
//! entries are built from) lives in `knobs.zig` and is re-exported here,
//! driving defaults, interpretation, and the schema tests.
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
const knobs_mod = @import("knobs");

// The knob table -- and the `Placement`/`Kind`/`Knob` vocabulary it is
// built from -- lives in `knobs.zig`. Re-exported here so the engine
// below, `bar_properties.applyBarProperties`, and the `schema.knobs`
// test seam keep one import.
pub const knobs = knobs_mod.knobs;

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

/// The config subtrees the coverage pass enumerates, as prefix + type. Knob
/// targets themselves always resolve from `types.Config` (whose nested fields
/// ARE these subtrees), so the prefixes exist to spell the full path of a
/// subtree field in the coverage report -- a target is written relative to its
/// subtree (`gap_width`, `bar.bg`) EXCEPT for the handful of top-level Config
/// knobs (`snap_distance`, `fullscreen_enabled`), which carry no prefix.
const coverage_subtrees = [_]struct { prefix: []const u8, ty: type }{
    .{ .prefix = "", .ty = types.Config },
    .{ .prefix = "tiling.", .ty = types.TilingConfig },
    .{ .prefix = "bar.", .ty = types.BarConfig },
    .{ .prefix = "workspaces.", .ty = types.WorkspaceConfig },
};

/// Resolves a knob target (a dotted path from `types.Config`) to its field
/// type, or null when any step is missing.
fn resolveTarget(comptime target: []const u8) ?type {
    return fieldTypeAt(types.Config, target);
}

/// True when `path` names a field whose value is a plain scalar the schema
/// knobs are expected to own: bool, int, float, or one of the config value
/// types. Containers (ArrayList, maps) and nested structs are excluded -- they
/// are the bespoke cases, declared below.
fn isScalarLeaf(comptime t: type) bool {
    if (t == types.ScalableValue or t == types.Color) return true;
    return switch (@typeInfo(t)) {
        // Owned string leaves: `[]const u8` slices (and their optionals)
        // count as scalars a knob may own.
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
const bespoke_fields = [_][]const u8{
    "bar.indicator_focused",
    "bar.indicator_unfocused",
};

comptime {
    // 55 knobs x dotted-path field walks, plus the coverage pass below.
    @setEvalBranchQuota(400_000);
    // Every knob target must name a REAL field. A renamed field, or a typo in
    // a builder's target string, previously produced a knob that parsed,
    // validated and assigned into nothing at all -- the config key worked, the
    // value went nowhere, and no build failed.
    for (knobs) |k| {
        if (resolveTarget(k.target) == null) @compileError(
            "schema.knobs: target '" ++ k.target ++ "' does not name a field of Config",
        );
    }

    // The reverse: a scalar field of Config or one of its subtrees that no knob
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
    for (coverage_subtrees) |r| {
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
            "schema.bespoke_fields: '" ++ b ++ "' does not name a field of Config",
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

// Value-level access into Config by dotted path.
//
// `fieldTypeAt` is the one TYPE walk; these walk the VALUE the same way, one
// segment per recursion step, so a path of any depth resolves identically on
// both sides.

/// The field type at the dotted `path`, or a build failure when it names
/// nothing: the mirror of `fieldTypeAt` for a path whose validity the knob
/// table already established at declaration time.
fn FieldType(comptime T: type, comptime path: []const u8) type {
    comptime {
        // One instantiation per distinct knob target (55+), each walking the
        // struct fields per segment: the shared comptime budget has to cover
        // them all, so this is a ceiling on work, not on depth.
        @setEvalBranchQuota(50_000);
        return fieldTypeAt(T, path) orelse @compileError(
            "schema: '" ++ path ++ "' does not name a field of " ++ @typeName(T),
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

/// Mutable pointer to a knob's target field.
fn ptr(cfg: *types.Config, comptime path: []const u8) *FieldType(types.Config, path) {
    return walkPtr(types.Config, cfg, path);
}

/// Read-only view of a knob's target field.
pub fn value(cfg: *const types.Config, comptime path: []const u8) FieldType(types.Config, path) {
    return walkVal(types.Config, cfg, path);
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

/// Applies every knob from a parsed Document: the single schema-driven scalar
/// pass over the document. OOM from string dupes
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
            // master_count unrecognized.
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
