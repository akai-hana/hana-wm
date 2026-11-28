//! The tiling config fragment: `Config` (the [tiling] subtree), its knob table,
//! the scalar parse, and the non-scalar structures (layouts array, per-layout
//! variants, master-stack counts). Also the parse/validate entry points the
//! generated `composed` dispatcher calls. Deleting this file (with the rest of
//! src/tiling/) removes the `tiling` field, every [tiling] knob, and all tiling
//! config vocabulary from the build. The scalar knobs below are applied by the
//! generic engine in `knob`.

const std = @import("std");
const model = @import("model");
const parser = @import("parser");
const scaling = @import("scaling");
const types = @import("types");
const knob = @import("knob");
const log = std.log.scoped(.tiling_config);
const layout_names = @import("layout_names");

/// Which side of the screen the master column occupies.
pub const MasterSide = enum {
    left,
    right,

    pub const string_map = std.StaticStringMap(MasterSide).initComptime(.{
        .{ "l", .left },
        .{ "left", .left },
        .{ "r", .right },
        .{ "right", .right },
    });
};

/// Per-workspace startup layout assignment, overriding the global default. variant
/// is null -> use the per-layout map default ([tiling].variants).
pub const WorkspaceLayoutOverride = struct {
    workspace_idx: model.WorkspaceId,
    layout_idx: u8, // index into Config.layouts
    variant: ?[]const u8, // null = use per-layout variants-map default
};

/// Per-workspace master count override, parsed from [tiling.layouts.master-stack.counts].
pub const WorkspaceMasterCountOverride = struct {
    workspace_idx: model.WorkspaceId,
    count: u8,
};

pub const Config = struct {
    layouts: std.ArrayList([]const u8) = .empty, // Available layouts in cycle order
    master_side: MasterSide = .left,
    master_width: types.ScalableValue = types.ScalableValue.percentage(50.0),
    master_count: u8 = 1,
    gap_width: types.ScalableValue = types.ScalableValue.absolute(10.0),
    border_width: types.ScalableValue = types.ScalableValue.absolute(2.0),
    border_focused: types.Color = types.default_focused_border,
    border_unfocused: types.Color = types.default_unfocused_border,
    /// Smallest on-screen width/height a tiled window (and floating drag resize) is
    /// allowed to reach, in pixels.
    min_window_dim: u16 = types.default_min_window_dim,

    // Per-layout variant preferences: placement policy as value-strings in a
    // canonical layout-name -> VALUE-STRING map (no closed per-layout enums; each
    // module interprets its strings via `variant_parse`). Both key and value are
    // heap-duped at parse so they outlive the document; deinit frees them.
    variants: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Per-workspace layout assignments parsed from the layouts array.
    workspace_layout_overrides: std.ArrayList(WorkspaceLayoutOverride) = .empty,

    /// Per-workspace master count overrides parsed from
    /// [tiling.layouts.master-stack.counts]. Only applied when global_layout = false.
    workspace_master_count_overrides: std.ArrayList(WorkspaceMasterCountOverride) = .empty,

    /// When true, layout changes apply globally across all workspaces instead of per
    /// workspace.
    global_layout: bool = false,

    /// Resolves the per-workspace master-count overrides into a fixed-size,
    /// workspace-indexed lookup with last-wins semantics (a duplicate entry
    /// overrides its predecessor). `null` means no override (use the global default).
    /// Consumed by seed.seedParamsFromConfig, so the last-wins rule lives in one
    /// place.
    pub fn masterCountLookup(self: *const Config) [model.max_workspaces]?u8 {
        var lookup: [model.max_workspaces]?u8 = .{null} ** model.max_workspaces;
        for (self.workspace_master_count_overrides.items) |o| {
            // One validity notion, not a second inline range test.
            if (o.workspace_idx.isValid())
                lookup[o.workspace_idx.index] = o.count;
        }
        return lookup;
    }

    /// The default layout name: the first entry of the layout cycle, or
    /// `canon_master_layout` when the cycle is empty. Derived, never stored.
    pub fn defaultLayout(self: *const Config) []const u8 {
        return if (self.layouts.items.len > 0) self.layouts.items[0] else types.canon_master_layout;
    }

    /// Resolves the per-workspace layout overrides into a fixed-size,
    /// workspace-indexed lookup of override indices with last-wins semantics (a
    /// duplicate entry overrides its predecessor). `null` means no override.
    /// Consumed by seed.seedParamsFromConfig, so the last-wins rule lives in one
    /// place.
    pub fn workspaceLayoutLookup(self: *const Config) [model.max_workspaces]?usize {
        var lookup: [model.max_workspaces]?usize = .{null} ** model.max_workspaces;
        for (self.workspace_layout_overrides.items, 0..) |o, oi| {
            if (o.workspace_idx.isValid())
                lookup[o.workspace_idx.index] = oi;
        }
        return lookup;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.layouts.items) |layout| allocator.free(layout);
        self.layouts.deinit(allocator);
        types.freeStringMap(&self.variants, allocator, types.free_storage);
        for (self.workspace_layout_overrides.items) |o| {
            if (o.variant) |v| allocator.free(v);
        }
        self.workspace_layout_overrides.deinit(allocator);
        self.workspace_master_count_overrides.deinit(allocator);
    }
};

/// Master-stack trio: dedicated-section short spelling wins over the flat [tiling]
/// spelling (section presence, not key presence, picks the spelling). Targets are
/// relative to THIS Config.
fn masterStack(dedicated_key: []const u8, flat_key: []const u8, kind: knob.Kind) knob.Knob {
    return .{
        .places = &.{ knob.place(types.section_tiling_layouts_master_stack, dedicated_key), knob.place(types.section_tiling, flat_key) },
        .target = flat_key,
        .kind = kind,
        .requires = types.section_tiling,
    };
}

/// Every tiling scalar knob, exactly once. ORDER MATTERS only for `needs` (none today),
/// which `validateTable` enforces.
pub const knobs = [_]knob.Knob{
    // [tiling]: functional knobs gated on the section itself -- a lone [tiling]
    // carrying only the aesthetics quartet (a theme file's shape) never fed these
    // knobs. (The quartet below is UNGATED: it's visual.)
    knob.knobGated(&.{knob.place(types.section_tiling, "global_layout")}, "global_layout", .b, types.section_tiling),
    knob.knobGated(&.{knob.place(types.section_tiling, "min_window_dim")}, "min_window_dim", .{ .int = .{ .T = u16, .min = 1 } }, types.section_tiling),

    // Aesthetics quartet: flat [tiling] spellings. UNGATED -- it's visual, so a
    // theme file may ship only these in a lone [tiling] with no functional key.
    knob.knob(&.{knob.place(types.section_tiling, "gap_width")}, "gap_width", .{ .scalable = 0.0 }),
    knob.knob(&.{knob.place(types.section_tiling, "border_width")}, "border_width", .{ .scalable = 0.0 }),
    // The two color knobs are read ONLY by the optional borders module; when that
    // module is deleted the settings are legitimately unread, so they carry the
    // ownership declaration (P2-47). border_width stays core-owned: core.borderWidth()
    // and the reconcile geometry read it regardless.
    knob.readerOf(&.{knob.place(types.section_tiling, "border_focused")}, "border_focused", .color, "borders"),
    knob.readerOf(&.{knob.place(types.section_tiling, "border_unfocused")}, "border_unfocused", .color, "borders"),

    // Master-stack trio: the dedicated section's shorter spellings win; flat
    // [tiling] keeps the flat spellings.
    masterStack("count", "master_count", .{ .int = .{ .T = u8, .min = 1 } }),
    masterStack("side", "master_side", .{ .enum_read = .{ .T = MasterSide, .ci = true } }),
    // No local bound: validate() owns master_width's ratio/negative policy.
    masterStack("width", "master_width", .scalable_free),
};

/// Module-owned knob readers (see `knob.readerOf` / `Knob.reader`): the two border
/// color knobs are read only by the optional borders module, so the build's
/// knob-reader scan excuses them on a tree that module has been deleted from (P2-47).
pub const knob_reader_modules = [_][2][]const u8{
    .{ "border_focused", "borders" },
    .{ "border_unfocused", "borders" },
};

comptime {
    knob.validateTable(Config, &knobs, &.{});
    knob.validateOwnership(&knobs, &knob_reader_modules, "tiling");
}

/// The section names the tiling subsystem owns (D13/P2-50): the composed facade unions
/// every fragment's list into the mis-case lint's inventory. The two master-stack
/// spellings are the shipped dedicated tables; other layout names arrive through the
/// `section_prefixes` family below, not as exact entries.
pub const sections = &[_][]const u8{
    types.section_tiling,
    types.section_tiling_layouts_master_stack,
    types.section_prefix_tiling_layouts ++ "master_stack",
};

/// Mis-case family: `[tiling.layouts.*]` is an open set (any registry layout name), so
/// a case-variant of the family gets the family warn rather than needing exact entries.
pub const section_prefixes = &[_][]const u8{types.section_prefix_tiling_layouts};

/// Inert family (D13/P2-50): `[tiling.*]` sub-tables are read only when bare
/// `[tiling]` is present; a present family with the parent missing leaves those knobs
/// inert, which the load warns about.
pub const inert_families = &[_]types.InertFamily{.{
    .parent = types.section_tiling,
    .child_prefix = types.section_prefix_tiling,
}};

/// `[tiling] layouts` accumulates the layout-name list by design (same list-reading
/// policy the layout cycle has always had); a scalar read takes the last declaration
/// without a "later wins" warn.
pub const accumulate_exempt = &[_]types.SectionKey{.{
    .section = types.section_tiling,
    .key = "layouts",
}};

/// The section HEADS whose presence in the embedded fallback TOML is gated on this
/// fragment's owner module (P2-50).
pub const fallback_sections = &[_][]const u8{"tiling"};

/// The fragment parse entry: self-seed the owned defaults (so an empty document still
/// yields a usable single-layout cycle), apply the scalar knobs, then parse the
/// non-scalar structures.
pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);
    try seedDefaultLayout(allocator, &cfg, types.canon_master_layout);
    try knob.applyAll(Config, doc, allocator, &cfg, &knobs);
    try parseTilingStructures(allocator, doc, &cfg);
    return cfg;
}

/// Range checks the knob engine does not own: master_width's ratio band (percentages
/// validate as a [min_master_width, max_master_width] ratio; pixels only as >= 0,
/// since the screen width for a ratio isn't available here and the runtime clamps).
/// Called by composed.parse.
pub fn validate(cfg: *const Config) !void {
    const mw = cfg.master_width;
    if (mw.is_percentage) {
        const mw_ratio: f32 = scaling.asRatio(mw);
        if (mw_ratio < model.min_master_width or mw_ratio > model.max_master_width) {
            log.err("Invalid config: master_width {d:.0}% out of [{d:.0}%, {d:.0}%]", .{
                mw_ratio * 100.0,
                model.min_master_width * 100.0,
                model.max_master_width * 100.0,
            });
            return error.InvalidConfig;
        }
    } else if (mw.value < 0.0) {
        log.err("Invalid config: master_width {d}px must be >= 0", .{mw.value});
        return error.InvalidConfig;
    }
}

// ---------------------------------------------------------------------------
// Non-scalar structures
// ---------------------------------------------------------------------------

/// Parses a 1-based workspace number from a bare token, warning with `fmt` on a
/// malformed token or a value outside 1..255 / `max` (callers embed the section name in
/// `fmt`), and returns null to skip it.
fn tryParseWsToken(tok: []const u8, max: usize, comptime fmt: []const u8, args: anytype) ?usize {
    const ws_1based = std.fmt.parseInt(usize, tok, 10) catch {
        log.warn(fmt, args);
        return null;
    };
    if (!types.workspaceInRange(ws_1based, max)) {
        log.warn(fmt, args);
        return null;
    }
    return ws_1based;
}

/// Appends one layout name (duped) to the tiling layout cycle -- the seed both the
/// default config and the single-layout parse path use.
pub fn seedDefaultLayout(allocator: std.mem.Allocator, cfg: *Config, name: []const u8) !void {
    const copy = try allocator.dupe(u8, name);
    cfg.layouts.append(allocator, copy) catch |err| {
        allocator.free(copy);
        return err;
    };
}

/// Upper bound for per-workspace master counts in `[tiling.layouts.master-stack.counts]`.
const max_master_count: u8 = 10;

/// Tiling's NON-scalar structures: the layouts array (cycle order + per-workspace
/// overrides), per-layout variant preferences, and master-stack counts. Every tiling
/// SCALAR is driven by schema.applyAll; all of it stays gated on the [tiling] section
/// existing.
pub fn parseTilingStructures(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *Config,
) !void {
    const section = doc.getSection(types.section_tiling) orelse return;
    types.freeStrings(&cfg.layouts, allocator, types.keep_capacity);
    cfg.workspace_layout_overrides.clearRetainingCapacity();
    types.freeStringMap(&cfg.variants, allocator, types.keep_capacity);
    if (section.getAsOrWarn([]const parser.Value, "layouts")) |arr| try parseLayoutsArray(allocator, arr, cfg) else {
        const layout_str = section.getAsOrWarn([]const u8, "layout") orelse types.canon_master_layout;
        try seedDefaultLayout(allocator, cfg, layout_names.canonicalLayoutName(layout_str));
    }
    try parseTilingLayoutSubtables(allocator, doc, cfg);
}

/// Flat `[tiling] *_variant` keys mapped onto their canonical layout names.
const flat_variant_keys = [_]struct { key: []const u8, canon: []const u8 }{
    .{ .key = "master_variant", .canon = types.canon_master_layout },
    .{ .key = "monocle_variant", .canon = "monocle" },
    .{ .key = "grid_variant", .canon = "grid" },
};

/// Stores `value` into tiling.variants under canonical key `canon`, duping both so
/// the map owns its storage independent of the parsed document (freed after
/// buildConfigFromDoc). Last override wins: any prior value is freed first.
fn setTilingVariant(
    allocator: std.mem.Allocator,
    cfg: *Config,
    canon: []const u8,
    value: []const u8,
) !void {
    if (cfg.variants.fetchRemove(canon)) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    const key = try allocator.dupe(u8, canon);
    errdefer allocator.free(key);
    const val = try allocator.dupe(u8, value);
    try cfg.variants.put(allocator, key, val);
}

/// The `[tiling.layouts.*]` sub-table family, scanned once: a bare
/// `[tiling.layouts.<name>]` table carries a per-layout `variants` string; a
/// `[tiling.layouts.<name>.counts]` one carries per-workspace master-count overrides
/// (workspace_number (1-based) = count; only meaningful with global_layout = false,
/// and only the master family can carry counts). Keys canonicalize so master alias
/// spellings resolve the same table; the flat `[tiling] *_variant` keys feed the map
/// too, and no validity check happens on variant strings (layout modules own their
/// meaning at seed time).
fn parseTilingLayoutSubtables(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *Config,
) !void {
    if (doc.getSection(types.section_tiling)) |sec| for (flat_variant_keys) |fk|
        if (sec.getAs([]const u8, fk.key)) |v| try setTilingVariant(allocator, cfg, fk.canon, v);

    const prefix = types.section_prefix_tiling_layouts;
    const suffix = ".counts";
    var iter = doc.sections.iterator();
    while (iter.next()) |entry| {
        const sec_name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, sec_name, prefix)) continue;
        // Only direct "<prefix><name>[.counts]" tables qualify (no deeper nesting); the
        // counts table is master-family only, and its keys are 1-based workspace
        // numbers -> [0,max_master_count] master counts.
        const tail = sec_name[prefix.len..];
        if (std.mem.endsWith(u8, tail, suffix)) {
            const seg = tail[0 .. tail.len - suffix.len];
            if (std.mem.eql(u8, layout_names.canonicalLayoutName(seg), types.canon_master_layout)) {
                const counts_sec = entry.value_ptr;
                cfg.workspace_master_count_overrides.clearRetainingCapacity();
                var inner = counts_sec.orderedIterator();
                while (inner.next()) |p| {
                    if (tryParseWsToken(p.key, model.max_workspaces, "master-stack.counts: invalid workspace key '{s}', skipping", .{p.key})) |ws_1based| {
                        const count_val = p.value.asScalar(i64) orelse {
                            log.warn("master-stack.counts: non-integer count for workspace {}, skipping", .{ws_1based});
                            continue;
                        };
                        if (count_val < 0 or count_val > max_master_count)
                            log.warn("master-stack.counts: count {} for workspace {} out of range [0,{d}], skipping", .{ count_val, ws_1based, max_master_count })
                        else
                            try cfg.workspace_master_count_overrides.append(allocator, .{
                                .workspace_idx = model.WorkspaceId.fromIndex(ws_1based - 1),
                                .count = @intCast(count_val),
                            });
                    }
                }
            }
        } else if (std.mem.indexOfScalar(u8, tail, '.') == null) {
            // Direct "<prefix><name>" keys canonicalize so master alias spellings
            // resolve the same variant entry.
            if (entry.value_ptr.getAs([]const u8, "variants")) |v|
                try setTilingVariant(allocator, cfg, layout_names.canonicalLayoutName(tail), v);
        }
    }
}

fn isWorkspaceList(s: []const u8) bool {
    if (s.len == 0) return false;
    var has_digit = false;
    for (s) |c| {
        if (std.ascii.isDigit(c)) {
            has_digit = true;
            continue;
        }
        if (c != ',' and c != ' ') return false;
    }
    return has_digit;
}

/// Parses a comma-separated workspace list string (e.g. "1,3,5") and appends one
/// WorkspaceLayoutOverride per valid workspace to `overrides`. Each override owns a
/// heap-dupe of the (possibly null) variant value-string, so it outlives the parsed
/// document.
fn parseWorkspaceListInto(
    allocator: std.mem.Allocator,
    ws_str: []const u8,
    layout_name: []const u8,
    layout_idx: u8,
    variant: ?[]const u8,
    overrides: *std.ArrayList(WorkspaceLayoutOverride),
) !void {
    var ws_iter = std.mem.splitScalar(u8, ws_str, ',');
    while (ws_iter.next()) |ws_tok| {
        const trimmed = std.mem.trim(u8, ws_tok, " \t");
        const ws_1based = tryParseWsToken(trimmed, model.max_workspaces, "layouts array: invalid workspace number '{s}' for layout '{s}', skipping", .{ trimmed, layout_name }) orelse continue;
        const variant_copy: ?[]const u8 = if (variant) |v| try allocator.dupe(u8, v) else null;
        try overrides.append(allocator, .{ .workspace_idx = model.WorkspaceId.fromIndex(ws_1based - 1), .layout_idx = layout_idx, .variant = variant_copy });
    }
}

/// Hard ceiling on the number of distinct layouts the cycle ring can hold. The
/// canonical value lives in the model (it bounds the u8 registry `kind` index and
/// WorkspaceLayoutOverride.layout_idx alike); the @intCast below relies on it so a
/// 256th entry can't trap in ReleaseFast. Names past the cap warn-and-skip.
const max_layouts = model.max_layouts;

/// Parses the `layouts` TOML array. A layout name (any string; registry resolution
/// happens at seed time) starts a new group; the optional next element is a variants
/// word or a workspace list ("1,3,5"); a third may follow as a workspace list when the
/// second was a variants. Plain single-name format is fully backward-compatible. Names
/// are stored lowercased, canonicalized (master aliases fold onto "master"), and
/// de-duplicated case-insensitively ON THE CANONICAL form — comparing the raw spelling
/// would let "master" and "master-stack" both land in the ring as two "master" rows;
/// an overlong name is skipped with a warning (resolution, not spelling, is
/// authoritative).
///
/// The optional trailing group after an appended layout name: a workspace list and/or
/// a variants word, consumed in either order. A variants word is stored into
/// `cfg.variants` under the canonical layout name and, when a workspace list follows,
/// also feeds the per-workspace overrides. `i` advances past every consumed token; null
/// when the trailing token is another layout name or nothing (a malformed variants word
/// also yields null, leaving the word for the caller's warn-and-skip).
fn parseLayoutTrailing(
    allocator: std.mem.Allocator,
    cfg: *Config,
    name_lower: []const u8,
    arr: []const parser.Value,
    i: *usize,
) !?struct { variants: ?[]const u8, ws_list: ?[]const u8 } {
    if (i.* + 1 >= arr.len) return null;
    const peek = arr[i.* + 1].asScalar([]const u8) orelse return null;
    if (isWorkspaceList(peek)) {
        i.* += 1;
        return .{ .variants = null, .ws_list = peek };
    }
    if (layout_names.isLayoutName(peek)) return null;
    // A variants word: stored canonical (aliases fold onto their registry module) under
    // the already-lowered layout name. Anything else leaves the word for the caller's
    // warn-and-skip.
    try setTilingVariant(allocator, cfg, layout_names.canonicalLayoutName(name_lower), peek);
    i.* += 1;
    if (i.* + 1 < arr.len) {
        if (arr[i.* + 1].asScalar([]const u8)) |peek2| {
            if (isWorkspaceList(peek2)) {
                i.* += 1;
                return .{ .variants = peek, .ws_list = peek2 };
            }
        }
    }
    return .{ .variants = peek, .ws_list = null };
}

fn parseLayoutsArray(
    allocator: std.mem.Allocator,
    arr: []const parser.Value,
    cfg: *Config,
) !void {
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        const raw_name = arr[i].asScalar([]const u8) orelse {
            log.warn("layouts array: expected a string at index {}, skipping", .{i});
            continue;
        };
        var name_lower_buf: [layout_names.max_layout_name]u8 = undefined;
        const name_lower = layout_names.normalizeLayoutName(&name_lower_buf, raw_name) orelse {
            log.warn("layouts array: layout name '{s}' at index {} is longer than the {d}-byte limit, skipping", .{ raw_name, i, layout_names.max_layout_name });
            continue;
        };
        // Canonicalize BEFORE the dedup check: stored entries are canonical, so comparing
        // the raw spelling would let an alias pair ("master" + "master-stack") past and
        // land two "master" rows in the cycle ring.
        const name_canon = layout_names.canonicalLayoutName(name_lower);
        const is_dup = for (cfg.layouts.items) |existing| {
            if (std.mem.eql(u8, existing, name_canon)) break true;
        } else false;
        if (is_dup) {
            log.warn("layouts array: duplicate layout '{s}' at index {}, skipping", .{ name_canon, i });
            continue;
        }
        // Stored canonical so every downstream resolution -- the global default,
        // per-workspace overrides, and the cycle ring -- sees the registry's canonical
        // spelling. The cycle ring is capped at max_layouts (the overrides index into
        // it via a u8), checked BEFORE the cast so an overlong config can't trap in
        // ReleaseFast.
        if (cfg.layouts.items.len >= max_layouts) {
            log.warn("layouts array: maximum of {d} unique layouts reached, skipping '{s}'", .{ max_layouts, raw_name });
            continue;
        }
        const layout_idx: u8 = @intCast(cfg.layouts.items.len);
        const copy = try allocator.dupe(u8, name_canon);
        cfg.layouts.append(allocator, copy) catch |err| {
            allocator.free(copy);
            return err;
        };

        // Optional trailing group: a workspace list and/or variants word.
        if (try parseLayoutTrailing(allocator, cfg, name_canon, arr, &i)) |trail| {
            if (trail.ws_list) |ws_str| {
                try parseWorkspaceListInto(allocator, ws_str, name_canon, layout_idx, trail.variants, &cfg.workspace_layout_overrides);
            }
        }
    }
}
