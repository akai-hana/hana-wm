//! The bar's `DrawContext` facade and painters: composes the font book
//! (`fonts.zig`) and the X surface (`surface.zig`) behind one context the
//! segments draw through -- baseline text, the padded/value segment
//! painters, the clock-format accessor, and the font-list bootstrap.
//! Cairo/Pango/GLib C bindings live in `bindings.zig`; every use is
//! qualified through it.

const std = @import("std");
const core = @import("core");
const log = std.log.scoped(.drawing);
const types = @import("types");
const bar_config = @import("bar_config");
const fonts = @import("fonts");
const surface = @import("surface");
const bindings = @import("bindings");

/// The clock's display format: the configured value or the built-in default.
pub fn clockFormat(config: bar_config.Config) []const u8 {
    return config.clock_format orelse types.default_clock_format;
}

inline fn pangoToF64(pango_units: c_int) f64 {
    return @as(f64, @floatFromInt(pango_units)) / bindings.pango_scale;
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

/// The validated span `[start, start + len)` inside `text`, or null when
/// not a legal non-empty range. Explicit offsets from the caller, so this
/// only range-checks -- pure and testable without Pango/cairo/display.
const ValueRange = struct { start: usize, len: usize };

pub fn valueRange(text: []const u8, start: usize, len: usize) ?ValueRange {
    // Empty span collapses to the single-colour path. A whole-string span
    // is legal: a value-only format ("{pct}") wants its number tinted.
    if (len == 0) return null;
    // Each bound independently necessary: a caller-supplied offset can be
    // near usize max, and in ReleaseFast `start + len` WRAPS rather than
    // trapping. Each guard rejects before the addition can wrap.
    if (len > text.len) return null;
    if (start >= text.len) return null;
    if (start + len > text.len) return null;
    return .{ .start = start, .len = len };
}

/// A rendered slider label plus its numeric value region: the byte subslice
/// holding the `{pct}` expansion (plus a directly-attached literal `%`, so
/// "42%" colors as one number). Null when the format has no number to color
/// (e.g. muted "MUTE"): the whole label paints in the segment color.
pub const Label = struct {
    text: []const u8,
    /// Explicit offsets; `value_len == 0` means "no value".
    value_start: usize = 0,
    value_len: usize = 0,
};

/// Shared substitution walker for volume/brightness display formats:
/// substitutes every `{pct}` with the decimal `pct` and (when `state` is
/// non-null) every `{state}` with that marker. Overflow stops the walk;
/// the truncated tail is still scan-safe. Other `{...}` pass through
/// literally. Records the numeric value region (first `{pct}` plus a
/// directly-following literal `%`) so the segment can paint it in the
/// `_value` color.
pub fn renderLineValue(format: []const u8, pct: u8, state: ?[]const u8, buf: []u8) Label {
    var n: usize = 0;
    var i: usize = 0;
    var value_start: usize = 0;
    var value_len: usize = 0;
    while (i < format.len and n < buf.len) {
        if (format[i] == '{') {
            if (state != null and std.mem.startsWith(u8, format[i..], "{state}")) {
                const s = state.?;
                if (n + s.len > buf.len) break;
                @memcpy(buf[n..][0..s.len], s);
                n += s.len;
                i += 7;
                continue;
            }
            if (std.mem.startsWith(u8, format[i..], "{pct}")) {
                var b: [16]u8 = undefined;
                const ps = std.fmt.bufPrint(&b, "{d}", .{pct}) catch break;
                if (n + ps.len > buf.len) break;
                @memcpy(buf[n..][0..ps.len], ps);
                // Extend the number's span through a literal '%' right after
                // the placeholder, coloring "42%" as one number.
                const ok_percent = i + 5 < format.len and format[i + 5] == '%';
                const span = ps.len + @intFromBool(ok_percent and n + ps.len < buf.len);
                // First {pct} wins.
                if (value_len == 0) {
                    value_start = n;
                    value_len = span;
                }
                n += ps.len;
                i += 5;
                continue;
            }
        }
        buf[n] = format[i];
        n += 1;
        i += 1;
    }
    return .{ .text = buf[0..n], .value_start = value_start, .value_len = value_len };
}

/// A foreground colour for the byte range `[start, start + len)` of the
/// laid-out text. Pango interprets offsets in BYTES and attributes by glyph
/// run, so a range splitting a multi-byte char degrades to intersecting
/// glyphs (in-tree callers pass ASCII numerals, which is exact).
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

pub const DrawContext = struct {
    /// Pango font state: layout, descriptions, metrics, sized-font cache.
    fonts: fonts.FontBook,
    /// Off-screen X drawable and the XCB/cairo machinery that writes to it.
    surface: surface.Surface,
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
        var sfc = try surface.Surface.init(conn, window, width, height, visual_id, is_argb, transparency);
        errdefer sfc.deinit();

        const books = try fonts.FontBook.initBook(allocator, sfc.ctx, dpi);
        errdefer bindings.g_object_unref(books.pango_layout);

        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);
        dc.* = .{ .surface = sfc, .fonts = books };
        return dc;
    }

    /// Headless construction: the same font book over an image surface, no
    /// X resources. Mirror of `initWithVisual` for tests without a display.
    pub fn initImage(
        allocator: std.mem.Allocator,
        width: u16,
        height: u16,
        dpi: f32,
    ) !*DrawContext {
        var sfc = try surface.Surface.initImage(width, height);
        errdefer sfc.deinit();

        const books = try fonts.FontBook.initBook(allocator, sfc.ctx, dpi);
        errdefer bindings.g_object_unref(books.pango_layout);

        const dc = try allocator.create(DrawContext);
        errdefer allocator.destroy(dc);
        dc.* = .{ .surface = sfc, .fonts = books };
        return dc;
    }

    pub fn deinit(self: *DrawContext) void {
        self.fonts.deinit();
        bindings.g_object_unref(self.fonts.pango_layout);
        self.surface.deinit();
        self.fonts.allocator.destroy(self);
    }

    /// Colors the context and paints `run` at (x, baseline). Empty run paints nothing.
    inline fn paintRun(self: *DrawContext, run: *fonts.TextRun, x: u16, y: u16, color: u32) void {
        const l = run.layout orelse return;
        self.surface.setColor(color);
        showLayoutAtBaseline(self.surface.ctx, l, @floatFromInt(x), y);
    }

    /// Draws `text` with its TOP at `y_top`, in a size-suffixed font.
    /// The sized description/caching live on `FontBook`; the run is this
    /// text's own layout, so no set/restore pairing is needed.
    pub fn drawTextSized(
        self: *DrawContext,
        x: u16,
        y_top: u16,
        text: []const u8,
        size_px: u16,
        color: u32,
    ) !void {
        // The one genuinely fallible text path: resolving the size-suffixed
        // description can fail with no base description to copy.
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
    /// Infallible: a run that cannot be built degrades to an empty run
    /// that measures 0 and paints nothing. The one genuinely fallible text
    /// path is `drawTextSized` (can return `error.NoFont`).
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
        // text in the same state, which one shared run guarantees.
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

    /// Draws `text` ellipsized to `max_width` at (x, y); one-shot run, no
    /// Pango state survives the call.
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

    /// Shared text rendering: build a run under `props`, optionally ellipsize
    /// to `max_width`, paint at baseline. Every draw goes through a private
    /// run so no layout state is left behind for the next draw.
    inline fn drawTextImpl(
        self: *DrawContext,
        x: u16,
        y: u16,
        text: []const u8,
        max_width: ?u16,
        color: u32,
        props: bar_config.SegmentProps,
    ) void {
        var run = self.fonts.beginRun(text, props, props.size);
        defer run.deinit();
        if (max_width) |w| {
            if (run.layout) |l| {
                bindings.pango_layout_set_width(l, @as(i32, w) * bindings.pango_scale);
                bindings.pango_layout_set_ellipsize(l, bindings.PangoEllipsizeMode.END);
            }
        }
        self.paintRun(&run, x, y, color);
    }

    /// Like `drawText` but with `props`' Pango styling.
    pub fn drawTextStyled(
        self: *DrawContext,
        x: u16,
        y: u16,
        text: []const u8,
        color: u32,
        props: bar_config.SegmentProps,
    ) void {
        self.drawTextImpl(x, y, text, null, color, props);
    }

    pub fn baselineY(self: *DrawContext, bar_height: u16) u16 {
        const asc, const desc = self.fonts.getMetrics();
        const top_pad: i32 = @max(0, @divTrunc(@as(i32, bar_height) - (asc + desc), 2));
        return @intCast(top_pad + asc);
    }

    /// Fill background, measure `text` (with `props` so bold/italic reserve
    /// the right slot), draw at baseline, return x + width. `min_w` forces
    /// the background to span at least that many text pixels (plus padding)
    /// so a region-scoped repaint of a shrunken segment still wipes its
    /// whole previous slot.
    fn paintedSegment(
        self: *DrawContext,
        x: u16,
        height: u16,
        text: []const u8,
        padding: u16,
        bg: u32,
        fg: u32,
        min_w: ?u16,
        props: bar_config.SegmentProps,
    ) !u16 {
        // One run measured AND painted so reserved width and painted styling
        // come from one derivation: measuring and painting through two passes
        // on a shared layout lets a styled segment reserve one width and paint
        // another, because the second pass can re-derive the styling.
        var run = self.fonts.beginRun(text, props, props.size);
        defer run.deinit();
        const text_w = run.measure();
        const width: u16 = (if (min_w) |m| @max(text_w, m) else text_w) + padding * 2;
        self.fillRect(x, 0, width, height, bg);
        self.paintRun(&run, x + padding, self.baselineY(height), fg);
        return x + width;
    }

    /// Facade forwarder; the paint-order rule lives on `Surface.fillRect`.
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        self.surface.fillRect(x, y, width, height, color);
    }

    /// Facade forwarder to `FontBook.measureTextWidth`.
    pub fn measureTextWidth(self: *DrawContext, text: []const u8) u16 {
        return self.fonts.measureTextWidth(text);
    }

    /// Facade forwarder to `FontBook.measureTextWidthStyled`; the styled
    /// width comes from the same content-keyed cache, so a styled draw
    /// reserves exactly the width it will paint.
    pub fn measureTextWidthStyled(self: *DrawContext, text: []const u8, props: bar_config.SegmentProps) u16 {
        return self.fonts.measureTextWidthStyled(text, props);
    }

    /// Facade metrics accessor; the prompt overlay reads the bar's font
    /// metrics through it.
    pub fn metrics(self: *DrawContext) struct { i16, i16 } {
        return self.fonts.getMetrics();
    }

    /// Region xcb_copy_area enqueued but not flushed. Safe inside
    /// xcb_grab_server; flushed by ungrabAndFlush() or event-loop xcb_flush.
    pub fn queueBlit(self: *DrawContext, x: u16, w: u16) void {
        if (w == 0) return;
        self.surface.blitImpl(x, w, false);
    }

    /// Region copy with immediate xcb_flush. Timer-driven paths (clock tick,
    /// prompt caret blink).
    pub fn blitRegion(self: *DrawContext, x: u16, w: u16) void {
        self.surface.blitImpl(x, w, true);
    }
};

/// Draws `text` at `x` using the config's scaled segment padding and bar
/// colors (a `[bar.properties]` override for `segment_name` when set, bar
/// `fg` otherwise), optionally with `props`' styling. When `cover_text` is
/// set, the background fill always spans at least its measured width plus
/// padding: the clock uses this so a region-scoped repaint of a NARROWER
/// display mode repaints the whole reserved slot instead of leaving stale
/// pixels. Collapses the otherwise repeated argument list of the icon-ish
/// segment modules.
pub fn drawPaddedSegment(
    dc: *DrawContext,
    config: bar_config.Config,
    height: u16,
    x: u16,
    segment_name: []const u8,
    text: []const u8,
    cover_text: ?[]const u8,
    props: bar_config.SegmentProps,
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
/// value_start + value_len)` of `text` (the numeric readout, e.g. "42%") in
/// the segment's NUMBER color -- the `<segment>_value` override via
/// `segmentValueFg`, falling back to the segment foreground -- and everything
/// else in the segment foreground. Collapses to `drawPaddedSegment` when the
/// span is not a legal range. The width comes from the whole string, so a
/// segment's reserved slot never changes when a value color is added.
pub fn drawPaddedSegmentValue(
    dc: *DrawContext,
    config: bar_config.Config,
    height: u16,
    x: u16,
    segment_name: []const u8,
    text: []const u8,
    value_start: usize,
    value_len: usize,
    props: bar_config.SegmentProps,
) !u16 {
    const padding = config.scaledSegmentPadding(height);
    const range = valueRange(text, value_start, value_len);
    const fg = config.segmentFg(segment_name);
    const value_fg = config.segmentValueFg(segment_name);
    if (range == null)
        return dc.paintedSegment(x, height, text, padding, config.bg, fg, null, props);

    // ONE Pango pass: measure the whole string, then paint once with a
    // foreground attribute over the value's byte range.
    //
    // One pass is load-bearing: splitting into prefix/value/suffix and
    // summing per-part measurements is not the same as measuring the whole
    // string -- shaping across a part boundary (kerning, ligatures) changes
    // the true advance, so the cursor drifts while the reserved width is
    // still measured from the whole string.
    //
    // Pango owning the range also composes for free: the value colour applies
    // alongside ellipsize and style props, and the props go on the SAME
    // layout as the range so the two cannot disagree about shaping. Both live
    // in the run's OWN attribute list / layout: deinit unrefs both together,
    // so there is no restore to forget.
    var run = dc.fonts.beginRun(text, props, props.size);
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

/// Loads the configured fonts into `dc`. Called once per DrawContext
/// creation. `allocator`/`font_names` passed in rather than read from
/// `core.getState()`: the caller that already holds cs does not want a
/// hidden second source of truth for the bar's fonts.
pub fn loadBarFonts(dc: *DrawContext, allocator: std.mem.Allocator, font_names: []const []const u8, font_size: u16) !void {
    var sized = try fonts.SizedFontList.build(allocator, font_names, font_size);
    defer sized.deinit();
    if (sized.items.len == 0) return; // keep Pango default, matching probeFontMetrics
    try dc.fonts.loadFonts(sized.items);
    if (sized.items.len > 1) log.info("Loaded {} fonts with fallback support", .{sized.items.len});
}
