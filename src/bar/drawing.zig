//! Status bar
//! Text drawing/rendering with Cairo + Pango
//! Cairo handles graphics and compositing, Pango handles text layout and fonts
//!
//! Added metrics caching and color state tracking

const std = @import("std");
const debug = @import("debug");
const defs = @import("defs");
const c = @import("c_bindings");

// ─── Visual lookup (moved here from bar.zig) ─────────────────────────────────

/// Result of finding a visual — contains both the structure and ID
pub const VisualInfo = struct {
    visual_type: ?*defs.xcb.xcb_visualtype_t,
    visual_id: u32,
};

/// Find a visual with the given depth, returning both structure and ID.
/// Falls back to the root visual if the requested depth is not available.
pub fn findVisualByDepth(screen: *defs.xcb.xcb_screen_t, depth: u8) VisualInfo {
    var depth_iter = defs.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (defs.xcb.xcb_depth_next(&depth_iter)) {
        if (depth_iter.data.*.depth == depth) {
            var visual_iter = defs.xcb.xcb_depth_visuals_iterator(depth_iter.data);
            if (visual_iter.rem > 0) {
                const vt = visual_iter.data;
                return .{ .visual_type = vt, .visual_id = vt.*.visual_id };
            }
        }
    }
    return .{ .visual_type = null, .visual_id = screen.root_visual };
}

// ─── DrawContext ──────────────────────────────────────────────────────────────

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    conn: *defs.xcb.xcb_connection_t,
    drawable: u32,
    width: u16,
    height: u16,

    // Cairo structures (text rendering only)
    surface: *c.cairo_surface_t,
    ctx: *c.cairo_t,

    // XCB graphics context (background rectangles / window borders)
    gc: u32,

    // Pango text rendering
    pango_layout: *c.PangoLayout,
    current_font_desc: ?*c.PangoFontDescription = null,

    // Track if this is an ARGB window (32-bit with alpha channel)
    is_argb: bool = false,

    // Transparency value for ARGB windows (0.0 = transparent, 1.0 = opaque)
    transparency: f32 = 1.0,

    // Cache font metrics to avoid repeated Pango queries
    cached_metrics: ?struct {
        ascent: i16,
        descent: i16,
    } = null,

    // Track last text color to avoid redundant Cairo calls
    last_color: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator, conn: *defs.xcb.xcb_connection_t, drawable: u32, width: u16, height: u16, dpi: f32) !*DrawContext {
        return initWithVisual(allocator, conn, drawable, width, height, null, dpi, false, 1.0);
    }

    pub fn initWithVisual(allocator: std.mem.Allocator, conn: *defs.xcb.xcb_connection_t,
                          drawable: u32, width: u16, height: u16,
                          visual_id: ?u32, dpi: f32, is_argb: bool, transparency: f32) !*DrawContext {
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);

        // Get screen from XCB
        const setup = defs.xcb.xcb_get_setup(conn);
        var screen_iter = defs.xcb.xcb_setup_roots_iterator(setup);
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
            @intCast(height),
        ) orelse return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);

        // Create Cairo context
        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        errdefer c.cairo_destroy(ctx);

        // Create Pango layout for text rendering
        const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;

        // Set Pango's DPI resolution to match display
        const pango_context = c.pango_layout_get_context(layout);
        c.pango_cairo_context_set_resolution(pango_context, @floatCast(dpi));

        dc.* = .{
            .allocator    = allocator,
            .conn         = conn,
            .drawable     = drawable,
            .width        = width,
            .height       = height,
            .surface      = surface,
            .ctx          = ctx,
            .pango_layout = layout,
            .gc           = 0, // Created below
            .is_argb      = is_argb,
            .transparency = transparency,
        };

        // Create XCB graphics context for direct rectangle drawing (window borders)
        dc.gc = defs.xcb.xcb_generate_id(conn);
        _ = defs.xcb.xcb_create_gc(conn, dc.gc, drawable, 0, null);

        return dc;
    }

    pub fn deinit(self: *DrawContext) void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
        _ = defs.xcb.xcb_free_gc(self.conn, self.gc);
        c.g_object_unref(self.pango_layout);
        c.cairo_destroy(self.ctx);
        c.cairo_surface_destroy(self.surface);
        self.allocator.destroy(self);
    }

    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);

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
        if (font_names.len > 0) {
            try self.loadFont(font_names[0]);
            if (font_names.len > 1) {
                debug.info("More than one font detected ({}). Pango will use these alongside primary font set.", .{font_names.len - 1});
            }
        } else {
            try self.loadFont("monospace:size=10");
        }
    }

    /// Extract Cairo RGB components from a packed 0xRRGGBB color value
    inline fn colorToRGB(color: u32) struct { f64, f64, f64 } {
        return .{
            @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0,
            @as(f64, @floatFromInt((color >> 8)  & 0xFF)) / 255.0,
            @as(f64, @floatFromInt( color        & 0xFF)) / 255.0,
        };
    }

    /// Set the Cairo source color, skipping the call if the color has not changed
    inline fn setColor(self: *DrawContext, color: u32) void {
        if (self.last_color == color) return;
        const r, const g, const b = colorToRGB(color);
        c.cairo_set_source_rgba(self.ctx, r, g, b, 1.0);
        self.last_color = color;
    }

    /// Clear the surface to fully transparent before drawing on ARGB windows.
    /// Required so the compositor can apply transparency correctly.
    pub fn clearTransparent(self: *DrawContext) void {
        c.cairo_save(self.ctx);
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.CLEAR);
        c.cairo_paint(self.ctx);
        c.cairo_restore(self.ctx);
        // Restore OVER blending for all subsequent draw calls
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.OVER);
        self.last_color = null;
    }

    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        // Use XCB to draw rectangles directly (like window borders).
        // Cairo's premultiplied alpha darkens colors significantly; raw XCB avoids this.
        // The compositor applies transparency, keeping bar and window border colors identical.

        // For ARGB windows, embed the alpha channel from the transparency setting
        const final_color = if (self.is_argb) blk: {
            const alpha_f32 = std.math.clamp(self.transparency, 0.0, 1.0);
            const alpha_byte: u32 = @intFromFloat(@round(alpha_f32 * 255.0));
            break :blk (alpha_byte << 24) | (color & 0xFFFFFF);
        } else color;

        _ = defs.xcb.xcb_change_gc(self.conn, self.gc, defs.xcb.XCB_GC_FOREGROUND, &[_]u32{final_color});

        const rect = defs.xcb.xcb_rectangle_t{
            .x      = @intCast(x),
            .y      = @intCast(y),
            .width  = width,
            .height = height,
        };
        _ = defs.xcb.xcb_poly_fill_rectangle(self.conn, self.drawable, self.gc, 1, &rect);
    }

    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColor(color);

        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));

        // Offset move_to by the baseline so text sits at the correct vertical position
        const baseline = c.pango_layout_get_baseline(self.pango_layout);
        const baseline_pixels: f64 = @as(f64, @floatFromInt(baseline)) / @as(f64, @floatFromInt(c.PANGO_SCALE));

        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - baseline_pixels);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
    }

    /// Draw text with end-ellipsis truncation when it exceeds max_width pixels
    pub fn drawTextEllipsis(self: *DrawContext, x: u16, y: u16, text: []const u8, max_width: u16, color: u32) !void {
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
        c.pango_layout_set_width(self.pango_layout, @intCast(@as(i32, max_width) * c.PANGO_SCALE));
        c.pango_layout_set_ellipsize(self.pango_layout, c.PangoEllipsizeMode.END);

        self.setColor(color);

        const asc, _ = self.getMetrics();
        const ascent_pixels: f64 = @floatFromInt(asc);

        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - ascent_pixels);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);

        // Reset ellipsize for subsequent draws
        c.pango_layout_set_width(self.pango_layout, -1);
        c.pango_layout_set_ellipsize(self.pango_layout, c.PangoEllipsizeMode.NONE);
    }

    /// Return the rendered pixel width of a string using the current font
    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.pango_layout_get_pixel_size(self.pango_layout, &width, &height);
        return @intCast(width);
    }

    /// Return cached font metrics (ascent, descent) in pixels, querying Pango on first call
    pub fn getMetrics(self: *DrawContext) struct { i16, i16 } {
        if (self.cached_metrics) |m| return .{ m.ascent, m.descent };

        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout),
            self.current_font_desc,
            null,
        );
        defer c.pango_font_metrics_unref(metrics);

        const ascent  = c.pango_font_metrics_get_ascent(metrics);
        const descent = c.pango_font_metrics_get_descent(metrics);

        const result = .{
            @as(i16, @intCast(@divTrunc(ascent,  c.PANGO_SCALE))),
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
        return @intCast(top_pad + asc);
    }
};

// ─── Private helpers ──────────────────────────────────────────────────────────

/// Search all screens for a visual matching the given visual_id
fn findVisualType(conn: *defs.xcb.xcb_connection_t, visual_id: u32) ?*defs.xcb.xcb_visualtype_t {
    const setup = defs.xcb.xcb_get_setup(conn);
    var screen_iter = defs.xcb.xcb_setup_roots_iterator(setup);

    while (screen_iter.rem > 0) {
        const screen = screen_iter.data;
        var depth_iter = defs.xcb.xcb_screen_allowed_depths_iterator(screen);

        while (depth_iter.rem > 0) {
            var visual_iter = defs.xcb.xcb_depth_visuals_iterator(depth_iter.data);

            while (visual_iter.rem > 0) {
                if (visual_iter.data.*.visual_id == visual_id) return visual_iter.data;
                defs.xcb.xcb_visualtype_next(&visual_iter);
            }
            defs.xcb.xcb_depth_next(&depth_iter);
        }
        defs.xcb.xcb_screen_next(&screen_iter);
    }

    return null;
}

/// Return the first available visual type on the given screen (used as a fallback)
fn getDefaultVisualType(screen: *defs.xcb.xcb_screen_t) *defs.xcb.xcb_visualtype_t {
    var depth_iter = defs.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) {
        var visual_iter = defs.xcb.xcb_depth_visuals_iterator(depth_iter.data);
        if (visual_iter.rem > 0) return visual_iter.data;
        defs.xcb.xcb_depth_next(&depth_iter);
    }
    unreachable;
}

/// Convert an Xft-style font name (e.g. "DejaVu Sans:size=11:weight=bold")
/// to the Pango format expected by pango_font_description_from_string
fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, xft_name, ':') == null) return xft_name;

    var result = try std.ArrayList(u8).initCapacity(allocator, xft_name.len);
    errdefer result.deinit(allocator);

    var parts = std.mem.splitScalar(u8, xft_name, ':');
    try result.appendSlice(allocator, parts.first());

    var size:   ?[]const u8 = null;
    var weight: ?[]const u8 = null;
    var slant:  ?[]const u8 = null;

    while (parts.next()) |part| {
        if      (std.mem.startsWith(u8, part, "size="))      size   = part[5..]
        else if (std.mem.startsWith(u8, part, "pixelsize=")) size   = part[10..]
        else if (std.mem.startsWith(u8, part, "weight="))    weight = part[7..]
        else if (std.mem.startsWith(u8, part, "slant="))     slant  = part[6..];
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
