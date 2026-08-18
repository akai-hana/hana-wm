//! DPI detection and scaling utilities
//! Detects display DPI and scales bar dimensions for consistent appearance across resolutions.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const debug = @import("debug");

const parser = @import("parser");
const utils = @import("utils");

const BASELINE_DPI = constants.BASELINE_DPI;

// Font size percentages are relative to 1080 p height, not the screen's own
// resolution, so font sizing degrades more gracefully on smaller screens.
const FONT_BASELINE_HEIGHT: f32 = 1080.0;

/// Minimum bar height in pixels. Exposed so callers can validate config values
/// before passing them to scaleBarHeight.
pub const BAR_MIN_HEIGHT_PX: u16 = 20;

/// Reasonable-DPI band applied to both the geometry-derived and Xft.dpi paths.
/// Values outside this range (or non-finite) are rejected as misconfiguration
/// rather than being fed straight into Pango, where 0/negative/NaN DPI would
/// produce divide-by-zero or garbage font metrics.
const MIN_REASONABLE_DPI: f32 = 50.0;
const MAX_REASONABLE_DPI: f32 = 300.0;

/// Maximum long-words to request for the RESOURCE_MANAGER property (16 KB).
const RESOURCE_MANAGER_MAX_LEN: u32 = 4096;

/// Reads the Xft.dpi value from the X RESOURCE_MANAGER property, if present.
/// Returns null when the property is absent, empty, or does not contain an Xft.dpi entry.
fn readXftDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) ?f32 {
    // Resolve the atom from the shared cache; a property request with atom 0
    // just comes back empty, so a cache miss reads as "no Xft.dpi".
    const atom = utils.getAtomCached("RESOURCE_MANAGER") catch 0;

    const prop_cookie = xcb.xcb_get_property(conn, 0, screen.*.root, atom, xcb.XCB_ATOM_STRING, 0, RESOURCE_MANAGER_MAX_LEN);
    const prop_reply = xcb.xcb_get_property_reply(conn, prop_cookie, null) orelse return null;
    defer std.c.free(prop_reply);

    if (prop_reply.*.format != 8 or prop_reply.*.type != xcb.XCB_ATOM_STRING) return null;

    const value_len = xcb.xcb_get_property_value_length(prop_reply);
    if (value_len == 0) return null;

    const value_ptr = xcb.xcb_get_property_value(prop_reply);
    const resource_str = @as([*]const u8, @ptrCast(value_ptr))[0..@intCast(value_len)];

    // Format: "Xft.dpi:\t96" or "Xft.dpi: 96".
    // Slice off the prefix and trim whitespace, avoiding the split-on-delimiter
    // trap where ":\t" would yield an empty token before the value.
    const prefix = "Xft.dpi:";
    var lines = std.mem.splitScalar(u8, resource_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, prefix)) {
            const rest = std.mem.trim(u8, trimmed[prefix.len..], " \t");
            const dpi = std.fmt.parseFloat(f32, rest) catch continue;
            return dpi;
        }
    }
    return null;
}

/// Computes DPI from the screen's physical dimensions reported by X.
/// Returns BASELINE_DPI if the screen reports 0mm dimensions (e.g. virtual displays).
fn calcDpiFromGeometry(screen: *xcb.xcb_screen_t) f32 {
    const width_px: f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    const width_mm: f32 = @floatFromInt(screen.width_in_millimeters);
    const height_mm: f32 = @floatFromInt(screen.height_in_millimeters);
    if (width_mm == 0 or height_mm == 0) {
        debug.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return BASELINE_DPI;
    }
    const dpi_x = (width_px / width_mm) * 25.4;
    const dpi_y = (height_px / height_mm) * 25.4;
    const avg_dpi = (dpi_x + dpi_y) / 2.0;
    debug.info("Calculated DPI: X={d:.1}, Y={d:.1}, Average={d:.1}", .{ dpi_x, dpi_y, avg_dpi });
    return avg_dpi;
}

/// Detect DPI: Xft.dpi from X resources -> geometry calculation -> BASELINE_DPI (96).
/// Called once at startup; core.dpi_info holds the result for the process lifetime.
pub fn detectDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) f32 {
    if (readXftDpi(conn, screen)) |xft_dpi| {
        if (isReasonableDpi(xft_dpi)) {
            debug.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
            return xft_dpi;
        }
        debug.warn("Ignoring unreasonable Xft.dpi value {d:.1}", .{xft_dpi});
    }

    const geometry_dpi = calcDpiFromGeometry(screen);
    if (!isReasonableDpi(geometry_dpi)) {
        debug.warn("Calculated DPI {d:.1} seems unreasonable, using baseline DPI", .{geometry_dpi});
        return BASELINE_DPI;
    }
    debug.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    return geometry_dpi;
}

fn isReasonableDpi(dpi: f32) bool {
    return std.math.isFinite(dpi) and dpi >= MIN_REASONABLE_DPI and dpi <= MAX_REASONABLE_DPI;
}

/// Scales a font size value against the screen height, clamped to a minimum of 1px.
/// Percentage values are relative to FONT_BASELINE_HEIGHT (1080px) rather than the
/// screen baseline, so font sizes degrade more gracefully on smaller screens.
pub fn scaleFontSize(value: parser.ScalableValue, screen: *xcb.xcb_screen_t) u16 {
    const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
    const raw = if (value.is_percentage) value.value * (screen_height / FONT_BASELINE_HEIGHT) else value.value;
    return utils.scaling.roundToU16(raw, 1.0);
}

/// Converts a scalable bar height value to pixels, clamped to BAR_MIN_HEIGHT_PX.
pub fn scaleBarHeight(value: parser.ScalableValue, screen_height: u16) u16 {
    const screen_height_f: f32 = @floatFromInt(screen_height);
    const scaled_px: f32 = utils.scaling.scaleToPixels(value, screen_height_f);
    return @max(BAR_MIN_HEIGHT_PX, utils.scaling.roundToU16(scaled_px, 0.0));
}
