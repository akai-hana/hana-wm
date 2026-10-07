//! The `[bar.properties]` table: per-segment color and style
//! overrides (`segment_fg` / `segment_value_fg` / `segment_props`),
//! split out of schema.zig (round-2 review). The table's keys are
//! segment NAMES -- any key the scalar knobs do not own -- so this
//! file owns the segment-entry decoding; the scalar knob loop stays
//! in schema, which calls `applyBarProperties` after its knob pass
//! and hands in its `knobs` table. That parameter is what keeps the
//! seam cycle-free: the knob-key test stays bound to the very table
//! the knob loop reads (a future `[bar.properties]` knob can never
//! desync the map pass) without this file importing schema, which
//! imports this file.

const std = @import("std");
const log = @import("log");
const parser = @import("parser");
const types = @import("types");
const color = @import("color");

/// Reads `[bar.properties]` segment-name entries (any key not owned by the
/// scalar knobs above) into `cfg.bar.segment_fg` / `segment_value_fg` /
/// `segment_props`.
///
/// A key with the `_value` suffix (`cpu_value`) is that segment's NUMBER
/// color: the numeric readout ("42%" in "CPU 42%") is painted with it while
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
/// Runs after the knob loop so the known keys (title, run_*, ...) are
/// distinguishable. Gated on [bar] exactly like the [bar.properties] chain;
/// an absent table or section leaves the maps empty, so segment text falls
/// back to `fg`. Keys are duped for the Config's lifetime.
pub fn applyBarProperties(
    comptime knobs: anytype,
    allocator: std.mem.Allocator,
    doc: *parser.Document,
    cfg: *types.Config,
) !void {
    types.freeSegmentMap(types.Color, &cfg.bar.segment_fg, allocator);
    types.freeSegmentMap(types.Color, &cfg.bar.segment_value_fg, allocator);
    types.freeSegmentMap(types.SegmentProps, &cfg.bar.segment_props, allocator);
    if (doc.getSection(types.section_bar) == null) return;
    const sec = doc.getSection(types.section_bar_properties) orelse return;
    var it = sec.orderedIterator();
    while (it.next()) |pair| {
        if (isBarPropertiesKnobKey(knobs, pair.key)) continue;
        const is_value = std.mem.endsWith(u8, pair.key, "_value");
        const seg_key = if (is_value) pair.key[0 .. pair.key.len - "_value".len] else pair.key;
        try applySegmentEntry(allocator, cfg, pair.key, seg_key, is_value, pair.value, &doc.palette);
    }
}

/// True when `key` is one of the [bar.properties] scalar knobs; every OTHER
/// key in that table is a bar segment name (a per-segment color + style
/// override, see `applyBarProperties`). Scanned from the knob table the
/// caller hands in, so a future [bar.properties] knob can never desync the
/// map pass.
fn isBarPropertiesKnobKey(comptime knobs: anytype, key: []const u8) bool {
    inline for (knobs) |k| {
        for (k.places) |pl| {
            if (std.mem.eql(u8, pl.section, types.section_bar_properties) and
                std.mem.eql(u8, pl.key, key)) return true;
        }
    }
    return false;
}

/// Sets one style flag (`underline`/`bold`/`italic`) on `props`. Returns
/// true when `name` was a recognized flag.
fn setStyleFlag(props: *types.SegmentProps, name: []const u8, val: bool) bool {
    inline for (std.meta.fields(types.SegmentProps)) |f| {
        if (f.type != bool) continue;
        if (std.mem.eql(u8, name, f.name)) {
            @field(props, f.name) = val;
            return true;
        }
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
        if (color.colorFromValue(item)) |c| return .{ .color = c, .consumed = i };
        if (item.asScalar([]const u8)) |s| {
            if (palette.get(s)) |c| return .{ .color = c, .consumed = i };
        }
    }
    return null;
}

/// Inserts one segment-keyed entry: dupes `seg_key`, hands ownership to `map`
/// on success, and rolls the key back on OOM so the map never holds a
/// dangling key. The six put sites in `applySegmentEntry` share this exact
/// contract.
fn putSegmentEntry(
    comptime V: type,
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(V),
    seg_key: []const u8,
    item: V,
) !void {
    const k = try allocator.dupe(u8, seg_key);
    errdefer allocator.free(k);
    try map.put(allocator, k, item);
}

/// The color map a segment entry writes to: `_value` keys own the segment's
/// number color, everything else the plain color override.
inline fn segmentColorMap(cfg: *types.Config, is_value: bool) *std.StringHashMapUnmanaged(types.Color) {
    return if (is_value) &cfg.bar.segment_value_fg else &cfg.bar.segment_fg;
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
                    try putSegmentEntry(types.SegmentProps, allocator, &cfg.bar.segment_props, seg_key, props);
                }
                return;
            }
        }
        // Plain scalar: color only, exactly as the pre-properties behavior.
        const map = segmentColorMap(cfg, is_value);
        const c = color.getColorFromValue(key, raw, cfg.bar.fg, palette);
        try putSegmentEntry(types.Color, allocator, map, seg_key, c);
        return;
    }

    const items = raw.asArray().?;
    // A satisfying color-mix expression spans the whole array; resolve it as a
    // unit first, so `a + (weight:40%) b` compounds aren't misread as stray
    // tokens (the per-item scan below would grab just the head operand).
    // Pure mixes are color-only, exactly as the pre-properties decoding.
    if (color.resolveColorExpr(raw, palette)) |mix| {
        try putSegmentEntry(types.Color, allocator, segmentColorMap(cfg, is_value), seg_key, mix);
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
                log.warn("Invalid token for '{s}': expected a color or underline/bold/italic flag, skipping", .{key});
                i += 1;
                continue;
            };
            // `name=true|false`, `name true`, `name 1|0`, or bare `name`
            // (true by default). Unified so the invalid-style warning lives once.
            const eq = boolFromEqualsToken(token);
            var set: bool = if (eq) |e| e.value else true;
            var consumed_next = false;
            if (eq == null and i + 1 < items.len) {
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
            const flag = if (eq) |e| e.name else token;
            if (setStyleFlag(&props, flag, set)) {
                if (consumed_next) i += 1;
            } else {
                log.warn("Invalid style for '{s}': '{s}' is not underline/bold/italic, skipping", .{ key, token });
            }
            i += 1;
        }
    }

    if (found) |f| {
        try putSegmentEntry(types.Color, allocator, segmentColorMap(cfg, is_value), seg_key, f.color);
    } else if (is_value) {
        // A `_value` key is color-only: an array with no color is invalid.
        const c = color.getColorFromValue(key, raw, cfg.bar.fg, palette);
        try putSegmentEntry(types.Color, allocator, &cfg.bar.segment_value_fg, seg_key, c);
    }
    // Else: style-only base entry; the segment color stays default fg (no
    // map entry), so segmentFg's orelse fallback yields exactly that.

    if (!is_value and !props.isDefault()) {
        try putSegmentEntry(types.SegmentProps, allocator, &cfg.bar.segment_props, seg_key, props);
    }
}
