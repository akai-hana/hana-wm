//! Cairo/Pango drawing context
//! Text measurement and rendering for bar segments.

const std = @import("std");

const core = @import("core");
const debug = @import("debug");

const c = @import("render");

/// Falls back to the root visual if no matching depth is found.
pub fn findVisualByDepth(screen: core.Screen, depth: u8) u32 {
    var di = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
        if (di.data.*.depth != depth) continue;
        const vi = core.xcb.xcb_depth_visuals_iterator(di.data);
        if (vi.rem == 0) continue;
        return vi.data.*.visual_id;
    }
    return screen.root_visual;
}

// Module-level font cache shared across all DrawContext instances (measurement + render DCs).
// Single-threaded; no synchronisation needed.

var font_conversion_cache: ?std.StringHashMap([]const u8) = null;

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

    pub fn loadFont(self: *FontState, font_name: []const u8) !void {
        if (self.current_font_desc) |desc| c.pango_font_description_free(desc);
        const pango_name_z = try self.allocator.dupeZ(u8, try convertFontName(self.allocator, font_name));
        defer self.allocator.free(pango_name_z);
        self.current_font_desc = c.pango_font_description_from_string(pango_name_z.ptr);
        if (self.current_font_desc == null) {
            debug.warn("Failed to load font '{s}', using default", .{font_name});
            self.current_font_desc = c.pango_font_description_from_string(fallbackFont);
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
            c.pango_layout_get_context(self.pango_layout),
            self.current_font_desc,
            null,
        );
        defer c.pango_font_metrics_unref(metrics);
        const ascent: i16 = @intCast(@divTrunc(c.pango_font_metrics_get_ascent(metrics), c.pango_scale));
        const descent: i16 = @intCast(@divTrunc(c.pango_font_metrics_get_descent(metrics), c.pango_scale));
        self.cached_metrics = .{ .ascent = ascent, .descent = descent };
        return .{ ascent, descent };
    }
};

/// Set the Cairo source color from a packed 0xRRGGBB u32 at full opacity.
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

/// Checks an XCB void-cookie; frees the error and returns GCCreationFailed on failure.
inline fn checkXcbCookie(conn: core.Connection, cookie: core.xcb.xcb_void_cookie_t) !void {
    if (core.xcb.xcb_request_check(conn, cookie)) |err| {
        std.c.free(err);
        return error.GCCreationFailed;
    }
}

inline fn createXcbPixmap(conn: core.Connection, depth: u8, drawable: u32, w: u16, h: u16) u32 {
    const pixmap = core.xcb.xcb_generate_id(conn);
    _ = core.xcb.xcb_create_pixmap(conn, depth, pixmap, drawable, w, h);
    return pixmap;
}

inline fn createCheckedGC(conn: core.Connection, drawable: u32) !u32 {
    const gc = core.xcb.xcb_generate_id(conn);
    const cookie = core.xcb.xcb_create_gc_checked(conn, gc, drawable, 0, null);
    try checkXcbCookie(conn, cookie);
    return gc;
}

/// Positions `layout` at `x` on `baseline` (accounting for the layout's own
/// baseline, font fallback can shift it per-run) and renders it.
inline fn showAtBaseline(ctx: *c.cairo_t, layout: *c.PangoLayout, x: u16, baseline: u16) void {
    c.cairo_move_to(ctx, @as(f64, @floatFromInt(x)), @as(f64, @floatFromInt(baseline)) - pangoToF64(c.pango_layout_get_baseline(layout)));
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
    /// Computed once at init so fillRect pays zero floating-point cost per call.
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

    /// Stored for legacy callers; no longer used by any drawing path.
    visual_type: ?*core.xcb.xcb_visualtype_t = null,
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

        const visual_type = try resolveVisualType(conn, screen, visual_id);

        const depth: u8 = if (is_argb) 32 else core.xcb.XCB_COPY_FROM_PARENT;

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
            .visual_type = visual_type,
            .depth = if (is_argb) 32 else screen.*.root_depth,
        };

        // Fire both GC-create requests before blocking on either reply so both
        // land in the same TCP segment.
        dc.gc = try createCheckedGC(conn, pixmap);
        dc.copy_gc = try createCheckedGC(conn, window);

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
        if (self.offscreen_pixmap != 0) _ = core.xcb.xcb_free_pixmap(self.conn, self.offscreen_pixmap);
        self.font.allocator.destroy(self);
    }

    inline fn setColor(self: *DrawContext, color: u32) void {
        if (self.last_color == color) return;
        setCairoColor(self.ctx, color);
        self.last_color = color;
    }

    pub inline fn withAlpha(self: *DrawContext, color: u32) u32 {
        if (!self.is_argb) return color;
        return (@as(u32, self.alpha_u8) << 24) | (color & 0x00FFFFFF);
    }

    inline fn setPangoText(self: *DrawContext, text: []const u8) void {
        c.pango_layout_set_text(self.font.pango_layout, text.ptr, @intCast(text.len));
    }

    /// Uses XCB rather than Cairo to write straight-alpha pixels (picom expects straight-alpha;
    /// Cairo's XRender backend writes premultiplied). `last_gc_color` skips xcb_change_gc
    /// when the color is unchanged, which is the common case for adjacent same-background segments.
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        const packed_color: u32 = self.withAlpha(color);
        if (self.last_gc_color != packed_color) {
            _ = core.xcb.xcb_change_gc(self.conn, self.gc, core.xcb.XCB_GC_FOREGROUND, &[_]u32{packed_color});
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
    pub fn drawTextSized(self: *DrawContext, x: u16, y_top: u16, text: []const u8, size_px: u16, color: u32) !void {
        const desc = self.font.current_font_desc orelse return error.NoFont;

        if (self.sized_font_desc == null or self.sized_font_px != size_px) {
            if (self.sized_font_desc) |old| c.pango_font_description_free(old);
            const temp = c.pango_font_description_copy(desc) orelse return error.PangoDescCopyFailed;
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
        c.cairo_move_to(self.ctx, @floatFromInt(x), @as(f64, @floatFromInt(y_top)) - pangoToF64(ink_rect.y));
        c.pango_cairo_show_layout(self.ctx, self.font.pango_layout);
    }

    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) !void {
        self.setColor(color);
        self.setPangoText(text);
        showAtBaseline(self.ctx, self.font.pango_layout, x, y);
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
        self.setPangoText(text);

        c.pango_layout_set_width(self.font.pango_layout, @as(i32, max_width) * c.pango_scale);
        c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.END);
        defer {
            c.pango_layout_set_width(self.font.pango_layout, -1);
            c.pango_layout_set_ellipsize(self.font.pango_layout, c.PangoEllipsizeMode.NONE);
        }

        self.setColor(color);
        showAtBaseline(self.ctx, self.font.pango_layout, x, y);
    }

    pub fn measureTextWidth(self: *DrawContext, text: []const u8) u16 {
        self.setPangoText(text);
        var width: c_int = undefined;
        c.pango_layout_get_pixel_size(self.font.pango_layout, &width, null);
        return @intCast(width);
    }

    inline fn xcbCopyArea(self: *DrawContext, src_x: u16, dst_x: u16, w: u16) void {
        _ = core.xcb.xcb_copy_area(self.conn, self.offscreen_pixmap, self.window, self.copy_gc, @intCast(src_x), 0, @intCast(dst_x), 0, w, self.height);
    }

    /// cairo_surface_flush only, no xcb_copy_area, no xcb_flush.
    /// Safe inside xcb_grab_server; pair with blitQueued() + ungrabAndFlush().
    pub fn renderOnly(self: *DrawContext) void {
        c.cairo_surface_flush(self.surface);
    }

    /// Enqueues xcb_copy_area without flushing; safe inside xcb_grab_server.
    /// The request is sent with all queued geometry changes when ungrabAndFlush() fires.
    pub fn blitQueued(self: *DrawContext) void {
        if (self.copy_gc != 0) self.xcbCopyArea(0, 0, self.width);
    }

    /// Does NOT call xcb_flush: the event loop's end-of-batch flush covers event-driven
    /// paths; timer-driven paths (clock tick, cursor blink) must flush explicitly.
    pub fn blit(self: *DrawContext) void {
        self.renderOnly();
        self.blitQueued();
    }

    /// Unlike blit(), calls xcb_flush immediately. Use on timer-driven paths where
    /// no event-loop flush is coming. Does NOT call cairo_surface_flush.
    pub fn blitAndFlush(self: *DrawContext, x: u16, w: u16) void {
        if (self.copy_gc != 0) {
            self.xcbCopyArea(x, x, w);
            _ = core.xcb.xcb_flush(self.conn);
        }
    }

    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.font.getMetrics();
        const top_pad: i32 = @max(0, @divTrunc(@as(i32, bar_height) - (asc + desc), 2));
        return @intCast(top_pad + asc);
    }

    /// Sets Pango text once for both measurement and render, avoiding a double pango_layout_set_text.
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
        self.setColor(fg);
        showAtBaseline(self.ctx, self.font.pango_layout, x + padding, self.baselineY(height));
        return x + width;
    }
};

// MeasureContext: lightweight font measurement backed by a 1x1 Cairo image surface.
// No XCB resources, no X round-trips. Same loadFont/loadFonts/getMetrics interface as DrawContext.

pub const MeasureContext = struct {
    font: FontState,
    surface: *c.cairo_surface_t,

    pub fn init(allocator: std.mem.Allocator, dpi: f32) !MeasureContext {
        const surface = c.cairo_image_surface_create(.ARGB32, 1, 1) orelse return error.CairoSurfaceCreateFailed;
        errdefer c.cairo_surface_destroy(surface);
        // The cairo context exists only to obtain the Pango layout, the
        // layout keeps its own PangoContext/font map; so it is created and
        // destroyed here rather than stored.
        const ctx = c.cairo_create(surface) orelse return error.CairoCreateFailed;
        defer c.cairo_destroy(ctx);
        const layout = try createPangoLayout(ctx, dpi);
        return .{ .font = .{ .allocator = allocator, .pango_layout = layout }, .surface = surface };
    }

    pub fn deinit(self: *MeasureContext) void {
        self.font.deinit();
        c.g_object_unref(self.font.pango_layout);
        c.cairo_surface_destroy(self.surface);
    }
};

fn createPangoLayout(ctx: *c.cairo_t, dpi: f32) !*c.PangoLayout {
    const layout = c.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    c.pango_cairo_context_set_resolution(c.pango_layout_get_context(layout), @floatCast(dpi));
    return layout;
}

fn findVisualById(conn: core.Connection, visual_id: u32) ?*core.xcb.xcb_visualtype_t {
    var si = core.xcb.xcb_setup_roots_iterator(core.xcb.xcb_get_setup(conn));
    while (si.rem > 0) : (core.xcb.xcb_screen_next(&si)) {
        var di = core.xcb.xcb_screen_allowed_depths_iterator(si.data);
        while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
            var vi = core.xcb.xcb_depth_visuals_iterator(di.data);
            while (vi.rem > 0) : (core.xcb.xcb_visualtype_next(&vi))
                if (vi.data.*.visual_id == visual_id) return vi.data;
        }
    }
    return null;
}

/// Returns the visual matching `visual_id` across all screens, or falls back to
/// the first visual on `screen`. Errors if the X server has no visuals at all.
fn resolveVisualType(
    conn: core.Connection,
    screen: core.Screen,
    visual_id: ?u32,
) !*core.xcb.xcb_visualtype_t {
    if (visual_id) |vid| {
        if (findVisualById(conn, vid)) |vt| return vt;
    }
    // Fall back to the first available visual on screen; error if there are none.
    var di = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
        const vi = core.xcb.xcb_depth_visuals_iterator(di.data);
        if (vi.rem > 0) return vi.data;
    }
    return error.NoVisuals;
}

/// Returns the value of a trailing `key=value` field inside an Xft font token,
/// or null when the token doesn't start with `key`.
inline fn styleField(part: []const u8, comptime key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, part, key)) return null;
    return part[key.len..];
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

    var size: ?[]const u8 = null;
    var weight: ?[]const u8 = null;
    var slant: ?[]const u8 = null;

    while (parts.next()) |part| {
        if (styleField(part, "size=")) |v| size = v
        else if (styleField(part, "pixelsize=")) |v| size = v
        else if (styleField(part, "weight=")) |v| weight = v
        else if (styleField(part, "slant=")) |v| slant = v;
    }

    if (slant) |s| {
        const is_italic = std.mem.eql(u8, s, "italic") or std.mem.eql(u8, s, "oblique");
        if (is_italic) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, "Italic");
        }
    }

    if (weight) |w| {
        const token = if (std.mem.eql(u8, w, "bold")) "Bold"
            else if (std.mem.eql(u8, w, "light")) "Light"
            else "";
        if (token.len > 0) {
            try result.append(allocator, ' ');
            try result.appendSlice(allocator, token);
        }
    }

    if (size) |s| {
        try result.append(allocator, ' ');
        try result.appendSlice(allocator, s);
    }

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
