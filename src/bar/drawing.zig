//! Drawing context for hana's status bar.
//!
//! Rectangle fills use XCB core drawing instead of Cairo's XRender, since the
//! latter always pre-multiplies alpha pixels, making rectangle colours appear
//! incorrect and too dark. Cairo + Pango handle all text layout and glyph
//! rendering on top of these XCB-filled rectangles.

const std   = @import("std");
const core  = @import("core");
const c     = @import("render");
const debug = @import("debug");

// Public types 

pub const VisualInfo = struct {
    visual_type: ?*core.xcb.xcb_visualtype_t,
    visual_id:   u32,
};

/// Find the first visual at `depth` bits on the root screen.
/// Falls back to the root visual if no matching depth is found.
pub fn findVisualByDepth(screen: *core.xcb.xcb_screen_t, depth: u8) VisualInfo {
    var depth_iter = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (core.xcb.xcb_depth_next(&depth_iter)) {
        if (depth_iter.data.*.depth != depth) continue;
        const visual_iter = core.xcb.xcb_depth_visuals_iterator(depth_iter.data);
        if (visual_iter.rem == 0) continue;
        const vt = visual_iter.data;
        return .{ .visual_type = vt, .visual_id = vt.*.visual_id };
    }
    return .{ .visual_type = null, .visual_id = screen.root_visual };
}

// Module-level font cache 
//
// Shared across all DrawContext instances. The bar creates multiple short-lived
// offscreen DCs for measurement and one long-lived rendering DC; cache hits
// across them avoid redundant allocations. Single-threaded WM only — no
// synchronisation needed.

var font_conversion_cache: ?std.StringHashMap([]const u8) = null;

/// Pango font string used when no fonts are configured or a named font fails to load.
const fallbackFont = "monospace:size=10";

// FontState 

pub const FontState = struct {
    allocator:         std.mem.Allocator,
    pango_layout:      *c.PangoLayout,
    current_font_desc: ?*c.PangoFontDescription         = null,
    cached_metrics:    ?struct { ascent: i16, descent: i16 } = null,

    /// Frees the current Pango font description, if one has been loaded.
    fn deinit(self: *FontState) void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
    }

    /// Load a single font by name, replacing any previously loaded description.
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

    /// Load one or more fonts as a Pango comma-separated fallback list.
    ///
    /// Both `loadFont` and `loadFonts` exist so that DrawContext and
    /// MeasureContext can share the same uniform call-site interface regardless
    /// of whether there is one font or many. Callers never need to branch on
    /// count.
    pub fn loadFonts(self: *FontState, font_names: []const []const u8) !void {
        if (font_names.len == 0) return self.loadFont(fallbackFont);
        if (font_names.len == 1) return self.loadFont(font_names[0]);
        const font_list = try std.mem.join(self.allocator, ",", font_names);
        defer self.allocator.free(font_list);
        try self.loadFont(font_list);
    }

    /// Returns (ascent, descent) in pixels for the current font. Cached after the first call;
    /// invalidated by loadFont. Result is in pixels, converted from Pango units via PANGO_SCALE.
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

/// Unpack one 8-bit RGB channel from a packed 0xRRGGBB colour and convert
/// to the [0.0, 1.0] float that Cairo expects.
inline fn unpackColorChannel(color: u32, shift: u5) f64 {
    return @as(f64, @floatFromInt((color >> shift) & 0xFF)) / 255.0;
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
    /// Separate GC used exclusively for the xcb_copy_area blit in flush().
    copy_gc:  u32,

    is_argb:       bool = false,
    /// Pre-computed alpha byte for XCB pixel packing: round(clamp(transparency)*255).
    /// Computed once at init so fillRect pays zero floating-point cost per call.
    alpha_u8:      u8   = 0xFF,
    last_color:    ?u32 = null,
    /// Cached GC foreground — skips xcb_change_gc when the packed ARGB pixel is unchanged.
    last_gc_color: ?u32 = null,
    /// Cached Pango layout width (in Pango units) set by drawTextEllipsis.
    /// Avoids pango_layout_set_width/set_ellipsize calls — which invalidate
    /// Pango's internal shaping cache — when the same width is reused across
    /// consecutive ellipsis draws (e.g. a stable window title in a narrow cell).
    /// Reset to -1 after each ellipsis draw so the cache is invalidated on the
    /// next frame (the layout is reset to defaults between draws).
    last_ellipsis_width: i32 = -1,

    // NOTE: pango_layout_get_baseline is intentionally NOT cached. The baseline
    // can vary per text run when font fallback is active (e.g. a CJK glyph
    // falling back to Noto Sans CJK has a different ascent than FiraCode),
    // so caching it would produce wrong positions for subsequent draws.

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

    /// Creates a DrawContext backed by an off-screen pixmap.
    ///
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

    /// Frees all Cairo/Pango resources and the pixmap, then deallocates the DrawContext itself.
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

    /// Loads a single font and clears the sized-font cache. Delegates to FontState.loadFont.
    pub fn loadFont(self: *DrawContext, font_name: []const u8) !void {
        try self.font.loadFont(font_name);
        if (self.cached_sized_desc) |old| c.pango_font_description_free(old);
        self.cached_sized_desc = null;
        debug.info("Cairo/Pango font loaded: {s}", .{font_name});
    }

    /// Loads a comma-separated Pango font fallback list. Delegates to FontState.loadFonts.
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

    // pango_layout_get_baseline is called unconditionally on every draw: the
    // baseline changes when font fallback is active (different scripts trigger
    // different fonts with different ascents), so caching it would silently
    // misalign text in multi-font configurations.
    /// Positions the Cairo cursor so that Pango text rendered at (x, y_top) lands on its baseline.
    inline fn moveToTextBaseline(self: *DrawContext, x: u16, y: u16) void {
        const baseline = @as(f64, @floatFromInt(c.pango_layout_get_baseline(self.font.pango_layout)))
            / @as(f64, @floatFromInt(c.PANGO_SCALE));
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y)) - baseline);
    }

    /// Fill a rectangle using XCB core drawing (xcb_poly_fill_rectangle).
    ///
    /// XCB writes the raw packed pixel (A, R, G, B) directly into the pixmap —
    /// the straight-alpha format picom expects. Cairo's XRender backend writes
    /// premultiplied pixels instead, which is why fills bypass Cairo entirely.
    /// `last_gc_color` guards xcb_change_gc: skips the roundtrip when the color
    /// is unchanged, which is the common case when adjacent segments share a
    /// background.
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

    /// Draw `text` at a temporarily-overridden absolute font size.
    ///
    /// The sized font description is cached by pixel size so repeated calls with
    /// the same size (the common case) pay zero allocation after the first call.
    /// The cache is invalidated whenever loadFont is called.
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

    /// Draw `text` at the font's natural baseline.
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColor(color);
        self.setPangoText(text);
        self.moveToTextBaseline(x, y);
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
    }

    /// Draw `text` truncated with an ellipsis if it exceeds `max_width` pixels.
    ///
    /// Use this instead of `drawText` whenever the available width is constrained
    /// (e.g. the title segment) and overflow must be handled gracefully.
    /// Pango resets to its internal defaults after the call, so subsequent draws
    /// are unaffected by the width/ellipsize state.
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

    /// Measure how many pixels wide `text` would render with the current font.
    pub fn measureTextWidth(self: *DrawContext, text: []const u8) u16 {
        self.setPangoText(text);
        var width: c_int = undefined;
        c.pango_layout_get_pixel_size(self.font.pango_layout, &width, null);
        return @intCast(width);
    }

    pub fn getMetrics(self: *DrawContext) struct { i16, i16 } { return self.font.getMetrics(); }

    /// Blit the off-screen pixmap to the window in a single xcb_copy_area call.
    /// The compositor only ever sees fully-rendered frames — no partial-draw flicker.
    ///
    /// NOTE: This does NOT call xcb_flush.  The caller is responsible for flushing:
    /// - On X-event-driven paths, the event loop's end-of-batch xcb_flush covers it.
    /// - On timer-driven paths (clock tick, cursor blink), the caller must flush
    ///   explicitly — see events.run() ready == 0 branch.
    pub fn blit(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
        if (self.copy_gc == 0) return;
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.offscreen_pixmap,
            self.window,
            self.copy_gc,
            0, 0, 0, 0,
            self.width, self.height,
        );
    }

    /// Flush the Cairo surface to the off-screen pixmap (pure Cairo/SHM op)
    /// WITHOUT issuing xcb_copy_area or xcb_flush on the shared connection.
    ///
    /// Use this inside xcb_grab_server sections so that the bar thread's render
    /// work does not trigger an early XCB flush that would let the compositor
    /// sneak in an intermediate frame.  After the grab, call blitQueued() to
    /// enqueue the xcb_copy_area, then let ungrabAndFlush() drain everything
    /// atomically with xcb_ungrab_server.
    pub fn renderOnly(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
        // Deliberately no xcb_copy_area and no xcb_flush here.
    }

    /// Queue an xcb_copy_area from the off-screen pixmap to the bar window
    /// WITHOUT calling xcb_flush.  Safe to call inside xcb_grab_server because
    /// no flush is issued; the request will be sent together with all other
    /// queued geometry changes when ungrabAndFlush() calls xcb_flush.
    pub fn blitQueued(self: *DrawContext) void {
        if (self.copy_gc == 0) return;
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.offscreen_pixmap,
            self.window,
            self.copy_gc,
            0, 0, 0, 0,
            self.width, self.height,
        );
        // No xcb_flush — caller owns the flush (ungrabAndFlush).
    }

    /// Blit only the rectangle [x, x+w) from the off-screen pixmap to the window,
    /// then flush the XCB connection immediately.
    ///
    /// Unlike blit(), this DOES call xcb_flush.  Use on timer-driven paths (e.g.
    /// carousel ticks) where no event-loop batch flush is coming to drain the queue.
    ///
    /// Does NOT call cairo_surface_flush — use this when only XCB (not Cairo) has
    /// written to the pixmap in the current frame, e.g. carousel blits.
    pub fn blitAndFlush(self: *DrawContext, x: u16, w: u16) void {
        if (self.copy_gc == 0) return;
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.offscreen_pixmap,
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
    /// that would occur if measureTextWidth() and drawText() were called separately.
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
// Lightweight font-measurement context backed by a 1×1 Cairo image surface.
// Carries no XCB resources and makes no X server round-trips. Exposes the same
// loadFont / loadFonts / getMetrics interface as DrawContext so callers can be
// generic over either.

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

    /// Frees all Cairo/Pango resources owned by this MeasureContext.
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

/// Pre-renders a window title (background + glyphs) into a wide XCB pixmap
/// exactly once.  Every subsequent carousel tick is a single xcb_copy_area —
/// one raw pixel blit with zero Pango/Cairo involvement.
///
/// Wide-pixmap model
/// ─────────────────
/// The pixmap stores two full copies of the text, separated by a gap, all on
/// the correct background colour:
///
///   [ bg * left_pad | text A | bg * gap | text B ]
///    ←── left_pad ──→←text_w→←── gap ──→←text_w→
///
/// where left_pad = text_x − seg_x (the segment's left inset) and
/// cycle_w = text_w + gap.
///
/// At scroll offset O (0 ≤ O < cycle_w), blitFrame copies exactly seg_w
/// pixels from position O into the offscreen pixmap at the segment's left
/// edge.  Because the pixmap is wide enough for any O in that range, the
/// copy is always a single, unclipped xcb_copy_area.  No fill step, no
/// clipping arithmetic, no second copy.
///
/// pixmap_w must satisfy:
///   pixmap_w ≥ max(left_pad + cycle_w + text_w,   // text B fits
///                  cycle_w + seg_w)                // blit at max offset fits
/// Callers (carousel.zig) compute this before calling init().
pub const CarouselPixmap = struct {
    conn:     *core.xcb.xcb_connection_t,
    pixmap:   u32,
    gc:       u32,
    surface:  *c.cairo_surface_t,
    pixmap_w: u16,
    height:   u16,

    /// Allocate an XCB pixmap of size (pixmap_w × bar_height) and a Cairo
    /// surface over it.  The pixmap is uninitialised until render() is called.
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

    /// Free the GC, Cairo surface, and XCB pixmap.
    pub fn deinit(self: *CarouselPixmap) void {
        _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        c.cairo_surface_destroy(self.surface);
        _ = core.xcb.xcb_free_pixmap(self.conn, self.pixmap);
    }

    /// Fill the pixmap with `bg` then render `text` at two x-positions:
    ///   copy A at x = left_pad
    ///   copy B at x = left_pad + cycle_w
    ///
    /// Called once when the title changes; blitFrame handles every tick after.
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

        const bl = @as(f64, @floatFromInt(c.pango_layout_get_baseline(layout)))
                 / @as(f64, @floatFromInt(c.PANGO_SCALE));
        const text_y = @as(f64, @floatFromInt(baseline)) - bl;

        // Copy A
        c.cairo_move_to(ctx, @as(f64, @floatFromInt(left_pad)), text_y);
        c.pango_cairo_show_layout(ctx, layout);

        // Copy B — one cycle_w to the right; same layout, different position.
        c.cairo_move_to(ctx, @as(f64, @floatFromInt(left_pad + cycle_w)), text_y);
        c.pango_cairo_show_layout(ctx, layout);

        c.cairo_surface_flush(self.surface);
    }

    /// Copy pixmap[offset .. offset+seg_w) → dst[dst_x .. dst_x+seg_w).
    ///
    /// Single xcb_copy_area — no clipping, no second copy, no fill.
    /// The wide pixmap layout guarantees the source range is always in bounds
    /// for any offset in [0, cycle_w).
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

// Private helpers 

fn createPangoLayout(ctx: *c.cairo_t, dpi: f32) !*c.PangoLayout {
    const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dpi));
    return layout;
}

/// Search all screens and depth levels to find the xcb_visualtype_t whose
/// `visual_id` matches the given value. Returns null if not found, in which
/// case the caller should fall back to `getDefaultVisualType`.
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

/// Return the first visual type available on the root screen.
///
/// Walks the screen's depth iterator and returns on the very first visual
/// entry found. This is the safe unconditional fallback used when a specific
/// visual ID cannot be located.  Panics in all build modes rather than invoking
/// undefined behaviour if the X server reports zero visuals — a condition that
/// cannot occur on any real server.
fn getDefaultVisualType(screen: *core.xcb.xcb_screen_t) *core.xcb.xcb_visualtype_t {
    var depth_iter = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (core.xcb.xcb_depth_next(&depth_iter)) {
        const visual_iter = core.xcb.xcb_depth_visuals_iterator(depth_iter.data);
        if (visual_iter.rem > 0) return visual_iter.data;
    }
    @panic("X server reported zero visuals — cannot create a drawing context");
}

/// Append a single whitespace-separated Pango style token (e.g. "Bold", "Italic", "12")
/// to the font name being assembled in `result`.
inline fn appendFontStyleToken(result: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, token: []const u8) !void {
    try result.append(allocator, ' ');
    try result.appendSlice(allocator, token);
}

/// Convert an Xft-style `"FontName:size=N:weight=bold"` descriptor to the
/// Pango `"FontName Bold N"` format that pango_font_description_from_string
/// expects. Returns `xft_name` unchanged when no `:` separator is present.
/// Results are memoised in `font_conversion_cache` to avoid repeated work.
///
/// ALLOCATOR CONTRACT: the same `allocator` must be passed on every call and
/// to `deinitFontCache`.  Mixing allocators produces use-after-free bugs.
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

/// Release the font-name conversion cache. Call once at shutdown.
///
/// Ownership invariant: every cache entry was inserted by `convertFontName`,
/// which always heap-allocates both the key (`allocator.dupe(xft_name)`) and
/// the value (`result.toOwnedSlice()`).  These are always distinct allocations,
/// so both can be freed unconditionally without a pointer-equality guard.
/// Callers that pass a no-conversion name (no `:` separator) take an early
/// return before any cache insertion, so no aliased key/value pairs exist.
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
