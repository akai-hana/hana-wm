//! Status bar text drawing/rendering using Cairo and Pango
//! Cairo handles graphics and compositing, Pango handles text layout and fonts
//! OPTIMIZED: Added metrics caching and color state tracking

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
    
    // Cairo structures (for text rendering only)
    surface: *c.cairo_surface_t,
    ctx: *c.cairo_t,
    
    // XCB graphics context (for background rectangles - like window borders)
    gc: u32,
    
    // Pango for text rendering
    pango_layout: *c.PangoLayout,
    current_font_desc: ?*c.PangoFontDescription = null,
    
    // Alpha override for window opacity (not used for Cairo anymore)
    alpha_override: ?u16 = null,
    
    // OPTIMIZATION: Cache font metrics to avoid repeated Pango calls
    cached_metrics: ?struct {
        ascent: i16,
        descent: i16,
    } = null,
    
    // OPTIMIZATION: Track last color to avoid redundant Cairo calls
    last_color: ?struct {
        color: u32,
        alpha: ?u16,
    } = null,
    
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
            .gc = 0, // Will be created below
        };
        
        // Create XCB graphics context for direct rectangle drawing (like window borders)
        dc.gc = defs.xcb.xcb_generate_id(conn);
        _ = defs.xcb.xcb_create_gc(conn, dc.gc, drawable, 0, null);
        
        return dc;
    }
    
    pub fn deinit(self: *DrawContext) void {
        if (self.current_font_desc) |desc| {
            c.pango_font_description_free(desc);
        }
        // Free XCB graphics context
        _ = defs.xcb.xcb_free_gc(self.conn, self.gc);
        
        c.g_object_unref(self.pango_layout);
        c.cairo_destroy(self.ctx);
        c.cairo_surface_destroy(self.surface);
        self.allocator.destroy(self);
    }
    
    pub fn setAlphaOverride(self: *DrawContext, alpha: ?u16) void {
        self.alpha_override = alpha;
        // OPTIMIZATION: Invalidate color cache when alpha changes
        self.last_color = null;
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
        
        // OPTIMIZATION: Invalidate cached metrics when font changes
        self.cached_metrics = null;
        
        debug.info("Cairo/Pango font loaded: {s}", .{pango_name});
    }
    
    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        // Pango handles font fallback automatically via fontconfig
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
    
    /// OPTIMIZATION: Set color only if changed (for backgrounds, uses alpha_override)
    inline fn setColorForBackground(self: *DrawContext, color: u32) void {
        if (self.last_color) |last| {
            if (last.color == color and last.alpha == self.alpha_override) {
                return; // Color unchanged, skip Cairo call
            }
        }
        
        const r, const g, const b, const a = rgbToRGBA(color, self.alpha_override);
        c.cairo_set_source_rgba(self.ctx, r, g, b, a);
        self.last_color = .{ .color = color, .alpha = self.alpha_override };
    }
    
    /// OPTIMIZATION: Set color for text (ALWAYS opaque, ignores alpha_override)
    inline fn setColorForText(self: *DrawContext, color: u32) void {
        if (self.last_color) |last| {
            if (last.color == color and last.alpha == null) {
                return; // Color unchanged, skip Cairo call
            }
        }
        
        const r, const g, const b, const a = rgbToRGBA(color, null); // Force opaque
        c.cairo_set_source_rgba(self.ctx, r, g, b, a);
        self.last_color = .{ .color = color, .alpha = null };
    }
    
    /// Clear the entire surface to fully transparent (for ARGB windows)
    /// This must be called before drawing when using transparency to properly
    /// initialize the alpha channel. Without this, the window will be opaque
    /// regardless of the alpha values used in drawing operations.
    pub fn clearTransparent(self: *DrawContext) void {
        c.cairo_save(self.ctx);
        c.cairo_set_operator(self.ctx, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(self.ctx);
        c.cairo_restore(self.ctx);
        
        // CRITICAL: Explicitly set operator to OVER for proper alpha blending
        // Without this, subsequent drawing operations may not blend correctly
        c.cairo_set_operator(self.ctx, c.CAIRO_OPERATOR_OVER);
        
        // OPTIMIZATION: Invalidate color cache after clearing
        self.last_color = null;
    }
    
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        // CRITICAL: Use XCB to draw rectangles directly (like window borders)
        // This avoids Cairo's premultiplied alpha - we use raw RGB pixel values
        // The compositor will apply transparency, just like with window borders
        
        // Set the foreground color in the graphics context
        _ = defs.xcb.xcb_change_gc(self.conn, self.gc, defs.xcb.XCB_GC_FOREGROUND, &[_]u32{color});
        
        // Draw the rectangle using XCB (not Cairo)
        const rect = defs.xcb.xcb_rectangle_t{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = width,
            .height = height,
        };
        _ = defs.xcb.xcb_poly_fill_rectangle(self.conn, self.drawable, self.gc, 1, &rect);
        
        // Flush to ensure the rectangle is drawn
        _ = defs.xcb.xcb_flush(self.conn);
    }
    
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColorForText(color);  // Text is ALWAYS opaque
        
        // Set text in Pango layout
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
        
        // Get baseline offset
        const baseline = c.pango_layout_get_baseline(self.pango_layout);
        const baseline_pixels: f64 = @as(f64, @floatFromInt(baseline)) / @as(f64, @floatFromInt(c.PANGO_SCALE));
        
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
        
        self.setColorForText(color);  // Text is ALWAYS opaque
        
        // OPTIMIZATION: Use cached metrics instead of querying Pango
        const asc, _ = self.getMetrics();
        const ascent_pixels: f64 = @floatFromInt(asc);
        
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
    
    /// OPTIMIZATION: Get cached metrics or query and cache them
    pub fn getMetrics(self: *DrawContext) struct { i16, i16 } {
        if (self.cached_metrics) |m| {
            return .{ m.ascent, m.descent };
        }
        
        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout),
            self.current_font_desc,
            null
        );
        defer c.pango_font_metrics_unref(metrics);
        
        const ascent = c.pango_font_metrics_get_ascent(metrics);
        const descent = c.pango_font_metrics_get_descent(metrics);
        
        const result = .{
            @as(i16, @intCast(@divTrunc(ascent, c.PANGO_SCALE))),
            @as(i16, @intCast(@divTrunc(descent, c.PANGO_SCALE))),
        };
        
        self.cached_metrics = .{ .ascent = result[0], .descent = result[1] };
        return result;
    }
    
    pub fn flush(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
    }
    
    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.getMetrics();
        const text_height = asc + desc;
        
        const total_pad = @as(i32, bar_height) - text_height;
        const top_pad: i32 = @max(0, @divTrunc(total_pad, 2));
        
        const baseline_y: i32 = top_pad + asc;
        return @intCast(baseline_y);
    }
};

// Helper functions (unchanged)
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

fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![]const u8 {
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
    
    if (slant) |s| {
        if (std.mem.eql(u8, s, "italic") or std.mem.eql(u8, s, "oblique")) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, "Italic");
        }
    }
    
    if (weight) |w| {
        if (std.mem.eql(u8, w, "bold")) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, "Bold");
        } else if (std.mem.eql(u8, w, "light")) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, "Light");
        }
    }
    
    if (size) |s| {
        try result.append(allocator, ' ');
        try result.appendSlice(allocator, s);
    }
    
    return result.toOwnedSlice(allocator);
}

