//! DPI detection and scaling utilities.
//! Detects display DPI and scales bar dimensions for consistent appearance across resolutions.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const constants = @import("constants");
const log = @import("log");

const types = @import("types");
const atoms = @import("atoms");
const dpi_math = @import("dpi_math");
const scaling = @import("scaling");

const baseline_dpi = constants.baseline_dpi;

// Font size percentages are relative to 1080p height, not the screen's own
// resolution, so font sizing degrades more gracefully on smaller screens.
const font_baseline_height: f32 = 1080.0;

/// The bar-height policy as ONE value (6.8). These were three loose pub consts
/// a caller had to know to apply together; nothing stopped someone clamping
/// against the min and forgetting the cap. Grouping them makes "the policy"
/// a thing you can pass, not a convention you have to remember.
pub const BarHeightPolicy = struct {
    /// Minimum bar height in pixels. Callers validate config values against
    /// this before calling scaleBarHeight.
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
        .dpi = dpi_math.parseXftDpi(resource_str),
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
/// Called once at startup; core.dpi_info holds the result for the process lifetime.
pub fn detectDpi(conn: core.Connection, screen: core.Screen) f32 {
    if (readXftDpi(conn, screen)) |xft_dpi| {
        if (dpi_math.isReasonableDpi(xft_dpi)) {
            log.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
            return xft_dpi;
        }
        log.warn("Ignoring unreasonable Xft.dpi value {d:.1}", .{xft_dpi});
    }

    // 6.3: the formula is pure and returns null for a 0mm screen (the
    // "virtual display" case), so the decision and its log stay here.
    const geometry_dpi = dpi_math.calcDpiFromGeometry(.{
        .width_px = screen.width_in_pixels,
        .height_px = screen.height_in_pixels,
        .width_mm = screen.width_in_millimeters,
        .height_mm = screen.height_in_millimeters,
    }) orelse {
        log.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return baseline_dpi;
    };
    if (!dpi_math.isReasonableDpi(geometry_dpi)) {
        log.warn("Calculated DPI {d:.1} seems unreasonable, using baseline DPI", .{geometry_dpi});
        return baseline_dpi;
    }
    log.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    return geometry_dpi;
}

/// Scales a font size value against the screen height, clamped to a minimum of 1px.
/// Percentage values are relative to font_baseline_height (1080px) rather than the
/// screen baseline, so font sizes degrade more gracefully on smaller screens.
/// Note the asymmetry with scaleBarHeight below: that sibling delegates to
/// scaling.scaleToPixels because bar height is an absolute figure against
/// the screen baseline, while font size keeps this inline relative-to-1080 form.
pub fn scaleFontSize(value: types.ScalableValue, screen: core.Screen) u16 {
    const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
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
    // clampBarHeight, not a bare @max: the bare floor honored
    // bar_min_height_px but silently ignored bar_max_height_px, so a large
    // `height` could hand the bar more of the screen than the policy allows.
    return clampBarHeight(@intFromFloat(scaled_px));
}
