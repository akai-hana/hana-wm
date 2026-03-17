//! Drawing context for the status bar.
//!
//! Rectangle fills use XCB core drawing (xcb_poly_fill_rectangle) so that
//! straight-alpha ARGB pixels are written directly into the pixmap — the format
//! picom and the X11 Composite extension expect from a core-protocol drawable.
//! Cairo's XRender backend always writes premultiplied pixels, which picom would
//! interpret as straight-alpha, rendering colours far too dark at any transparency.
//! Cairo + Pango handle all text layout and glyph rendering.

const std   = @import("std");
const debug = @import("debug");
const core  = @import("core");
const c     = @import("c_bindings");

pub const VisualInfo = struct {
    visual_type: ?*core.xcb.xcb_visualtype_t,
    visual_id:   u32,
};

/// Find the first visual at `depth` bits. Falls back to the root visual if none found.
pub fn findVisualByDepth(screen: *core.xcb.xcb_screen_t, depth: u8) VisualInfo {
    var depth_iter = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (core.xcb.xcb_depth_next(&depth_iter)) {
        if (depth_iter.data.*.depth == depth) {
            var visual_iter = core.xcb.xcb_depth_visuals_iterator(depth_iter.data);
            if (visual_iter.rem > 0) {
                const vt = visual_iter.data;
                return .{ .visual_type = vt, .visual_id = vt.*.visual_id };
            }
        }
    }
    return .{ .visual_type = null, .visual_id = screen.root_visual };
}

// Module-level font name conversion cache shared across all DrawContext instances.
// Bar creates multiple short-lived offscreen DCs for measurement and one long-lived
// rendering DC; cache hits across them avoid redundant allocations.
// Single-threaded WM only — no synchronization needed.
var font_conversion_cache: ?std.StringHashMap([]const u8) = null;

const FALLBACK_FONT = "monospace:size=10";

pub const FontState = struct {
    allocator:         std.mem.Allocator,
    pango_layout:      *c.PangoLayout,
    current_font_desc: ?*c.PangoFontDescription         = null,
    cached_metrics:    ?struct { ascent: i16, descent: i16 } = null,

    fn deinit(self: *FontState) void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
    }

    pub fn loadFont(self: *FontState, font_name: []const u8) !void {
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
        self.cached_metrics = null;
    }

    pub fn loadFonts(self: *FontState, font_names: []const []const u8) !void {
        if (font_names.len == 0) return self.loadFont(FALLBACK_FONT);
        if (font_names.len == 1) return self.loadFont(font_names[0]);
        const font_list = try std.mem.join(self.allocator, ",", font_names);
        defer self.allocator.free(font_list);
        try self.loadFont(font_list);
    }

    pub fn getMetrics(self: *FontState) struct { i16, i16 } {
        if (self.cached_metrics) |m| return .{ m.ascent, m.descent };
        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout), self.current_font_desc, null,
        );
        defer c.pango_font_metrics_unref(metrics);
        const ascent:  i16 = @intCast(@divTrunc(c.pango_font_metrics_get_ascent(metrics),  c.PANGO_SCALE));
        const descent: i16 = @intCast(@divTrunc(c.pango_font_metrics_get_descent(metrics), c.PANGO_SCALE));
        self.cached_metrics = .{ .ascent = ascent, .descent = descent };
        return .{ ascent, descent };
    }
};

pub const DrawContext = struct {
    font:   FontState,
    conn:   *core.xcb.xcb_connection_t,
    /// The real X window — only used as the copy destination in flush().
    window:   u32,
    /// Off-screen pixmap — all drawing targets this.
    drawable: u32,
    width:    u16,
    height:   u16,

    surface:  *c.cairo_surface_t,
    ctx:      *c.cairo_t,
    /// GC used by fillRect (xcb_poly_fill_rectangle).
    gc:       u32,
    /// Separate GC used exclusively for the xcb_copy_area blit in flush().
    copy_gc:  u32,

    is_argb:             bool = false,
    /// Pre-computed alpha byte for XCB pixel packing: round(clamp(transparency)*255).
    /// Computed once at init so fillRect pays zero floating-point cost per call.
    alpha_u8:            u8   = 0xFF,
    last_color:          ?u32 = null,
    /// Cached GC foreground — skips xcb_change_gc when the packed ARGB pixel is unchanged.
    last_gc_color:       ?u32 = null,

    // NOTE: pango_layout_get_baseline is intentionally NOT cached. The baseline
    // can vary per text run when font fallback is active (e.g. a CJK glyph
    // falling back to Noto Sans CJK has a different ascent than FiraCode),
    // so caching it would produce wrong positions for subsequent draws.

    // drawTextSized cache 
    // Avoids copying the font description on every indicator-glyph draw when the
    // requested size matches the previous call.
    cached_sized_desc:   ?*c.PangoFontDescription  = null,
    cached_sized_px:     u16                        = 0,

    /// Stored for CarouselPixmap — needed to create a Cairo surface with the same visual.
    visual_type: ?*core.xcb.xcb_visualtype_t = null,
    /// DPI used when rendering into a CarouselPixmap (must match bar's Pango layout).
    dpi:         f32                          = 96.0,
    /// Actual pixel depth of dc.drawable — 32 for ARGB, screen root_depth otherwise.
    depth:       u8                           = 24,

    /// Creates a DrawContext backed by an off-screen pixmap.
    /// All drawing targets the pixmap; call flush() to blit it to the window
    /// atomically via xcb_copy_area, eliminating visible partial-frame compositing.
    pub fn initWithVisual(
        allocator:    std.mem.Allocator,
        conn:         *core.xcb.xcb_connection_t,
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

        const setup  = core.xcb.xcb_get_setup(conn);
        const screen = core.xcb.xcb_setup_roots_iterator(setup).data;

        const visual_type = if (visual_id) |vid|
            findVisualType(conn, vid) orelse getDefaultVisualType(screen)
        else
            getDefaultVisualType(screen);

        const depth: u8 = if (is_argb) 32 else core.xcb.XCB_COPY_FROM_PARENT;

        const pixmap = core.xcb.xcb_generate_id(conn);
        _ = core.xcb.xcb_create_pixmap(conn, depth, pixmap, window, width, height);

        const surface = c.cairo_xcb_surface_create(
            conn, pixmap, visual_type, @intCast(width), @intCast(height),
        ) orelse {
            _ = core.xcb.xcb_free_pixmap(conn, pixmap);
            return error.CairoSurfaceCreateFailed;
        };
        errdefer c.cairo_surface_destroy(surface);

        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        errdefer c.cairo_destroy(ctx);

        const layout = try createPangoLayout(ctx, dpi);
        errdefer c.g_object_unref(layout);

        dc.* = .{
            .conn         = conn,
            .window       = window,
            .drawable     = pixmap,
            .width        = width,
            .height       = height,
            .surface      = surface,
            .ctx          = ctx,
            .font         = .{ .allocator = allocator, .pango_layout = layout },
            .gc           = 0,
            .copy_gc      = 0,
            .is_argb      = is_argb,
            .alpha_u8     = if (is_argb)
                @intFromFloat(@round(std.math.clamp(transparency, 0.0, 1.0) * 255.0))
            else
                0xFF,
            .visual_type  = visual_type,
            .dpi          = dpi,
            .depth        = if (is_argb) 32 else screen.*.root_depth,
        };

        // Fire both GC-create requests before blocking on either reply so both
        // land in the same TCP segment.
        dc.gc      = core.xcb.xcb_generate_id(conn);
        dc.copy_gc = core.xcb.xcb_generate_id(conn);
        const gc_cookie      = core.xcb.xcb_create_gc_checked(conn, dc.gc,      pixmap, 0, null);
        const copy_gc_cookie = core.xcb.xcb_create_gc_checked(conn, dc.copy_gc, window, 0, null);
        if (core.xcb.xcb_request_check(conn, gc_cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }
        if (core.xcb.xcb_request_check(conn, copy_gc_cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }

        return dc;
    }

    pub fn deinit(self: *DrawContext) void {
        self.font.deinit();
        if (self.cached_sized_desc) |desc| c.pango_font_description_free(desc);
        if (self.gc      != 0) _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        if (self.copy_gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.copy_gc);
        c.g_object_unref(self.font.pango_layout);
        c.cairo_destroy(self.ctx);
        // Destroy surface before pixmap — Cairo holds a reference to the pixmap.
        c.cairo_surface_destroy(self.surface);
        if (self.drawable != 0) _ = core.xcb.xcb_free_pixmap(self.conn, self.drawable);
        self.font.allocator.destroy(self);
    }

    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        try self.font.loadFont(font_name);
        if (self.cached_sized_desc) |old| c.pango_font_description_free(old);
        self.cached_sized_desc = null;
        debug.info("Cairo/Pango font loaded: {s}", .{font_name});
    }

    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        try self.font.loadFonts(font_names);
        if (font_names.len > 1) debug.info("Loaded {} fonts with fallback support", .{font_names.len});
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
        return (@as(u32, self.alpha_u8) << 24) | (color & 0x00FFFFFF);
    }

    inline fn setPangoText(self: *DrawContext, text: []const u8) void {
        c.pango_layout_set_text(self.font.pango_layout, text.ptr, @intCast(text.len));
    }

    // pango_layout_get_baseline is called unconditionally on every draw: the
    // baseline changes when font fallback is active (different scripts trigger
    // different fonts with different ascents), so caching it would silently
    // misalign text in multi-font configurations.
    inline fn moveToTextBaseline(self: *DrawContext, x: u16, y: u16) void {
        const baseline = @as(f64, @floatFromInt(c.pango_layout_get_baseline(self.font.pango_layout)))
            / @as(f64, @floatFromInt(c.PANGO_SCALE));
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - baseline);
    }

    pub fn clearTransparent(self: *DrawContext) void {
        if (!self.is_argb) return;
        // Skip cairo_save/cairo_restore: we only change the operator temporarily
        // and always want to end at OVER. Direct set/reset is cheaper than a
        // full graphics-state push/pop. The source pattern (last_color) is
        // unaffected by the operator change or cairo_paint, so no cache reset.
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.CLEAR);
        c.cairo_paint(self.ctx);
        c.cairo_set_operator(self.ctx, c.cairo_operator_t.OVER);
    }

    /// Fill a rectangle via XCB core drawing (xcb_poly_fill_rectangle).
    ///
    /// XCB writes the raw packed pixel (A, R, G, B) directly into the pixmap —
    /// the straight-alpha format picom expects. Cairo's XRender backend writes
    /// premultiplied pixels instead, which is why fills bypass Cairo entirely.
    /// last_gc_color guards xcb_change_gc: skips the call when the color is
    /// unchanged, which is the common case when adjacent segments share a background.
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const final_color: u32 = self.applyTransparency(color);
        if (self.last_gc_color != final_color) {
            _ = core.xcb.xcb_change_gc(self.conn, self.gc, core.xcb.XCB_GC_FOREGROUND, &[_]u32{final_color});
            self.last_gc_color = final_color;
        }
        const rect = core.xcb.xcb_rectangle_t{
            .x = @intCast(x), .y = @intCast(y), .width = width, .height = height,
        };
        _ = core.xcb.xcb_poly_fill_rectangle(self.conn, self.drawable, self.gc, 1, &rect);
    }

    /// Draw `text` at a temporarily-overridden absolute font size.
    /// The sized font description is cached by pixel size so repeated calls with
    /// the same size (the common case) pay zero allocation after the first call.
    /// The cache is invalidated in loadFont.
    pub fn drawTextSized(self: *DrawContext, x: u16, y_top: u16, text: []const u8, size_px: u16, color: u32) !void {
        const desc = self.font.current_font_desc orelse return error.NoFont;

        if (self.cached_sized_desc == null or self.cached_sized_px != size_px) {
            if (self.cached_sized_desc) |old| c.pango_font_description_free(old);
            const temp = c.pango_font_description_copy(desc) orelse return error.PangoDescCopyFailed;
            c.pango_font_description_set_absolute_size(temp,
                @as(f64, @floatFromInt(size_px)) * @as(f64, @floatFromInt(c.PANGO_SCALE)));
            self.cached_sized_desc = temp;
            self.cached_sized_px   = size_px;
        }
        const sized = self.cached_sized_desc.?;

        c.pango_layout_set_font_description(self.font.pango_layout, sized);
        defer c.pango_layout_set_font_description(self.font.pango_layout, desc);

        self.setPangoText(text);

        var ink_rect: c.PangoRectangle = undefined;
        c.pango_layout_get_extents(self.font.pango_layout, &ink_rect, null);
        const ink_top_px: f64 = @as(f64, @floatFromInt(ink_rect.y)) /
                                 @as(f64, @floatFromInt(c.PANGO_SCALE));

        self.setColor(color);
        c.cairo_move_to(self.ctx, @floatFromInt(x),
            @as(f64, @floatFromInt(y_top)) - ink_top_px);
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
    }

    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColor(color);
        self.setPangoText(text);
        self.moveToTextBaseline(x, y);
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
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

        // Pango re-invalidates its internal layout shaping on every set_width /
        // set_ellipsize call even when the value is unchanged. These four calls
        // are unconditional because the layout is always reset to defaults after
        // each draw, so a cache would never find a matching value on entry anyway.
        const pango_width: i32 = @as(i32, max_width) * c.PANGO_SCALE;
        c.pango_layout_set_width(self.font.pango_layout, pango_width);
        c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.END);

        self.setColor(color);
        self.moveToTextBaseline(x, y);
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);

        c.pango_layout_set_width(self.font.pango_layout, -1);
        c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.NONE);
    }

    pub fn textWidth(self: *DrawContext, text: []const u8) u16 {
        self.setPangoText(text);
        var width: c_int = undefined;
        c.pango_layout_get_pixel_size(self.font.pango_layout, &width, null);
        return @intCast(width);
    }

    pub fn getMetrics(self: *DrawContext) struct { i16, i16 } { return self.font.getMetrics(); }

    /// Flush the off-screen pixmap to the window in a single xcb_copy_area call.
    /// The compositor only ever sees fully-rendered frames — no partial-draw flicker.
    pub fn flush(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
        if (self.copy_gc == 0) return;
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.drawable,
            self.window,
            self.copy_gc,
            0, 0,
            0, 0,
            self.width,
            self.height,
        );
    }

    /// Blit only the rectangle [x, x+w) from the off-screen pixmap to the window.
    /// Does NOT call cairo_surface_flush — use this when only XCB (not Cairo) has
    /// written to the pixmap in the current frame, e.g. carousel blits.
    pub fn flushRect(self: *DrawContext, x: u16, w: u16) void {
        if (self.copy_gc == 0) return;
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.drawable,
            self.window,
            self.copy_gc,
            @intCast(x), 0,
            @intCast(x), 0,
            w, self.height,
        );
        _ = core.xcb.xcb_flush(self.conn);
    }

    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.getMetrics();
        const top_pad: i32    = @max(0, @divTrunc(@as(i32, bar_height) - (asc + desc), 2));
        return @intCast(top_pad + asc);
    }

    /// Fill a background rectangle and draw `text` with padding, returning the next X position.
    ///
    /// Sets the Pango text once and reuses the laid-out state for both the width
    /// measurement and the render, avoiding the double pango_layout_set_text call
    /// that would occur if textWidth() and drawText() were called separately.
    pub fn drawSegment(
        self:    *DrawContext,
        x:       u16,
        height:  u16,
        text:    []const u8,
        padding: u16,
        bg:      u32,
        fg:      u32,
    ) !u16 {
        self.setPangoText(text);
        var tw: c_int = undefined;
        c.pango_layout_get_pixel_size(self.font.pango_layout, &tw, null);
        const width: u16 = @as(u16, @intCast(tw)) + padding * 2;
        self.fillRect(x, 0, width, height, bg);
        self.setColor(fg);
        self.moveToTextBaseline(x + padding, self.baselineY(height));
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
        return x + width;
    }
};

// MeasureContext
//
// Lightweight font-measurement context backed by a 1x1 Cairo image surface.
// Carries no XCB resources and makes no X server round-trips.

pub const MeasureContext = struct {
    font:    FontState,
    surface: *c.cairo_surface_t,
    ctx:     *c.cairo_t,

    pub fn init(allocator: std.mem.Allocator, dpi: f32) !MeasureContext {
        const surface = c.cairo_image_surface_create(.ARGB32, 1, 1)
            orelse return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);
        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        errdefer c.cairo_destroy(ctx);
        const layout = try createPangoLayout(ctx, dpi);
        return .{ .font = .{ .allocator = allocator, .pango_layout = layout }, .surface = surface, .ctx = ctx };
    }

    pub fn deinit(self: *MeasureContext) void {
        self.font.deinit();
        c.g_object_unref(self.font.pango_layout);
        c.cairo_destroy(self.ctx);
        c.cairo_surface_destroy(self.surface);
    }

    pub fn loadFont(self: *MeasureContext,  font_name: []const u8)        !void          { return self.font.loadFont(font_name); }
    pub fn loadFonts(self: *MeasureContext, font_names: []const []const u8) !void        { return self.font.loadFonts(font_names); }
    pub fn getMetrics(self: *MeasureContext) struct { i16, i16 }                         { return self.font.getMetrics(); }
};

// CarouselPixmap 
//
// Pre-renders a window title (background + glyphs) into a dedicated XCB pixmap
// exactly once.  Every subsequent carousel tick is two xcb_copy_area calls —
// raw pixel blits with zero Pango/Cairo involvement.
//
// Leapfrog model: two logical copies of the pixmap exist side-by-side,
// `cycle_w` pixels apart (cycle_w = text_w + gap).  As `offset` advances from
// 0 to cycle_w the first copy scrolls out of the left edge while the second
// enters from the right.  At offset == cycle_w the state is identical to
// offset == 0, giving a perfectly seamless loop.

pub const CarouselPixmap = struct {
    conn:    *core.xcb.xcb_connection_t,
    pixmap:  u32,
    gc:      u32,
    surface: *c.cairo_surface_t,
    text_w:  u16,
    height:  u16,

    pub fn init(dc: *const DrawContext, text_w: u16) !CarouselPixmap {
        const pixmap = core.xcb.xcb_generate_id(dc.conn);
        _ = core.xcb.xcb_create_pixmap(dc.conn, dc.depth, pixmap, dc.drawable, text_w, dc.height);
        errdefer _ = core.xcb.xcb_free_pixmap(dc.conn, pixmap);

        const gc     = core.xcb.xcb_generate_id(dc.conn);
        const cookie = core.xcb.xcb_create_gc_checked(dc.conn, gc, pixmap, 0, null);
        if (core.xcb.xcb_request_check(dc.conn, cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }
        errdefer _ = core.xcb.xcb_free_gc(dc.conn, gc);

        const vt = dc.visual_type orelse return error.NoVisualType;
        const surface = c.cairo_xcb_surface_create(
            dc.conn, pixmap, vt, @intCast(text_w), @intCast(dc.height),
        ) orelse return error.CairoSurfaceFailed;

        return .{ .conn = dc.conn, .pixmap = pixmap, .gc = gc,
                   .surface = surface, .text_w = text_w, .height = dc.height };
    }

    pub fn deinit(self: *CarouselPixmap) void {
        _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        c.cairo_surface_destroy(self.surface);
        _ = core.xcb.xcb_free_pixmap(self.conn, self.pixmap);
    }

    /// Render background colour + text into the pixmap.
    /// Called once when the title changes; blitFrame handles every tick after.
    pub fn render(
        self:     *CarouselPixmap,
        dc:       *DrawContext,
        text:     []const u8,
        bg:       u32,
        fg:       u32,
        baseline: u16,
    ) !void {
        // Background fill (XCB, straight-alpha, matches fillRect)
        const packed_bg = dc.applyTransparency(bg);
        _ = core.xcb.xcb_change_gc(self.conn, self.gc, core.xcb.XCB_GC_FOREGROUND, &[_]u32{packed_bg});
        _ = core.xcb.xcb_poly_fill_rectangle(self.conn, self.pixmap, self.gc, 1,
            &core.xcb.xcb_rectangle_t{ .x = 0, .y = 0, .width = self.text_w, .height = self.height });

        // Text (Cairo + Pango — ctx and layout are per-call; surface is persistent)
        const ctx = c.cairo_create(self.surface) orelse return error.CairoFailed;
        defer c.cairo_destroy(ctx);

        const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoFailed;
        defer c.g_object_unref(layout);
        c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dc.dpi));
        c.pango_layout_set_font_description(layout, dc.font.current_font_desc);
        c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));

        c.cairo_set_source_rgba(ctx,
            @as(f64, @floatFromInt((fg >> 16) & 0xFF)) / 255.0,
            @as(f64, @floatFromInt((fg >>  8) & 0xFF)) / 255.0,
            @as(f64, @floatFromInt( fg         & 0xFF)) / 255.0,
            1.0);

        const bl = @as(f64, @floatFromInt(c.pango_layout_get_baseline(layout)))
                 / @as(f64, @floatFromInt(c.PANGO_SCALE));
        c.cairo_move_to(ctx, 0.0, @as(f64, @floatFromInt(baseline)) - bl);
        c.pango_cairo_show_layout(ctx, layout);
        c.cairo_surface_flush(self.surface);
    }

    /// Blit two copies into `dst_pixmap` using `dst_gc`, clipped to the title
    /// segment [`clip_x`, `clip_x + clip_w`].  No Pango/Cairo — pure XCB blits.
    ///
    /// `anchor_x` — screen x of pixmap pixel 0 when offset=0 (= text start, after padding).
    /// `clip_x`   — left clip boundary (= segment start, before padding).
    /// `clip_w`   — width of the clip region (from clip_x to segment right edge).
    pub fn blitFrame(
        self:     *const CarouselPixmap,
        dst:      u32,
        dst_gc:   u32,
        anchor_x: u16,
        clip_x:   u16,
        clip_w:   u16,
        offset:   u16,
        cycle_w:  u16,
    ) void {
        // Copy A sits at (anchor_x - offset); copy B is one cycle_w to its right.
        // As offset grows from 0 → cycle_w, A scrolls off left while B enters right.
        // Clipping to [clip_x, clip_x+clip_w) lets text scroll into the left padding
        // gap rather than disappearing at the text-start position.
        const ax: i32 = @intCast(anchor_x);
        const cx: i32 = @intCast(clip_x);
        const cw: i32 = @intCast(clip_w);
        const tw: i32 = @intCast(self.text_w);
        const h              = self.height;
        const offset_i32: i32 = @intCast(offset);

        for ([2]i32{ 0, @intCast(cycle_w) }) |shift| {
            const draw_x: i32 = ax - offset_i32 + shift;

            // Intersect [draw_x, draw_x+text_w) with [clip_x, clip_x+clip_w).
            const vis_start = @max(draw_x, cx);
            const vis_end   = @min(draw_x + tw, cx + cw);
            if (vis_end <= vis_start) continue;

            _ = core.xcb.xcb_copy_area(
                self.conn,
                self.pixmap, dst, dst_gc,
                @intCast(vis_start - draw_x), 0,   // src_x, src_y
                @intCast(vis_start),           0,   // dst_x, dst_y
                @intCast(vis_end - vis_start), h,   // width, height
            );
        }
    }
};

fn createPangoLayout(ctx: *c.cairo_t, dpi: f32) !*c.PangoLayout {
    const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dpi));
    return layout;
}

fn findVisualType(conn: *core.xcb.xcb_connection_t, visual_id: u32) ?*core.xcb.xcb_visualtype_t {
    const setup = core.xcb.xcb_get_setup(conn);
    var screen_iter = core.xcb.xcb_setup_roots_iterator(setup);
    while (screen_iter.rem > 0) : (core.xcb.xcb_screen_next(&screen_iter)) {
        var depth_iter = core.xcb.xcb_screen_allowed_depths_iterator(screen_iter.data);
        while (depth_iter.rem > 0) : (core.xcb.xcb_depth_next(&depth_iter)) {
            var visual_iter = core.xcb.xcb_depth_visuals_iterator(depth_iter.data);
            while (visual_iter.rem > 0) : (core.xcb.xcb_visualtype_next(&visual_iter)) {
                if (visual_iter.data.*.visual_id == visual_id) return visual_iter.data;
            }
        }
    }
    return null;
}

fn getDefaultVisualType(screen: *core.xcb.xcb_screen_t) *core.xcb.xcb_visualtype_t {
    var depth_iter = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (core.xcb.xcb_depth_next(&depth_iter)) {
        var visual_iter = core.xcb.xcb_depth_visuals_iterator(depth_iter.data);
        if (visual_iter.rem > 0) return visual_iter.data;
    }
    unreachable;
}

inline fn appendStyle(result: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, token: []const u8) !void {
    try result.append(allocator, ' ');
    try result.appendSlice(allocator, token);
}

/// Convert Xft-style `"FontName:size=N:weight=bold"` to Pango `"FontName Bold N"`.
/// Returns `xft_name` unchanged when no `:` separator is present.
/// Results are memoised in `font_conversion_cache`.
fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![]const u8 {
    if (font_conversion_cache == null)
        font_conversion_cache = std.StringHashMap([]const u8).init(allocator);
    if (font_conversion_cache.?.get(xft_name)) |cached| return cached;
    if (std.mem.indexOfScalar(u8, xft_name, ':') == null) return xft_name;

    var result: std.ArrayListUnmanaged(u8) = .empty;
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
    const owned_key = try allocator.dupe(u8, xft_name);
    errdefer allocator.free(owned_key);
    font_conversion_cache.?.put(owned_key, converted) catch {};
    return converted;
}

/// Release the font-name conversion cache. Call once at shutdown.
pub fn deinitFontCache(allocator: std.mem.Allocator) void {
    if (font_conversion_cache) |*cache| {
        var iter = cache.iterator();
        while (iter.next()) |entry| {
            // Both keys and values (when converted) are owned allocations.
            // Keys are always duped on insertion; values share the key pointer
            // only when no conversion was needed (i.e. no ':' separator), in
            // which case the converted string IS the key — skip the double-free.
            allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*.ptr != entry.key_ptr.*.ptr)
                allocator.free(entry.value_ptr.*);
        }
        cache.deinit();
        font_conversion_cache = null;
    }
}
