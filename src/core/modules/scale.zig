//! DPI detection and scaling utilities for consistent bar appearance across display resolutions.

const std = @import("std");

const core      = @import("core");
    const xcb   = core.xcb;
const constants = @import("constants");
const debug     = @import("debug");

const parser = @import("parser");

// Baseline screen used to define "1× scale". All percentage-based values
// are computed relative to this reference display.
const BASELINE_WIDTH:  f32 = 2560.0;
const BASELINE_HEIGHT: f32 = 1600.0;
const BASELINE_DPI          = constants.BASELINE_DPI;

// Font size percentages are relative to 1080 p height, not the baseline display,
// so font sizing degrades more gracefully on smaller screens.
const FONT_BASELINE_HEIGHT: f32 = 1080.0;

const BASELINE_DIAGONAL: f32 = @sqrt(BASELINE_WIDTH * BASELINE_WIDTH + BASELINE_HEIGHT * BASELINE_HEIGHT);

/// Snap to a common DPI value if within 5% of it, to avoid rendering at odd
/// intermediate DPIs caused by imprecise monitor EDID data.
const SNAP_THRESHOLD: f32 = 0.05;

/// Minimum bar height in pixels. Exposed so callers can validate config values
/// before passing them to scaleBarHeight.
pub const BAR_MIN_HEIGHT_PX: u16 = 20;

/// Maximum long-words to request for the RESOURCE_MANAGER property (16 KB).
const RESOURCE_MANAGER_MAX_LEN: u32 = 4096;

// Not thread-safe; assumes detectDpi() is only called from the main thread.
var dpi_cache: ?DpiInfo = null;

const COMMON_DPI_TABLE = [_]f32{ 96.0, 120.0, 144.0, 192.0 };

/// Re-exported from core so callers that only import scale still get the type.
pub const DpiInfo = core.DpiInfo;

/// Reads the Xft.dpi value from the X RESOURCE_MANAGER property, if present.
/// Returns null when the property is absent, empty, or does not contain an Xft.dpi entry.
fn readXftDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) ?f32 {
    const atom_cookie = xcb.xcb_intern_atom(conn, 0, "RESOURCE_MANAGER".len, "RESOURCE_MANAGER");
    const atom_reply  = xcb.xcb_intern_atom_reply(conn, atom_cookie, null) orelse return null;
    defer std.c.free(atom_reply);

    const prop_cookie = xcb.xcb_get_property(conn, 0, screen.*.root, atom_reply.*.atom,
        xcb.XCB_ATOM_STRING, 0, RESOURCE_MANAGER_MAX_LEN);
    const prop_reply = xcb.xcb_get_property_reply(conn, prop_cookie, null) orelse return null;
    defer std.c.free(prop_reply);

    if (prop_reply.*.format != 8 or prop_reply.*.type != xcb.XCB_ATOM_STRING) return null;

    const value_len = xcb.xcb_get_property_value_length(prop_reply);
    if (value_len == 0) return null;

    const value_ptr    = xcb.xcb_get_property_value(prop_reply);
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
            const dpi  = std.fmt.parseFloat(f32, rest) catch continue;
            return dpi;
        }
    }
    return null;
}

/// Computes DPI from the screen's physical dimensions reported by X.
/// Returns BASELINE_DPI if the screen reports 0mm dimensions (e.g. virtual displays).
fn calcDpiFromGeometry(screen: *xcb.xcb_screen_t) f32 {
    const width_px:  f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    const width_mm:  f32 = @floatFromInt(screen.width_in_millimeters);
    const height_mm: f32 = @floatFromInt(screen.height_in_millimeters);
    if (width_mm == 0 or height_mm == 0) {
        debug.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return BASELINE_DPI;
    }
    const dpi_x   = (width_px  / width_mm)  * 25.4;
    const dpi_y   = (height_px / height_mm) * 25.4;
    const avg_dpi = (dpi_x + dpi_y) / 2.0;
    debug.info("Calculated DPI: X={d:.1}, Y={d:.1}, Average={d:.1}", .{ dpi_x, dpi_y, avg_dpi });
    return avg_dpi;
}

/// Returns the entry in COMMON_DPI_TABLE nearest to `dpi`, snapping only when
/// within SNAP_THRESHOLD of it to avoid rendering at odd intermediate DPIs.
fn snapToCommonDpi(dpi: f32) f32 {
    var closest = COMMON_DPI_TABLE[0];
    for (COMMON_DPI_TABLE[1..]) |entry| {
        if (@abs(dpi - entry) < @abs(dpi - closest)) closest = entry;
    }
    if (@abs(dpi - closest) / closest < SNAP_THRESHOLD) {
        debug.info("Snapped DPI {d:.1} to common value {d:.1}", .{ dpi, closest });
        return closest;
    }
    return dpi;
}

/// Computes a scale factor from the screen's pixel diagonal relative to the baseline display.
/// Used as a fallback when geometry-based DPI is out of a plausible range.
fn calcScaleFromResolution(screen: *xcb.xcb_screen_t) f32 {
    const width_px:  f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    const diagonal         = @sqrt(width_px * width_px + height_px * height_px);
    const resolution_scale = diagonal / BASELINE_DIAGONAL;
    debug.info("Resolution scaling: {d:.0}x{d:.0} -> {d:.2}x baseline ({d:.0}x{d:.0})",
        .{ width_px, height_px, resolution_scale, BASELINE_WIDTH, BASELINE_HEIGHT });
    return resolution_scale;
}

/// Detect DPI, returning a cached result until the DPI cache is invalidated.
/// Priority: Xft.dpi from X resources -> geometry calculation -> resolution-based scaling.
pub fn detectDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) DpiInfo {
    if (dpi_cache) |cached| return cached;
    const result = detectDpiUncached(conn, screen);
    dpi_cache = result;
    return result;
}

/// Performs the actual DPI detection without consulting or updating the cache.
fn detectDpiUncached(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) DpiInfo {
    if (readXftDpi(conn, screen)) |xft_dpi| {
        debug.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
        return DpiInfo.fromDpi(snapToCommonDpi(xft_dpi));
    }

    var geometry_dpi = calcDpiFromGeometry(screen);
    if (geometry_dpi < 50.0 or geometry_dpi > 300.0) {
        debug.warn("Calculated DPI {d:.1} seems unreasonable, using resolution-based scaling", .{geometry_dpi});
        geometry_dpi = BASELINE_DPI * calcScaleFromResolution(screen);
        debug.info("Using resolution-based DPI: {d:.1}", .{geometry_dpi});
    } else {
        debug.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    }

    return DpiInfo.fromDpi(snapToCommonDpi(geometry_dpi));
}

/// Scales an integer value by `scale_factor`, rounding to the nearest integer.
pub fn scaleInt(base_value: anytype, scale_factor: f32) @TypeOf(base_value) {
    const T = @TypeOf(base_value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @intFromFloat(@round(@as(f32, @floatFromInt(base_value)) * scale_factor)),
        else => @compileError("scaleInt() only supports integer types; use scaleToInt() for floats"),
    };
}

/// Scales a float value by `scale_factor` and rounds to the nearest integer of type `T`.
pub fn scaleToInt(comptime T: type, base_value: f32, scale_factor: f32) T {
    return @intFromFloat(@round(base_value * scale_factor));
}

/// Scale a border or gap value.
/// Percentage values are screen-relative, so scale_factor is intentionally
/// excluded — applying it would double-scale on HiDPI displays.
/// Absolute pixel values are screen-independent and used as-is.
pub fn scaleBorderWidth(value: parser.ScalableValue, reference_dimension: u16) u16 {
    if (value.is_percentage) {
        const dim_f: f32 = @floatFromInt(reference_dimension);
        return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f)));
    }
    return @intFromFloat(@max(0.0, @round(value.value)));
}

/// Returns the master width as a fraction (0.0–1.0) for percentage values,
/// or as a negative float encoding an absolute pixel value otherwise.
/// Callers should treat negative results as `@abs(result)` pixels.
pub fn scaleMasterWidth(value: parser.ScalableValue) f32 {
    return if (value.is_percentage) value.value / 100.0 else -value.value;
}

/// Scales a font size value against the screen height, clamped to a minimum of 1px.
/// Percentage values are relative to FONT_BASELINE_HEIGHT (1080px) rather than the
/// screen baseline, so font sizes degrade more gracefully on smaller screens.
pub fn scaleFontSize(value: parser.ScalableValue, screen: *xcb.xcb_screen_t) u16 {
    if (value.is_percentage) {
        const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
        return @intFromFloat(@max(1.0, @round(value.value * (screen_height / FONT_BASELINE_HEIGHT))));
    }
    return @intFromFloat(@max(1.0, @round(value.value)));
}

/// Converts a scalable bar height value to pixels, clamped to BAR_MIN_HEIGHT_PX.
pub fn scaleBarHeight(value: parser.ScalableValue, screen_height: u16) u16 {
    const screen_height_f: f32 = @floatFromInt(screen_height);
    const scaled_px: f32 = if (value.is_percentage)
        screen_height_f * (value.value / 100.0)
    else
        value.value;
    return @max(BAR_MIN_HEIGHT_PX, @as(u16, @intFromFloat(@round(scaled_px))));
}

// Refresh-rate detection

/// Fallback refresh rate used when RandR is unavailable or returns an invalid value.
pub const default_hz: f64 = 60.0;

const HzCache = struct {
    hz:       f64  = default_hz,
    is_ready: bool = false,
};
var hz_cache: HzCache = .{};

/// Detect and cache the monitor refresh rate.
/// Subsequent calls are a single branch and a return — zero X11 I/O.
pub fn ensureRefreshRateDetected(conn: *xcb.xcb_connection_t) void {
    if (hz_cache.is_ready) return;
    hz_cache.is_ready = true;
    hz_cache.hz       = detectRefreshRate(conn);
}

/// Returns the root window ID of the first screen, or 0 if no screens are available.
fn xcbRootWindow(conn: *xcb.xcb_connection_t) u32 {
    const setup = xcb.xcb_get_setup(conn);
    var it      = xcb.xcb_setup_roots_iterator(setup);
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
    const n_crtcs          = @min(crtcs.len, max_crtcs);
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
            if (htotal == 0 or vtotal == 0) break;
            const hz: f64 = @as(f64, @floatFromInt(m.dot_clock)) /
                @as(f64, @floatFromInt(htotal * vtotal));
            if (hz > best_hz) best_hz = hz;
            break;
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
    const reply  = xcb.xcb_randr_get_screen_info_reply(conn, cookie, null) orelse
        return default_hz;
    defer std.c.free(reply);

    const rate = reply.*.rate;
    if (rate > 0) return @floatFromInt(rate);

    if (@hasDecl(xcb, "xcb_randr_get_screen_resources_current"))
        if (detectRefreshRateViaCrtc(conn, root)) |hz| return hz;

    return default_hz;
}