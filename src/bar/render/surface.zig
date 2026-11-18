//! Off-screen X drawable and the XCB/cairo machinery that writes to it:
//! the pixmap + cairo surface a frame draws into, visual/depth resolution,
//! and the fill/blit primitives with their paint-order rule (XCB fills land
//! under cairo glyphs of the same frame). `DrawContext` in `drawing.zig`
//! composes this with the font book from `fonts.zig`.

const std = @import("std");
const core = @import("core");
const bindings = @import("bindings");
const types = @import("types");

fn firstVisualOfDepth(screen: core.Screen, depth: u8) ?*core.xcb.xcb_visualtype_t {
    var di = core.xcb.xcb_screen_allowed_depths_iterator(screen);
    while (di.rem > 0) : (core.xcb.xcb_depth_next(&di)) {
        if (di.data.*.depth != depth) continue;
        const vi = core.xcb.xcb_depth_visuals_iterator(di.data);
        if (vi.rem > 0) return vi.data;
    }
    return null;
}

/// Returns the visual id for `depth`, or null when the screen has none.
/// Callers decide the fallback: the bar must drop ARGB, not claim it while
/// drawing through a 24-bit root visual.
pub fn findVisualByDepth(screen: core.Screen, depth: u8) ?u32 {
    const vt = firstVisualOfDepth(screen, depth) orelse return null;
    return vt.visual_id;
}

/// Whether an X compositor currently owns the `_NET_WM_CM_S0` selection.
///
/// Without one, nothing blends the bar's depth-32 window: the server displays
/// the stored RGB and ignores the alpha channel. Premultiplied fills would
/// then darken toward black as the requested alpha falls, so `packFill` uses
/// this to fall back to straight RGB instead.
fn compositorActive(conn: core.Connection) bool {
    const name = "_NET_WM_CM_S0";
    const atom_cookie = core.xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
    const atom_reply = core.xcb.xcb_intern_atom_reply(conn, atom_cookie, null) orelse return false;
    defer std.c.free(atom_reply);

    const owner_cookie = core.xcb.xcb_get_selection_owner(conn, atom_reply.*.atom);
    const owner_reply = core.xcb.xcb_get_selection_owner_reply(conn, owner_cookie, null) orelse return false;
    defer std.c.free(owner_reply);
    return owner_reply.*.owner != 0;
}

/// File-based dev override for the paint formula. The color-demo tool writes
/// this file and pokes the bar with a synthetic Expose; nothing in normal use
/// creates it, so the shipped behavior stays `native`.
pub const color_mode_path = "/tmp/hana-color-mode";

pub const ColorMode = enum {
    native,
    normal,
    legacy,
    tint25,
    tint50,
    tint75,
    gamma50,
    gamma75,

    fn fromFile() ColorMode {
        const io = std.Options.debug_io;
        var buf: [32]u8 = undefined;
        const f = std.Io.Dir.openFileAbsolute(io, color_mode_path, .{}) catch return .native;
        defer f.close(io);
        const n = f.readPositionalAll(io, &buf, 0) catch return .native;
        const name = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return std.meta.stringToEnum(ColorMode, name) orelse .native;
    }
};

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
    /// Whether a compositor owned the selection when this surface was made.
    /// Without one, alpha is not blended and fills stay straight RGB.
    composited: bool = false,
    /// Global alpha multiplier for XCB fills (0xFF = no global fade). The
    /// per-color alpha byte is folded in by `packFill`.
    alpha_u8: u8 = 0xFF,
    /// Dev-only formula override from `color_mode_path`.
    color_mode: ColorMode = .native,
    last_color: ?types.Color = null,
    /// Cached GC foreground: skips xcb_change_gc when unchanged (the common
    /// case for adjacent same-background segments).
    last_gc_color: ?u32 = null,
    /// True once this frame has issued its first XCB fill.
    xcb_filled_this_frame: bool = false,

    pub fn init(
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
        // only valid for CreateWindow and fails here with BadValue.
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

        // Fire both GC-create requests before blocking on either reply so
        // both land in the same TCP segment. The errdefers free both on any
        // failure after they exist; deinit owns them once init returns.
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
            .composited = is_argb and compositorActive(conn),
            .color_mode = ColorMode.fromFile(),
            .alpha_u8 = if (is_argb)
                @intFromFloat(@round(std.math.clamp(transparency, 0.0, 1.0) * 255.0))
            else
                0xFF,
        };
    }

    pub fn deinit(self: *Surface) void {
        if (self.gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        if (self.copy_gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.copy_gc);
        bindings.cairo_destroy(self.ctx);
        // Destroy surface before pixmap: Cairo holds a reference to the
        // pixmap.
        bindings.cairo_surface_destroy(self.cairo_surface);
        if (self.pixmap != 0) _ = core.xcb.xcb_free_pixmap(self.conn, self.pixmap);
    }

    /// Image-backed surface with the XCB half inert: no pixmap, no GCs, so
    /// every wire path short-circuits on its zero handle (`fillRect` falls
    /// back to cairo, `blitImpl` returns after the flush). The test-only
    /// constructor for a headless DrawContext -- same cairo surface type the
    /// font probe measures against, no display.
    pub fn initImage(width: u16, height: u16) !Surface {
        const cairo_surface = bindings.cairo_image_surface_create(
            .ARGB32,
            @intCast(width),
            @intCast(height),
        ) orelse return error.CairoSurfaceCreateFailed;
        errdefer bindings.cairo_surface_destroy(cairo_surface);

        const ctx = bindings.cairo_create(cairo_surface) orelse return error.CairoCreateFailed;
        errdefer bindings.cairo_destroy(ctx);

        return .{
            .conn = undefined,
            .window = 0,
            .pixmap = 0,
            .width = width,
            .height = height,
            .cairo_surface = cairo_surface,
            .ctx = ctx,
            .gc = 0,
            .copy_gc = 0,
        };
    }

    pub inline fn setColor(self: *Surface, color: types.Color) void {
        if (self.last_color) |last| if (last.eql(color)) return;
        setCairoColor(self.ctx, color.raw());
        self.last_color = color;
    }

    /// Re-reads the dev color-mode file. True when it changed, so the caller
    /// can trigger a full repaint with the new fill formula.
    pub fn refreshColorMode(self: *Surface) bool {
        if (!self.is_argb) return false;
        const now = ColorMode.fromFile();
        if (now == self.color_mode) return false;
        self.color_mode = now;
        return true;
    }

    /// Re-probes the compositor selection. Returns true when it changed, so
    /// the caller can repaint every fill with the new packing (a compositor
    /// starting makes alpha live; one stopping makes it meaningless again).
    pub fn refreshCompositor(self: *Surface) bool {
        if (!self.is_argb) return false;
        const now = compositorActive(self.conn);
        if (now == self.composited) return false;
        self.composited = now;
        return true;
    }

    /// Uses XCB rather than Cairo to write background pixels; `packFill`
    /// owns the alpha encoding (legacy straight-alpha for six-digit colors,
    /// premultiplied for explicit per-color alpha).
    ///
    /// ## Paint-order rule: XCB fills are ordered BEFORE every cairo glyph
    /// of the frame
    ///
    /// `cairo_surface` is an xcb surface backed by `pixmap`. Glyphs go
    /// through cairo and are buffered until the frame's blit flushes them;
    /// `xcb_poly_fill_rectangle` goes on the wire immediately, so the server
    /// sees every fill of the frame, then every glyph, regardless of the
    /// order modules called them in. That is what makes `fillRect` usable as
    /// a BACKGROUND: the segment fills first, the label lands on top.
    ///
    /// Enforced at the top: the first XCB write of a frame quiesces cairo
    /// first, so no cairo operation is left pending across the boundary
    /// where the two orderings diverge.
    pub fn fillRect(self: *Surface, x: u16, y: u16, width: u16, height: u16, color: types.Color) void {
        // Image surface (no pixmap): the same pixels via cairo, so a
        // headless frame still paints a background. The wire-only state
        // below is skipped entirely -- no GC to arm, no ordering to enforce.
        if (self.pixmap == 0) {
            self.setColor(color);
            bindings.cairo_rectangle(
                self.ctx,
                @floatFromInt(x),
                @floatFromInt(y),
                @floatFromInt(width),
                @floatFromInt(height),
            );
            bindings.cairo_fill(self.ctx);
            return;
        }
        if (!self.xcb_filled_this_frame) {
            // Quiesce before the first wire write of the frame.
            bindings.cairo_surface_flush(self.cairo_surface);
            self.xcb_filled_this_frame = true;
        }
        const packed_color = packFillMode(color, self.alpha_u8, self.is_argb, self.composited, self.color_mode);
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

    /// Shared blit body: bindings.cairo_surface_flush + xcb_copy_area of
    /// [x, x+w), plus an immediate xcb_flush only for `blitRegion`.
    /// `queueBlit` must NOT flush here: it is safe inside xcb_grab_server
    /// precisely because the copy is sent with the caller's batch end.
    pub inline fn blitImpl(self: *Surface, x: u16, w: u16, comptime flush: bool) void {
        // The frame's glyphs go on the wire here, which is what puts them after
        // this frame's fills. Re-arms the one-shot quiesce for the next
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

/// Packs a fill color for the XCB GC.
///
/// Six-digit colors (opaque alpha byte) keep the PRE-RGBA straight-alpha
/// encoding: the compositor treats ARGB32 as premultiplied, so their full RGB
/// is contributed at every global alpha. That is what preserves the old bar
/// look -- accents stay visible at `transparency = 0%` instead of vanishing,
/// and the frame clear tints the content behind the bar exactly as it did
/// before per-color alpha existed.
///
/// A color with an explicit alpha byte (`#RRGGBBAA`, including `FF`) instead
/// owns its transparency: it is premultiplied by that byte alone, so `00` is
/// genuinely transparent and partial alphas blend correctly no matter what
/// the bar-wide legacy fade is set to. `#RRGGBBFF` is therefore opaque even
/// at `transparency = 0%`, while `#RRGGBB` keeps the legacy fade.
///
/// With no compositor owning `_NET_WM_CM_S0`, the depth-32 window's alpha is
/// not blended at all: the server shows the stored RGB as-is. Premultiplying
/// there would darken every alpha fill (and turn a zero combined alpha into
/// black), so the fill degrades to opaque straight RGB -- the only useful
/// rendering without a compositor.
pub inline fn packFill(color: types.Color, global_alpha: u8, is_argb: bool, composited: bool) u32 {
    return packFillMode(color, global_alpha, is_argb, composited, .native);
}

/// `packFill` plus the dev-only formula override. The alpha fed to a formula
/// is the color's own alpha when explicit, otherwise the bar-wide fade; that
/// keeps the color-demo's six-digit swatches comparable to real theme fills.
pub inline fn packFillMode(
    color: types.Color,
    global_alpha: u8,
    is_argb: bool,
    composited: bool,
    mode: ColorMode,
) u32 {
    const argb = color.raw();
    if (!is_argb) return argb & 0x00FF_FFFF;
    if (!composited) return 0xFF00_0000 | (argb & 0x00FF_FFFF);
    const rgb = argb & 0x00FF_FFFF;
    const alpha = if (color.explicit_alpha) types.alphaOf(color) else global_alpha;
    return switch (mode) {
        .native => if (color.explicit_alpha)
            premultiply(argb, alpha)
        else
            (@as(u32, global_alpha) << 24) | rgb,
        .normal => premultiply(0xFF00_0000 | rgb, alpha),
        .legacy => (@as(u32, alpha) << 24) | rgb,
        .tint25 => tintPixel(rgb, alpha, 0.25),
        .tint50 => tintPixel(rgb, alpha, 0.50),
        .tint75 => tintPixel(rgb, alpha, 0.75),
        .gamma50 => gammaPixel(rgb, alpha, 0.5),
        .gamma75 => gammaPixel(rgb, alpha, 0.75),
    };
}

fn tintPixel(rgb: u32, alpha: u8, t: f64) u32 {
    const a = @as(f64, @floatFromInt(alpha)) / 255.0;
    const k = a + t * (1.0 - a);
    return (@as(u32, alpha) << 24) | scaleRgb(rgb, k);
}

fn gammaPixel(rgb: u32, alpha: u8, gamma: f64) u32 {
    const a = @as(f64, @floatFromInt(alpha)) / 255.0;
    const k = std.math.pow(f64, a, gamma);
    return (@as(u32, alpha) << 24) | scaleRgb(rgb, k);
}

fn scaleRgb(rgb: u32, factor: f64) u32 {
    const f = std.math.clamp(factor, 0.0, 1.0);
    const r = scaleChannel((rgb >> 16) & 0xFF, f);
    const g = scaleChannel((rgb >> 8) & 0xFF, f);
    const b = scaleChannel(rgb & 0xFF, f);
    return (r << 16) | (g << 8) | b;
}

fn scaleChannel(v: u32, factor: f64) u32 {
    return @intFromFloat(@round(@as(f64, @floatFromInt(v)) * factor));
}

/// Packs a straight-alpha `0xAARRGGBB` color into XRender's premultiplied
/// `0xAARRGGBB` pixel: each RGB channel is scaled by `alpha / 255`, rounded.
/// An opaque color is returned unchanged and a transparent one becomes zero.
pub inline fn premultiply(color: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const r = (((color >> 16) & 0xFF) * a + 127) / 255;
    const g = (((color >> 8) & 0xFF) * a + 127) / 255;
    const b = ((color & 0xFF) * a + 127) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

inline fn setCairoColor(ctx: *bindings.cairo_t, color: u32) void {
    const a = @as(f64, @floatFromInt((color >> 24) & 0xFF)) / 255.0;
    const r = @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g = @as(f64, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b = @as(f64, @floatFromInt(color & 0xFF)) / 255.0;
    bindings.cairo_set_source_rgba(ctx, r, g, b, a);
}

inline fn createXcbPixmap(conn: core.Connection, depth: u8, drawable: u32, w: u16, h: u16) u32 {
    const pixmap = core.xcb.xcb_generate_id(conn);
    _ = core.xcb.xcb_create_pixmap(conn, depth, pixmap, drawable, w, h);
    return pixmap;
}

/// Returns the visual matching `visual_id` across all screens, or falls
/// back to a visual matching `depth` on `screen`. Errors if no visuals
/// exist.
fn resolveVisualType(
    conn: core.Connection,
    screen: core.Screen,
    visual_id: ?u32,
    depth: u8,
) !*core.xcb.xcb_visualtype_t {
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
    // Fallback: a visual matching the PIXMAP depth to avoid BadMatch when
    // the surface pairs visual+drawable at different depths.
    return firstVisualOfDepth(screen, depth) orelse error.NoVisuals;
}
