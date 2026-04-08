//! DPI detection and scaling utilities for consistent bar appearance across display resolutions.

const std       = @import("std");
const core      = @import("core");
const constants = @import("constants");
const debug     = @import("debug");

const xcb           = core.xcb;
const ScalableValue = @import("parser").ScalableValue;

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

fn calcScaleFromResolution(screen: *xcb.xcb_screen_t) f32 {
    const width_px:  f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    const diagonal         = @sqrt(width_px * width_px + height_px * height_px);
    const resolution_scale = diagonal / BASELINE_DIAGONAL;
    debug.info("Resolution scaling: {d:.0}x{d:.0} -> {d:.2}x baseline ({d:.0}x{d:.0})",
        .{ width_px, height_px, resolution_scale, BASELINE_WIDTH, BASELINE_HEIGHT });
    return resolution_scale;
}

/// Invalidate the DPI cache. Call this when a screen-change event is received
/// before the next detectDpi() so the values are recomputed from fresh data.
pub fn resetDpiCache() void {
    dpi_cache = null;
}

/// Detect DPI, returning a cached result until resetDpiCache() is called.
/// Priority: Xft.dpi from X resources -> geometry calculation -> resolution-based scaling.
pub fn detectDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) DpiInfo {
    if (dpi_cache) |cached| return cached;
    const result = detectDpiUncached(conn, screen);
    dpi_cache = result;
    return result;
}

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

pub fn scaleInt(base_value: anytype, scale_factor: f32) @TypeOf(base_value) {
    const T = @TypeOf(base_value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @intFromFloat(@round(@as(f32, @floatFromInt(base_value)) * scale_factor)),
        else => @compileError("scaleInt() only supports integer types; use scaleToInt() for floats"),
    };
}

pub fn scaleToInt(comptime T: type, base_value: f32, scale_factor: f32) T {
    return @intFromFloat(@round(base_value * scale_factor));
}

/// Scale a border or gap value.
/// Percentage values are screen-relative, so scale_factor is intentionally
/// excluded — applying it would double-scale on HiDPI displays.
/// Absolute pixel values are screen-independent and used as-is.
pub fn scaleBorderWidth(value: ScalableValue, reference_dimension: u16) u16 {
    if (value.is_percentage) {
        const dim_f: f32 = @floatFromInt(reference_dimension);
        return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f)));
    }
    return @intFromFloat(@max(0.0, @round(value.value)));
}

/// Alias for `scaleBorderWidth` — gaps and borders share identical scaling semantics.
pub const scaleGaps = scaleBorderWidth;

/// Returns the master width as a fraction (0.0–1.0) for percentage values,
/// or as a negative float encoding an absolute pixel value otherwise.
/// Callers should treat negative results as `@abs(result)` pixels.
pub fn scaleMasterWidth(value: ScalableValue) f32 {
    return if (value.is_percentage) value.value / 100.0 else -value.value;
}

pub fn scaleFontSize(value: ScalableValue, screen: *xcb.xcb_screen_t) u16 {
    if (value.is_percentage) {
        const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
        return @intFromFloat(@max(1.0, @round(value.value * (screen_height / FONT_BASELINE_HEIGHT))));
    }
    return @intFromFloat(@max(1.0, @round(value.value)));
}

pub fn scaleBarHeight(value: ScalableValue, screen_height: u16) u16 {
    const screen_height_f: f32 = @floatFromInt(screen_height);
    const scaled_px: f32 = if (value.is_percentage)
        screen_height_f * (value.value / 100.0)
    else
        value.value;
    return @max(BAR_MIN_HEIGHT_PX, @as(u16, @intFromFloat(@round(scaled_px))));
}
