//! Cairo + Pango drawing context for the status bar.
//!
//! Cairo handles graphics and compositing; Pango handles text layout and fonts.

const std   = @import("std");
const debug = @import("debug");
const defs  = @import("defs");
const c     = @import("c_bindings");

// Visual helpers 

pub const VisualInfo = struct {
    visual_type: ?*defs.xcb.xcb_visualtype_t,
    visual_id:   u32,
};

/// Finds the first visual at `depth` bits. Falls back to the root visual if none is found.
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

// DrawContext

/// Packed 0xRRGGBB color broken into Cairo-ready f64 components.
const RGBColor = struct { r: f64, g: f64, b: f64 };

/// Font name conversion cache — avoids repeated allocations across bar redraws.
var font_conversion_cache: ?std.StringHashMap([]const u8) = null;

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    conn:      *defs.xcb.xcb_connection_t,
    drawable:  u32,
    width:     u16,
    height:    u16,

    surface:      *c.cairo_surface_t,
    ctx:          *c.cairo_t,
    gc:           u32,
    pango_layout: *c.PangoLayout,

    current_font_desc: ?*c.PangoFontDescription = null,
    is_argb:           bool                      = false,
    transparency:      f32                       = 1.0,
    cached_metrics:    ?struct { ascent: i16, descent: i16 } = null,
    last_color:        ?u32                      = null,
    color_cache:       std.AutoHashMap(u32, RGBColor),

    /// Creates a DrawContext on the default root visual.
    pub fn init(
        allocator: std.mem.Allocator,
        conn:      *defs.xcb.xcb_connection_t,
        drawable:  u32,
        width:     u16,
        height:    u16,
        dpi:       f32,
    ) !*DrawContext {
        return initWithVisual(allocator, conn, drawable, width, height, null, dpi, false, 1.0);
    }

    /// Creates a DrawContext with an explicit visual (required for ARGB/32-bit windows).
    pub fn initWithVisual(
        allocator:    std.mem.Allocator,
        conn:         *defs.xcb.xcb_connection_t,
        drawable:     u32,
        width:        u16,
        height:       u16,
        visual_id:    ?u32,
        dpi:          f32,
        is_argb:      bool,
        transparency: f32,
    ) !*DrawContext {
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);

        const setup  = defs.xcb.xcb_get_setup(conn);
        const screen = defs.xcb.xcb_setup_roots_iterator(setup).data;

        const visual_type = if (visual_id) |vid|
            findVisualType(conn, vid) orelse getDefaultVisualType(screen)
        else
            getDefaultVisualType(screen);

        const surface = c.cairo_xcb_surface_create(
            conn, drawable, visual_type, @intCast(width), @intCast(height),
        ) orelse return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);

        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        errdefer c.cairo_destroy(ctx);

        const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
        c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dpi));

        dc.* = .{
            .allocator    = allocator,
            .conn         = conn,
            .drawable     = drawable,
            .width        = width,
            .height       = height,
            .surface      = surface,
            .ctx          = ctx,
            .pango_layout = layout,
            .gc           = 0,
            .is_argb      = is_argb,
            .transparency = transparency,
            .color_cache  = std.AutoHashMap(u32, RGBColor).init(allocator),
        };

        dc.gc = defs.xcb.xcb_generate_id(conn);
        const gc_cookie = defs.xcb.xcb_create_gc_checked(conn, dc.gc, drawable, 0, null);
        if (defs.xcb.xcb_request_check(conn, gc_cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }

        return dc;
    }

    /// Frees all resources owned by this DrawContext.
    pub fn deinit(self: *DrawContext) void {
        self.color_cache.deinit();
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
        _ = defs.xcb.xcb_free_gc(self.conn, self.gc);
        c.g_object_unref(self.pango_layout);
        c.cairo_destroy(self.ctx);
        c.cairo_surface_destroy(self.surface);
        self.allocator.destroy(self);
    }

    /// Loads a single Pango font by name (Xft-style, e.g. `"JetBrains Mono:size=10"`).
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);

        const pango_name   = try convertFontName(self.allocator, font_name);
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

    /// Loads multiple fonts as a comma-separated fallback list.
    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        if (font_names.len == 0) return self.loadFont("monospace:size=10");
        if (font_names.len == 1) return self.loadFont(font_names[0]);
        const font_list = try std.mem.join(self.allocator, ",", font_names);
        defer self.allocator.free(font_list);
        try self.loadFont(font_list);
        debug.info("Loaded {} fonts with fallback support", .{font_names.len});
    }

    /// Converts a packed 0xRRGGBB integer to {r, g, b} f64 components, with caching.
    fn colorToRGB(self: *DrawContext, color: u32) struct { f64, f64, f64 } {
        if (self.color_cache.get(color)) |rgb| return .{ rgb.r, rgb.g, rgb.b };
        const rgb = RGBColor{
            .r = @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0,
            .g = @as(f64, @floatFromInt((color >> 8)  & 0xFF)) / 255.0,
            .b = @as(f64, @floatFromInt( color         & 0xFF)) / 255.0,
        };
        self.color_cache.put(color, rgb) catch {};
        return .{ rgb.r, rgb.g, rgb.b };
    }

    /// Sets the current Cairo source color, skipping redundant calls via `last_color`.
    inline fn setColor(self: *DrawContext, color: u32) void {
        if (self.last_color == color) return;
        const r, const g, const b = self.colorToRGB(color);
        c.cairo_set_source_rgba(self.ctx, r, g, b, 1.0);
        self.last_color = color;
    }

    /// Prepends an alpha byte to `color` based on `self.transparency`. No-op for opaque contexts.
    pub inline fn applyTransparency(self: *DrawContext, color: u32) u32 {
        if (!self.is_argb) return color;
        const alpha: u32 = @intFromFloat(@round(
            std.math.clamp(self.transparency, 0.0, 1.0) * 255.0));
        return (alpha << 24) | (color & 0xFFFFFF);
    }

    inline fn setPangoText(self: *DrawContext, text: []const u8) void {
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
    }

    inline fn pangoToPixelsI16(pango_units: c_int) i16 {
        return @intCast(@divTrunc(pango_units, c.PANGO_SCALE));
    }

    /// Clears the surface to fully transparent (required before drawing ARGB frames).
    pub fn clearTransparent(self: *DrawContext) void {
        c.cairo_save(self.ctx);
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.CLEAR);
        c.cairo_paint(self.ctx);
        c.cairo_restore(self.ctx);
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.OVER);
        self.last_color = null;
    }

    /// Fills a rectangle using XCB (bypasses Cairo — used for solid bar backgrounds).
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const final_color = self.applyTransparency(color);
        _ = defs.xcb.xcb_change_gc(self.conn, self.gc, defs.xcb.XCB_GC_FOREGROUND, &[_]u32{final_color});
        const rect = defs.xcb.xcb_rectangle_t{
            .x = @intCast(x), .y = @intCast(y), .width = width, .height = height,
        };
        _ = defs.xcb.xcb_poly_fill_rectangle(self.conn, self.drawable, self.gc, 1, &rect);
    }

    /// Draws `text` at pixel coordinates `(x, y)` where `y` is the font baseline.
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColor(color);
        self.setPangoText(text);
        // y is the baseline; compute the layout top by subtracting the Pango baseline offset.
        const baseline_px = @as(f64, @floatFromInt(c.pango_layout_get_baseline(self.pango_layout)))
            / @as(f64, @floatFromInt(c.PANGO_SCALE));
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - baseline_px);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
    }

    /// Draws `text` clipped to `max_width` pixels, adding an ellipsis if truncated.
    pub fn drawTextEllipsis(
        self:      *DrawContext,
        x:         u16,
        y:         u16,
        text:      []const u8,
        max_width: u16,
        color:     u32,
    ) !void {
        self.setPangoText(text);
        c.pango_layout_set_width(self.pango_layout, @intCast(@as(i32, max_width) * c.PANGO_SCALE));
        c.pango_layout_set_ellipsize(self.pango_layout, c.PangoEllipsizeMode.END);
        self.setColor(color);
        const asc, _ = self.getMetrics();
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - @as(f64, @floatFromInt(asc)));
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
        c.pango_layout_set_width(self.pango_layout, -1);
        c.pango_layout_set_ellipsize(self.pango_layout, c.PangoEllipsizeMode.NONE);
    }

    /// Returns the rendered pixel width of `text` using the current font.
    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        self.setPangoText(text);
        var width:  c_int = undefined;
        var height: c_int = undefined;
        c.pango_layout_get_pixel_size(self.pango_layout, &width, &height);
        return @intCast(width);
    }

    /// Returns `{ascent, descent}` in pixels, with lazy caching.
    pub fn getMetrics(self: *DrawContext) struct { i16, i16 } {
        if (self.cached_metrics) |m| return .{ m.ascent, m.descent };
        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout), self.current_font_desc, null,
        );
        defer c.pango_font_metrics_unref(metrics);
        const result = .{
            pangoToPixelsI16(c.pango_font_metrics_get_ascent(metrics)),
            pangoToPixelsI16(c.pango_font_metrics_get_descent(metrics)),
        };
        self.cached_metrics = .{ .ascent = result[0], .descent = result[1] };
        return result;
    }

    /// Flushes pending Cairo commands to the underlying XCB surface.
    pub fn flush(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
    }

    /// Computes the Y pixel coordinate of the font baseline when centered in `bar_height`.
    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.getMetrics();
        const text_height     = asc + desc;
        const top_pad: i32    = @max(0, @divTrunc(@as(i32, bar_height) - text_height, 2));
        return @intCast(top_pad + asc);
    }

    /// Fills a background rectangle and draws `text` with padding, returning the next X position.
    pub fn drawSegment(
        self:    *DrawContext,
        x:       u16,
        height:  u16,
        text:    []const u8,
        padding: u16,
        bg:      u32,
        fg:      u32,
    ) !u16 {
        const width = self.textWidth(text) + padding * 2;
        self.fillRect(x, 0, width, height, bg);
        try self.drawText(x + padding, self.baselineY(height), text, fg);
        return x + width;
    }
};

// Private helpers 

/// Finds the `xcb_visualtype_t` for `visual_id` by scanning all screens and depths.
fn findVisualType(conn: *defs.xcb.xcb_connection_t, visual_id: u32) ?*defs.xcb.xcb_visualtype_t {
    const setup = defs.xcb.xcb_get_setup(conn);
    var screen_iter = defs.xcb.xcb_setup_roots_iterator(setup);
    while (screen_iter.rem > 0) : (defs.xcb.xcb_screen_next(&screen_iter)) {
        var depth_iter = defs.xcb.xcb_screen_allowed_depths_iterator(screen_iter.data);
        while (depth_iter.rem > 0) : (defs.xcb.xcb_depth_next(&depth_iter)) {
            var visual_iter = defs.xcb.xcb_depth_visuals_iterator(depth_iter.data);
            while (visual_iter.rem > 0) : (defs.xcb.xcb_visualtype_next(&visual_iter)) {
                if (visual_iter.data.*.visual_id == visual_id) return visual_iter.data;
            }
        }
    }
    return null;
}

/// Returns the first visual type available on `screen`. Unreachable if none exist.
fn getDefaultVisualType(screen: *defs.xcb.xcb_screen_t) *defs.xcb.xcb_visualtype_t {
    var depth_iter = defs.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (defs.xcb.xcb_depth_next(&depth_iter)) {
        var visual_iter = defs.xcb.xcb_depth_visuals_iterator(depth_iter.data);
        if (visual_iter.rem > 0) return visual_iter.data;
    }
    unreachable;
}

/// Appends a space followed by `token` (a style keyword such as "Bold") to `result`.
inline fn appendStyle(result: *std.ArrayList(u8), allocator: std.mem.Allocator, token: []const u8) !void {
    try result.append(allocator, ' ');
    try result.appendSlice(allocator, token);
}

/// Converts an Xft-style font name (e.g. `"JetBrains Mono:size=10:weight=bold"`) to
/// the Pango format (`"JetBrains Mono Bold 10"`). Returns `xft_name` unchanged when
/// no `:` separator is present. Results are memoised in `font_conversion_cache`.
fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![]const u8 {
    if (font_conversion_cache == null)
        font_conversion_cache = std.StringHashMap([]const u8).init(allocator);

    if (font_conversion_cache.?.get(xft_name)) |cached| return cached;
    if (std.mem.indexOfScalar(u8, xft_name, ':') == null) return xft_name;

    var result = std.ArrayList(u8){};
    try result.ensureTotalCapacity(allocator, xft_name.len);
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

    if (slant) |s| if (std.mem.eql(u8, s, "italic") or std.mem.eql(u8, s, "oblique"))
        try appendStyle(&result, allocator, "Italic");

    if (weight) |w| {
        const token: ?[]const u8 =
            if      (std.mem.eql(u8, w, "bold"))  "Bold"
            else if (std.mem.eql(u8, w, "light")) "Light"
            else                                   null;
        if (token) |t| try appendStyle(&result, allocator, t);
    }

    if (size) |s| try appendStyle(&result, allocator, s);

    const converted = try result.toOwnedSlice(allocator);
    font_conversion_cache.?.put(xft_name, converted) catch {};
    return converted;
}

/// Releases the font-name conversion cache. Call once at shutdown.
pub fn deinitFontCache(allocator: std.mem.Allocator) void {
    if (font_conversion_cache) |*cache| {
        var iter = cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.ptr != entry.key_ptr.*.ptr)
                allocator.free(entry.value_ptr.*);
        }
        cache.deinit();
        font_conversion_cache = null;
    }
}
