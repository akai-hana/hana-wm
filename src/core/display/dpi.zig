//! DPI detection and scaling utilities.
//! Detects display DPI and scales bar dimensions for consistent appearance across resolutions.
//! The display-free half (RESOURCE_MANAGER parsing, geometry→DPI formula,
//! sanity band) lives here too -- it used to be a separate `dpi_math` module,
//! but it exists only to serve the detection path below and is folded in;
//! `dpi_test.zig` exercises it without an X server.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;

const log = @import("log");

const types = @import("types");
const atoms = @import("atoms");
const scaling = @import("scaling");

const baseline_dpi = core.baseline_dpi;

/// Reasonable-DPI band applied to both the geometry-derived and Xft.dpi paths.
/// Values outside this range (or non-finite) are rejected as misconfiguration
/// rather than being fed straight into Pango, where 0/negative/NaN DPI would
/// produce divide-by-zero or garbage font metrics.
const min_reasonable_dpi: f32 = 50.0;
const max_reasonable_dpi: f32 = 300.0;

/// Inches per meter, i.e. mm per inch: converts screen mm to pixels-per-inch.
const mm_per_inch: f32 = 25.4;

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

// Font size percentages are relative to 1080p height, not the screen's own
// resolution, so font sizing degrades more gracefully on smaller screens.
const font_baseline_height: f32 = 1080.0;

/// The bar-height policy as ONE value. These were three loose pub consts
/// a caller had to know to apply together; nothing stopped someone clamping
/// against the min and forgetting the cap. Grouping them makes "the policy"
/// a thing you can pass, not a convention you have to remember.
const BarHeightPolicy = struct {
    /// Minimum bar height in pixels. `scaleBarHeight` clamps an explicit
    /// `height` up to this floor.
    min_px: u16 = 20,
    /// Pixel cap on an auto-sized bar (no explicit `height`): an unconfigured
    /// bar derives its height from font metrics, and this bounds that
    /// derivation so a huge fallback font can't take over the whole screen.
    max_px: u16 = 200,
    /// Fallback bar height when even font metrics are unavailable: a small
    /// strip-sized default that stays in proportion on any screen.
    default_px: u16 = 24,
};

pub const bar_height_policy: BarHeightPolicy = .{};

/// Clamps an auto-derived bar height (from font metrics, in pixels) into the
/// policy's range, BOTH ends.
pub fn clampBarHeight(px: i32) u16 {
    return @intCast(std.math.clamp(
        px,
        @as(i32, @intCast(bar_height_policy.min_px)),
        @as(i32, @intCast(bar_height_policy.max_px)),
    ));
}

/// Maximum number of u32 words to request for the RESOURCE_MANAGER property (4 KB).
/// Xft.dpi is almost always near the start; a smaller fetch is faster and
/// sufficient for the common case.
const resource_manager_max_len: u32 = 1024;

/// Larger retry fetch (16 KB) used when Xft.dpi is not in the first probe.
const resource_manager_retry_len: u32 = 4096;

/// Result of probing RESOURCE_MANAGER. `.got_string` is true when a
/// structurally valid string came back (regardless of whether it held an
/// entry), so callers can tell "entry not in this window" from "unreadable".
const XftProbe = struct {
    got_string: bool = false,
    dpi: ?f32 = null,
    /// True when the fetch was cut short (reply.bytes_after > 0). Lets the
    /// caller distinguish "Xft.dpi genuinely absent from this window of the
    /// resource string" from "the probe window was too small to see it".
    possibly_truncated: bool = false,
};

/// Fetches RESOURCE_MANAGER (up to `max_len` u32 words) and parses Xft.dpi
/// from it.
fn probeXftDpi(conn: core.Connection, root: xcb.xcb_window_t, atom: u32, max_len: u32) XftProbe {
    const prop_cookie = xcb.xcb_get_property(conn, 0, root, atom, xcb.XCB_ATOM_STRING, 0, max_len);
    const prop_reply = xcb.xcb_get_property_reply(conn, prop_cookie, null) orelse return .{};
    defer std.c.free(prop_reply);

    if (prop_reply.*.format != 8 or prop_reply.*.type != xcb.XCB_ATOM_STRING) return .{};

    const value_len = xcb.xcb_get_property_value_length(prop_reply);
    if (value_len == 0) return .{};

    const value_ptr = xcb.xcb_get_property_value(prop_reply);
    const resource_str = @as([*]const u8, @ptrCast(value_ptr))[0..@intCast(value_len)];
    return .{
        .got_string = true,
        .dpi = parseXftDpi(resource_str),
        // Truncation is `bytes_after > 0`, not the value_len hitting the
        // requested cap (a string of exactly cap length is complete).
        .possibly_truncated = prop_reply.*.bytes_after > 0,
    };
}

/// Reads the Xft.dpi value from the X RESOURCE_MANAGER property, if present.
/// Returns null when the property is absent, empty, or does not contain an Xft.dpi entry.
fn readXftDpi(conn: core.Connection, screen: core.Screen) ?f32 {
    // Resolve the atom from the shared cache; a property request with atom 0
    // just comes back empty, so a cache miss reads as "no Xft.dpi".
    const atom = atoms.getAtomOrZero("RESOURCE_MANAGER");
    const root = screen.root;

    // Xft.dpi is almost always near the start; a smaller first fetch is
    // faster and sufficient for the common case.
    const first = probeXftDpi(conn, root, atom, resource_manager_max_len);
    if (first.dpi) |dpi| return dpi;

    // Xft.dpi was not in the first resource_manager_max_len bytes; retry with a
    // larger fetch ONLY when the reply was a string AND was cut short
    // (bytes_after > 0). An untruncated fetch that lacks Xft.dpi genuinely
    // lacks it; a bigger fetch would return the same bytes.
    if (!first.got_string or !first.possibly_truncated) return null;
    return probeXftDpi(conn, root, atom, resource_manager_retry_len).dpi;
}

/// Detect DPI: Xft.dpi from X resources -> geometry calculation -> baseline_dpi (96).
/// Called once at startup; `core.setDpi` records the result for the process
/// lifetime (and on a RandR size change, which can move it).
pub fn detectDpi(conn: core.Connection, screen: core.Screen) f32 {
    if (readXftDpi(conn, screen)) |xft_dpi| {
        if (isReasonableDpi(xft_dpi)) {
            log.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
            return xft_dpi;
        }
        log.warn("Ignoring unreasonable Xft.dpi value {d:.1}", .{xft_dpi});
    }

    // The formula is pure and returns null for a 0mm screen (the
    // "virtual display" case), so the decision and its log stay here.
    const geometry_dpi = calcDpiFromGeometry(.{
        .width_px = screen.width_in_pixels,
        .height_px = screen.height_in_pixels,
        .width_mm = screen.width_in_millimeters,
        .height_mm = screen.height_in_millimeters,
    }) orelse {
        log.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return baseline_dpi;
    };
    if (!isReasonableDpi(geometry_dpi)) {
        log.warn("Calculated DPI {d:.1} seems unreasonable, using baseline DPI", .{geometry_dpi});
        return baseline_dpi;
    }
    log.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    return geometry_dpi;
}

/// Scales a font size value against the screen HEIGHT, clamped to a minimum of
/// 1px. Percentage values are relative to font_baseline_height (1080px)
/// rather than the screen baseline, so font sizes degrade more gracefully on
/// smaller screens.
///
/// Takes the height as a plain value rather than a `core.Screen`. There
/// used to be two shapes of this one function -- this one took a whole
/// `Screen`, and a sibling took `RefDims { screen_h, screen_w }` -- so a
/// caller holding only a height, or the wrong half of a `RefDims`, had no
/// signature that made the mistake impossible: width and height are the same
/// type, and a swap compiles silently and scales a 2560-wide screen as if it
/// were 1440 tall. A single scalar reference cannot be transposed.
///
/// The bar's metric resolution takes its inputs as plain values so it can be
/// resolved and tested without a live screen, and this is the only
/// screen-derived input it needs.
pub fn scaleFontSizeForHeight(value: types.ScalableValue, screen_height_px: u16) u16 {
    const screen_height: f32 = @floatFromInt(screen_height_px);
    const raw = if (value.is_percentage)
        value.value * (screen_height / font_baseline_height)
    else
        value.value;
    return scaling.roundToU16(raw, 1.0);
}

/// Converts a scalable bar height value to pixels, clamped into the
/// bar-height policy's range.
pub fn scaleBarHeight(value: types.ScalableValue, screen_height: u16) u16 {
    const screen_height_f: f32 = @floatFromInt(screen_height);
    const scaled_px: f32 = scaling.scaleToPixels(value, screen_height_f);
    // clampBarHeight, not a bare @max: the floor and the cap are one policy
    // value to apply together, so a large `height` can't hand the bar more of
    // the screen than the policy allows.
    return clampBarHeight(@intFromFloat(scaled_px));
}
