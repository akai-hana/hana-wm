//! DPI detection and scaling utilities
//! DPI-aware scaling for consistent bar appearance across different display resolutions

const std = @import("std");
const defs = @import("defs");
const debug = @import("debug");

const xcb = defs.xcb;

// Baseline reference: 2560x1600 display at 16:10 aspect ratio
// This is what the user's current config is designed for
const BASELINE_WIDTH: f32 = 2560.0;
const BASELINE_HEIGHT: f32 = 1600.0;
const BASELINE_DPI: f32 = 96.0; // Standard DPI

// Font size baseline: 1920x1080 (1080p)
// Font percentages are relative to this resolution
const FONT_BASELINE_WIDTH: f32 = 1920.0;
const FONT_BASELINE_HEIGHT: f32 = 1080.0;

/// DPI information and scaling factor
pub const DpiInfo = struct {
    dpi: f32,
    scale_factor: f32,
    
    /// Calculate scale factor relative to baseline
    pub fn init(dpi: f32) DpiInfo {
        return .{
            .dpi = dpi,
            .scale_factor = dpi / BASELINE_DPI,
        };
    }
};

/// Read DPI from X resources (Xft.dpi property) using XCB
/// Note: Xft.dpi is a standard X resource set in .Xresources, used by many applications for DPI scaling
fn readXftDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) ?f32 {
    // Get RESOURCE_MANAGER property from root window
    const atom_cookie = xcb.xcb_intern_atom(conn, 0, 16, "RESOURCE_MANAGER");
    const atom_reply = xcb.xcb_intern_atom_reply(conn, atom_cookie, null) orelse return null;
    defer std.c.free(atom_reply);
    
    const prop_cookie = xcb.xcb_get_property(conn, 0, screen.*.root, atom_reply.*.atom,
        xcb.XCB_ATOM_STRING, 0, std.math.maxInt(u32));
    const prop_reply = xcb.xcb_get_property_reply(conn, prop_cookie, null) orelse return null;
    defer std.c.free(prop_reply);
    
    if (prop_reply.*.format != 8 or prop_reply.*.type != xcb.XCB_ATOM_STRING) return null;
    
    const value_len = xcb.xcb_get_property_value_length(prop_reply);
    if (value_len == 0) return null;
    
    const value_ptr = xcb.xcb_get_property_value(prop_reply);
    const resource_string = @as([*]const u8, @ptrCast(value_ptr))[0..@intCast(value_len)];
    
    // Parse the resource string looking for "Xft.dpi:"
    var lines = std.mem.splitScalar(u8, resource_string, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Xft.dpi:") or 
            std.mem.startsWith(u8, trimmed, "Xft.dpi\t")) {
            // Find the value after the colon or tab
            var parts = std.mem.splitAny(u8, trimmed, ":\t");
            _ = parts.next(); // Skip "Xft.dpi"
            if (parts.next()) |value_str| {
                const value_trimmed = std.mem.trim(u8, value_str, " \t");
                const dpi = std.fmt.parseFloat(f32, value_trimmed) catch continue;
                return dpi;
            }
        }
    }
    
    return null;
}

/// Calculate DPI from display geometry
/// Uses diagonal size and pixel density to estimate DPI
fn calculateDpiFromGeometry(screen: *xcb.xcb_screen_t) f32 {
    const width_px: f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    const width_mm: f32 = @floatFromInt(screen.width_in_millimeters);
    const height_mm: f32 = @floatFromInt(screen.height_in_millimeters);
    
    // Avoid division by zero
    if (width_mm == 0 or height_mm == 0) {
        debug.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return BASELINE_DPI;
    }
    
    // Calculate DPI from horizontal and vertical separately, then average
    const dpi_x = (width_px / width_mm) * 25.4;
    const dpi_y = (height_px / height_mm) * 25.4;
    const avg_dpi = (dpi_x + dpi_y) / 2.0;
    
    debug.info("Calculated DPI: X={d:.1}, Y={d:.1}, Average={d:.1}", .{dpi_x, dpi_y, avg_dpi});
    
    return avg_dpi;
}

/// Calculate scale factor based on resolution relative to baseline
/// This is an alternative approach that scales based on screen width
fn calculateScaleFromResolution(screen: *xcb.xcb_screen_t) f32 {
    const width_px: f32 = @floatFromInt(screen.width_in_pixels);
    const height_px: f32 = @floatFromInt(screen.height_in_pixels);
    
    // Calculate diagonal in pixels
    const diagonal_px = @sqrt(width_px * width_px + height_px * height_px);
    const baseline_diagonal = @sqrt(BASELINE_WIDTH * BASELINE_WIDTH + BASELINE_HEIGHT * BASELINE_HEIGHT);
    
    // Scale based on diagonal size
    const resolution_scale = diagonal_px / baseline_diagonal;
    
    debug.info("Resolution scaling: {d}x{d} -> {d:.2}x baseline ({d}x{d})", 
        .{@as(u16, @intFromFloat(width_px)), @as(u16, @intFromFloat(height_px)), 
          resolution_scale, @as(u16, @intFromFloat(BASELINE_WIDTH)), @as(u16, @intFromFloat(BASELINE_HEIGHT))});
    
    return resolution_scale;
}

/// Detect DPI and calculate scaling factor
/// Priority:
/// 1. Xft.dpi from X resources/.Xresources (most accurate if user has set it)
/// 2. Calculated from display physical dimensions
/// 3. Resolution-based scaling as fallback
pub fn detect(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) !DpiInfo {
    // Try to get DPI from X resources (Xft.dpi property)
    if (readXftDpi(conn, screen)) |xft_dpi| {
        debug.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
        return DpiInfo.init(xft_dpi);
    }
    
    // Calculate from geometry
    const geometry_dpi = calculateDpiFromGeometry(screen);
    
    // Sanity check: if DPI seems unreasonable, use resolution-based scaling
    if (geometry_dpi < 50.0 or geometry_dpi > 300.0) {
        debug.warn("Calculated DPI {d:.1} seems unreasonable, using resolution-based scaling", .{geometry_dpi});
        const resolution_scale = calculateScaleFromResolution(screen);
        const effective_dpi = BASELINE_DPI * resolution_scale;
        debug.info("Using resolution-based DPI: {d:.1}", .{effective_dpi});
        return DpiInfo.init(effective_dpi);
    }
    
    debug.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    return DpiInfo.init(geometry_dpi);
}

/// Scale a dimension value based on DPI
pub inline fn scale(base_value: anytype, scale_factor: f32) @TypeOf(base_value) {
    const T = @TypeOf(base_value);
    const float_val: f32 = @floatFromInt(base_value);
    const scaled = float_val * scale_factor;
    
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @intFromFloat(@round(scaled)),
        .float, .comptime_float => scaled,
        else => @compileError("Unsupported type for scaling"),
    };
}

/// Scale a float value and round to integer
pub inline fn scaleToInt(comptime T: type, base_value: f32, scale_factor: f32) T {
    const scaled = base_value * scale_factor;
    return @intFromFloat(@round(scaled));
}

/// Scale a border width value
/// For absolute values: use the value as-is (DPI-independent)
/// For percentage values: 
///   - 0% = 0 pixels
///   - 100% = border and viewing area are equal (border = 50% of total space)
///   - Formula: (percentage / 100) * 0.5 * reference_dimension
pub fn scaleBorderWidth(value: @import("parser").ScalableValue, scale_factor: f32, reference_dimension: u16) u16 {
    if (value.is_percentage) {
        // For percentage: scale relative to window dimension
        // 100% means border equals viewing area (border = 50% of total)
        const dim_f: f32 = @floatFromInt(reference_dimension);
        const border_px = (value.value / 100.0) * 0.5 * dim_f * scale_factor;
        const result: u16 = @intFromFloat(@max(0.0, @round(border_px)));
        return result;
    } else {
        // Absolute value - use as-is, no DPI scaling
        const result: u16 = @intFromFloat(@max(0.0, @round(value.value)));
        return result;
    }
}

/// Scale gap value between tiled windows (same semantics as scaleBorderWidth)
pub const scaleGaps = scaleBorderWidth;

/// Scale master width value
/// For absolute values: use the value as-is in pixels
/// For percentage values: interpret as percentage (0-100) and convert to ratio (0.0-1.0)
pub fn scaleMasterWidth(value: @import("parser").ScalableValue) f32 {
    if (value.is_percentage) {
        // Convert percentage to ratio (50% -> 0.50)
        return value.value / 100.0;
    } else {
        // Absolute value in pixels - will need to be converted to ratio based on screen width
        // Return negative to indicate it's absolute pixels (caller will handle conversion)
        return -value.value;
    }
}

/// Scale font size based on 1080p baseline
/// For percentage values: scale relative to 1080p
///   - 12% on 1080p = 12 pixels
///   - 12% on 1440p = 12 * (1440/1080) = 16 pixels
/// For absolute values: use as-is (no scaling)
pub fn scaleFontSize(value: @import("parser").ScalableValue, screen: *@import("defs").xcb.xcb_screen_t) u16 {
    if (value.is_percentage) {
        // Scale based on screen height relative to 1080p
        const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
        const scale_factor = screen_height / FONT_BASELINE_HEIGHT;
        const scaled_size = value.value * scale_factor;
        return @intFromFloat(@max(1.0, @round(scaled_size)));
    } else {
        // Absolute value - use as-is
        return @intFromFloat(@max(1.0, @round(value.value)));
    }
}
