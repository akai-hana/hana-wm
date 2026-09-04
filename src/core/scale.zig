//! DPI detection and scaling utilities.
//! Detects display DPI and scales bar dimensions for consistent appearance across resolutions.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const debug = @import("debug");

const parser = @import("parser");
const utils = @import("utils");

const baseline_dpi = constants.baseline_dpi;

// Font size percentages are relative to 1080p height, not the screen's own
// resolution, so font sizing degrades more gracefully on smaller screens.
const font_baseline_height: f32 = 1080.0;

/// Minimum bar height in pixels. Exposed so callers can validate config values
/// before passing them to scaleBarHeight.
pub const bar_min_height_px: u16 = 20;

/// Reasonable-DPI band applied to both the geometry-derived and Xft.dpi paths.
/// Values outside this range (or non-finite) are rejected as misconfiguration
/// rather than being fed straight into Pango, where 0/negative/NaN DPI would
/// produce divide-by-zero or garbage font metrics.
const min_reasonable_dpi: f32 = 50.0;
const max_reasonable_dpi: f32 = 300.0;

/// Maximum number of u32 words to request for the RESOURCE_MANAGER property (4 KB).
/// Xft.dpi is almost always near the start; a smaller fetch is faster and
/// sufficient for the common case.
const resource_manager_max_len: u32 = 1024;

/// Larger retry fetch (16 KB) used when Xft.dpi is not in the first probe.
const resource_manager_retry_len: u32 = 4096;

/// Result of probing RESOURCE_MANAGER. `.got_string` is true when a
/// structurally valid string came back (regardless of whether it held an
/// entry), so callers can tell "entry not in this window" from "unreadable".
const XftProbe = struct { got_string: bool = false, dpi: ?f32 = null };

/// Finds and parses the Xft.dpi value within a raw RESOURCE_MANAGER string.
fn parseXftDpi(resource_str: []const u8) ?f32 {
    const prefix = "Xft.dpi:";
    const idx = std.mem.indexOf(u8, resource_str, prefix) orelse return null;
    const rest_raw = resource_str[idx + prefix.len ..];
    const rest = std.mem.trim(u8, rest_raw, " \t");
    // The value ends at the next newline or end of string.
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const value = std.mem.trim(u8, rest[0..end], " \t\r");
    return std.fmt.parseFloat(f32, value) catch null;
}

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
    return .{ .got_string = true, .dpi = parseXftDpi(resource_str) };
}

/// Reads the Xft.dpi value from the X RESOURCE_MANAGER property, if present.
/// Returns null when the property is absent, empty, or does not contain an Xft.dpi entry.
fn readXftDpi(conn: core.Connection, screen: core.Screen) ?f32 {
    // Resolve the atom from the shared cache; a property request with atom 0
    // just comes back empty, so a cache miss reads as "no Xft.dpi".
    const atom = utils.getAtomCached("RESOURCE_MANAGER") catch 0;
    const root = screen.*.root;

    // Xft.dpi is almost always near the start; a smaller first fetch is
    // faster and sufficient for the common case.
    const first = probeXftDpi(conn, root, atom, resource_manager_max_len);
    if (first.dpi) |dpi| return dpi;

    // Xft.dpi was not in the first resource_manager_max_len bytes; retry with
    // a larger fetch, but only when the first reply was actually a string.
    if (!first.got_string) return null;
    return probeXftDpi(conn, root, atom, resource_manager_retry_len).dpi;
}

/// Computes DPI from the screen's physical dimensions reported by X.
/// Returns baseline_dpi if the screen reports 0mm dimensions (e.g. virtual displays).
fn calcDpiFromGeometry(screen: core.Screen) f32 {
    const width_px: f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    const width_mm: f32 = @floatFromInt(screen.width_in_millimeters);
    const height_mm: f32 = @floatFromInt(screen.height_in_millimeters);
    if (width_mm == 0 or height_mm == 0) {
        debug.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return baseline_dpi;
    }
    const dpi_x = (width_px / width_mm) * 25.4;
    const dpi_y = (height_px / height_mm) * 25.4;
    const avg_dpi = (dpi_x + dpi_y) / 2.0;
    debug.info("Calculated DPI: X={d:.1}, Y={d:.1}, Average={d:.1}", .{ dpi_x, dpi_y, avg_dpi });
    return avg_dpi;
}

fn isReasonableDpi(dpi: f32) bool {
    return std.math.isFinite(dpi) and dpi >= min_reasonable_dpi and dpi <= max_reasonable_dpi;
}

/// Detect DPI: Xft.dpi from X resources -> geometry calculation -> baseline_dpi (96).
/// Called once at startup; core.dpi_info holds the result for the process lifetime.
pub fn detectDpi(conn: core.Connection, screen: core.Screen) f32 {
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
        return baseline_dpi;
    }
    debug.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    return geometry_dpi;
}

/// Scales a font size value against the screen height, clamped to a minimum of 1px.
/// Percentage values are relative to font_baseline_height (1080px) rather than the
/// screen baseline, so font sizes degrade more gracefully on smaller screens.
pub fn scaleFontSize(value: parser.ScalableValue, screen: core.Screen) u16 {
    const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
    const raw = if (value.is_percentage)
        value.value * (screen_height / font_baseline_height)
    else
        value.value;
    return utils.scaling.roundToU16(raw, 1.0);
}

/// Converts a scalable bar height value to pixels, clamped to bar_min_height_px.
pub fn scaleBarHeight(value: parser.ScalableValue, screen_height: u16) u16 {
    const screen_height_f: f32 = @floatFromInt(screen_height);
    const scaled_px: f32 = utils.scaling.scaleToPixels(value, screen_height_f);
    return @max(bar_min_height_px, utils.scaling.roundToU16(scaled_px, 0.0));
}
