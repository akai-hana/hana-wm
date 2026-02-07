//! Status bar text drawing/rendering using Cairo and Pango
//! Cairo handles graphics and compositing, Pango handles text layout and fonts

const std = @import("std");
const debug = @import("debug");
const defs = @import("defs");
const c = @import("c_bindings");

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    conn: *c.xcb_connection_t,
    drawable: u32,
    width: u16,
    height: u16,
    
    // Cairo structures
    surface: *c.cairo_surface_t,
    ctx: *c.cairo_t,
    
    // Pango for text rendering
    pango_layout: *c.PangoLayout,
    current_font_desc: ?*c.PangoFontDescription = null,
    
    // Alpha override for bar transparency (0xFFFF = opaque, 0x0000 = fully transparent)
    alpha_override: ?u16 = null,
    
    pub fn init(allocator: std.mem.Allocator, conn: *c.xcb_connection_t, drawable: u32, width: u16, height: u16, dpi: f32) !*DrawContext {
        return initWithVisual(allocator, conn, drawable, width, height, null, 0, dpi);
    }
    
    pub fn initWithVisual(allocator: std.mem.Allocator, conn: *c.xcb_connection_t, 
                          drawable: u32, width: u16, height: u16, 
                          visual_id: ?u32, colormap_id: u32, dpi: f32) !*DrawContext {
        _ = colormap_id; // Not needed for Cairo XCB
        
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);
        
        // Get screen from XCB
        const setup = c.xcb_get_setup(conn);
        var screen_iter = c.xcb_setup_roots_iterator(setup);
        const screen = screen_iter.data;
        
        // Find visual type
        const visual_type = if (visual_id) |vid| 
            findVisualType(conn, vid) orelse getDefaultVisualType(screen)
        else 
            getDefaultVisualType(screen);
        
        // Create Cairo XCB surface
        const surface = c.cairo_xcb_surface_create(
            conn,
            drawable,
            visual_type,
            @intCast(width),
            @intCast(height)
        ) orelse return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);
        
        // Create Cairo context
        const ctx = c.cairo_create(surface) orelse {
            return error.CairoCreateFailed;
        };
        errdefer c.cairo_destroy(ctx);
        
        // Create Pango layout for text rendering
        const layout = c.pango_cairo_create_layout(ctx) orelse {
            return error.PangoLayoutCreateFailed;
        };
        
        // CRITICAL: Set Pango's DPI resolution to match display
        // Font sizes in config are in points, which need DPI to convert to pixels
        // Without this, Pango defaults to 96 DPI, making fonts render at wrong size
        const pango_context = c.pango_layout_get_context(layout);
        c.pango_cairo_context_set_resolution(pango_context, @floatCast(dpi));
        
        dc.* = .{
            .allocator = allocator,
            .conn = conn,
            .drawable = drawable,
            .width = width,
            .height = height,
            .surface = surface,
            .ctx = ctx,
            .pango_layout = layout,
        };
        
        return dc;
    }
    
    pub fn deinit(self: *DrawContext) void {
        if (self.current_font_desc) |desc| {
            c.pango_font_description_free(desc);
        }
        c.g_object_unref(self.pango_layout);
        c.cairo_destroy(self.ctx);
        c.cairo_surface_destroy(self.surface);
        self.allocator.destroy(self);
    }
    
    pub fn setAlphaOverride(self: *DrawContext, alpha: ?u16) void {
        self.alpha_override = alpha;
    }
    
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        if (self.current_font_desc) |desc| {
            c.pango_font_description_free(desc);
        }
        
        // Convert Xft-style font names to Pango format if needed
        const pango_name = try convertFontName(self.allocator, font_name);
        defer if (pango_name.ptr != font_name.ptr) self.allocator.free(pango_name);
        
        const pango_name_z = try self.allocator.dupeZ(u8, pango_name);
        defer self.allocator.free(pango_name_z);
        
        self.current_font_desc = c.pango_font_description_from_string(pango_name_z.ptr);
        if (self.current_font_desc == null) {
            debug.warn("Failed to load font '{s}', using default", .{font_name});
            self.current_font_desc = c.pango_font_description_from_string("monospace 10");
        }
        
        c.pango_layout_set_font_description(self.pango_layout, self.current_font_desc);
        debug.info("Cairo/Pango font loaded: {s}", .{pango_name});
    }
    
    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        // Pango handles font fallback automatically via fontconfig
        // Just load the first font, Pango will use others as fallbacks
        if (font_names.len > 0) {
            try self.loadFont(font_names[0]);
            
            if (font_names.len > 1) {
                debug.info("Font fallback: Pango will automatically use {} additional fonts for missing glyphs", .{font_names.len - 1});
            }
        } else {
            try self.loadFont("monospace:size=10");
        }
    }
    
    /// Helper: Convert RGB color to Cairo RGBA components
    /// Returns (r, g, b, a) as f64 values in 0.0-1.0 range
    inline fn rgbToRGBA(color: u32, alpha_override: ?u16) struct { f64, f64, f64, f64 } {
        const r = @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
        const g = @as(f64, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
        const b = @as(f64, @floatFromInt(color & 0xFF)) / 255.0;
        const a = if (alpha_override) |alpha|
            @as(f64, @floatFromInt(alpha)) / 65535.0
        else
            1.0;
        return .{ r, g, b, a };
    }
    
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const r, const g, const b, const a = rgbToRGBA(color, self.alpha_override);
        
        c.cairo_set_source_rgba(self.ctx, r, g, b, a);
        c.cairo_rectangle(self.ctx, @floatFromInt(x), @floatFromInt(y), 
                         @floatFromInt(width), @floatFromInt(height));
        c.cairo_fill(self.ctx);
    }
    
    /// Draw text at the specified position
    /// x: horizontal position (left edge)
    /// y: vertical position (baseline) - use dc.baselineY() for centering
    /// text: UTF-8 text to render
    /// color: RGB color (0xRRGGBB format)
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        const r, const g, const b, const a = rgbToRGBA(color, self.alpha_override);
        c.cairo_set_source_rgba(self.ctx, r, g, b, a);
        
        // Set text in Pango layout
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
        
        // Pango draws from top-left. Y parameter is the baseline position.
        // Get baseline offset from the layout (works for any font, including fallbacks)
        const baseline = c.pango_layout_get_baseline(self.pango_layout);
        const baseline_pixels: f64 = @as(f64, @floatFromInt(baseline)) / @as(f64, @floatFromInt(c.PANGO_SCALE));
        
        // Move to baseline - baseline_offset = top of layout
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - baseline_pixels);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
    }
    
    pub fn drawTextEllipsis(self: *DrawContext, x: u16, y: u16, text: []const u8, 
                           max_width: u16, color: u32) !void {
        // Set text
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
        
        // Set ellipsize mode and width
        c.pango_layout_set_width(self.pango_layout, @intCast(@as(i32, max_width) * c.PANGO_SCALE));
        c.pango_layout_set_ellipsize(self.pango_layout, c.PANGO_ELLIPSIZE_END);
        
        const r, const g, const b, const a = rgbToRGBA(color, self.alpha_override);
        c.cairo_set_source_rgba(self.ctx, r, g, b, a);
        
        // Pango draws from top-left, but our API uses baseline Y
        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout),
            self.current_font_desc,
            null
        );
        defer c.pango_font_metrics_unref(metrics);
        
        const ascent = c.pango_font_metrics_get_ascent(metrics);
        const ascent_pixels: f64 = @as(f64, @floatFromInt(ascent)) / @as(f64, @floatFromInt(c.PANGO_SCALE));
        
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - ascent_pixels);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
        
        // Reset ellipsize for next draw
        c.pango_layout_set_width(self.pango_layout, -1);
        c.pango_layout_set_ellipsize(self.pango_layout, c.PANGO_ELLIPSIZE_NONE);
    }
    
    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
        
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.pango_layout_get_pixel_size(self.pango_layout, &width, &height);
        
        return @intCast(width);
    }
    
    /// Get ascender and descender metrics in one call (optimization)
    /// Returns (ascender, descender) both as positive values
    fn getMetrics(self: *DrawContext) struct { i16, i16 } {
        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout),
            self.current_font_desc,
            null
        );
        defer c.pango_font_metrics_unref(metrics);
        
        const ascent = c.pango_font_metrics_get_ascent(metrics);
        const descent = c.pango_font_metrics_get_descent(metrics);
        
        return .{
            @intCast(@divTrunc(ascent, c.PANGO_SCALE)),
            @intCast(@divTrunc(descent, c.PANGO_SCALE)),
        };
    }
    
    pub fn getAscender(self: *DrawContext) i16 {
        const asc, _ = self.getMetrics();
        return asc;
    }
    
    pub fn getDescender(self: *DrawContext) i16 {
        _, const desc = self.getMetrics();
        return -@as(i16, desc); // Return as negative
    }
    
    pub inline fn flush(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
    }
    
    /// Calculate baseline Y position for vertical centering in the bar
    /// This uses the primary font's metrics for consistent alignment across all segments
    pub inline fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.getMetrics();
        const text_height = asc + desc;
        
        // Calculate padding to vertically center the text
        const total_pad = @as(i32, bar_height) - text_height;
        const top_pad: i32 = @max(0, @divTrunc(total_pad, 2));
        
        // Baseline Y = top padding + ascender height
        const baseline_y: i32 = top_pad + asc;
        return @intCast(baseline_y);
    }
};

// Helper to find visual type from visual ID
fn findVisualType(conn: *c.xcb_connection_t, visual_id: u32) ?*c.xcb_visualtype_t {
    const setup = c.xcb_get_setup(conn);
    var screen_iter = c.xcb_setup_roots_iterator(setup);
    
    while (screen_iter.rem > 0) {
        const screen = screen_iter.data;
        var depth_iter = c.xcb_screen_allowed_depths_iterator(screen);
        
        while (depth_iter.rem > 0) {
            var visual_iter = c.xcb_depth_visuals_iterator(depth_iter.data);
            
            while (visual_iter.rem > 0) {
                if (visual_iter.data.*.visual_id == visual_id) {
                    return visual_iter.data;
                }
                c.xcb_visualtype_next(&visual_iter);
            }
            c.xcb_depth_next(&depth_iter);
        }
        c.xcb_screen_next(&screen_iter);
    }
    
    return null;
}

fn getDefaultVisualType(screen: *c.xcb_screen_t) *c.xcb_visualtype_t {
    var depth_iter = c.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) {
        var visual_iter = c.xcb_depth_visuals_iterator(depth_iter.data);
        if (visual_iter.rem > 0) {
            return visual_iter.data;
        }
        c.xcb_depth_next(&depth_iter);
    }
    unreachable;
}

// Convert Xft-style font names to Pango format
// "monospace:size=10" -> "monospace 10"
// "DejaVu Sans:size=12:weight=bold" -> "DejaVu Sans Bold 12"
// "FiraCode Nerd Font Ret" -> "FiraCode Nerd Font Ret" (unchanged)
fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![]const u8 {
    // If it already looks like Pango format (no colons), return as-is
    if (std.mem.indexOfScalar(u8, xft_name, ':') == null) {
        return xft_name;
    }
    
    var result = try std.ArrayList(u8).initCapacity(allocator, xft_name.len);
    errdefer result.deinit(allocator);
    
    var parts = std.mem.splitScalar(u8, xft_name, ':');
    const family = parts.first();
    try result.appendSlice(allocator, family);
    
    var size: ?[]const u8 = null;
    var weight: ?[]const u8 = null;
    var slant: ?[]const u8 = null;
    
    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "size=")) {
            size = part[5..];
        } else if (std.mem.startsWith(u8, part, "pixelsize=")) {
            size = part[10..];
        } else if (std.mem.startsWith(u8, part, "weight=")) {
            weight = part[7..];
        } else if (std.mem.startsWith(u8, part, "slant=")) {
            slant = part[6..];
        }
    }
    
    // Add slant
    if (slant) |s| {
        if (std.mem.eql(u8, s, "italic") or std.mem.eql(u8, s, "oblique")) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, "Italic");
        }
    }
    
    // Add weight
    if (weight) |w| {
        if (std.mem.eql(u8, w, "bold")) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, "Bold");
        } else if (std.mem.eql(u8, w, "light")) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, "Light");
        }
    }
    
    // Add size
    if (size) |s| {
        try result.append(allocator, ' ');
        try result.appendSlice(allocator, s);
    }
    
    return result.toOwnedSlice(allocator);
}
