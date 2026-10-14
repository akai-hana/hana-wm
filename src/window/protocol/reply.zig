//! Pure ICCCM property-reply parsing: the WM_CLASS split (identity) and
//! the WM_NORMAL_HINTS / WM_SIZE_HINTS field walk (size hints). Both take
//! the reply BYTES/fields and derive model values; no X round trips, no
//! cache writes. The caller owns the wire read (icccm.firePropQuery +
//! reply drain) and where the result lands -- the model entry, threaded
//! as a parameter at admission time (see manage.mapRequest). Pure by
//! construction, so both derivations are unit-testable without a
//! connection (reply_test.zig). Former identity.zig + hints.zig, merged
//! 2026-10-10; the X-wired query/refresh half stays in icccm.zig.

const std = @import("std");
const model = @import("model");
const scaling = @import("scaling");

// ---------------------------------------------------------------------------
// WM_CLASS split (former identity.zig).
// ---------------------------------------------------------------------------

/// The two WM_CLASS components: `instance` (the res_name,
/// e.g. "alacritty") and `class` (the res_class, e.g.
/// "Alacritty").
pub const WmClass = struct {
    instance: []const u8,
    class: []const u8,
};

/// Splits a WM_CLASS property value: two consecutive
/// null-terminated strings, "instance\x00class\x00". Trailing
/// nulls are trimmed per component, not on the whole
/// buffer: trimming the whole buffer first turns
/// "instance\x00\x00" (empty class) into "instance" with no
/// separator, silently skipping the instance lookup.
/// Returns null when no separator is present at all.
pub fn parseWmClass(data: []const u8) ?WmClass {
    const sep = std.mem.indexOfScalar(u8, data, 0) orelse return null;
    const instance = data[0..sep];

    const class_start = sep + 1;
    const class_raw = if (class_start < data.len) data[class_start..] else "";
    const class_end = std.mem.indexOfScalar(u8, class_raw, 0) orelse class_raw.len;
    return .{ .instance = instance, .class = class_raw[0..class_end] };
}

// ---------------------------------------------------------------------------
// WM_NORMAL_HINTS field walk (former hints.zig).
// ---------------------------------------------------------------------------

/// ICCCM flag bits (the PMinSize/PMaxSize/... word of the reply).
const p_min_size: u32 = 0x10;
const p_max_size: u32 = 0x20;
const p_resize_inc: u32 = 0x40;
const p_aspect: u32 = 0x80;
const p_base_size: u32 = 0x100;

/// Reply length for the property query: flags + 17 fields (up to
/// base_size/win_gravity).
pub const wm_normal_hints_long_length: u32 = 18;

/// Extract a pair of consecutive u16 fields when the flag is set and enough
/// fields are present. Shared by max_size and resize_inc extraction which
/// share the same 2-field pattern.
const SizePair = struct { width: u16, height: u16 };

fn extractFieldPair(
    fields: [*]const u32,
    field_count: u32,
    want: bool,
    comptime off: usize,
) SizePair {
    if (want and field_count >= off + 2) return .{
        .width = scaling.clampToU16(fields[off]),
        .height = scaling.clampToU16(fields[off + 1]),
    };
    return .{ .width = 0, .height = 0 };
}

const Aspect = struct { min: f32, max: f32 };

/// Parses a WM_NORMAL_HINTS reply's u32 fields into the model's
/// SizeHints, or null when no constraint flag is set.
///
/// PMinSize/PBaseSize feed the floating drag-resize floor: tiling
/// ignores declared minimums outright (policy on model.SizeHints), but
/// when both are declared the effective floor is the larger, so a
/// client can never be dragged smaller than either it or its base
/// declares. The max/increment/aspect constraints are forwarded so
/// hint-constrained windows behave correctly in both modes.
///
/// PAspect: fields[11..14] = min_aspect.x/y, max_aspect.x/y. dwm
/// convention: min_aspect = y/x (lower bound on h/w), max_aspect =
/// x/y (upper bound on w/h).
pub fn parse(fields: [*]const u32, field_count: u32) ?model.SizeHints {
    const flags = fields[0];

    const want_min = flags & p_min_size != 0;
    const want_base = flags & p_base_size != 0;
    const want_max = flags & p_max_size != 0;
    const want_inc = flags & p_resize_inc != 0;
    const want_asp = flags & p_aspect != 0;

    if (!want_min and !want_base and !want_max and !want_inc and !want_asp) return null;

    const min_pair = extractFieldPair(fields, field_count, want_min, 5);
    const base_pair = extractFieldPair(fields, field_count, want_base, 15);
    const max_pair = extractFieldPair(fields, field_count, want_max, 7);
    const inc_pair = extractFieldPair(fields, field_count, want_inc, 9);

    const aspect: Aspect = if (want_asp and field_count >= 15)
        .{
            .min = if (fields[11] > 0) @as(f32, @floatFromInt(fields[12])) / @as(f32, @floatFromInt(fields[11])) else 0.0,
            .max = if (fields[14] > 0) @as(f32, @floatFromInt(fields[13])) / @as(f32, @floatFromInt(fields[14])) else 0.0,
        }
    else
        .{ .min = 0.0, .max = 0.0 };

    return .{
        .min_width = @max(min_pair.width, base_pair.width),
        .min_height = @max(min_pair.height, base_pair.height),
        .max_width = max_pair.width,
        .max_height = max_pair.height,
        .inc_width = inc_pair.width,
        .inc_height = inc_pair.height,
        .min_aspect = aspect.min,
        .max_aspect = aspect.max,
    };
}
