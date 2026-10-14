//! Pango font book: the layout/description/metrics lifecycle for one draw
//! target (`FontBook`), the one-shot text run, the metric probe, the
//! sized-font list, and the Xft->Pango name conversion.
//!
//! Split OUT of `drawing.zig` in Phase 4 (step 24): font state has one
//! owner (`FontBook`, composed into `DrawContext` in `drawing.zig` beside
//! the surface from `surface.zig`), so the font lifecycle can change
//! without touching the painters.

const std = @import("std");
const log = @import("log");
const types = @import("types");
const bindings = @import("bindings");

/// Default point size for scaled metrics; also the size embedded in the
/// fallback font description below, so the last-resort font and the metric
/// probe always agree. It lives HERE (it was metrics.zig's) so this file
/// needs no metrics import: metrics.zig's live probe adapters import this
/// file, and the shared number must not force a fonts<->metrics cycle.
pub const default_scaled_font_size: u16 = 10;

/// Fallback Pango font description used when no configured font loads:
/// monospace at the default `default_scaled_font_size` point size.
pub const default_fallback_font: [:0]const u8 =
    std.fmt.comptimePrint("monospace:size={d}", .{default_scaled_font_size});

/// Pango font string used when no fonts are configured or a named font fails
/// to load; family/size come from the consts above.
const fallbackFont = default_fallback_font;

/// One piece of text together with the exact Pango state it will be measured
/// and painted with: its own layout, its own attribute list, and its own font
/// description.
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
/// A run that could not be built degrades to an empty run that measures
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

/// Owns all Pango font state for one draw target: the layout, the resolved
/// base font description, its cached metrics, and the size-suffixed description
/// the indicator-glyph path needs.
///
/// Extracted from `DrawContext` so the font lifecycle has one owner. The sized
/// description used to be keyed by POINTER IDENTITY against the base
/// description (`sized_font_base`), a key that only existed because a failed
/// reload could swap the base underneath a long-lived context. `loadFont` is
/// the only thing that swaps the base, so it invalidates the sized copy
/// directly and the cache key is just `sized_px` -- no pointer comparison.
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

    pub fn deinit(self: *FontBook) void {
        if (self.sized_desc) |d| bindings.pango_font_description_free(d);
        if (self.current_font_desc) |desc| bindings.pango_font_description_free(desc);
    }

    pub fn loadFonts(self: *FontBook, font_names: []const []const u8) !void {
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

    /// Measures `text` in its own run. The run's layout is discarded
    /// immediately, so this is a pure read of the font state with no lasting
    /// effect on any later measure or draw.
    pub fn measureTextWidth(self: *FontBook, text: []const u8) u16 {
        var run = self.beginRun(text, .{}, null);
        defer run.deinit();
        return run.measure();
    }

    /// Builds a run for `text` under `props` (and `sized_px` when non-null),
    /// with its own layout. Never returns an error: a failed run is an empty
    /// run, which measures 0 and paints nothing.
    pub fn beginRun(
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

    /// Builds a book around a fresh Pango layout on `ctx`. This is the
    /// ONLY place a layout is created: the live context and the probe both go
    /// through it, so a change to layout setup cannot reach one path and miss
    /// the other.
    pub fn initBook(allocator: std.mem.Allocator, ctx: *bindings.cairo_t, dpi: f32) !FontBook {
        return .{
            .allocator = allocator,
            .pango_layout = try createPangoLayout(ctx, dpi),
        };
    }

    /// Loads `font_names` into a throwaway detached book and returns its
    /// metrics. This is the single layout-bootstrap path: the probe and
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

// One-shot font metrics probing (used by the bar height / font-size calc).

/// Font metrics pair (ascent, descent) in pixels.
pub const FontMetrics = struct { ascent: i16, descent: i16 };

/// Loads `font_names` into a throwaway layout and returns its (ascent, descent)
/// in pixels. Delegates to the one font-bootstrap path in `FontBook`.
pub fn probeFontMetrics(
    allocator: std.mem.Allocator,
    dpi: f32,
    font_names: []const []const u8,
) ?FontMetrics {
    return FontBook.probe(allocator, dpi, font_names);
}

/// Owned, size-suffixed copies of the configured font list.
///
/// This is a VALUE that owns what it built. It used to be a bare
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
/// nothing in the signature mentioned -- `font_size` from
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

fn createPangoLayout(ctx: *bindings.cairo_t, dpi: f32) !*bindings.PangoLayout {
    const layout = bindings.pango_cairo_create_layout(ctx) orelse return error.PangoLayoutCreateFailed;
    bindings.pango_cairo_context_set_resolution(bindings.pango_layout_get_context(layout), @floatCast(dpi));
    return layout;
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
