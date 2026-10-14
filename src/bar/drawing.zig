//! Cairo/Pango drawing context
//! Text measurement and rendering for bar segments.

const std = @import("std");

const core = @import("core");
const log = @import("log");

const types = @import("types");
const bar_metrics = @import("metrics");
// Cairo/Pango/GLib C bindings, in their own leaf file on the
// core/x11/xcb.zig precedent (review 05-input round 2): drawing
// is a layer of logic over them, not a C-header translation.
const bindings = @import("bindings");

/// The clock's display format: the configured value, or the built-in default
/// when unset. Single accessor shared by the clock segment and the bar's
/// updateClock (each previously re-derived the same fallback).
pub fn clockFormat(config: types.BarConfig) []const u8 {
    return config.clock_format orelse types.default_clock_format;
}

// Cairo, Pango, and GLib C bindings for bar rendering live in
// bindings.zig (see the import above); every use below is
// qualified through it.

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

/// Pango font string used when no fonts are configured or a named font fails
/// to load; family/size come from the bar-owned metrics module.
const fallbackFont = bar_metrics.default_fallback_font;

/// Owns all Pango font state for one draw target: the layout, the resolved
/// base font description, its cached metrics, and the size-suffixed description
/// the indicator-glyph path needs. (22.6)
///
/// Extracted from `DrawContext` so the font lifecycle has one owner. The sized
/// description used to be keyed by POINTER IDENTITY against the base
/// description (`sized_font_base`), a key that only existed because a failed
/// reload could swap the base underneath a long-lived context. `loadFont` is
/// the only thing that swaps the base, so it invalidates the sized copy
/// directly and the cache key is just `sized_px` -- no pointer comparison.
/// One piece of text together with the exact Pango state it will be measured
/// and painted with: its own layout, its own attribute list, and its own font
/// description. (22.7)
///
/// Previously a single layout was shared by every measure and every draw, and
/// correctness depended on a caller pairing apply/restore correctly. Two
/// things went wrong with that. A measure is a SIDE EFFECT -- it sets the
/// shared layout's text -- so measuring a string and then painting something
/// else paints the measurement unless the text is reset. And the style
/// attributes had to be attached before a draw and detached after, so any
/// unbalanced apply left bold/italic/colour on the layout and silently changed
/// every LATER draw in the frame. Both were invisible in review because each
/// helper looked correct in isolation.
///
/// A run removes the shared mutable state instead of policing it. The run's
/// layout is private, so measuring it cannot disturb a draw, and its attributes
/// die with it rather than needing a restore. The draw helpers are infallible
/// (22.4): a run that could not be built degrades to an empty run that measures
/// zero and paints nothing, which is what a zero-length text draw would have
/// done anyway.
pub const TextRun = struct {
    /// Null exactly when the run could not be built; every method tolerates it.
    layout: ?*bindings.PangoLayout = null,
    /// The attribute list built for this run, owned by the run.
    attrs: ?*bindings.PangoAttrList = null,
    /// Size-suffixed description this run uses, borrowed from the FontBook.
    sized_font: ?*bindings.PangoFontDescription = null,

    /// Width in pixels of the run's text, 0 for an empty run.
    pub fn measure(self: *TextRun) u16 {
        const l = self.layout orelse return 0;
        var width: c_int = undefined;
        bindings.pango_layout_get_pixel_size(l, &width, null);
        const w: c_int = std.math.clamp(width, 0, @as(c_int, std.math.maxInt(u16)));
        return @intCast(w);
    }

    pub fn deinit(self: *TextRun) void {
        if (self.attrs) |a| {
            if (self.layout) |l| bindings.pango_layout_set_attributes(l, null);
            bindings.pango_attr_list_unref(a);
        }
        if (self.layout) |l| bindings.g_object_unref(l);
        self.* = undefined;
    }
};

pub const FontBook = struct {
    allocator: std.mem.Allocator,
    pango_layout: *bindings.PangoLayout,
    current_font_desc: ?*bindings.PangoFontDescription = null,
    /// Cached (ascent, descent) in pixels; invalidated by loadFont.
    cached_metrics: ?struct { i16, i16 } = null,
    /// Size-suffixed copy of `current_font_desc` for `drawTextSized`, rebuilt
    /// only when `sized_px` differs. Never outlives a base-description swap.
    sized_desc: ?*bindings.PangoFontDescription = null,
    sized_px: u16 = 0,
    /// The description the layout currently has set, so a sized draw can skip
    /// the set/restore pair when it is already the sized one.
    layout_font: ?*bindings.PangoFontDescription = null,

    fn deinit(self: *FontBook) void {
        if (self.sized_desc) |d| bindings.pango_font_description_free(d);
        if (self.current_font_desc) |desc| bindings.pango_font_description_free(desc);
    }

    fn loadFonts(self: *FontBook, font_names: []const []const u8) !void {
        if (font_names.len == 0) return self.loadFont(fallbackFont);
        const font_list = try std.mem.join(self.allocator, ",", font_names);
        defer self.allocator.free(font_list);
        try self.loadFont(font_list);
    }

    fn loadFont(self: *FontBook, font_name: []const u8) !void {
        const pango_name_z = try convertFontName(self.allocator, font_name);
        defer self.allocator.free(pango_name_z);
        const new_desc = bindings.pango_font_description_from_string(pango_name_z.ptr);
        var desc = new_desc;
        if (desc == null) {
            log.warn("Failed to load font '{s}', using default", .{font_name});
            desc = bindings.pango_font_description_from_string(fallbackFont);
        }
        // Install the new description only after it exists, so a failed
        // conversion cannot leave `current_font_desc` dangling. Free the old
        // one after the new one is in hand.
        if (self.current_font_desc) |old| bindings.pango_font_description_free(old);
        self.current_font_desc = desc;
        bindings.pango_layout_set_font_description(self.pango_layout, self.current_font_desc);
        self.layout_font = self.current_font_desc;
        self.cached_metrics = null;
        self.invalidateSized();
    }

    /// Drops the size-suffixed copy after a base-description swap. The layout
    /// may still reference the freed sized description, so re-seat it on the
    /// base; the next sized draw sets its own before painting.
    fn invalidateSized(self: *FontBook) void {
        if (self.sized_desc) |d| bindings.pango_font_description_free(d);
        self.sized_desc = null;
        self.sized_px = 0;
        if (self.layout_font != self.current_font_desc) {
            bindings.pango_layout_set_font_description(self.pango_layout, self.current_font_desc);
            self.layout_font = self.current_font_desc;
        }
    }

    /// The base description scaled to `size_px`, cached by size alone. The only
    /// failure is having no base description to copy.
    fn sizedDesc(self: *FontBook, size_px: u16) !*bindings.PangoFontDescription {
        const desc = self.current_font_desc orelse return error.NoFont;
        if (self.sized_desc == null or self.sized_px != size_px) {
            // Copy FIRST, then free the old descriptor: freeing before the copy
            // leaves a dangling `sized_desc` if the copy fails.
            const temp = bindings.pango_font_description_copy(desc) orelse
                return error.PangoDescCopyFailed;
            if (self.sized_desc) |old| bindings.pango_font_description_free(old);
            bindings.pango_font_description_set_absolute_size(temp, pxToPango(size_px));
            self.sized_desc = temp;
            self.sized_px = size_px;
        }
        return self.sized_desc.?;
    }

    /// Returns (ascent, descent) in pixels; cached per font description,
    /// invalidated by loadFont.
    pub fn getMetrics(self: *FontBook) struct { i16, i16 } {
        if (self.cached_metrics) |m| return m;
        const metrics = bindings.pango_context_get_metrics(
            bindings.pango_layout_get_context(self.pango_layout),
            self.current_font_desc,
            null,
        );
        defer bindings.pango_font_metrics_unref(metrics);
        const ascent = pangoPxToI16(bindings.pango_font_metrics_get_ascent(metrics));
        const descent = pangoPxToI16(bindings.pango_font_metrics_get_descent(metrics));
        self.cached_metrics = .{ ascent, descent };
        return .{ ascent, descent };
    }

    /// Measures `text` in its own run. (22.7) The run's layout is discarded
    /// immediately, so this is a pure read of the font state with no lasting
    /// effect on any later measure or draw.
    fn measureTextWidth(self: *FontBook, text: []const u8) u16 {
        var run = self.beginRun(text, .{}, null);
        defer run.deinit();
        return run.measure();
    }

    /// Builds a run for `text` under `props` (and `sized_px` when non-null),
    /// with its own layout. Never returns an error: a failed run is an empty
    /// run, which measures 0 and paints nothing. (22.7)
    fn beginRun(
        self: *FontBook,
        text: []const u8,
        props: types.SegmentProps,
        sized_px: ?u16,
    ) TextRun {
        const l = bindings.pango_layout_new(bindings.pango_layout_get_context(self.pango_layout)) orelse
            return .{};
        var run = TextRun{ .layout = l };
        // Sized runs need a base description to copy. Unsized runs fall back to
        // Pango's default when none is loaded, which is what a shared layout
        // with no font set would have used.
        if (sized_px) |px| {
            const sized = self.sizedDesc(px) catch {
                run.deinit();
                return .{};
            };
            run.sized_font = sized;
            bindings.pango_layout_set_font_description(l, sized);
        } else if (self.current_font_desc) |d| {
            bindings.pango_layout_set_font_description(l, d);
        }
        run.attrs = buildStyleAttrs(props);
        if (run.attrs) |a| bindings.pango_layout_set_attributes(l, a);
        bindings.pango_layout_set_text(l, text.ptr, @intCast(text.len));
        return run;
    }

    /// Builds a book around a fresh Pango layout on `ctx`. (22.6) This is the
    /// ONLY place a layout is created: the live context and the probe both go
    /// through it, so a change to layout setup cannot reach one path and miss
    /// the other.
    fn initBook(allocator: std.mem.Allocator, ctx: *bindings.cairo_t, dpi: f32) !FontBook {
        return .{
            .allocator = allocator,
            .pango_layout = try createPangoLayout(ctx, dpi),
        };
    }

    /// Loads `font_names` into a throwaway detached book and returns its
    /// metrics. (22.6) This is the single layout-bootstrap path: the probe and
    /// the live context now share this construction instead of each building a
    /// surface/context/layout of its own.
    pub fn probe(
        allocator: std.mem.Allocator,
        dpi: f32,
        font_names: []const []const u8,
    ) ?FontMetrics {
        const surface = bindings.cairo_image_surface_create(.ARGB32, 1, 1) orelse return null;
        defer bindings.cairo_surface_destroy(surface);
        // The cairo context exists only to obtain the Pango layout.
        const ctx = bindings.cairo_create(surface) orelse return null;
        defer bindings.cairo_destroy(ctx);
        var book = initBook(allocator, ctx, dpi) catch return null;
        defer bindings.g_object_unref(book.pango_layout);
        defer book.deinit();
        if (font_names.len > 0) book.loadFonts(font_names) catch return null;
        const asc, const desc = book.getMetrics();
        return .{ .ascent = asc, .descent = desc };
    }
};

/// Owns the off-screen X drawable and the XCB/cairo machinery that writes to
/// it. (22.6) Extracted from `DrawContext` so the display resources and the
/// font resources have independent owners; `DrawContext` is the facade that
/// composes them.
pub const Surface = struct {
    conn: core.Connection,
    /// The real X window, only used as the copy destination in `blit`.
    window: u32,
    /// Off-screen pixmap; all drawing targets this.
    pixmap: u32,
    width: u16,
    height: u16,
    cairo_surface: *bindings.cairo_surface_t,
    ctx: *bindings.cairo_t,
    /// GC used by `fillRect` (xcb_poly_fill_rectangle).
    gc: u32,
    /// Separate GC used exclusively for the xcb_copy_area blit.
    copy_gc: u32,
    is_argb: bool = false,
    /// Pre-computed alpha byte for XCB pixel packing.
    alpha_u8: u8 = 0xFF,
    last_color: ?u32 = null,
    /// Cached GC foreground: skips xcb_change_gc when the packed pixel is unchanged.
    last_gc_color: ?u32 = null,
    /// True once this frame has issued its first XCB fill (22.5).
    xcb_filled_this_frame: bool = false,

    fn init(
        conn: core.Connection,
        window: u32,
        width: u16,
        height: u16,
        visual_id: ?u32,
        is_argb: bool,
        transparency: f32,
    ) !Surface {
        const setup = core.xcb.xcb_get_setup(conn);
        const screen = core.xcb.xcb_setup_roots_iterator(setup).data;

        // CreatePixmap requires a concrete depth: XCB_COPY_FROM_PARENT (0) is
        // only valid for CreateWindow and fails here with BadValue, which
        // silently killed opaque-bar init (default transparency = 1.0).
        const depth: u8 = if (is_argb) 32 else screen.*.root_depth;
        const visual_type = try resolveVisualType(conn, screen, visual_id, depth);

        const pixmap = createXcbPixmap(conn, depth, window, width, height);
        errdefer _ = core.xcb.xcb_free_pixmap(conn, pixmap);

        const cairo_surface = bindings.cairo_xcb_surface_create(
            conn,
            pixmap,
            visual_type,
            @intCast(width),
            @intCast(height),
        ) orelse return error.CairoSurfaceCreateFailed;
        errdefer bindings.cairo_surface_destroy(cairo_surface);

        const ctx = bindings.cairo_create(cairo_surface) orelse return error.CairoCreateFailed;
        errdefer bindings.cairo_destroy(ctx);

        // Fire both GC-create requests before blocking on either reply so both
        // land in the same TCP segment. The errdefers free both on any failure
        // after they exist; deinit owns them once init returns.
        const gc = core.xcb.xcb_generate_id(conn);
        errdefer _ = core.xcb.xcb_free_gc(conn, gc);
        const copy_gc = core.xcb.xcb_generate_id(conn);
        errdefer _ = core.xcb.xcb_free_gc(conn, copy_gc);
        const gc_cookie = core.xcb.xcb_create_gc_checked(conn, gc, pixmap, 0, null);
        const copy_gc_cookie = core.xcb.xcb_create_gc_checked(conn, copy_gc, window, 0, null);
        if (core.xcb.xcb_request_check(conn, gc_cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }
        if (core.xcb.xcb_request_check(conn, copy_gc_cookie)) |err| {
            std.c.free(err);
            return error.GCCreationFailed;
        }

        return .{
            .conn = conn,
            .window = window,
            .pixmap = pixmap,
            .width = width,
            .height = height,
            .cairo_surface = cairo_surface,
            .ctx = ctx,
            .gc = gc,
            .copy_gc = copy_gc,
            .is_argb = is_argb,
            .alpha_u8 = if (is_argb)
                @intFromFloat(@round(std.math.clamp(transparency, 0.0, 1.0) * 255.0))
            else
                0xFF,
        };
    }

    fn deinit(self: *Surface) void {
        if (self.gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        if (self.copy_gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.copy_gc);
        bindings.cairo_destroy(self.ctx);
        // Destroy surface before pixmap: Cairo holds a reference to the pixmap.
        bindings.cairo_surface_destroy(self.cairo_surface);
        if (self.pixmap != 0) _ = core.xcb.xcb_free_pixmap(self.conn, self.pixmap);
    }

    inline fn setColor(self: *Surface, color: u32) void {
        if (self.last_color == color) return;
        setCairoColor(self.ctx, color);
        self.last_color = color;
    }

    /// Uses XCB rather than Cairo to write straight-alpha pixels (picom expects
    /// straight-alpha; Cairo's XRender backend writes premultiplied).
    /// `last_gc_color` skips xcb_change_gc when the color is unchanged, which is
    /// the common case for adjacent same-background segments.
    ///
    /// ## Paint-order rule (22.5): XCB fills are ordered BEFORE every cairo
    /// glyph of the frame
    ///
    /// `cairo_surface` is an xcb surface backed by `pixmap` -- the very pixmap
    /// this writes -- so the two paths meet in one place but do not arrive there
    /// together. Glyphs go through cairo and are buffered until something
    /// flushes them; this method's `xcb_poly_fill_rectangle` is put on the wire
    /// immediately. The frame's blit flushes cairo at the end, so the order the
    /// server sees is: every fill of the frame, then every glyph of the frame --
    /// regardless of the order the modules called them in. That is what makes
    /// `fillRect` usable as a BACKGROUND: the segment fills first and the label
    /// lands on top of it.
    ///
    /// The rule is enforced at the top: the first XCB write of a frame
    /// quiesces cairo first, so no cairo operation can be left pending across
    /// the boundary where the two orderings diverge.
    pub fn fillRect(self: *Surface, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        if (!self.xcb_filled_this_frame) {
            // Quiesce before the first wire write of the frame (22.5).
            bindings.cairo_surface_flush(self.cairo_surface);
            self.xcb_filled_this_frame = true;
        }
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
        _ = core.xcb.xcb_poly_fill_rectangle(self.conn, self.pixmap, self.gc, 1, &rect);
    }

    /// Shared blit body: bindings.cairo_surface_flush + xcb_copy_area of [x, x+w),
    /// plus an immediate xcb_flush only for `blitRegion`. `queueBlit` must NOT
    /// flush here: it is safe inside xcb_grab_server precisely because the copy
    /// is sent with the caller's batch end.
    inline fn blitImpl(self: *Surface, x: u16, w: u16, comptime flush: bool) void {
        // The frame's glyphs go on the wire here, which is what puts them after
        // this frame's fills (22.5). Re-arms the one-shot quiesce for the next
        // frame.
        bindings.cairo_surface_flush(self.cairo_surface);
        self.xcb_filled_this_frame = false;
        if (self.copy_gc == 0) return;
        _ = core.xcb.xcb_copy_area(
            self.conn,
            self.pixmap,
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
};

inline fn setCairoColor(ctx: *bindings.cairo_t, color: u32) void {
    const r = @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g = @as(f64, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b = @as(f64, @floatFromInt(color & 0xFF)) / 255.0;
    bindings.cairo_set_source_rgba(ctx, r, g, b, 1.0);
}

inline fn pangoToF64(pango_units: c_int) f64 {
    return @as(f64, @floatFromInt(pango_units)) / bindings.pango_scale;
}

inline fn pangoPxToI16(val: c_int) i16 {
    return @intCast(std.math.clamp(
        @divTrunc(val, bindings.pango_scale),
        std.math.minInt(i16),
        std.math.maxInt(i16),
    ));
}

inline fn pxToPango(px: u16) f64 {
    return @as(f64, @floatFromInt(px)) * bindings.pango_scale;
}

inline fn createXcbPixmap(conn: core.Connection, depth: u8, drawable: u32, w: u16, h: u16) u32 {
    const pixmap = core.xcb.xcb_generate_id(conn);
    _ = core.xcb.xcb_create_pixmap(conn, depth, pixmap, drawable, w, h);
    return pixmap;
}

inline fn showLayoutAtBaseline(
    ctx: *bindings.cairo_t,
    layout: *bindings.PangoLayout,
    x: f64,
    baseline: u16,
) void {
    const baseline_f: f64 = @floatFromInt(baseline);
    bindings.cairo_move_to(ctx, x, baseline_f - pangoToF64(bindings.pango_layout_get_baseline(layout)));
    bindings.pango_cairo_show_layout(ctx, layout);
}

/// The validated span `[start, start + len)` inside `text`, or null when the
/// span is not a legal non-empty range of it. (22.1/25.3)
///
/// The span arrives as EXPLICIT OFFSETS from the caller. It used to arrive as a
/// subslice, whose position the painter recovered by subtracting raw addresses
/// (`@intFromPtr(v.ptr) - @intFromPtr(text.ptr)`) and whose validity was checked
/// by comparing raw pointers -- see 25.3. A module that knows where its number
/// sits now says so, and this only has to range-check it, which is pure and
/// testable without Pango, cairo or a display.
pub const ValueRange = struct { start: usize, len: usize };

pub fn valueRange(text: []const u8, start: usize, len: usize) ?ValueRange {
    // An empty span would colour nothing, so it collapses to the single-colour
    // path. A span covering the WHOLE string is legal now and was not before:
    // a value-only format (a slider whose display is just "{pct}") legitimately
    // wants its number tinted. Under the old subslice API that case was
    // indistinguishable from a caller handing over the whole text by accident,
    // so it was rejected; with explicit offsets the caller is stating intent.
    if (len == 0) return null;
    // These two bounds are each independently necessary, not redundant with
    // the `start + len` test below: a caller-supplied offset can be near
    // usize max, and in ReleaseFast `start + len` WRAPS rather than trapping.
    // A start of maxInt - 1 with len 2 would wrap to 0, pass the sum check, and
    // hand the painter a slice far outside the text. Each guard rejects the
    // input before the addition can wrap.
    if (len > text.len) return null;
    if (start >= text.len) return null;
    if (start + len > text.len) return null;
    return .{ .start = start, .len = len };
}

/// A foreground colour applied to the byte range `[start, start + len)` of the
/// laid-out text. (22.1)
///
/// The one primitive the two-tone segment path needs. Pango interprets
/// attribute offsets in BYTES, and it attributes by glyph run internally, so a
/// byte range that splits a multi-byte character is not a caller error we can
/// detect cheaply -- it degrades to whatever glyphs intersect the range. Every
/// in-tree caller passes an ASCII numeral range, which is exact.
fn foregroundAttr(list: *bindings.PangoAttrList, start: usize, len: usize, rgb: u32) void {
    // hana stores 0xRRGGBB; Pango wants each channel scaled to 0..65535.
    const scale8to16 = struct {
        fn f(c: u32) u16 {
            return @intCast((c * 0xFFFF) / 0xFF);
        }
    }.f;
    const attr = bindings.pango_attr_foreground_new(
        scale8to16((rgb >> 16) & 0xFF),
        scale8to16((rgb >> 8) & 0xFF),
        scale8to16(rgb & 0xFF),
    ) orelse return;
    attr.start_index = @intCast(start);
    attr.end_index = @intCast(start + len);
    bindings.pango_attr_list_insert(list, attr);
}

/// Builds a one-shot attribute list encoding the non-default flags of `props`
/// (underline, bold, italic), or null when no flags are set. The caller owns
/// the returned list and must unref it (bindings.pango_attr_list_unref) once detached
/// from the layout.
fn buildStyleAttrs(props: types.SegmentProps) ?*bindings.PangoAttrList {
    if (props.isDefault()) return null;
    const list = bindings.pango_attr_list_new() orelse return null;
    // On a partial attribute-creation failure, unref the list (which frees
    // any attrs already inserted) and degrade to unstyled drawing.
    if (props.underline) {
        const attr = bindings.pango_attr_underline_new(.SINGLE) orelse {
            bindings.pango_attr_list_unref(list);
            return null;
        };
        bindings.pango_attr_list_insert(list, attr);
    }
    if (props.bold) {
        const attr = bindings.pango_attr_weight_new(.BOLD) orelse {
            bindings.pango_attr_list_unref(list);
            return null;
        };
        bindings.pango_attr_list_insert(list, attr);
    }
    if (props.italic) {
        const attr = bindings.pango_attr_style_new(.ITALIC) orelse {
            bindings.pango_attr_list_unref(list);
            return null;
        };
        bindings.pango_attr_list_insert(list, attr);
    }
    return list;
}

pub const DrawContext = struct {
    /// Pango font state: layout, descriptions, metrics, sized-font cache.
    fonts: FontBook,
    /// Off-screen X drawable and the XCB/cairo machinery that writes to it.
    surface: Surface,
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
        var surface = try Surface.init(conn, window, width, height, visual_id, is_argb, transparency);
        errdefer surface.deinit();

        const books = try FontBook.initBook(allocator, surface.ctx, dpi);
        errdefer bindings.g_object_unref(books.pango_layout);

        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);
        dc.* = .{ .surface = surface, .fonts = books };
        return dc;
    }

    pub fn deinit(self: *DrawContext) void {
        self.fonts.deinit();
        bindings.g_object_unref(self.fonts.pango_layout);
        self.surface.deinit();
        self.fonts.allocator.destroy(self);
    }

    /// Colors the context and paints `run` with its left edge at `x` and its
    /// baseline at `y`. An empty run paints nothing. (22.7)
    inline fn paintRun(self: *DrawContext, run: *TextRun, x: u16, y: u16, color: u32) void {
        const l = run.layout orelse return;
        self.surface.setColor(color);
        showLayoutAtBaseline(self.surface.ctx, l, @floatFromInt(x), y);
    }

    /// Draws `text` with its TOP at `y_top`, in a size-suffixed font. (22.6/22.7)
    /// The sized description and its caching live on `FontBook`; the run is
    /// this text's own layout, so the set/restore pairing is gone.
    pub fn drawTextSized(
        self: *DrawContext,
        x: u16,
        y_top: u16,
        text: []const u8,
        size_px: u16,
        color: u32,
    ) !void {
        // Still the one genuinely fallible text path (22.4): resolving the
        // size-suffixed description can fail with no base description to copy.
        var run = self.fonts.beginRun(text, .{}, size_px);
        defer run.deinit();
        const l = run.layout orelse return error.NoFont;

        var ink_rect: bindings.PangoRectangle = undefined;
        bindings.pango_layout_get_extents(l, &ink_rect, null);

        self.surface.setColor(color);
        bindings.cairo_move_to(
            self.surface.ctx,
            @floatFromInt(x),
            @as(f64, @floatFromInt(y_top)) - pangoToF64(ink_rect.y),
        );
        bindings.pango_cairo_show_layout(self.surface.ctx, l);
    }

    /// Draws `text` with its left edge at `x` and baseline at `y`.
    /// Infallible (22.4): a run that cannot be built degrades to an empty run
    /// that measures 0 and paints nothing, so this path has no `error` for
    /// callers to handle. The `!void` this used to declare had an EMPTY error
    /// set, so it was not a contract, just a `try` that callers had to write and
    /// an `error` they had to catch. The one genuinely fallible text path is
    /// `drawTextSized`, which resolves a font
    /// description and can really return `error.NoFont`; that one stays `!`.
    pub fn drawText(self: *DrawContext, x: u16, y: u16, text: []const u8, color: u32) void {
        self.drawTextImpl(x, y, text, null, color, .{});
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
    ) void {
        // One run, painted at both positions: the two copies must be the same
        // text in the same state, and a shared mutable layout was the only
        // thing making that true before. (22.7)
        var run = self.fonts.beginRun(text, .{}, null);
        defer run.deinit();
        const l = run.layout orelse return;
        self.surface.setColor(color);
        bindings.cairo_save(self.surface.ctx);
        defer bindings.cairo_restore(self.surface.ctx);
        bindings.cairo_rectangle(
            self.surface.ctx,
            @floatFromInt(clip_x),
            0,
            @floatFromInt(clip_w),
            @floatFromInt(self.surface.height),
        );
        bindings.cairo_clip(self.surface.ctx);
        for (x_positions) |x| showLayoutAtBaseline(self.surface.ctx, l, x, y);
    }

    /// Draws `text` ellipsized to `max_width` at (x, y); the text run is
    /// one-shot, so no Pango state survives the call.
    pub fn drawTextEllipsis(
        self: *DrawContext,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: u16,
        color: u32,
    ) void {
        self.drawTextImpl(x, y, text, max_width, color, .{});
    }

    /// Shared text rendering: build a run for `text` under `props`, optionally
    /// ellipsize it to `max_width`, and paint at baseline. (22.7) Every draw
    /// now goes through a private run, so there is no layout state left behind
    /// for the next draw to inherit.
    inline fn drawTextImpl(
        self: *DrawContext,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: ?u16,
        color: u32,
        props: types.SegmentProps,
    ) void {
        var run = self.fonts.beginRun(text, props, null);
        defer run.deinit();
        if (max_width) |w| {
            if (run.layout) |l| {
                bindings.pango_layout_set_width(l, @as(i32, w) * bindings.pango_scale);
                bindings.pango_layout_set_ellipsize(l, bindings.PangoEllipsizeMode.END);
            }
        }
        self.paintRun(&run, x, y, color);
    }

    /// Like `drawText`, but `text` is drawn with `props`' Pango styling.
    pub fn drawTextStyled(
        self: *DrawContext,
        x: u16,
        y: u16,
        text: []const u8,
        color: u32,
        props: types.SegmentProps,
    ) void {
        self.drawTextImpl(x, y, text, null, color, props);
    }

    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.fonts.getMetrics();
        const top_pad: i32 = @max(0, @divTrunc(@as(i32, bar_height) - (asc + desc), 2));
        return @intCast(top_pad + asc);
    }

    /// Fill background, measure `text` (with `props` styling applied so
    /// bold/italic reserve the right slot), draw text at baseline, return
    /// x + width. Pass `min_w` to force the background to span at least that
    /// many text pixels (plus padding) so a region-scoped repaint of a
    /// shrunken segment still wipes its whole previous slot.
    fn paintedSegment(
        self: *DrawContext,
        x: u16,
        height: u16,
        text: []const u8,
        padding: u16,
        bg: u32,
        fg: u32,
        min_w: ?u16,
        props: types.SegmentProps,
    ) !u16 {
        // One run measured AND painted. (22.7) These used to be two separate
        // operations on a shared layout, which is precisely how a styled
        // segment could reserve one width and paint another: the second
        // operation re-derived the styling instead of reusing the first.
        var run = self.fonts.beginRun(text, props, null);
        defer run.deinit();
        const text_w = run.measure();
        const width: u16 = (if (min_w) |m| @max(text_w, m) else text_w) + padding * 2;
        self.fillRect(x, 0, width, height, bg);
        self.paintRun(&run, x + padding, self.baselineY(height), fg);
        return x + width;
    }

    /// (22.6) Facade forwarder; the implementation AND the paint-order rule
    /// (22.5) now live on `Surface.fillRect`.
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        self.surface.fillRect(x, y, width, height, color);
    }

    /// (22.6) Facade forwarder to `FontBook.measureTextWidth`.
    pub fn measureTextWidth(self: *DrawContext, text: []const u8) u16 {
        return self.fonts.measureTextWidth(text);
    }

    /// Measures `text` with `props` styling applied, so a styled draw reserves
    /// exactly the width it will paint. (22.7)
    pub fn measureTextWidthStyled(self: *DrawContext, text: []const u8, props: types.SegmentProps) u16 {
        var run = self.fonts.beginRun(text, props, null);
        defer run.deinit();
        return run.measure();
    }

    /// (22.6) Facade metrics accessor, replacing direct `dc.font.getMetrics()`
    /// access from modules (prompt.zig).
    pub fn metrics(self: *DrawContext) struct { i16, i16 } {
        return self.fonts.getMetrics();
    }

    /// Region xcb_copy_area enqueued but not flushed. Safe inside
    /// xcb_grab_server; flushed by ungrabAndFlush() or the event-loop's xcb_flush.
    pub fn queueBlit(self: *DrawContext, x: u16, w: u16) void {
        if (w == 0) return;
        self.surface.blitImpl(x, w, false);
    }

    /// Region copy with immediate xcb_flush. Used on timer-driven paths
    /// (clock tick, prompt caret blink).
    pub fn blitRegion(self: *DrawContext, x: u16, w: u16) void {
        self.surface.blitImpl(x, w, true);
    }
};

/// Draws `text` at `x` using the config's scaled segment padding and bar
/// colors (a `[bar.properties]` override for segment `segment_name` when set,
/// bar `fg` otherwise), optionally with `props`' Pango styling. When
/// `cover_text` is set, the background fill always spans at least its measured
/// width plus padding: the clock uses this so a region-scoped repaint of a
/// NARROWER display mode repaints the whole reserved slot instead of leaving
/// stale pixels from the previous wider frame. Collapses the otherwise
/// repeated drawSegment argument list of the icon-ish segment modules (layout,
/// variants, clock).
pub fn drawPaddedSegment(
    dc: *DrawContext,
    config: types.BarConfig,
    height: u16,
    x: u16,
    segment_name: []const u8,
    text: []const u8,
    cover_text: ?[]const u8,
    props: types.SegmentProps,
) !u16 {
    const padding = config.scaledSegmentPadding(height);
    return dc.paintedSegment(
        x,
        height,
        text,
        padding,
        config.bg,
        config.segmentFg(segment_name),
        if (cover_text) |ct| dc.measureTextWidthStyled(ct, props) else null,
        props,
    );
}

/// Like `drawPaddedSegment`, but paints the byte span `[value_start,
/// value_start + value_len)` of `text` (the numeric readout, e.g. "42%") in the
/// segment's NUMBER color -- the
/// `[bar.properties] <segment>_value` override (`segmentValueFg`), falling
/// back to the segment foreground -- and everything else in the segment
/// foreground. Collapses into `drawPaddedSegment` behavior when `value` is
/// null or not a subslice of `text`. The width comes from the whole string,
/// exactly like `drawSegment`, so a segment's reserved slot never changes when
/// a value color is added.
pub fn drawPaddedSegmentValue(
    dc: *DrawContext,
    config: types.BarConfig,
    height: u16,
    x: u16,
    segment_name: []const u8,
    text: []const u8,
    value_start: usize,
    value_len: usize,
    props: types.SegmentProps,
) !u16 {
    const padding = config.scaledSegmentPadding(height);
    const range = valueRange(text, value_start, value_len);
    const fg = config.segmentFg(segment_name);
    const value_fg = config.segmentValueFg(segment_name);
    if (range == null)
        return dc.paintedSegment(x, height, text, padding, config.bg, fg, null, props);

    // (22.1) ONE Pango pass: measure the whole string, then paint it once with
    // a foreground attribute over the value's byte range.
    //
    // What this deletes, and why each part was load-bearing-bad rather than
    // merely verbose:
    //
    //   - The three-way re-shape. `text` was split into prefix/value/suffix and
    //     each part measured and drawn SEPARATELY, advancing a cursor by
    //     `measureTextWidth(part)`. Summing per-part measurements is not the
    //     same as measuring the whole string: shaping across a part boundary
    //     (kerning, ligatures) means the sum can differ from the true advance,
    //     so the cursor drifted away from where the glyphs actually went. The
    //     reserved width came from `measureTextWidth(text)` -- the whole string
    //     -- while the paint walked a different total. That measure/paint
    //     divergence is the bug; it was invisible whenever the segment text had
    //     no boundary-sensitive shaping, which is why it survived.
    //
    //   - The pointer-arithmetic subslice contract. `start` was computed as
    //     `@intFromPtr(v.ptr) - @intFromPtr(text.ptr)`, and validity was checked
    //     by comparing raw addresses. That encodes "the caller must hand me a
    //     subslice of this exact string" as a runtime-address property instead
    //     of a type, and it is what made the range unrepresentable as anything
    //     but a pointer delta.
    //
    // What it gains: Pango owns the range, so the value colour composes with
    // ellipsize and the style props (bold/italic/underline) for free instead of
    // being a separate draw that had to reproduce them. The style props are
    // applied to the SAME layout as the range, so the two can no longer
    // disagree about how the text is shaped.
    //
    // (22.7) The style props and the value's foreground go into the
    // run's OWN attribute list, on the run's OWN layout. Nothing is attached
    // to a shared layout and nothing has to be restored: the run's deinit
    // unrefs the list and the layout together, so a forgotten restore is no
    // longer representable.
    var run = dc.fonts.beginRun(text, props, null);
    defer run.deinit();
    if (run.layout) |l| {
        if (run.attrs) |a| {
            const r = range.?;
            foregroundAttr(a, r.start, r.len, value_fg);
        } else {
            // Default props built no list; make one so the range has a home.
            const fresh = bindings.pango_attr_list_new() orelse return x;
            foregroundAttr(fresh, range.?.start, range.?.len, value_fg);
            bindings.pango_layout_set_attributes(l, fresh);
            run.attrs = fresh;
        }
    }

    const width: u16 = run.measure() + padding * 2;
    dc.fillRect(x, 0, width, height, config.bg);
    // No ellipsize: an ellipsized layout would CUT the value range, and the
    // reserved width was measured from the untruncated string.
    dc.paintRun(&run, x + padding, dc.baselineY(height), fg);
    return x + width;
}

// One-shot font metrics probing (used by the bar height / font-size calc).

/// Font metrics pair (ascent, descent) in pixels.
pub const FontMetrics = struct { ascent: i16, descent: i16 };

/// Loads `font_names` into a throwaway layout and returns its (ascent, descent)
/// in pixels. (22.6) Delegates to the one font-bootstrap path in `FontBook`.
pub fn probeFontMetrics(
    allocator: std.mem.Allocator,
    dpi: f32,
    font_names: []const []const u8,
) ?FontMetrics {
    return FontBook.probe(allocator, dpi, font_names);
}

/// Owned, size-suffixed copies of the configured font list.
///
/// (22.3) This is a VALUE that owns what it built. It used to be a bare
/// `[][]const u8` plus a separate `freeSizedFontList`, and the free function
/// re-read `core.getState().config.bar.fonts.items` to work out which entries
/// it owned -- inferring ownership from POINTER IDENTITY against live config.
/// A config swap between build and free (a reload mid-frame is exactly that)
/// makes that inference wrong: a borrowed entry can be freed, and an owned one
/// leaked. It also silently zipped to the shorter of the two lists.
///
/// Every entry is now an owned copy, so deinit has nothing to infer. The extra
/// copies cost one small allocation per font on a path that runs once per
/// DrawContext creation, which is not a hot path.
///
/// `fonts` is the configured font family list, and `font_size` is
/// the point size to build at; both are REQUIRED rather than
/// optional: each used to be read out of process state that
/// nothing in the signature mentioned (21.5) -- `font_size` from
/// a module-level global the bar set during height resolution,
/// `fonts` from `core.getState()` right here. A caller measuring
/// a trial size passes the trial; a caller drawing the bar passes
/// the bar's resolved `Metrics` and the live config's font list.
pub const SizedFontList = struct {
    allocator: std.mem.Allocator,
    items: [][]const u8,

    pub fn build(allocator: std.mem.Allocator, fonts: []const []const u8, font_size: u16) !SizedFontList {
        const items = try allocator.alloc([]const u8, fonts.len);
        errdefer allocator.free(items);
        for (fonts, items) |f, *out| {
            // Even at font_size 0 this COPIES rather than borrowing: a
            // borrowed entry is exactly what made deinit unsafe to reason
            // about, and the string is handed straight to Pango which copies
            // it again anyway.
            out.* = if (font_size > 0)
                try std.fmt.allocPrint(allocator, "{s}:size={}", .{ f, font_size })
            else
                try allocator.dupe(u8, f);
        }
        return .{ .allocator = allocator, .items = items };
    }

    pub fn deinit(self: *SizedFontList) void {
        for (self.items) |s| self.allocator.free(s);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Loads the configured fonts into `dc`. Called once per DrawContext creation.
/// `allocator` and `fonts` are passed in rather than read out of
/// `core.getState()`: the caller that already holds cs does not want a hidden
/// second source of truth here (the SizedFontList doc above names exactly
/// that bug class for `freeSizedFontList`, and 21.5 fixed it for `build`).
pub fn loadBarFonts(dc: *DrawContext, allocator: std.mem.Allocator, fonts: []const []const u8, font_size: u16) !void {
    var sized = try SizedFontList.build(allocator, fonts, font_size);
    defer sized.deinit();
    if (sized.items.len == 0) return; // keep Pango default, matching probeFontMetrics
    try dc.fonts.loadFonts(sized.items);
    if (sized.items.len > 1) log.info("Loaded {} fonts with fallback support", .{sized.items.len});
}

fn createPangoLayout(ctx: *bindings.cairo_t, dpi: f32) !*bindings.PangoLayout {
    const layout = bindings.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    bindings.pango_cairo_context_set_resolution(bindings.pango_layout_get_context(layout), @floatCast(dpi));
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

/// Converts Xft `"FontName:size=N:weight=bold"` (or a comma-joined fallback
/// chain of those) to Pango `"FontName,OtherFont Bold N"` format. Comma-joined
/// families are kept as a Pango family list so multi-font configs get real
/// per-glyph fallback rather than first-family-only.
fn convertFontName(allocator: std.mem.Allocator, xft_name: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, xft_name, ':') == null and
        std.mem.indexOfScalar(u8, xft_name, ',') == null)
        return allocator.dupeZ(u8, xft_name);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var size: ?[]const u8 = null;
    var weight: ?[]const u8 = null;
    var slant: ?[]const u8 = null;

    var fonts = std.mem.splitScalar(u8, xft_name, ',');
    var first_family = true;
    while (fonts.next()) |font| {
        // Bound each family to its own Xft spec (`Family:size=..:weight=..`).
        // The font description is family-first, so emit families up front and
        // let the option tokens below trail the whole list.
        if (!first_family) try result.append(allocator, ',');
        first_family = false;

        var parts = std.mem.splitScalar(u8, font, ':');
        try result.appendSlice(allocator, parts.first());

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

    return result.toOwnedSliceSentinel(allocator, 0);
}
