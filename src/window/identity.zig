//! Window identity extraction from properties (pure): the
//! WM_CLASS reply split into its instance and class
//! components. The reply read itself stays with the caller
//! (an X round trip); this file owns only the byte-level
//! split, so the per-component trimming rule is
//! unit-testable without a server (identity_test.zig).

const std = @import("std");

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
