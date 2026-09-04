//! Cairo/Pango drawing context
//! Text measurement and rendering for bar segments.

const std = @import("std");

const core = @import("core");
const debug = @import("debug");

const c = @import("render");

/// First visual on `screen` matching `depth`, or null.
fn firstVisualOfDepth(screen: core.Screen, depth: u8) ?*core.xcb.xcb_visualtype_t {
    var di = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
        if (di.data.*.depth != depth) continue;
        const vi = core.xcb.xcb_depth_visuals_iterator(di.data);
        if (vi.rem > 0) return vi.data;
    }
    return null;
}

/// Falls back to the root visual if no matching depth is found.
pub fn findVisualByDepth(screen: core.Screen, depth: u8) u32 {
    const vt = firstVisualOfDepth(screen, depth) orelse return screen.root_visual;
    return vt.visual_id;
}

/// Pango font string used when no fonts are configured or a named font fails to load.
const fallbackFont = "monospace:size=10";

pub const FontState = struct {
    allocator: std.mem.Allocator,
    pango_layout: *c.PangoLayout,
    current_font_desc: ?*c.PangoFontDescription = null,
    cached_metrics: ?struct { ascent: i16, descent: i16 } = null,

    fn deinit(self: *FontState) void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
    }

    pub fn loadFonts(self: *FontState, font_names: []const []const u8) !void {
        if (font_names.len == 0) return self.loadFont(fallbackFont);
        const font_list = try std.mem.join(self.allocator, ",", font_names);
        defer self.allocator.free(font_list);
        try self.loadFont(font_list);
    }

    fn loadFont(self: *FontState, font_name: []const u8) !void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
        const converted = try convertFontName(self.allocator, font_name);
        defer self.allocator.free(converted);
        const pango_name_z = try self.allocator.dupeZ(u8, converted);
        defer self.allocator.free(pango_name_z);
        self.current_font_desc = c.pango_font_description_from_string(pango_name_z.ptr);
        if (self.current_font_desc == null) {
            debug.warn("Failed to load font '{s}', using default", .{font_name});
            self.current_font_desc = c.pango_font_description_from_string(fallbackFont);
        }
        c.pango_layout_set_font_description(self.pango_layout, self.current_font_desc);
        self.cached_metrics = null;
    }

    /// Returns (ascent, descent) in pixels; cached per font description, invalidated by loadFont.
    pub fn getMetrics(self: *FontState) struct { i16, i16 } {
        if (self.cached_metrics) |m| return .{ m.ascent, m.descent };
        const metrics = c.pango_context_get_metrics(
            c.pango_layout_get_context(self.pango_layout),
            self.current_font_desc,
            null,
        );
        defer c.pango_font_metrics_unref(metrics);
        const ascent: i16 = @intCast(std.math.clamp(
            @divTrunc(c.pango_font_metrics_get_ascent(metrics), c.pango_scale),
            std.math.minInt(i16),
            std.math.maxInt(i16),
        ));
        const descent: i16 = @intCast(std.math.clamp(
            @divTrunc(c.pango_font_metrics_get_descent(metrics), c.pango_scale),
            std.math.minInt(i16),
            std.math.maxInt(i16),
        ));
        self.cached_metrics = .{ .ascent = ascent, .descent = descent };
        return .{ ascent, descent };
    }
};

// ---------------------------------------------------------------------------

inline fn setCairoColor(ctx: *c.cairo_t, color: u32) void {
    const r = @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g = @as(f64, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b = @as(f64, @floatFromInt(color & 0xFF)) / 255.0;
    c.cairo_set_source_rgba(ctx, r, g, b, 1.0);
}

inline fn pangoToF64(pango_units: c_int) f64 {
    return @as(f64, @floatFromInt(pango_units)) / c.pango_scale;
}

inline fn pxToPango(px: u16) f64 {
    return @as(f64, @floatFromInt(px)) * c.pango_scale;
}

inline fn createXcbPixmap(conn: core.Connection, depth: u8, drawable: u32, w: u16, h: u16) u32 {
    const pixmap = core.xcb.xcb_generate_id(conn);
    _ = core.xcb.xcb_create_pixmap(conn, depth, pixmap, drawable, w, h);
    return pixmap;
}

inline fn createCheckedGC(conn: core.Connection, drawable: u32) !u32 {
    const gc = core.xcb.xcb_generate_id(conn);
    const cookie = core.xcb.xcb_create_gc_checked(conn, gc, drawable, 0, null);
    if (core.xcb.xcb_request_check(conn, cookie)) |err| {
        std.c.free(err);
        return error.GCCreationFailed;
    }
    return gc;
}

inline fn showLayoutAtBaseline(
    ctx: *c.cairo_t,
    layout: *c.PangoLayout,
    x: f64,
    baseline: u16,
) void {
    const baseline_f: f64 = @floatFromInt(baseline);
    c.cairo_move_to(ctx, x, baseline_f - pangoToF64(c.pango_layout_get_baseline(layout)));
    c.pango_cairo_show_layout(ctx, layout);
}

pub const DrawContext = struct {
    font: FontState,
    conn: core.Connection,
    /// The real X window, only used as the copy destination in flush().
    window: u32,
    /// Off-screen pixmap; all drawing targets this.
    offscreen_pixmap: u32,
    width: u16,
    height: u16,

    surface: *c.cairo_surface_t,
    ctx: *c.cairo_t,
    /// GC used by fillRect (xcb_poly_fill_rectangle).
    gc: u32,
    /// Separate GC used exclusively for the xcb_copy_area blit in blit().
    copy_gc: u32,

    is_argb: bool = false,
    /// Pre-computed alpha byte for XCB pixel packing: round(clamp(transparency)*255).
    alpha_u8: u8 = 0xFF,
    last_color: ?u32 = null,
    /// Cached GC foreground: skips xcb_change_gc when the packed ARGB pixel is unchanged.
    last_gc_color: ?u32 = null,

    // drawTextSized cache: avoids copying the font description on every
    // indicator-glyph draw when the requested size matches the previous call.
    sized_font_desc: ?*c.PangoFontDescription = null,
    sized_font_px: u16 = 0,
    /// Tracks the font description currently set on the Pango layout so
    /// drawTextSized can skip the set/restore pair when reusing the same sized font.
    layout_font: ?*c.PangoFontDescription = null,

    /// Actual pixel depth of the offscreen pixmap: 32 for ARGB, screen root_depth otherwise.
    depth: u8 = 24,

    pub fn initWithVisual(
        allocator: std.mem.Allocator,
        conn: core.Connection,
        window: u32,
        width: u16,
        height: u16,
        visual_id: ?u32,
        dpi: f32,
        is_argb: bool,
        transparency: f32,
    ) !*DrawContext {
        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);

        const setup = core.xcb.xcb_get_setup(conn);
        const screen = core.xcb.xcb_setup_roots_iterator(setup).data;

        // CreatePixmap requires a concrete depth: XCB_COPY_FROM_PARENT (0) is
        // only valid for CreateWindow and fails here with BadValue, which
        // silently killed opaque-bar init (default transparency = 1.0).
        const depth: u8 = if (is_argb) 32 else screen.*.root_depth;

        const visual_type = try resolveVisualType(conn, screen, visual_id, depth);

        const pixmap = createXcbPixmap(conn, depth, window, width, height);
        errdefer _ = core.xcb.xcb_free_pixmap(conn, pixmap);

        const surface = c.cairo_xcb_surface_create(
            conn,
            pixmap,
            visual_type,
            @intCast(width),
            @intCast(height),
        ) orelse return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);

        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        errdefer c.cairo_destroy(ctx);

        const layout = try createPangoLayout(ctx, dpi);
        errdefer c.g_object_unref(layout);

        dc.* = .{
            .conn = conn,
            .window = window,
            .offscreen_pixmap = pixmap,
            .width = width,
            .height = height,
            .surface = surface,
            .ctx = ctx,
            .font = .{ .allocator = allocator, .pango_layout = layout },
            .gc = 0,
            .copy_gc = 0,
            .is_argb = is_argb,
            .alpha_u8 = if (is_argb)
                @intFromFloat(@round(std.math.clamp(transparency, 0.0, 1.0) * 255.0))
            else
                0xFF,
            .depth = depth,
        };

        // Fire both GC-create requests before blocking on either reply so both
        // land in the same TCP segment. Each GC gets an errdefer so a failure
        // on the second create doesn't leak the first (on success these don't
        // fire; deinit owns the resources).
        dc.gc = try createCheckedGC(conn, pixmap);
        errdefer _ = core.xcb.xcb_free_gc(conn, dc.gc);
        dc.copy_gc = try createCheckedGC(conn, window);
        errdefer _ = core.xcb.xcb_free_gc(conn, dc.copy_gc);

        return dc;
    }

    pub fn deinit(self: *DrawContext) void {
        self.font.deinit();
        if (self.sized_font_desc) |desc| c.pango_font_description_free(desc);
        if (self.gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        if (self.copy_gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.copy_gc);
        c.g_object_unref(self.font.pango_layout);
        c.cairo_destroy(self.ctx);
        // Destroy surface before pixmap: Cairo holds a reference to the pixmap.
        c.cairo_surface_destroy(self.surface);
        if (self.offscreen_pixmap != 0)
            _ = core.xcb.xcb_free_pixmap(self.conn, self.offscreen_pixmap);
        self.font.allocator.destroy(self);
    }

    inline fn setColor(self: *DrawContext, color: u32) void {
        if (self.last_color == color) return;
        setCairoColor(self.ctx, color);
        self.last_color = color;
    }

    inline fn setPangoText(self: *DrawContext, text: []const u8) void {
        c.pango_layout_set_text(self.font.pango_layout, text.ptr, @intCast(text.len));
    }

    /// Colors the context and renders the layout's CURRENT text at the
    /// (x, y-baseline) position. Shared tail of the baseline-anchored draw
    /// variants (`drawText`, `drawTextEllipsis`, `drawSegment`).
    inline fn paintText(self: *DrawContext, x: u16, y: u16, color: u32) void {
        self.setColor(color);
        showLayoutAtBaseline(self.ctx, self.font.pango_layout, @floatFromInt(x), y);
    }

    /// Uses XCB rather than Cairo to write straight-alpha pixels (picom expects straight-alpha;
    /// Cairo's XRender backend writes premultiplied). `last_gc_color` skips xcb_change_gc
    /// when the color is unchanged, which is the common case for adjacent same-background segments.
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const packed_color: u32 = if (self.is_argb)
            (@as(u32, self.alpha_u8) << 24) | (color & 0x00FFFFFF)
        else
            color;
        if (self.last_gc_color != packed_color) {
            _ = core.xcb.xcb_change_gc(
                self.conn,
                self.gc,
                core.xcb.XCB_GC_FOREGROUND,
                &[_]u32{packed_color},
            );
            self.last_gc_color = packed_color;
        }
        const rect = core.xcb.xcb_rectangle_t{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = width,
            .height = height,
        };
        _ = core.xcb.xcb_poly_fill_rectangle(self.conn, self.offscreen_pixmap, self.gc, 1, &rect);
    }

    /// Cached sized font description; rebuilt whenever `size_px` changes.
    /// Derived from font.current_font_desc, so it is stale after a font reload;
    /// DrawContexts are created fresh per reload, which keeps it consistent today.
    pub fn drawTextSized(
        self: *DrawContext,
        x: u16,
        y_top: u16,
        text: []const u8,
        size_px: u16,
        color: u32,
    ) !void {
        const desc = self.font.current_font_desc orelse return error.NoFont;

        if (self.sized_font_desc == null or self.sized_font_px != size_px) {
            if (self.sized_font_desc) |old| c.pango_font_description_free(old);
            const temp = c.pango_font_description_copy(desc) orelse
                return error.PangoDescCopyFailed;
            c.pango_font_description_set_absolute_size(temp, pxToPango(size_px));
            self.sized_font_desc = temp;
            self.sized_font_px = size_px;
        }
        const sized = self.sized_font_desc.?;

        const already_set = self.layout_font == sized;
        if (!already_set) {
            c.pango_layout_set_font_description(self.font.pango_layout, sized);
            self.layout_font = sized;
        }
        defer if (!already_set) {
            c.pango_layout_set_font_description(self.font.pango_layout, desc);
            self.layout_font = desc;
        };

        self.setPangoText(text);

        var ink_rect: c.PangoRectangle = undefined;
        c.pango_layout_get_extents(self.font.pango_layout, &ink_rect, null);

        self.setColor(color);
        c.cairo_move_to(
            self.ctx,
            @floatFromInt(x),
            @as(f64, @floatFromInt(y_top)) - pangoToF64(ink_rect.y),
        );
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
    }

    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        try self.drawTextImpl(x, y, text, null, color);
    }

    /// Draws `text` at each x position in `x_positions`, clipped to
    /// [clip_x, clip_x + clip_w). The title marquee passes two positions one
    /// cycle apart so the copies tile into a seamless wrap.
    pub fn drawTextScrolled(
        self: *DrawContext,
        clip_x: u16,
        clip_w: u16,
        y: u16,
        x_positions: [2]f64,
        text: []const u8,
        color: u32,
    ) !void {
        self.setColor(color);
        self.setPangoText(text);
        c.cairo_save(self.ctx);
        defer c.cairo_restore(self.ctx);
        c.cairo_rectangle(
            self.ctx,
            @floatFromInt(clip_x),
            0,
            @floatFromInt(clip_w),
            @floatFromInt(self.height),
        );
        c.cairo_clip(self.ctx);
        for (x_positions) |x|
            showLayoutAtBaseline(self.ctx, self.font.pango_layout, x, y);
    }

    /// Resets Pango width/ellipsize to defaults after rendering; subsequent draws unaffected.
    pub fn drawTextEllipsis(
        self: *DrawContext,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: u16,
        color: u32,
    ) !void {
        try self.drawTextImpl(x, y, text, max_width, color);
    }

    /// Shared text rendering: set pango text, optionally ellipsize to
    /// `max_width`, and paint at baseline.
    inline fn drawTextImpl(
        self: *DrawContext,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: ?u16,
        color: u32,
    ) !void {
        self.setPangoText(text);
        if (max_width) |w| {
            c.pango_layout_set_width(self.font.pango_layout, @as(i32, w) * c.pango_scale);
            c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.END);
        }
        defer if (max_width != null) {
            c.pango_layout_set_width(self.font.pango_layout, -1);
            c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.NONE);
        };
        self.paintText(x, y, color);
    }

    pub fn measureTextWidth(self: *DrawContext, text: []const u8) u16 {
        self.setPangoText(text);
        var width: c_int = undefined;
        c.pango_layout_get_pixel_size(self.font.pango_layout, &width, null);
        // Pango returns signed pixels; clamp to the u16 range so an
        // unexpected negative or >65535 measurement can't panic/UB the cast.
        const w: c_int = std.math.clamp(width, 0, @as(c_int, std.math.maxInt(u16)));
        return @intCast(w);
    }

    /// Shared blit body: cairo_surface_flush + xcb_copy_area of [x, x+w),
    /// plus an immediate xcb_flush only for blitRegion. queueBlit must NOT
    /// flush here: it is safe inside xcb_grab_server precisely because the
    /// copy is sent with the caller's batch end.
    inline fn blitImpl(self: *DrawContext, x: u16, w: u16, comptime flush: bool) void {
        c.cairo_surface_flush(self.surface);
        if (self.copy_gc == 0) return;
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.offscreen_pixmap,
            self.window,
            self.copy_gc,
            @intCast(x),
            0,
            @intCast(x),
            0,
            w,
            self.height,
        );
        if (flush) _ = core.xcb.xcb_flush(self.conn);
    }

    /// Full-width xcb_copy_area enqueued but not flushed.
    /// Safe inside xcb_grab_server; flushed by ungrabAndFlush() or the event-loop's xcb_flush.
    pub fn queueBlit(self: *DrawContext) void {
        self.blitImpl(0, self.width, false);
    }

    /// Region copy with immediate xcb_flush. Used on timer-driven paths
    /// (clock tick, prompt caret blink).
    pub fn blitRegion(self: *DrawContext, x: u16, w: u16) void {
        self.blitImpl(x, w, true);
    }

    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.font.getMetrics();
        const top_pad: i32 = @max(0, @divTrunc(@as(i32, bar_height) - (asc + desc), 2));
        return @intCast(top_pad + asc);
    }

    /// Fill background, draw text at baseline, return x + width.
    /// Sets pango text once for both measure and render.
    pub fn drawSegment(
        self: *DrawContext,
        x: u16,
        height: u16,
        text: []const u8,
        padding: u16,
        bg: u32,
        fg: u32,
    ) !u16 {
        const width: u16 = self.measureTextWidth(text) + padding * 2;
        self.fillRect(x, 0, width, height, bg);
        self.paintText(x + padding, self.baselineY(height), fg);
        return x + width;
    }
};

// ---------------------------------------------------------------------------
// One-shot font metrics probing (used by the bar height / font-size calc).

/// Loads `font_names` into a throwaway layout and returns its (ascent, descent) in pixels.
pub fn probeFontMetrics(
    allocator: std.mem.Allocator,
    dpi: f32,
    font_names: []const []const u8,
) ?struct { ascent: i16, descent: i16 } {
    const surface = c.cairo_image_surface_create(.ARGB32, 1, 1) orelse return null;
    defer c.cairo_surface_destroy(surface);
    // The cairo context exists only to obtain the Pango layout.
    const ctx = c.cairo_create(surface) orelse return null;
    defer c.cairo_destroy(ctx);
    const layout = createPangoLayout(ctx, dpi) catch return null;
    defer c.g_object_unref(layout);

    var font = FontState{ .allocator = allocator, .pango_layout = layout };
    if (font_names.len > 0) font.loadFonts(font_names) catch return null;
    const asc, const desc = font.getMetrics();
    return .{ .ascent = asc, .descent = desc };
}

/// Builds size-suffixed copies of the configured font list. Borrowed entries keep the
/// config string's pointer, which freeSizedFontList uses to free only owned copies.
pub fn buildSizedFontList(allocator: std.mem.Allocator, size_override: ?u16) ![][]const u8 {
    const cs = core.getState();
    const font_size: u16 = size_override orelse cs.config.bar.scaled_font_size;
    const fonts = cs.config.bar.fonts.items;
    const sized = try allocator.alloc([]const u8, fonts.len);
    errdefer allocator.free(sized);
    for (fonts, sized) |f, *out| {
        out.* = if (font_size > 0)
            try std.fmt.allocPrint(allocator, "{s}:size={}", .{ f, font_size })
        else
            f;
    }
    return sized;
}

/// Frees a list returned by buildSizedFontList, skipping entries borrowed from the live config.
pub fn freeSizedFontList(allocator: std.mem.Allocator, sized: [][]const u8) void {
    const fonts = core.getState().config.bar.fonts.items;
    for (sized, fonts) |s, orig| {
        if (s.ptr != orig.ptr) allocator.free(s);
    }
    allocator.free(sized);
}

/// Loads the configured fonts into `dc`. Called once per DrawContext creation.
pub fn loadBarFonts(dc: *DrawContext, size_override: ?u16) !void {
    const cs = core.getState();
    const sized = try buildSizedFontList(cs.alloc, size_override);
    defer freeSizedFontList(cs.alloc, sized);
    if (sized.len == 0) return; // keep Pango default, matching probeFontMetrics
    try dc.font.loadFonts(sized);
    if (sized.len > 1) debug.info("Loaded {} fonts with fallback support", .{sized.len});
}

fn createPangoLayout(ctx: *c.cairo_t, dpi: f32) !*c.PangoLayout {
    const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dpi));
    return layout;
}

/// Returns the visual matching `visual_id` across all screens, or falls back
/// to a visual matching `depth` on `screen`. Errors if no visuals exist.
fn resolveVisualType(
    conn: core.Connection,
    screen: core.Screen,
    visual_id: ?u32,
    depth: u8,
) !*core.xcb.xcb_visualtype_t {
    if (visual_id) |vid| {
        // Scan all screens/depths for the requested visual_id.
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
    // Fallback: return a visual matching the PIXMAP depth to avoid BadMatch
    // when the surface pairs visual+drawable at different depths.
    return firstVisualOfDepth(screen, depth) orelse error.NoVisuals;
}

/// Converts Xft `"FontName:size=N:weight=bold"` to Pango `"FontName Bold N"` format.
fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, xft_name, ':') == null)
        return allocator.dupe(u8, xft_name);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var parts = std.mem.splitScalar(u8, xft_name, ':');
    try result.appendSlice(allocator, parts.first());

    var size: ?[]const u8 = null;
    var weight: ?[]const u8 = null;
    var slant: ?[]const u8 = null;

    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "size="))
            size = part["size=".len..]
        else if (std.mem.startsWith(u8, part, "pixelsize="))
            size = part["pixelsize=".len..]
        else if (std.mem.startsWith(u8, part, "weight="))
            weight = part["weight=".len..]
        else if (std.mem.startsWith(u8, part, "slant="))
            slant = part["slant=".len..];
    }

    const slant_token: []const u8 = if (slant) |s|
        if (std.mem.eql(u8, s, "italic") or std.mem.eql(u8, s, "oblique")) "Italic" else ""
    else
        "";
    const weight_token: []const u8 = if (weight) |w|
        if (std.mem.eql(u8, w, "bold")) "Bold" else if (std.mem.eql(u8, w, "light")) "Light" else ""
    else
        "";
    inline for (&[_][]const u8{ slant_token, weight_token }) |token| {
        if (token.len > 0) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, token);
        }
    }
    if (size) |s| {
        try result.append(allocator, ' ');
        try result.appendSlice(allocator, s);
    }

    return result.toOwnedSlice(allocator);
}
