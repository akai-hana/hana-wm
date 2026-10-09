//! The bar's `DrawContext` facade and painters: composes the font book
//! (`fonts.zig`) and the X surface (`surface.zig`) behind one context the
//! segments draw through -- baseline text, the padded/value segment
//! painters, the clock-format accessor, and the font-list bootstrap
//! (`loadBarFonts`).
//!
//! Cairo, Pango, and GLib C bindings live in `bindings.zig` (see the import
//! below); every use is qualified through it.

const std = @import("std");
const core = @import("core");
const log = @import("log");
const types = @import("types");
const defaults = @import("defaults");
const fonts = @import("fonts");
const surface = @import("surface");
const bindings = @import("bindings");

/// The clock's display format: the configured value, or the built-in default
/// when unset. Single accessor shared by the clock segment and the bar's
/// updateClock (each previously re-derived the same fallback).
pub fn clockFormat(config: types.BarConfig) []const u8 {
    return config.clock_format orelse defaults.default_clock_format;
}

// Cairo, Pango, and GLib C bindings for bar rendering live in
// bindings.zig (see the import above); every use below is
// qualified through it.

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

/// The validated span `[start, start + len)` inside `text`, or null when the
/// span is not a legal non-empty range of it.
///
/// The span arrives as EXPLICIT OFFSETS from the caller. It used to arrive as a
/// subslice, whose position the painter recovered by subtracting raw addresses
/// (`@intFromPtr(v.ptr) - @intFromPtr(text.ptr)`) and whose validity was checked
/// by comparing raw pointers. A module that knows where its number
/// sits now says so, and this only has to range-check it, which is pure and
/// testable without Pango, cairo or a display.
const ValueRange = struct { start: usize, len: usize };

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

/// A rendered slider label plus its numeric value region: the byte subslice of
/// `text` holding the `{pct}` expansion (plus a directly-attached literal
/// `%`, so "42%" colors as one number). Null when the format has no number to
/// color (e.g. volume's muted "MUTE"), in which case the whole label paints in
/// the segment color.
pub const Label = struct {
    text: []const u8,
    /// The numeric value's span as EXPLICIT offsets, with `value_len ==
    /// 0` meaning "no value".
    value_start: usize = 0,
    value_len: usize = 0,
};

/// Renders a control's display `format` into `buf`, substituting every
/// `{pct}` placeholder with the decimal `pct` and -- when `state` is non-null
/// -- every `{state}` placeholder with that marker string. A substitution
/// that would overflow `buf` stops the walk; a truncated tail is still a
/// complete, scan-safe string. Any other `{...}` passes through literally.
/// Shared substitution walker for the volume/brightness display formats;
/// records the numeric value region (see `Label.value_start`/`value_len`) so the segment can
/// paint the number in its `_value` color. The value is the first `{pct}`
/// expansion plus a literal `%` that directly follows the placeholder.
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
                // the placeholder (guarded by `n` so the record never points
                // past the final `text`), coloring "42%" as one number.
                const ok_percent = i + 5 < format.len and format[i + 5] == '%';
                const span = ps.len + @intFromBool(ok_percent and n + ps.len < buf.len);
                // First {pct} wins, as before.
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

/// A foreground colour applied to the byte range `[start, start + len)` of the
/// laid-out text.
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

    pub fn deinit(self: *DrawContext) void {
        self.fonts.deinit();
        bindings.g_object_unref(self.fonts.pango_layout);
        self.surface.deinit();
        self.fonts.allocator.destroy(self);
    }

    /// Colors the context and paints `run` with its left edge at `x` and its
    /// baseline at `y`. An empty run paints nothing.
    inline fn paintRun(self: *DrawContext, run: *fonts.TextRun, x: u16, y: u16, color: u32) void {
        const l = run.layout orelse return;
        self.surface.setColor(color);
        showLayoutAtBaseline(self.surface.ctx, l, @floatFromInt(x), y);
    }

    /// Draws `text` with its TOP at `y_top`, in a size-suffixed font.
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
        // Still the one genuinely fallible text path: resolving the
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
    /// Infallible: a run that cannot be built degrades to an empty run
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
        // thing making that true before.
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
    /// ellipsize it to `max_width`, and paint at baseline. Every draw
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
        // One run measured AND painted. These used to be two separate
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

    /// Facade forwarder; the implementation AND the paint-order rule
    /// Now live on `Surface.fillRect`.
    pub fn fillRect(self: *DrawContext, x: u16, y: u16, width: u16, height: u16, color: u32) void {
        self.surface.fillRect(x, y, width, height, color);
    }

    /// Facade forwarder to `FontBook.measureTextWidth`.
    pub fn measureTextWidth(self: *DrawContext, text: []const u8) u16 {
        return self.fonts.measureTextWidth(text);
    }

    /// Measures `text` with `props` styling applied, so a styled draw reserves
    /// exactly the width it will paint.
    pub fn measureTextWidthStyled(self: *DrawContext, text: []const u8, props: types.SegmentProps) u16 {
        var run = self.fonts.beginRun(text, props, null);
        defer run.deinit();
        return run.measure();
    }

    /// Facade metrics accessor, replacing direct `dc.font.getMetrics()`
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

    // ONE Pango pass: measure the whole string, then paint it once with
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
    // The style props and the value's foreground go into the
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

/// Loads the configured fonts into `dc`. Called once per DrawContext creation.
/// `allocator` and `font_names` are passed in rather than read out of
/// `core.getState()`: the caller that already holds cs does not want a hidden
/// second source of truth here (the SizedFontList doc above names exactly
/// that bug class for `freeSizedFontList`, and `build` was fixed the same way).
pub fn loadBarFonts(dc: *DrawContext, allocator: std.mem.Allocator, font_names: []const []const u8, font_size: u16) !void {
    var sized = try fonts.SizedFontList.build(allocator, font_names, font_size);
    defer sized.deinit();
    if (sized.items.len == 0) return; // keep Pango default, matching probeFontMetrics
    try dc.fonts.loadFonts(sized.items);
    if (sized.items.len > 1) log.info("Loaded {} fonts with fallback support", .{sized.items.len});
}
