//! Cairo + Pango drawing context for the status bar.
//!
//! Cairo handles graphics and compositing; Pango handles text layout and fonts.

const std   = @import("std");
const debug = @import("debug");
const defs  = @import("defs");
const c     = @import("c_bindings");

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

// font_conversion_cache is module-level mutable state shared across all DrawContext
// instances. Bar creates multiple short-lived offscreen DCs for measurement and one
// long-lived rendering DC; cache hits across them avoid redundant allocations.
// Single-threaded WM only — no synchronization needed.
var font_conversion_cache: ?std.StringHashMap([]const u8) = null;

const FALLBACK_FONT = "monospace:size=10";

pub const DrawContext = struct {
    allocator: std.mem.Allocator,
    conn:      *defs.xcb.xcb_connection_t,
    /// The real X window — only used as the copy destination in present().
    window:    u32,
    /// Off-screen pixmap — all drawing targets this.
    drawable:  u32,
    width:     u16,
    height:    u16,

    surface:      *c.cairo_surface_t,
    ctx:          *c.cairo_t,
    gc:           u32,
    /// Separate GC used exclusively for the xcb_copy_area in flush().
    copy_gc:      u32,
    pango_layout: *c.PangoLayout,

    current_font_desc: ?*c.PangoFontDescription = null,
    is_argb:           bool                      = false,
    transparency:      f32                       = 1.0,
    cached_metrics:    ?struct { ascent: i16, descent: i16 } = null,
    last_color:        ?u32                      = null,
    /// Cached GC foreground color — skips xcb_change_gc when color is unchanged.
    last_gc_color:     ?u32                      = null,

    /// Creates a DrawContext backed by an off-screen pixmap.
    /// All drawing targets the pixmap; call flush() to blit it to the window
    /// atomically via xcb_copy_area, eliminating visible partial-frame compositing.
    pub fn initWithVisual(
        allocator:    std.mem.Allocator,
        conn:         *defs.xcb.xcb_connection_t,
        window:       u32,
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

        const depth: u8 = if (is_argb) 32 else defs.xcb.XCB_COPY_FROM_PARENT;

        // Off-screen pixmap — Cairo renders here; flushed to window in one blit.
        const pixmap = defs.xcb.xcb_generate_id(conn);
        _ = defs.xcb.xcb_create_pixmap(conn, depth, pixmap, window, width, height);

        const surface = c.cairo_xcb_surface_create(
            conn, pixmap, visual_type, @intCast(width), @intCast(height),
        ) orelse {
            _ = defs.xcb.xcb_free_pixmap(conn, pixmap);
            return error.CairoSurfaceCreateFailed;
        };
        errdefer c.cairo_surface_destroy(surface);

        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        errdefer c.cairo_destroy(ctx);

        const layout = try createPangoLayout(ctx, dpi);
        errdefer c.g_object_unref(layout);

        dc.* = .{
            .allocator    = allocator,
            .conn         = conn,
            .window       = window,
            .drawable     = pixmap,
            .width        = width,
            .height       = height,
            .surface      = surface,
            .ctx          = ctx,
            .pango_layout = layout,
            .gc           = 0,
            .copy_gc      = 0,
            .is_argb      = is_argb,
            .transparency = transparency,
        };

        // Drawing GC — targets the pixmap for fillRect calls.
        dc.gc = defs.xcb.xcb_generate_id(conn);
        const gc_cookie = defs.xcb.xcb_create_gc_checked(conn, dc.gc, pixmap, 0, null);
        if (defs.xcb.xcb_request_check(conn, gc_cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }

        // Copy GC — targets the window, used only in flush().
        dc.copy_gc = defs.xcb.xcb_generate_id(conn);
        const copy_gc_cookie = defs.xcb.xcb_create_gc_checked(conn, dc.copy_gc, window, 0, null);
        if (defs.xcb.xcb_request_check(conn, copy_gc_cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }

        return dc;
    }

    /// Creates an off-screen DrawContext backed by a Cairo image surface.
    /// Intended for one-shot font measurement. Do NOT call fillRect/drawText/flush.
    pub fn initOffscreen(
        allocator: std.mem.Allocator,
        conn:      *defs.xcb.xcb_connection_t,
        dpi:       f32,
    ) !*DrawContext {
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);

        const surface = c.cairo_image_surface_create(.ARGB32, 1, 1)
            orelse return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);

        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        errdefer c.cairo_destroy(ctx);

        const layout = try createPangoLayout(ctx, dpi);

        dc.* = .{
            .allocator    = allocator,
            .conn         = conn,
            .window       = 0,
            .drawable     = 0,
            .width        = 1,
            .height       = 1,
            .surface      = surface,
            .ctx          = ctx,
            .pango_layout = layout,
            .gc           = 0, // sentinel: deinit skips xcb_free_gc
            .copy_gc      = 0,
        };

        return dc;
    }

    pub fn deinit(self: *DrawContext) void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
        if (self.gc != 0)      _ = defs.xcb.xcb_free_gc(self.conn, self.gc);
        if (self.copy_gc != 0) _ = defs.xcb.xcb_free_gc(self.conn, self.copy_gc);
        c.g_object_unref(self.pango_layout);
        c.cairo_destroy(self.ctx);
        // Cairo surface wraps the pixmap — destroy surface first, then pixmap.
        c.cairo_surface_destroy(self.surface);
        if (self.drawable != 0) _ = defs.xcb.xcb_free_pixmap(self.conn, self.drawable);
        self.allocator.destroy(self);
    }

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

    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        if (font_names.len == 0) return self.loadFont(FALLBACK_FONT);
        if (font_names.len == 1) return self.loadFont(font_names[0]);
        const font_list = try std.mem.join(self.allocator, ",", font_names);
        defer self.allocator.free(font_list);
        try self.loadFont(font_list);
        debug.info("Loaded {} fonts with fallback support", .{font_names.len});
    }

    inline fn setColor(self: *DrawContext, color: u32) void {
        if (self.last_color == color) return;
        c.cairo_set_source_rgba(self.ctx,
            @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0,
            @as(f64, @floatFromInt((color >> 8)  & 0xFF)) / 255.0,
            @as(f64, @floatFromInt( color         & 0xFF)) / 255.0,
            1.0);
        self.last_color = color;
    }

    pub inline fn applyTransparency(self: *DrawContext, color: u32) u32 {
        if (!self.is_argb) return color;
        const alpha: u32 = @intFromFloat(@round(
            std.math.clamp(self.transparency, 0.0, 1.0) * 255.0));
        return (alpha << 24) | (color & 0xFFFFFF);
    }

    inline fn setPangoText(self: *DrawContext, text: []const u8) void {
        c.pango_layout_set_text(self.pango_layout, text.ptr, @intCast(text.len));
    }

    // Extracted from drawText and drawTextEllipsis to avoid duplicating
    // the identical cairo_move_to call in both functions.
    inline fn moveToTextBaseline(self: *DrawContext, x: u16, y: u16) void {
        const baseline = @as(f64, @floatFromInt(c.pango_layout_get_baseline(self.pango_layout)))
            / @as(f64, @floatFromInt(c.PANGO_SCALE));
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - baseline);
    }

    pub fn clearTransparent(self: *DrawContext) void {
        c.cairo_save(self.ctx);
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.CLEAR);
        c.cairo_paint(self.ctx);
        c.cairo_restore(self.ctx);
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.OVER);
        self.last_color = null;
    }

    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const final_color = self.applyTransparency(color);
        if (self.last_gc_color != final_color) {
            _ = defs.xcb.xcb_change_gc(self.conn, self.gc, defs.xcb.XCB_GC_FOREGROUND, &[_]u32{final_color});
            self.last_gc_color = final_color;
        }
        const rect = defs.xcb.xcb_rectangle_t{
            .x = @intCast(x), .y = @intCast(y), .width = width, .height = height,
        };
        _ = defs.xcb.xcb_poly_fill_rectangle(self.conn, self.drawable, self.gc, 1, &rect);
    }

    /// Draws `text` at a temporarily-overridden absolute font size.
    /// Uses a temporary copy of the font description so the shared
    /// current_font_desc and cached_metrics are never touched.
    pub fn drawTextSized(self: *DrawContext, x: u16, y_top: u16, text: []const u8, size_px: u16, color: u32) !void {
        const desc = self.current_font_desc orelse return error.NoFont;

        const temp = c.pango_font_description_copy(desc) orelse return error.PangoDescCopyFailed;
        defer c.pango_font_description_free(temp);

        c.pango_font_description_set_absolute_size(temp,
            @as(f64, @floatFromInt(size_px)) * @as(f64, @floatFromInt(c.PANGO_SCALE)));
        c.pango_layout_set_font_description(self.pango_layout, temp);
        defer c.pango_layout_set_font_description(self.pango_layout, desc);

        self.setPangoText(text);

        var ink_rect: c.PangoRectangle = undefined;
        c.pango_layout_get_extents(self.pango_layout, &ink_rect, null);
        const ink_top_px: f64 = @as(f64, @floatFromInt(ink_rect.y)) /
                                 @as(f64, @floatFromInt(c.PANGO_SCALE));

        self.setColor(color);
        c.cairo_move_to(self.ctx, @floatFromInt(x),
            @as(f64, @floatFromInt(y_top)) - ink_top_px);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
    }

    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColor(color);
        self.setPangoText(text);
        self.moveToTextBaseline(x, y);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
    }

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
        self.moveToTextBaseline(x, y);
        c.pango_cairo_show_layout(self.ctx, self.pango_layout);
        c.pango_layout_set_width(self.pango_layout, -1);
        c.pango_layout_set_ellipsize(self.pango_layout, c.PangoEllipsizeMode.NONE);
    }

    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        self.setPangoText(text);
        var width: c_int = undefined;
        c.pango_layout_get_pixel_size(self.pango_layout, &width, null);
        return @intCast(width);
    }

    pub fn getMetrics(self: *DrawContext) struct { i16, i16 } {
        if (self.cached_metrics) |m| return .{ m.ascent, m.descent };
        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout), self.current_font_desc, null,
        );
        defer c.pango_font_metrics_unref(metrics);
        const result = .{
            @as(i16, @intCast(@divTrunc(c.pango_font_metrics_get_ascent(metrics),  c.PANGO_SCALE))),
            @as(i16, @intCast(@divTrunc(c.pango_font_metrics_get_descent(metrics), c.PANGO_SCALE))),
        };
        self.cached_metrics = .{ .ascent = result[0], .descent = result[1] };
        return result;
    }

    /// Flushes the off-screen pixmap to the window in a single xcb_copy_area call.
    /// The compositor only ever sees fully-rendered frames — no partial-draw flicker.
    pub fn flush(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
        if (self.copy_gc == 0) return; // offscreen measurement DC — nothing to blit
        _ = defs.xcb.xcb_copy_area(
            self.conn,
            self.drawable, // src: pixmap
            self.window,   // dst: window
            self.copy_gc,
            0, 0,          // src x, y
            0, 0,          // dst x, y
            self.width,
            self.height,
        );
    }

    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.getMetrics();
        const top_pad: i32    = @max(0, @divTrunc(@as(i32, bar_height) - (asc + desc), 2));
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

/// Extracted from initWithVisual and initOffscreen to eliminate duplicated
/// Pango layout creation + DPI setup across both init paths.
fn createPangoLayout(ctx: *c.cairo_t, dpi: f32) !*c.PangoLayout {
    const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dpi));
    return layout;
}

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

fn getDefaultVisualType(screen: *defs.xcb.xcb_screen_t) *defs.xcb.xcb_visualtype_t {
    var depth_iter = defs.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (defs.xcb.xcb_depth_next(&depth_iter)) {
        var visual_iter = defs.xcb.xcb_depth_visuals_iterator(depth_iter.data);
        if (visual_iter.rem > 0) return visual_iter.data;
    }
    unreachable;
}

inline fn appendStyle(result: *std.ArrayList(u8), allocator: std.mem.Allocator, token: []const u8) !void {
    try result.append(allocator, ' ');
    try result.appendSlice(allocator, token);
}

/// Converts Xft-style `"FontName:size=N:weight=bold"` to Pango `"FontName Bold N"`.
/// Returns `xft_name` unchanged when no `:` separator is present.
/// Results are memoised in `font_conversion_cache`.
fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![]const u8 {
    // font_conversion_cache is guaranteed initialised by drawing.initFontCache().
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

/// Initialises the font-name conversion cache. Must be called once before any
/// DrawContext loads fonts. Idempotent — safe to call on reload.
pub fn initFontCache(allocator: std.mem.Allocator) void {
    if (font_conversion_cache == null)
        font_conversion_cache = std.StringHashMap([]const u8).init(allocator);
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
