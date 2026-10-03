//! Display-free DPI math: RESOURCE_MANAGER parsing, geometry→DPI formula,
//! and sanity band; pure and testable without X server.

const std = @import("std");

/// Reasonable-DPI band applied to both the geometry-derived and Xft.dpi paths.
/// Values outside this range (or non-finite) are rejected as misconfiguration
/// rather than being fed straight into Pango, where 0/negative/NaN DPI would
/// produce divide-by-zero or garbage font metrics.
pub const min_reasonable_dpi: f32 = 50.0;
pub const max_reasonable_dpi: f32 = 300.0;

/// Inches per meter, i.e. mm per inch: converts screen mm to pixels-per-inch.
pub const mm_per_inch: f32 = 25.4;

/// Geometry inputs to the DPI formula, in the units X reports them. A struct
/// so the formula cannot be called with the four values in the wrong order.
pub const Geometry = struct {
    width_px: u32,
    height_px: u32,
    width_mm: u32,
    height_mm: u32,
};

/// Index of the first occurrence of `key` that sits at a LINE BOUNDARY (the
/// string head, or the byte after a newline), or null when there is none.
fn lineStartOf(haystack: []const u8, key: []const u8) ?usize {
    var from: usize = 0;
    while (from + key.len <= haystack.len) {
        const at = std.mem.indexOfPos(u8, haystack, from, key) orelse return null;
        if (at == 0 or haystack[at - 1] == '\n') return at;
        // Not at a line start: keep looking from just past this occurrence.
        from = at + 1;
    }
    return null;
}

/// Finds and parses the Xft.dpi value within a raw RESOURCE_MANAGER string.
///
/// The key is matched at a LINE BOUNDARY, not as a bare substring. A plain
/// `indexOf` meant any key whose name ended in "Xft.dpi:" matched -- e.g. a
/// client's "NotXft.dpi: 96" or "MyXft.dpi: 144" was read as hana's own
/// setting, silently overriding the real resolution. The X resource format
/// is one name/value binding per line, so a binding starts at the string
/// head or right after a newline; that is the only place a match is valid.
pub fn parseXftDpi(resource_str: []const u8) ?f32 {
    const prefix = "Xft.dpi:";
    const start = lineStartOf(resource_str, prefix) orelse return null;
    const rest_raw = resource_str[start + prefix.len ..];
    const rest = std.mem.trim(u8, rest_raw, " \t");
    // The value ends at the next newline or end of string.
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..end], " \t\r");
    return std.fmt.parseFloat(f32, value) catch null;
}

/// Computes DPI from physical screen dimensions, or null when the screen
/// reports 0mm (virtual displays and headless X report this). Null rather
/// than a silent baseline: the caller owns the decision and the log message.
pub fn calcDpiFromGeometry(g: Geometry) ?f32 {
    if (g.width_mm == 0 or g.height_mm == 0) return null;
    const width_px: f32 = @floatFromInt(g.width_px);
    const height_px: f32 = @floatFromInt(g.height_px);
    const width_mm: f32 = @floatFromInt(g.width_mm);
    const height_mm: f32 = @floatFromInt(g.height_mm);
    const dpi_x = (width_px / width_mm) * mm_per_inch;
    const dpi_y = (height_px / height_mm) * mm_per_inch;
    return (dpi_x + dpi_y) / 2.0;
}

/// True when `dpi` is finite and inside the sanity band.
pub fn isReasonableDpi(dpi: f32) bool {
    return std.math.isFinite(dpi) and dpi >= min_reasonable_dpi and dpi <= max_reasonable_dpi;
}
