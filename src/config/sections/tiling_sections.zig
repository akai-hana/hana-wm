//! Tiling's non-scalar config structures: the layouts array (cycle order +
//! per-workspace overrides), per-layout variant preferences, and master-
//! stack counts -- the tables the comptime schema walk (schema.applyAll)
//! does not cover. The workspace-rules family lives in rules.zig; the bar
//! family lives in bar_sections.zig. Every parser here is gated on its
//! parent section existing, exactly as the scalar knobs are, and every
//! owned string it stores is duped off the parsed document so it outlives
//! the load-scoped arena.

const std = @import("std");
const constants = @import("constants");
const ids = @import("ids");
const log = @import("log");
const model = @import("model");
const parser = @import("parser");
const types = @import("types");
const layout_names = @import("layout_names");

/// Parses a 1-based workspace number from a bare token, warning with `fmt` on
/// a malformed token or a value outside 1..255 / `max` (the callers embed the
/// section name in `fmt`, so no separate context is needed), and returns null
/// to skip it.
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

/// Appends one layout name (duped) to the tiling layout cycle -- the seed
/// both the default config and the single-layout parse path use.
pub fn seedDefaultLayout(allocator: std.mem.Allocator, cfg: *types.Config, name: []const u8) !void {
    try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, name));
}

/// Upper bound for per-workspace master counts in `[tiling.layouts.master-stack.counts]`.
const max_master_count: u8 = 10;

/// Tiling's NON-scalar structures: the layouts array (cycle order +
/// per-workspace overrides), per-layout variant preferences, and
/// master-stack counts. Every tiling SCALAR ([tiling] flags, aesthetics,
/// master trio) is driven by schema.applyAll; all of it stays gated on the
/// [tiling] section existing.
pub fn parseTilingStructures(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    const section = doc.getSection(types.section_tiling) orelse return;
    types.freeStrings(&cfg.tiling.layouts, allocator, types.keep_capacity);
    cfg.tiling.workspace_layout_overrides.clearRetainingCapacity();
    types.freeStringMap(&cfg.tiling.variants, allocator, types.keep_capacity);
    if (section.getAsOrWarn([]const parser.Value, "layouts")) |arr| try parseLayoutsArray(allocator, arr, cfg) else {
        const layout_str = section.getAsOrWarn([]const u8, "layout") orelse types.canon_master_layout;
        try seedDefaultLayout(allocator, cfg, layout_names.canonicalLayoutName(layout_str));
    }
    try parseTilingLayoutSubtables(allocator, doc, cfg);
}

/// The flat `[tiling] master_variant/monocle_variant/grid_variant` keys
/// map onto their canonical layout names.
const flat_variant_keys = [_]struct { key: []const u8, canon: []const u8 }{
    .{ .key = "master_variant", .canon = types.canon_master_layout },
    .{ .key = "monocle_variant", .canon = "monocle" },
    .{ .key = "grid_variant", .canon = "grid" },
};

/// Stores `value` into tiling.variants under canonical key `canon`, duping
/// both so the map owns its storage independent of the parsed document (which
/// is freed after buildConfigFromDoc). Last override wins: any prior value
/// for the same key is freed first.
fn setTilingVariant(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
    canon: []const u8,
    value: []const u8,
) !void {
    if (cfg.tiling.variants.fetchRemove(canon)) |kv| {
        allocator.free(kv.key);
        allocator.free(kv.value);
    }
    const key = try allocator.dupe(u8, canon);
    errdefer allocator.free(key);
    const val = try allocator.dupe(u8, value);
    try cfg.tiling.variants.put(allocator, key, val);
}

/// The `[tiling.layouts.*]` sub-table family, scanned once: a bare
/// `[tiling.layouts.<name>]` table carries a per-layout `variants` string; a
/// `[tiling.layouts.<name>.counts]` one carries per-workspace master-count
/// overrides (workspace_number (1-based) = count; only meaningful with
/// global_layout = false, and only the master family can carry counts). Keys
/// canonicalize so master alias spellings resolve the same table; the flat
/// `[tiling] *_variant` keys feed the map too, and no validity check happens
/// on variant strings (layout modules own their meaning at seed time).
fn parseTilingLayoutSubtables(
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    if (doc.getSection(types.section_tiling)) |sec| for (flat_variant_keys) |fk|
        if (sec.getAs([]const u8, fk.key)) |v| try setTilingVariant(allocator, cfg, fk.canon, v);

    const prefix = types.section_prefix_tiling_layouts;
    const suffix = ".counts";
    var iter = doc.sections.iterator();
    while (iter.next()) |entry| {
        const sec_name = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, sec_name, prefix)) continue;
        // Only direct "<prefix><name>[.counts]" tables qualify (no deeper
        // nesting); the counts table is master-family only, and its keys are
        // 1-based workspace numbers -> in-[0,max_master_count] master counts.
        const tail = sec_name[prefix.len..];
        if (std.mem.endsWith(u8, tail, suffix)) {
            const seg = tail[0 .. tail.len - suffix.len];
            if (std.mem.eql(u8, layout_names.canonicalLayoutName(seg), types.canon_master_layout)) {
                const counts_sec = entry.value_ptr;
                cfg.tiling.workspace_master_count_overrides.clearRetainingCapacity();
                var inner = counts_sec.orderedIterator();
                while (inner.next()) |p| {
                    if (tryParseWsToken(p.key, constants.max_workspaces, "master-stack.counts: invalid workspace key '{s}', skipping", .{p.key})) |ws_1based| {
                        const count_val = p.value.asScalar(i64) orelse {
                            log.warn("master-stack.counts: non-integer count for workspace {}, skipping", .{ws_1based});
                            continue;
                        };
                        if (count_val < 0 or count_val > max_master_count)
                            log.warn("master-stack.counts: count {} for workspace {} out of range [0,{d}], skipping", .{ count_val, ws_1based, max_master_count })
                        else
                            try cfg.tiling.workspace_master_count_overrides.append(allocator, .{
                                .workspace_idx = ids.WorkspaceId.fromIndex(ws_1based - 1),
                                .count = @intCast(count_val),
                            });
                    }
                }
            }
        } else if (std.mem.indexOfScalar(u8, tail, '.') == null) {
            // Direct "<prefix><name>" keys canonicalize so master alias
            // spellings resolve the same variant entry.
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

/// Parses a comma-separated workspace list string (e.g. "1,3,5") and appends
/// one WorkspaceLayoutOverride per valid workspace to `overrides`. Each
/// override owns a heap-dupe of the (possibly null) variant value-string, so
/// it outlives the parsed document.
fn parseWorkspaceListInto(
    allocator: std.mem.Allocator,
    ws_str: []const u8,
    layout_name: []const u8,
    layout_idx: u8,
    variant: ?[]const u8,
    overrides: *std.ArrayList(types.WorkspaceLayoutOverride),
) !void {
    var ws_iter = std.mem.splitScalar(u8, ws_str, ',');
    while (ws_iter.next()) |ws_tok| {
        const trimmed = std.mem.trim(u8, ws_tok, " \t");
        const ws_1based = tryParseWsToken(trimmed, constants.max_workspaces, "layouts array: invalid workspace number '{s}' for layout '{s}', skipping", .{ trimmed, layout_name }) orelse continue;
        const variant_copy: ?[]const u8 = if (variant) |v| try allocator.dupe(u8, v) else null;
        try overrides.append(allocator, .{ .workspace_idx = ids.WorkspaceId.fromIndex(ws_1based - 1), .layout_idx = layout_idx, .variant = variant_copy });
    }
}

/// Hard ceiling on the number of distinct layouts the cycle ring can hold.
/// The canonical value lives in the model (it bounds the u8 registry `kind`
/// index and WorkspaceLayoutOverride.layout_idx alike); the @intCast below
/// relies on it so a 256th entry can't trap in ReleaseFast. Names past the
/// cap warn-and-skip.
const max_layouts = model.max_layouts;

/// Parses the `layouts` TOML array. A layout name (any string; registry
/// resolution happens at seed time) starts a new group; the optional next
/// element is a variants word or a workspace list ("1,3,5"); a third may
/// follow as a workspace list when the second was a variants. Plain
/// single-name format ("master-stack") is fully backward-compatible. Names
/// are stored lowercased and de-duplicated case-insensitively; an overlong
/// name is skipped with a warning (resolution, not spelling, is authoritative).
/// The optional trailing group after an appended layout name: a workspace
/// list and/or a variants word, consumed in either order. A variants word
/// is stored into `cfg.tiling.variants` under the canonical layout name and
/// also, when a workspace list follows, feeds the per-workspace overrides.
/// `i` advanced past every consumed token; null when the trailing token is
/// another layout name or nothing (a malformed variants word also yields
/// null, leaving the word for the caller's warn-and-skip).
fn parseLayoutTrailing(
    allocator: std.mem.Allocator,
    cfg: *types.Config,
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
    // A variants word: stored canonical (aliases fold onto their registry
    // module) under the already-lowered layout name. Anything else leaves the
    // word for the caller's warn-and-skip.
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
    cfg: *types.Config,
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
        const is_dup = for (cfg.tiling.layouts.items) |existing| {
            if (std.mem.eql(u8, existing, name_lower)) break true;
        } else false;
        if (is_dup) {
            log.warn("layouts array: duplicate layout '{s}' at index {}, skipping", .{ name_lower, i });
            continue;
        }
        // Stored canonical (config.canonicalLayoutName) so every downstream
        // resolution -- the global default, per-workspace overrides, and the
        // cycle ring -- sees the registry's canonical spelling. The cycle
        // ring is capped at max_layouts (the overrides index into it via a
        // u8), checked BEFORE the cast so an overlong config can't trap in
        // ReleaseFast.
        if (cfg.tiling.layouts.items.len >= max_layouts) {
            log.warn("layouts array: maximum of {d} unique layouts reached, skipping '{s}'", .{ max_layouts, raw_name });
            continue;
        }
        const layout_idx: u8 = @intCast(cfg.tiling.layouts.items.len);
        try cfg.tiling.layouts.append(allocator, try allocator.dupe(u8, layout_names.canonicalLayoutName(name_lower)));

        // Optional trailing group: a workspace list and/or variants word.
        if (try parseLayoutTrailing(allocator, cfg, name_lower, arr, &i)) |trail| {
            if (trail.ws_list) |ws_str| {
                try parseWorkspaceListInto(allocator, ws_str, name_lower, layout_idx, trail.variants, &cfg.tiling.workspace_layout_overrides);
            }
        }
    }
}
