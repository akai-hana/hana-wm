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

/// Maximum long-words to request for the RESOURCE_MANAGER property (16 KB).
const RESOURCE_MANAGER_MAX_LEN: u32 = 4096;

/// Reads the Xft.dpi value from the X RESOURCE_MANAGER property, if present.
/// Returns null when the property is absent, empty, or does not contain an Xft.dpi entry.
fn readXftDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) ?f32 {
    const atom_cookie = xcb.xcb_intern_atom(conn, 0, "RESOURCE_MANAGER".len, "RESOURCE_MANAGER");
    const atom_reply = xcb.xcb_intern_atom_reply(conn, atom_cookie, null) orelse return null;
    defer std.c.free(atom_reply);

    const prop_cookie = xcb.xcb_get_property(conn, 0, screen.*.root, atom_reply.*.atom, xcb.XCB_ATOM_STRING, 0, RESOURCE_MANAGER_MAX_LEN);
    const prop_reply = xcb.xcb_get_property_reply(conn, prop_cookie, null) orelse return null;
    defer std.c.free(prop_reply);

    if (prop_reply.*.format != 8 or prop_reply.*.type != xcb.XCB_ATOM_STRING) return null;

    const value_len = xcb.xcb_get_property_value_length(prop_reply);
    if (value_len == 0) return null;

    const value_ptr = xcb.xcb_get_property_value(prop_reply);
    const resource_str = @as([*]const u8, @ptrCast(value_ptr))[0..@intCast(value_len)];

    // Format: "Xft.dpi:\t96" or "Xft.dpi: 96".
    // Slice off the prefix and trim whitespace — avoids the split-on-delimiter
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
        debug.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
        return xft_dpi;
    }

    const geometry_dpi = calcDpiFromGeometry(screen);
    const reasonable = geometry_dpi >= 50.0 and geometry_dpi <= 300.0;
    if (reasonable) {
        debug.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    } else {
        debug.warn("Calculated DPI {d:.1} seems unreasonable, using baseline DPI", .{geometry_dpi});
    }

    return if (reasonable) geometry_dpi else BASELINE_DPI;
}

/// Scale a border or gap value. Percentages are screen-relative and applied
/// as-is (no global scale, or HiDPI displays would get double-scaled);
/// absolute pixel values pass through unchanged.
/// See utils.scaling.scaleBorderWidth, the shared source of truth.
pub fn scaleBorderWidth(value: parser.ScalableValue, reference_dimension: u16) u16 {
    return utils.scaling.scaleBorderWidth(value, reference_dimension);
}

/// Returns the master width as a fraction (0.0–1.0) for percentage values,
/// or as a negative float encoding an absolute pixel value otherwise
/// (callers should treat negative results as `@abs(result)` pixels).
/// See utils.scaling.scaleMasterWidth, the shared source of truth.
pub fn scaleMasterWidth(value: parser.ScalableValue) f32 {
    return utils.scaling.scaleMasterWidth(value);
}

/// Scales a font size value against the screen height, clamped to a minimum of 1px.
/// Percentage values are relative to FONT_BASELINE_HEIGHT (1080px) rather than the
/// screen baseline, so font sizes degrade more gracefully on smaller screens.
pub fn scaleFontSize(value: parser.ScalableValue, screen: *xcb.xcb_screen_t) u16 {
    const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
    const raw = if (value.is_percentage) value.value * (screen_height / FONT_BASELINE_HEIGHT) else value.value;
    return @intFromFloat(@max(1.0, @round(raw)));
}

/// Converts a scalable bar height value to pixels, clamped to BAR_MIN_HEIGHT_PX.
pub fn scaleBarHeight(value: parser.ScalableValue, screen_height: u16) u16 {
    const screen_height_f: f32 = @floatFromInt(screen_height);
    const scaled_px: f32 = utils.scaling.scaleToPixels(value, screen_height_f);
    return @max(BAR_MIN_HEIGHT_PX, @as(u16, @intFromFloat(@round(scaled_px))));
}

// Refresh-rate detection

/// Fallback refresh rate used when RandR is unavailable or returns an invalid value.
const default_hz: f64 = 60.0;

var hz_cache: ?f64 = null;

/// Detect and cache the monitor refresh rate.
/// Subsequent calls are a single branch and a return — zero X11 I/O.
pub fn ensureRefreshRateDetected(conn: *xcb.xcb_connection_t) void {
    if (hz_cache != null) return;
    hz_cache = detectRefreshRate(conn);
}

/// Returns the detected monitor refresh rate in Hz.
/// Returns `default_hz` (60.0) when called before `ensureRefreshRateDetected`.
pub fn getDetectedRateHz() f64 {
    return hz_cache orelse default_hz;
}

/// Returns the root window ID of the first screen, or 0 if no screens are available.
fn xcbRootWindow(conn: *xcb.xcb_connection_t) u32 {
    const setup = xcb.xcb_get_setup(conn);
    const it = xcb.xcb_setup_roots_iterator(setup);
    return if (it.rem > 0) it.data.*.root else 0;
}

/// Read the refresh rate of all active CRTCs and return the highest value.
///
/// All `xcb_randr_get_crtc_info` cookies are fired before any reply is read,
/// reducing round-trips from O(crtcs) to O(1).
///
/// Returning the maximum rate rather than the first ensures correct behaviour
/// on multi-monitor setups where each display has a different refresh rate.
///
/// Returns null on any failure.
fn detectRefreshRateViaCrtc(conn: *xcb.xcb_connection_t, root: u32) ?f64 {
    const rc = xcb.xcb_randr_get_screen_resources_current(conn, root);
    const rr = xcb.xcb_randr_get_screen_resources_current_reply(conn, rc, null) orelse
        return null;
    defer std.c.free(rr);

    const mode_it_len = xcb.xcb_randr_get_screen_resources_current_modes_length(rr);
    const mode_it_ptr = xcb.xcb_randr_get_screen_resources_current_modes(rr);
    if (mode_it_len <= 0 or mode_it_ptr == null) return null;
    const modes = mode_it_ptr.?[0..@intCast(mode_it_len)];

    const crtc_it_len = xcb.xcb_randr_get_screen_resources_current_crtcs_length(rr);
    const crtc_it_ptr = xcb.xcb_randr_get_screen_resources_current_crtcs(rr);
    if (crtc_it_len <= 0 or crtc_it_ptr == null) return null;
    const crtcs = crtc_it_ptr.?[0..@intCast(crtc_it_len)];

    const max_crtcs: usize = 16;
    const n_crtcs = @min(crtcs.len, max_crtcs);
    var crtc_cookies: [max_crtcs]xcb.xcb_randr_get_crtc_info_cookie_t = undefined;
    for (crtcs[0..n_crtcs], crtc_cookies[0..n_crtcs]) |crtc, *cookie| {
        cookie.* = xcb.xcb_randr_get_crtc_info(conn, crtc, rr.*.config_timestamp);
    }

    var best_hz: f64 = 0.0;
    for (0..n_crtcs) |i| {
        const cr = xcb.xcb_randr_get_crtc_info_reply(conn, crtc_cookies[i], null) orelse continue;
        defer std.c.free(cr);

        const mode_id = cr.*.mode;
        if (mode_id == 0) continue;

        for (modes) |m| {
            if (m.id != mode_id) continue;
            const htotal: u64 = m.htotal;
            const vtotal: u64 = m.vtotal;
            if (htotal != 0 and vtotal != 0) {
                const hz: f64 = @as(f64, @floatFromInt(m.dot_clock)) /
                    @as(f64, @floatFromInt(htotal * vtotal));
                if (hz > best_hz) best_hz = hz;
            }
            break; // found the mode entry regardless; stop searching
        }
    }
    return if (best_hz > 0.0) best_hz else null;
}

/// Attempt to read the current refresh rate via `xcb_randr_get_screen_info`.
/// Falls back to CRTC mode data when rate == 0, then to `default_hz`.
fn detectRefreshRate(conn: *xcb.xcb_connection_t) f64 {
    if (!@hasDecl(xcb, "xcb_randr_get_screen_info")) return default_hz;

    const root = xcbRootWindow(conn);
    if (root == 0) return default_hz;

    const cookie = xcb.xcb_randr_get_screen_info(conn, root);
    const reply = xcb.xcb_randr_get_screen_info_reply(conn, cookie, null) orelse
        return default_hz;
    defer std.c.free(reply);

    const rate = reply.*.rate;
    if (rate > 0) return @floatFromInt(rate);

    if (@hasDecl(xcb, "xcb_randr_get_screen_resources_current"))
        if (detectRefreshRateViaCrtc(conn, root)) |hz| return hz;

    return default_hz;
}
