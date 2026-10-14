//! Off-screen X drawable and the XCB/cairo machinery that writes to it:
//! the pixmap + cairo surface a frame draws into, visual/depth resolution,
//! and the fill/blit primitives with their paint-order rule (XCB fills land
//! under cairo glyphs of the same frame).
//!
//! Split OUT of `drawing.zig` in Phase 4 (step 24): `DrawContext` composes
//! this with the font book from `fonts.zig`.

const std = @import("std");
const core = @import("core");
const bindings = @import("bindings");

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

/// Owns the off-screen X drawable and the XCB/cairo machinery that writes to
/// it. Extracted from `DrawContext` so the display resources and the
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

    pub fn deinit(self: *Surface) void {
        if (self.gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.gc);
        if (self.copy_gc != 0) _ = core.xcb.xcb_free_gc(self.conn, self.copy_gc);
        bindings.cairo_destroy(self.ctx);
        // Destroy surface before pixmap: Cairo holds a reference to the pixmap.
        bindings.cairo_surface_destroy(self.cairo_surface);
        if (self.pixmap != 0) _ = core.xcb.xcb_free_pixmap(self.conn, self.pixmap);
    }

    pub inline fn setColor(self: *Surface, color: u32) void {
        if (self.last_color == color) return;
        setCairoColor(self.ctx, color);
        self.last_color = color;
    }

    /// Uses XCB rather than Cairo to write straight-alpha pixels (picom expects
    /// straight-alpha; Cairo's XRender backend writes premultiplied).
    /// `last_gc_color` skips xcb_change_gc when the color is unchanged, which is
    /// the common case for adjacent same-background segments.
    ///
    /// ## Paint-order rule: XCB fills are ordered BEFORE every cairo
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
            // Quiesce before the first wire write of the frame.
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

inline fn setCairoColor(ctx: *bindings.cairo_t, color: u32) void {
    const r = @as(f64, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
    const g = @as(f64, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
    const b = @as(f64, @floatFromInt(color & 0xFF)) / 255.0;
    bindings.cairo_set_source_rgba(ctx, r, g, b, 1.0);
}

inline fn createXcbPixmap(conn: core.Connection, depth: u8, drawable: u32, w: u16, h: u16) u32 {
    const pixmap = core.xcb.xcb_generate_id(conn);
    _ = core.xcb.xcb_create_pixmap(conn, depth, pixmap, drawable, w, h);
    return pixmap;
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
