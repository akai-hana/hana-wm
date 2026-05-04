//! Cairo/Pango drawing context
//! Text measurement and rendering for bar segments.

const std = @import("std");

const core    = @import("core");
    const xcb = core.xcb;
const debug   = @import("debug");

const c = @import("render");

// Public types

pub const VisualInfo = struct {
    visual_type: ?*core.xcb.xcb_visualtype_t,
    visual_id:   u32,
};

/// Falls back to the root visual if no matching depth is found.
pub fn findVisualByDepth(screen: *core.xcb.xcb_screen_t, depth: u8) VisualInfo {
    var di = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
        if (di.data.*.depth != depth) continue;
        const vi = core.xcb.xcb_depth_visuals_iterator(di.data);
        if (vi.rem == 0) continue;
        return .{ .visual_type = vi.data, .visual_id = vi.data.*.visual_id };
    }
    return .{ .visual_type = null, .visual_id = screen.root_visual };
}

// Module-level font cache shared across all DrawContext instances (measurement + render DCs).
// Single-threaded — no synchronisation needed.

var font_conversion_cache: ?std.StringHashMap([]const u8) = null;

/// Pango font string used when no fonts are configured or a named font fails to load.
const fallbackFont = "monospace:size=10";

// FontState

pub const FontState = struct {
    allocator:         std.mem.Allocator,
    pango_layout:      *c.PangoLayout,
    current_font_desc: ?*c.PangoFontDescription = null,
    cached_metrics:    ?struct { ascent: i16, descent: i16 } = null,

    fn deinit(self: *FontState) void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
    }

    pub fn loadFont(self: *FontState, font_name: []const u8) !void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
        const pango_name_z = try self.allocator.dupeZ(u8, try convertFontName(self.allocator, font_name));
        defer self.allocator.free(pango_name_z);
        self.current_font_desc = c.pango_font_description_from_string(pango_name_z.ptr);
        if (self.current_font_desc == null) {
            debug.warn("Failed to load font '{s}', using default", .{font_name});
            self.current_font_desc = c.pango_font_description_from_string("monospace 10");
        }
        c.pango_layout_set_font_description(self.pango_layout, self.current_font_desc);
        self.cached_metrics = null;
    }

    /// Unified entry point shared with MeasureContext so callers need no font-count branch.
    pub fn loadFonts(self: *FontState, font_names: []const []const u8) !void {
        if (font_names.len == 0) return self.loadFont(fallbackFont);
        const font_list = try std.mem.join(self.allocator, ",", font_names);
        defer self.allocator.free(font_list);
        try self.loadFont(font_list);
    }

    /// Returns (ascent, descent) in pixels; cached per font description, invalidated by loadFont.
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

// DrawContext

inline fn unpackColorChannel(color: u32, shift: u5) f64 {
    return @as(f64, @floatFromInt((color >> shift) & 0xFF)) / 255.0;
}

/// Converts Pango units (1/1024 px) to floating-point pixels.
inline fn pangoToF64(pango_units: c_int) f64 {
    return @as(f64, @floatFromInt(pango_units)) / @as(f64, @floatFromInt(c.PANGO_SCALE));
}

pub const DrawContext = struct {
    font:   FontState,
    conn:   *core.xcb.xcb_connection_t,
    /// The real X window — only used as the copy destination in flush().
    window:   u32,
    /// Off-screen pixmap — all drawing targets this.
    offscreen_pixmap: u32,
    width:    u16,
    height:   u16,

    surface:  *c.cairo_surface_t,
    ctx:      *c.cairo_t,
    /// GC used by fillRect (xcb_poly_fill_rectangle).
    gc:       u32,
    /// Separate GC used exclusively for the xcb_copy_area blit in blit().
    copy_gc:  u32,

    is_argb:       bool = false,
    /// Pre-computed alpha byte for XCB pixel packing: round(clamp(transparency)*255).
    /// Computed once at init so fillRect pays zero floating-point cost per call.
    alpha_u8:      u8   = 0xFF,
    last_color:    ?u32 = null,
    /// Cached GC foreground — skips xcb_change_gc when the packed ARGB pixel is unchanged.
    last_gc_color: ?u32 = null,
    /// Cached Pango layout width (Pango units). Skips pango_layout_set_width/set_ellipsize —
    /// which invalidate Pango's shaping cache unconditionally — when width is stable across frames.
    last_ellipsis_width: i32 = -1,

    // drawTextSized cache: avoids copying the font description on every
    // indicator-glyph draw when the requested size matches the previous call.
    cached_sized_desc: ?*c.PangoFontDescription = null,
    cached_sized_px:   u16                       = 0,

    /// Stored for CarouselPixmap — needed to create a Cairo surface with the same visual.
    visual_type: ?*core.xcb.xcb_visualtype_t = null,
    /// DPI used when rendering into a CarouselPixmap (must match bar's Pango layout).
    dpi:         f32                          = 96.0,
    /// Actual pixel depth of the offscreen pixmap — 32 for ARGB, screen root_depth otherwise.
    depth:       u8                           = 24,

    /// Checks an XCB void-cookie; frees the error and returns GCCreationFailed on failure.
    inline fn checkXcbCookie(conn: *core.xcb.xcb_connection_t, cookie: core.xcb.xcb_void_cookie_t) !void {
        if (core.xcb.xcb_request_check(conn, cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }
    }

    /// All drawing targets the off-screen pixmap; call blit() to copy to the window atomically.
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

        const visual_type = resolveVisualType(conn, screen, visual_id);

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
            .conn             = conn,
            .window           = window,
            .offscreen_pixmap = pixmap,
            .width            = width,
            .height           = height,
            .surface          = surface,
            .ctx              = ctx,
            .font             = .{ .allocator = allocator, .pango_layout = layout },
            .gc               = 0,
            .copy_gc          = 0,
            .is_argb          = is_argb,
            .alpha_u8         = if (is_argb)
                @intFromFloat(@round(std.math.clamp(transparency, 0.0, 1.0) * 255.0))
            else
                0xFF,
            .visual_type = visual_type,
            .dpi         = dpi,
            .depth       = if (is_argb) 32 else screen.*.root_depth,
        };

        // Fire both GC-create requests before blocking on either reply so both
        // land in the same TCP segment.
        dc.gc      = core.xcb.xcb_generate_id(conn);
        dc.copy_gc = core.xcb.xcb_generate_id(conn);
        const gc_cookie      = core.xcb.xcb_create_gc_checked(conn, dc.gc,      pixmap, 0, null);
        const copy_gc_cookie = core.xcb.xcb_create_gc_checked(conn, dc.copy_gc, window, 0, null);
        try checkXcbCookie(conn, gc_cookie);
        try checkXcbCookie(conn, copy_gc_cookie);

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
        if (self.offscreen_pixmap != 0) _ = core.xcb.xcb_free_pixmap(self.conn, self.offscreen_pixmap);
        self.font.allocator.destroy(self);
    }

    /// Also clears the sized-font cache; delegates to FontState.loadFont.
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        try self.font.loadFont(font_name);
        if (self.cached_sized_desc) |old| c.pango_font_description_free(old);
        self.cached_sized_desc = null;
        debug.info("Cairo/Pango font loaded: {s}", .{font_name});
    }

    /// Delegates to FontState.loadFonts.
    pub fn loadFonts(self: *DrawContext, font_names: []const []const u8) !void {
        try self.font.loadFonts(font_names);
        if (font_names.len > 1) debug.info("Loaded {} fonts with fallback support", .{font_names.len});
    }

    inline fn setColor(self: *DrawContext, color: u32) void {
        if (self.last_color == color) return;
        c.cairo_set_source_rgba(self.ctx,
            unpackColorChannel(color, 16),
            unpackColorChannel(color, 8),
            unpackColorChannel(color, 0),
            1.0);
        self.last_color = color;
    }

    pub inline fn setTransparency(self: *DrawContext, color: u32) u32 {
        if (!self.is_argb) return color;
        return (@as(u32, self.alpha_u8) << 24) | (color & 0x00FFFFFF);
    }

    inline fn setPangoText(self: *DrawContext, text: []const u8) void {
        c.pango_layout_set_text(self.font.pango_layout, text.ptr, @intCast(text.len));
    }

    // pango_layout_get_baseline is called unconditionally: font fallback can change the
    // baseline per-run (e.g. a CJK glyph triggering Noto Sans CJK), so caching it
    // would silently misalign text in multi-font configurations.
    inline fn moveToTextBaseline(self: *DrawContext, x: u16, y: u16) void {
        const baseline = pangoToF64(c.pango_layout_get_baseline(self.font.pango_layout));
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - baseline);
    }

    /// Uses XCB rather than Cairo to write straight-alpha pixels (picom expects straight-alpha;
    /// Cairo's XRender backend writes premultiplied). `last_gc_color` skips xcb_change_gc
    /// when the color is unchanged, which is the common case for adjacent same-background segments.
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const packed_color: u32 = self.setTransparency(color);
        if (self.last_gc_color != packed_color) {
            _ = core.xcb.xcb_change_gc(self.conn, self.gc, core.xcb.XCB_GC_FOREGROUND, &[_]u32{packed_color});
            self.last_gc_color = packed_color;
        }
        const rect = core.xcb.xcb_rectangle_t{
            .x = @intCast(x), .y = @intCast(y), .width = width, .height = height,
        };
        _ = core.xcb.xcb_poly_fill_rectangle(self.conn, self.offscreen_pixmap, self.gc, 1, &rect);
    }

    /// Sized font description cached by pixel size; cache invalidated by loadFont.
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

        self.setColor(color);
        c.cairo_move_to(self.ctx, @floatFromInt(x),
            @as(f64, @floatFromInt(y_top)) - pangoToF64(ink_rect.y));
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
    }

    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColor(color);
        self.setPangoText(text);
        self.moveToTextBaseline(x, y);
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
    }

    /// Resets Pango width/ellipsize to defaults after rendering; subsequent draws unaffected.
    pub fn drawTextEllipsis(
        self:      *DrawContext,
        x:         u16,
        y:         u16,
        text:      []const u8,
        max_width: u16,
        color:     u32,
    ) !void {
        self.setPangoText(text);

        // Only call pango_layout_set_width / set_ellipsize when the width has
        // changed since the last draw.  Both calls invalidate Pango's internal
        // shaping cache unconditionally — even when the value is unchanged — so
        // skipping them when max_width is stable across frames avoids reshaping.
        const pango_width: i32 = @as(i32, max_width) * c.PANGO_SCALE;
        if (pango_width != self.last_ellipsis_width) {
            c.pango_layout_set_width(self.font.pango_layout, pango_width);
            c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.END);
            self.last_ellipsis_width = pango_width;
        }

        self.setColor(color);
        self.moveToTextBaseline(x, y);
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);

        c.pango_layout_set_width(self.font.pango_layout, -1);
        c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.NONE);
        self.last_ellipsis_width = -1; // invalidate cache: layout is back to defaults
    }

    pub fn measureTextWidth(self: *DrawContext, text: []const u8) u16 {
        self.setPangoText(text);
        var width: c_int = undefined;
        c.pango_layout_get_pixel_size(self.font.pango_layout, &width, null);
        return @intCast(width);
    }

    pub fn getMetrics(self: *DrawContext) struct { i16, i16 } { return self.font.getMetrics(); }

    inline fn xcbCopyArea(self: *DrawContext, src_x: u16, dst_x: u16, w: u16) void {
        _ = core.xcb.xcb_copy_area(self.conn, self.offscreen_pixmap, self.window, self.copy_gc,
            @intCast(src_x), 0, @intCast(dst_x), 0, w, self.height);
    }

    /// cairo_surface_flush only — no xcb_copy_area, no xcb_flush.
    /// Safe inside xcb_grab_server; pair with blitQueued() + ungrabAndFlush().
    pub fn renderOnly(self: *DrawContext) void { c.cairo_surface_flush(self.surface); }

    /// Enqueues xcb_copy_area without flushing; safe inside xcb_grab_server.
    /// The request is sent with all queued geometry changes when ungrabAndFlush() fires.
    pub fn blitQueued(self: *DrawContext) void {
        if (self.copy_gc != 0) self.xcbCopyArea(0, 0, self.width);
    }

    /// Does NOT call xcb_flush — the event loop's end-of-batch flush covers event-driven
    /// paths; timer-driven paths (clock tick, cursor blink) must flush explicitly.
    pub fn blit(self: *DrawContext) void { self.renderOnly(); self.blitQueued(); }

    /// Unlike blit(), calls xcb_flush immediately. Use on timer-driven paths where
    /// no event-loop flush is coming. Does NOT call cairo_surface_flush.
    pub fn blitAndFlush(self: *DrawContext, x: u16, w: u16) void {
        if (self.copy_gc != 0) { self.xcbCopyArea(x, x, w); _ = core.xcb.xcb_flush(self.conn); }
    }

    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.getMetrics();
        const top_pad: i32    = @max(0, @divTrunc(@as(i32, bar_height) - (asc + desc), 2));
        return @intCast(top_pad + asc);
    }

    /// Sets Pango text once for both measurement and render, avoiding a double pango_layout_set_text.
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

// MeasureContext: lightweight font measurement backed by a 1×1 Cairo image surface.
// No XCB resources, no X round-trips. Same loadFont/loadFonts/getMetrics interface as DrawContext.

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

    pub fn loadFont(self: *MeasureContext,  font_name: []const u8)          !void { return self.font.loadFont(font_name); }
    pub fn loadFonts(self: *MeasureContext, font_names: []const []const u8) !void { return self.font.loadFonts(font_names); }
    pub fn getMetrics(self: *MeasureContext) struct { i16, i16 }                  { return self.font.getMetrics(); }
};

/// Pre-renders a title into a wide XCB pixmap once; every carousel tick is a single
/// xcb_copy_area with zero Pango/Cairo involvement.
///
/// Wide-pixmap layout
/// ──────────────────
/// Two full copies of the text are stored at offsets `left_pad` and `left_pad + cycle_w`:
///
///   [ bg * left_pad | text A | bg * gap | text B ]
///    ←── left_pad ──→←text_w→←── gap ──→←text_w→
///
/// At scroll offset O (0 ≤ O < cycle_w), blitFrame copies seg_w pixels from O into
/// the offscreen pixmap.  The pixmap is wide enough that the copy is always a single
/// unclipped xcb_copy_area — no fill step, no clipping arithmetic, no second copy.
///
/// Required: pixmap_w ≥ max(left_pad + cycle_w + text_w, cycle_w + seg_w)
/// Callers (carousel.zig) compute this before calling init().
pub const CarouselPixmap = struct {
    conn:     *core.xcb.xcb_connection_t,
    pixmap:   u32,
    gc:       u32,
    surface:  *c.cairo_surface_t,
    pixmap_w: u16,
    height:   u16,

    pub fn init(dc: *const DrawContext, pixmap_w: u16) !CarouselPixmap {
        const pixmap = core.xcb.xcb_generate_id(dc.conn);
        _ = core.xcb.xcb_create_pixmap(dc.conn, dc.depth, pixmap,
                dc.offscreen_pixmap, pixmap_w, dc.height);
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
            dc.conn, pixmap, vt, @intCast(pixmap_w), @intCast(dc.height),
        ) orelse return error.CairoSurfaceFailed;

        return .{ .conn = dc.conn, .pixmap = pixmap, .gc = gc,
                   .surface = surface, .pixmap_w = pixmap_w, .height = dc.height };
    }

    pub fn deinit(self: *CarouselPixmap) void {
        _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        c.cairo_surface_destroy(self.surface);
        _ = core.xcb.xcb_free_pixmap(self.conn, self.pixmap);
    }

    /// Called once per title change; subsequent ticks use blitFrame.
    pub fn render(
        self:     *CarouselPixmap,
        dc:       *DrawContext,
        text:     []const u8,
        bg:       u32,
        fg:       u32,
        baseline: u16,
        left_pad: u16,
        cycle_w:  u16,
    ) !void {
        // Fill the entire pixmap with the background colour (XCB, straight-alpha).
        const packed_bg = dc.setTransparency(bg);
        _ = core.xcb.xcb_change_gc(self.conn, self.gc,
                core.xcb.XCB_GC_FOREGROUND, &[_]u32{packed_bg});
        _ = core.xcb.xcb_poly_fill_rectangle(self.conn, self.pixmap, self.gc, 1,
            &core.xcb.xcb_rectangle_t{
                .x = 0, .y = 0, .width = self.pixmap_w, .height = self.height });

        // Render text glyphs at both copy positions via Cairo + Pango.
        const ctx = c.cairo_create(self.surface) orelse return error.CairoFailed;
        defer c.cairo_destroy(ctx);

        const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoFailed;
        defer c.g_object_unref(layout);
        c.pango_cairo_context_set_resolution(
            c.pango_layout_get_context(layout), @floatCast(dc.dpi));
        c.pango_layout_set_font_description(layout, dc.font.current_font_desc);
        c.pango_layout_set_text(layout, text.ptr, @intCast(text.len));

        c.cairo_set_source_rgba(ctx,
            unpackColorChannel(fg, 16),
            unpackColorChannel(fg, 8),
            unpackColorChannel(fg, 0),
            1.0);

        const text_y = @as(f64, @floatFromInt(baseline)) - pangoToF64(c.pango_layout_get_baseline(layout));

        // Copy A
        c.cairo_move_to(ctx, @as(f64, @floatFromInt(left_pad)), text_y);
        c.pango_cairo_show_layout(ctx, layout);

        // Copy B — one cycle_w to the right; same layout, different position.
        c.cairo_move_to(ctx, @as(f64, @floatFromInt(left_pad + cycle_w)), text_y);
        c.pango_cairo_show_layout(ctx, layout);

        c.cairo_surface_flush(self.surface);
    }

    /// Single xcb_copy_area; the wide-pixmap layout guarantees source is always in bounds.
    pub fn blitFrame(
        self:   *const CarouselPixmap,
        dst:    u32,
        dst_gc: u32,
        dst_x:  u16,
        offset: u16,
        seg_w:  u16,
    ) void {
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.pixmap, dst, dst_gc,
            @intCast(offset), 0,
            @intCast(dst_x),  0,
            seg_w, self.height,
        );
    }
};

fn createPangoLayout(ctx: *c.cairo_t, dpi: f32) !*c.PangoLayout {
    const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dpi));
    return layout;
}

/// Returns the visual matching `visual_id` across all screens, or falls back to
/// the first visual on `screen`. Panics if the X server has no visuals at all.
fn resolveVisualType(
    conn:      *core.xcb.xcb_connection_t,
    screen:    *core.xcb.xcb_screen_t,
    visual_id: ?u32,
) *core.xcb.xcb_visualtype_t {
    if (visual_id) |vid| {
        var si = core.xcb.xcb_setup_roots_iterator(core.xcb.xcb_get_setup(conn));
        while (si.rem > 0) : (core.xcb.xcb_screen_next(&si)) {
            var di = core.xcb.xcb_screen_allowed_depths_iterator(si.data);
            while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
                var vi = core.xcb.xcb_depth_visuals_iterator(di.data);
                while (vi.rem > 0) : (core.xcb.xcb_visualtype_next(&vi))
                    if (vi.data.*.visual_id == vid) return vi.data;
            }
        }
    }
    // Fall back to the first available visual on screen; panic if there are none.
    var di = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
        const vi = core.xcb.xcb_depth_visuals_iterator(di.data);
        if (vi.rem > 0) return vi.data;
    }
    @panic("X server reported zero visuals — cannot create a drawing context");
}

inline fn appendFontStyleToken(result: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, token: []const u8) !void {
    try result.append(allocator, ' ');
    try result.appendSlice(allocator, token);
}

/// Converts Xft `"FontName:size=N:weight=bold"` to Pango `"FontName Bold N"` format.
/// Returns `xft_name` unchanged when no `:` is present. Results cached in `font_conversion_cache`.
///
/// ALLOCATOR CONTRACT: the same `allocator` must be passed on every call and to `deinitFontCache`.
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
        try appendFontStyleToken(&result, allocator, "Italic");

    if (weight) |w| {
        const token: ?[]const u8 =
            if      (std.mem.eql(u8, w, "bold"))  "Bold"
            else if (std.mem.eql(u8, w, "light")) "Light"
            else                                   null;
        if (token) |t| try appendFontStyleToken(&result, allocator, t);
    }

    if (size) |s| try appendFontStyleToken(&result, allocator, s);

    const converted = try result.toOwnedSlice(allocator);
    const owned_key = try allocator.dupe(u8, xft_name);
    errdefer allocator.free(owned_key);
    font_conversion_cache.?.put(owned_key, converted) catch {};
    return converted;
}

/// Call once at shutdown. Key and value are always distinct heap allocations, so both are freed unconditionally.
pub fn deinitFontCache(allocator: std.mem.Allocator) void {
    if (font_conversion_cache) |*cache| {
        var iter = cache.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        cache.deinit();
        font_conversion_cache = null;
    }
}
