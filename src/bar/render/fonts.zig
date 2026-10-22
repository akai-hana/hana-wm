//! Pango font book: the layout/description/metrics lifecycle for one draw
//! target (`FontBook`), the one-shot text run, the metric probe, the
//! sized-font list, and the Xft->Pango name conversion.

const std = @import("std");
const log = std.log.scoped(.fonts);
const types = @import("types");
const bar_config = @import("bar_config");
const bindings = @import("bindings");

/// Default point size for scaled metrics; also the size in the fallback
/// font description, so the last-resort font and the metric probe always
/// agree. Lives HERE so this file needs no metrics import (metrics.zig's
/// probe adapters import this file; the number must not force a cycle).
pub const default_scaled_font_size: u16 = 10;

/// Fallback Pango description when no configured font loads: monospace at
/// `default_scaled_font_size`.
pub const default_fallback_font: [:0]const u8 =
    std.fmt.comptimePrint("monospace:size={d}", .{default_scaled_font_size});

const fallbackFont = default_fallback_font;

/// One piece of text together with the exact Pango state it will be
/// measured and painted with: its own layout, attribute list, and font
/// description.
///
/// The point is that the state is NOT shared. A measure is a SIDE EFFECT --
/// it sets the layout's text -- so on one shared layout, measuring a string
/// and then painting something else paints the measurement unless the text
/// is reset; style attributes attached for one draw and not detached change
/// every LATER draw. A run's layout is private, and its attributes die with
/// it. Draw helpers are infallible: a failed run measures 0 and paints
/// nothing.
pub const TextRun = struct {
    /// Null exactly when the run could not be built; every method tolerates it.
    layout: ?*bindings.PangoLayout = null,
    attrs: ?*bindings.PangoAttrList = null,
    /// Size-suffixed description, borrowed from the FontBook.
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

/// Bound on the text-width cache: a full cache is cleared wholesale rather
/// than evicted entry-by-entry -- a measure is cheap to recompute.
const measure_cache_max: u32 = 512;

/// `sized_px` sentinel for "no size override" (the key carries the dimension
/// so a sized measure can join without colliding with an unsized one).
const no_sized_px: u16 = std.math.maxInt(u16);

/// Cache key: measured text content plus the style bits and size that derived
/// its width. Content-keyed, never pointer-keyed (a font swap would alias).
const MeasureKey = struct {
    /// Borrowed on lookup, owned by the map on insert (`MeasureEntry`).
    text: []const u8,
    props: u8,
    sized_px: u16,
};

/// Map payload: the width plus the owned text backing `MeasureKey.text`.
const MeasureEntry = struct {
    owned_text: []const u8,
    width: u16,
};

const MeasureContext = struct {
    pub fn hash(_: MeasureContext, k: MeasureKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.text);
        h.update(&[_]u8{k.props});
        h.update(std.mem.asBytes(&k.sized_px));
        return h.final();
    }
    pub fn eql(_: MeasureContext, a: MeasureKey, b: MeasureKey) bool {
        return a.props == b.props and a.sized_px == b.sized_px and
            std.mem.eql(u8, a.text, b.text);
    }
};

const MeasureCache = std.HashMapUnmanaged(MeasureKey, MeasureEntry, MeasureContext, 80);

/// Packs style flags into the cache key: underline | bold<<1 | italic<<2.
/// Two props that share bits measure to the same width.
fn propsBits(props: bar_config.SegmentProps) u8 {
    return @as(u8, @intFromBool(props.underline)) |
        (@as(u8, @intFromBool(props.bold)) << 1) |
        (@as(u8, @intFromBool(props.italic)) << 2);
}

/// Owns all Pango font state for one draw target: the layout, the resolved
/// base font description, its cached metrics, and the size-suffixed
/// description the indicator-glyph path needs.
///
/// One owner. `loadFont` is the only thing that swaps the base description,
/// so the sized cache key is just `sized_px` -- no pointer comparison. The
/// text-width cache follows the same rule: keyed by TEXT CONTENT + style
/// bits + size, never by a pointer; a font swap drops every width.
pub const FontBook = struct {
    allocator: std.mem.Allocator,
    pango_layout: *bindings.PangoLayout,
    current_font_desc: ?*bindings.PangoFontDescription = null,
    /// Cached (ascent, descent) in pixels; invalidated by loadFont.
    cached_metrics: ?struct { i16, i16 } = null,
    /// Bounded (text, style bits, size) -> pixel width map. Replaces a
    /// per-call Pango layout alloc for the common case of measuring the same
    /// label repeatedly. Cleared wholesale, not LRU: a measure is cheap.
    measure_cache: MeasureCache = .empty,
    /// Uncached (real Pango) measures since construction; the observable
    /// a "static label measures once per config" test asserts against.
    measure_misses: u32 = 0,
    /// Size-suffixed copy of `current_font_desc`, rebuilt only when
    /// `sized_px` differs. Never outlives a base-description swap.
    sized_desc: ?*bindings.PangoFontDescription = null,
    sized_px: u16 = 0,
    /// The description the layout currently has set, so a sized draw can skip
    /// the set/restore pair when it is already the sized one.
    layout_font: ?*bindings.PangoFontDescription = null,

    pub fn deinit(self: *FontBook) void {
        self.clearMeasureCache();
        // clearMeasureCache retains the map's metadata allocation; only the
        // real teardown releases it.
        self.measure_cache.deinit(self.allocator);
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
        // Install the new description only after it exists so a failed
        // conversion cannot leave `current_font_desc` dangling.
        if (self.current_font_desc) |old| bindings.pango_font_description_free(old);
        self.current_font_desc = desc;
        bindings.pango_layout_set_font_description(self.pango_layout, self.current_font_desc);
        self.layout_font = self.current_font_desc;
        self.cached_metrics = null;
        self.clearMeasureCache();
        self.invalidateSized();
    }

    /// Drops the size-suffixed copy after a base-description swap. The
    /// layout may still reference the freed sized description, so re-seat
    /// it on the base; the next sized draw sets its own before painting.
    fn invalidateSized(self: *FontBook) void {
        if (self.sized_desc) |d| bindings.pango_font_description_free(d);
        self.sized_desc = null;
        self.sized_px = 0;
        if (self.layout_font != self.current_font_desc) {
            bindings.pango_layout_set_font_description(self.pango_layout, self.current_font_desc);
            self.layout_font = self.current_font_desc;
        }
    }

    /// The base description scaled to `size_px`, cached by size alone. The
    /// only failure is having no base description to copy.
    fn sizedDesc(self: *FontBook, size_px: u16) !*bindings.PangoFontDescription {
        const desc = self.current_font_desc orelse return error.NoFont;
        if (self.sized_desc == null or self.sized_px != size_px) {
            // Copy FIRST, then free the old: freeing before the copy leaves
            // a dangling `sized_desc` if the copy fails.
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

    /// Measures `text` with no style, through the bounded width cache. A
    /// hit returns the stored width; a miss builds a throwaway run and stores.
    pub fn measureTextWidth(self: *FontBook, text: []const u8) u16 {
        return self.measureCached(text, .{}, null);
    }

    /// Measures `text` with `props` styling through the same cache. Styled
    /// and unstyled measures of one string are distinct keys, so a width can
    /// never be served from an entry that measured something else.
    pub fn measureTextWidthStyled(self: *FontBook, text: []const u8, props: bar_config.SegmentProps) u16 {
        return self.measureCached(text, props, props.size);
    }

    /// Cache lookup by content; on a miss, measure in a throwaway run and
    /// store. `measure_misses` counts the real Pango measures.
    fn measureCached(self: *FontBook, text: []const u8, props: bar_config.SegmentProps, sized_px: ?u16) u16 {
        const key = MeasureKey{ .text = text, .props = propsBits(props), .sized_px = sized_px orelse no_sized_px };
        if (self.measure_cache.get(key)) |entry| return entry.width;
        var run = self.beginRun(text, props, sized_px);
        defer run.deinit();
        const width = run.measure();
        self.measure_misses +%= 1;
        self.storeMeasure(key, width);
        return width;
    }

    /// Inserts an owned copy of `key`'s text plus the measured width. An
    /// allocation failure (or a full cache) just leaves the entry unstored:
    /// the width is still returned, so a full cache never fails a measure.
    fn storeMeasure(self: *FontBook, key: MeasureKey, width: u16) void {
        if (self.measure_cache.count() >= measure_cache_max) self.clearMeasureCache();
        const owned = self.allocator.dupe(u8, key.text) catch return;
        const entry = MeasureEntry{ .owned_text = owned, .width = width };
        self.measure_cache.put(self.allocator, key, entry) catch {
            self.allocator.free(owned);
        };
    }

    /// Frees every owned key text and empties the map, retaining capacity;
    /// called on a base-description swap (`loadFont`) and at `deinit`.
    fn clearMeasureCache(self: *FontBook) void {
        var it = self.measure_cache.valueIterator();
        while (it.next()) |entry| self.allocator.free(entry.owned_text);
        self.measure_cache.clearRetainingCapacity();
    }

    /// Builds a run for `text` under `props` (and `sized_px` when non-null),
    /// with its own layout. Never errors: a failed run is empty.
    pub fn beginRun(
        self: *FontBook,
        text: []const u8,
        props: bar_config.SegmentProps,
        sized_px: ?u16,
    ) TextRun {
        const l = bindings.pango_layout_new(bindings.pango_layout_get_context(self.pango_layout)) orelse
            return .{};
        var run = TextRun{ .layout = l };
        // Sized runs need a base description to copy. Unsized runs fall back
        // to Pango's default when none is loaded.
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

    /// Builds a book around a fresh Pango layout on `ctx`. The ONLY place
    /// a layout is created: the live context and the probe both go through
    /// it, so a change to layout setup cannot reach one path and miss the other.
    pub fn initBook(allocator: std.mem.Allocator, ctx: *bindings.cairo_t, dpi: f32) !FontBook {
        return .{
            .allocator = allocator,
            .pango_layout = try createPangoLayout(ctx, dpi),
        };
    }

    /// Loads `font_names` into a throwaway detached book and returns its
    /// metrics. Single layout-bootstrap path shared by the probe and live context.
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

/// Builds a one-shot attribute list encoding the non-default flags of
/// `props`, or null when no flags are set. Caller owns the returned list.
fn buildStyleAttrs(props: bar_config.SegmentProps) ?*bindings.PangoAttrList {
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

/// Owned, size-suffixed copies of the configured font list. A VALUE that
/// owns what it built: every entry is an owned copy, so deinit has nothing
/// to infer. Ownership is never read back from the live config -- inferring
/// it from POINTER IDENTITY is wrong whenever a config swap between build
/// and free (a reload mid-frame) hands out a borrowed entry to free or an
/// owned one to leak. `fonts` and `font_size` are REQUIRED: a trial-size
/// prober passes the trial; a bar drawer passes resolved metrics.
pub const SizedFontList = struct {
    allocator: std.mem.Allocator,
    items: [][]const u8,

    pub fn build(allocator: std.mem.Allocator, fonts: []const []const u8, font_size: u16) !SizedFontList {
        const items = try allocator.alloc([]const u8, fonts.len);
        errdefer allocator.free(items);
        for (fonts, items) |f, *out| {
            // Even at font_size 0 this COPIES rather than borrowing: every
            // entry must be owned for deinit to need no inference.
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
/// chain) to Pango `"FontName,OtherFont Bold N"`. Comma-joined families stay
/// a Pango family list, so multi-font configs get real per-glyph fallback.
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
        // Bound each family to its own Xft spec. The description is
        // family-first, so emit families up front and let option tokens trail.
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
