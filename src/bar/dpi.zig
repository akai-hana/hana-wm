//! DPI detection and scaling utilities for consistent bar appearance across display resolutions.

const std   = @import("std");
const defs  = @import("defs");
const debug = @import("debug");

const xcb = defs.xcb;

const BASELINE_WIDTH:  f32 = 2560.0;
const BASELINE_HEIGHT: f32 = 1600.0;
const BASELINE_DPI:    f32 = 96.0;

const FONT_BASELINE_HEIGHT: f32 = 1080.0;

const BASELINE_DIAGONAL: f32 = @sqrt(BASELINE_WIDTH * BASELINE_WIDTH + BASELINE_HEIGHT * BASELINE_HEIGHT);

const DpiCache = struct {
    result:           ?DpiInfo = null,
    screen_signature: u64      = 0,
};

var dpi_cache: DpiCache = .{};

const COMMON_DPI_TABLE = [_]struct { dpi: f32, name: []const u8 }{
    .{ .dpi =  96.0, .name = "1x (Standard)" },
    .{ .dpi = 120.0, .name = "1.25x" },
    .{ .dpi = 144.0, .name = "1.5x (High DPI)" },
    .{ .dpi = 192.0, .name = "2x (Retina)" },
};

const ScreenDimensions = struct {
    width_px:  f32,
    height_px: f32,
    width_mm:  f32,
    height_mm: f32,

    fn from(screen: *xcb.xcb_screen_t) ScreenDimensions {
        return .{
            .width_px  = @floatFromInt(screen.width_in_pixels),
            .height_px = @floatFromInt(screen.height_in_pixels),
            .width_mm  = @floatFromInt(screen.width_in_millimeters),
            .height_mm = @floatFromInt(screen.height_in_millimeters),
        };
    }

    fn diagonalPx(self: ScreenDimensions) f32 {
        return @sqrt(self.width_px * self.width_px + self.height_px * self.height_px);
    }
};

pub const DpiInfo = struct {
    dpi:          f32,
    scale_factor: f32,

    pub fn init(dpi: f32) DpiInfo {
        return .{ .dpi = dpi, .scale_factor = dpi / BASELINE_DPI };
    }
};

fn readXftDpi(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) ?f32 {
    const atom_cookie = xcb.xcb_intern_atom(conn, 0, 16, "RESOURCE_MANAGER");
    const atom_reply  = xcb.xcb_intern_atom_reply(conn, atom_cookie, null) orelse return null;
    defer std.c.free(atom_reply);

    const prop_cookie = xcb.xcb_get_property(conn, 0, screen.*.root, atom_reply.*.atom,
        xcb.XCB_ATOM_STRING, 0, std.math.maxInt(u32));
    const prop_reply = xcb.xcb_get_property_reply(conn, prop_cookie, null) orelse return null;
    defer std.c.free(prop_reply);

    if (prop_reply.*.format != 8 or prop_reply.*.type != xcb.XCB_ATOM_STRING) return null;

    const value_len = xcb.xcb_get_property_value_length(prop_reply);
    if (value_len == 0) return null;

    const value_ptr    = xcb.xcb_get_property_value(prop_reply);
    const resource_str = @as([*]const u8, @ptrCast(value_ptr))[0..@intCast(value_len)];

    var lines = std.mem.splitScalar(u8, resource_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "Xft.dpi:") or
            std.mem.startsWith(u8, trimmed, "Xft.dpi\t"))
        {
            var parts = std.mem.splitAny(u8, trimmed, ":\t");
            _ = parts.next();
            if (parts.next()) |val| {
                const dpi = std.fmt.parseFloat(f32, std.mem.trim(u8, val, " \t")) catch continue;
                return dpi;
            }
        }
    }
    return null;
}

fn calculateDpiFromGeometry(screen: *xcb.xcb_screen_t) f32 {
    const dims = ScreenDimensions.from(screen);
    if (dims.width_mm == 0 or dims.height_mm == 0) {
        debug.warn("Display reports 0mm dimensions, using baseline DPI", .{});
        return BASELINE_DPI;
    }
    const dpi_x   = (dims.width_px  / dims.width_mm)  * 25.4;
    const dpi_y   = (dims.height_px / dims.height_mm) * 25.4;
    const avg_dpi = (dpi_x + dpi_y) / 2.0;
    debug.info("Calculated DPI: X={d:.1}, Y={d:.1}, Average={d:.1}", .{ dpi_x, dpi_y, avg_dpi });
    return avg_dpi;
}

fn snapToCommonDPI(dpi: f32) f32 {
    var closest  = COMMON_DPI_TABLE[0];
    var min_diff = @abs(dpi - closest.dpi);
    for (COMMON_DPI_TABLE[1..]) |entry| {
        const diff = @abs(dpi - entry.dpi);
        if (diff < min_diff) { min_diff = diff; closest = entry; }
    }
    if (min_diff / closest.dpi < 0.05) {
        debug.info("Snapped DPI {d:.1} to common value {d:.1} ({s})",
            .{ dpi, closest.dpi, closest.name });
        return closest.dpi;
    }
    return dpi;
}

fn calculateScaleFromResolution(screen: *xcb.xcb_screen_t) f32 {
    const dims             = ScreenDimensions.from(screen);
    const resolution_scale = dims.diagonalPx() / BASELINE_DIAGONAL;
    debug.info("Resolution scaling: {d}x{d} -> {d:.2}x baseline ({d}x{d})",
        .{ @as(u16, @intFromFloat(dims.width_px)), @as(u16, @intFromFloat(dims.height_px)),
           resolution_scale, @as(u16, @intFromFloat(BASELINE_WIDTH)), @as(u16, @intFromFloat(BASELINE_HEIGHT)) });
    return resolution_scale;
}

/// Detects DPI with caching. Detection priority:
///   1. `Xft.dpi` from X resources
///   2. Calculated from display physical dimensions
///   3. Resolution-based scaling as a last resort
pub fn detect(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) !DpiInfo {
    const sig =
        (@as(u64, screen.width_in_pixels)        << 48) |
        (@as(u64, screen.height_in_pixels)        << 32) |
        (@as(u64, screen.width_in_millimeters)    << 16) |
         @as(u64, screen.height_in_millimeters);

    if (dpi_cache.result) |cached| {
        if (dpi_cache.screen_signature == sig) return cached;
    }

    const result               = try detectFresh(conn, screen);
    dpi_cache.result           = result;
    dpi_cache.screen_signature = sig;
    return result;
}

fn detectFresh(conn: *xcb.xcb_connection_t, screen: *xcb.xcb_screen_t) !DpiInfo {
    if (readXftDpi(conn, screen)) |xft_dpi| {
        debug.info("Using DPI from X resources (Xft.dpi): {d:.1}", .{xft_dpi});
        return DpiInfo.init(snapToCommonDPI(xft_dpi));
    }

    var geometry_dpi = calculateDpiFromGeometry(screen);
    if (geometry_dpi < 50.0 or geometry_dpi > 300.0) {
        debug.warn("Calculated DPI {d:.1} seems unreasonable, using resolution-based scaling", .{geometry_dpi});
        geometry_dpi = BASELINE_DPI * calculateScaleFromResolution(screen);
        debug.info("Using resolution-based DPI: {d:.1}", .{geometry_dpi});
    } else {
        debug.info("Using geometry-calculated DPI: {d:.1}", .{geometry_dpi});
    }

    return DpiInfo.init(snapToCommonDPI(geometry_dpi));
}

pub inline fn scale(base_value: anytype, scale_factor: f32) @TypeOf(base_value) {
    const T = @TypeOf(base_value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @intFromFloat(@round(@as(f32, @floatFromInt(base_value)) * scale_factor)),
        else => @compileError("scale() only supports integer types; use scaleToInt() for floats"),
    };
}

pub inline fn scaleToInt(comptime T: type, base_value: f32, scale_factor: f32) T {
    return @intFromFloat(@round(base_value * scale_factor));
}

pub fn scaleBorderWidth(value: @import("parser").ScalableValue, scale_factor: f32, reference_dimension: u16) u16 {
    if (value.is_percentage) {
        const dim_f: f32 = @floatFromInt(reference_dimension);
        return @intFromFloat(@max(0.0, @round((value.value / 100.0) * 0.5 * dim_f * scale_factor)));
    } else {
        return @intFromFloat(@max(0.0, @round(value.value)));
    }
}

/// Alias for `scaleBorderWidth` — gaps and borders share identical scaling semantics.
pub const scaleGaps = scaleBorderWidth;

pub fn scaleMasterWidth(value: @import("parser").ScalableValue) f32 {
    return if (value.is_percentage) value.value / 100.0 else -value.value;
}

pub fn scaleFontSize(value: @import("parser").ScalableValue, screen: *@import("defs").xcb.xcb_screen_t) u16 {
    if (value.is_percentage) {
        const screen_height: f32 = @floatFromInt(screen.height_in_pixels);
        return @intFromFloat(@max(1.0, @round(value.value * (screen_height / FONT_BASELINE_HEIGHT))));
    } else {
        return @intFromFloat(@max(1.0, @round(value.value)));
    }
}

pub fn scaleBarHeight(value: @import("parser").ScalableValue, screen_height: u16) u16 {
    const MIN_PX: u16 = 20;
    const h: f32  = @floatFromInt(screen_height);
    const px: f32 = if (value.is_percentage)
        h * (value.value / 100.0)
    else
        value.value;
    return @max(MIN_PX, @as(u16, @intFromFloat(@round(px))));
}
