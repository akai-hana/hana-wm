//! C bindings for Cairo, Pango, GLib, and xcb-cursor.
//! XCB types come from defs.zig via @cImport.

const defs = @import("defs");

const xcb_connection_t = defs.xcb.xcb_connection_t;
const xcb_drawable_t   = defs.xcb.xcb_drawable_t;
const xcb_visualtype_t = defs.xcb.xcb_visualtype_t;

// ── Cairo ─────────────────────────────────────────────────────────────────────

pub const cairo_surface_t = opaque {};
pub const cairo_t         = opaque {};

pub const cairo_format_t = enum(c_int) {
    ARGB32    = 0,
    RGB24     = 1,
    A8        = 2,
    A1        = 3,
    RGB16_565 = 4,
    RGB30     = 5,
};

pub extern fn cairo_xcb_surface_create(
    connection: *xcb_connection_t,
    drawable:   xcb_drawable_t,
    visual:     *xcb_visualtype_t,
    width:      c_int,
    height:     c_int,
) ?*cairo_surface_t;

/// In-memory image surface; no X connection needed. Used for off-screen font measurement.
pub extern fn cairo_image_surface_create(
    format: cairo_format_t,
    width:  c_int,
    height: c_int,
) ?*cairo_surface_t;

pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;
pub extern fn cairo_surface_flush(surface: *cairo_surface_t) void;

pub extern fn cairo_create(surface: *cairo_surface_t) ?*cairo_t;
pub extern fn cairo_destroy(cr: *cairo_t) void;

// Trimmed to only the two operators used (CLEAR, OVER); the full enum has 29
// variants. Numeric values are unchanged so the ABI is unaffected.
pub const cairo_operator_t = enum(c_int) {
    CLEAR = 0,
    OVER  = 2,
};

pub extern fn cairo_set_source_rgba(cr: *cairo_t, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern fn cairo_move_to(cr: *cairo_t, x: f64, y: f64) void;
pub extern fn cairo_set_operator(cr: *cairo_t, op: cairo_operator_t) void;
pub extern fn cairo_paint(cr: *cairo_t) void;

// ── Pango ─────────────────────────────────────────────────────────────────────

pub const PangoLayout          = opaque {};
pub const PangoContext         = opaque {};
pub const PangoFontDescription = opaque {};
pub const PangoFontMetrics     = opaque {};
pub const PangoLayoutLine      = opaque {};

/// Internal Pango unit divisor — 1 pixel = PANGO_SCALE pango units.
pub const PANGO_SCALE: c_int = 1024;

pub const PangoEllipsizeMode = enum(c_int) {
    NONE   = 0,
    START  = 1,
    MIDDLE = 2,
    END    = 3,
};

pub const PangoRectangle = extern struct {
    x:      c_int,
    y:      c_int,
    width:  c_int,
    height: c_int,
};

pub extern fn pango_cairo_create_layout(cr: *cairo_t) ?*PangoLayout;
pub extern fn pango_cairo_show_layout(cr: *cairo_t, layout: *PangoLayout) void;
pub extern fn pango_cairo_context_set_resolution(context: *PangoContext, dpi: f64) void;

pub extern fn pango_layout_set_text(layout: *PangoLayout, text: [*]const u8, length: c_int) void;
pub extern fn pango_layout_set_font_description(layout: *PangoLayout, desc: ?*PangoFontDescription) void;
pub extern fn pango_layout_get_context(layout: *PangoLayout) *PangoContext;
/// `width` and `height` may be null if the caller only needs one dimension.
pub extern fn pango_layout_get_pixel_size(layout: *PangoLayout, width: ?*c_int, height: ?*c_int) void;
pub extern fn pango_layout_set_width(layout: *PangoLayout, width: c_int) void;
pub extern fn pango_layout_set_ellipsize(layout: *PangoLayout, ellipsize: PangoEllipsizeMode) void;
pub extern fn pango_layout_get_baseline(layout: *PangoLayout) c_int;

pub extern fn pango_font_description_from_string(str: [*:0]const u8) ?*PangoFontDescription;
pub extern fn pango_font_description_copy(desc: *PangoFontDescription) ?*PangoFontDescription;
pub extern fn pango_font_description_free(desc: *PangoFontDescription) void;
pub extern fn pango_font_description_get_size(desc: *PangoFontDescription) c_int;
pub extern fn pango_font_description_get_size_is_absolute(desc: *PangoFontDescription) c_int;
pub extern fn pango_font_description_set_size(desc: *PangoFontDescription, size: c_int) void;
pub extern fn pango_font_description_set_absolute_size(desc: *PangoFontDescription, size: f64) void;

pub extern fn pango_layout_get_extents(layout: *PangoLayout, ink_rect: ?*PangoRectangle, logical_rect: ?*PangoRectangle) void;

pub extern fn pango_context_get_metrics(
    context:  *PangoContext,
    desc:     ?*PangoFontDescription,
    language: ?*anyopaque,
) *PangoFontMetrics;

pub extern fn pango_font_metrics_get_ascent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_get_descent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_unref(metrics: *PangoFontMetrics) void;

// ── GLib/GObject ──────────────────────────────────────────────────────────────

pub extern fn g_object_unref(object: *anyopaque) void;

// ── xcb-cursor ────────────────────────────────────────────────────────────────
// Wraps libXcursor for XCB callers. Link with: -lxcb-cursor

pub const xcb_cursor_context_t = opaque {};

pub extern fn xcb_cursor_context_new(
    conn:   *xcb_connection_t,
    screen: *anyopaque,
    ctx:    **xcb_cursor_context_t,
) c_int;

pub extern fn xcb_cursor_load_cursor(
    ctx:  *xcb_cursor_context_t,
    name: [*:0]const u8,
) u32;

pub extern fn xcb_cursor_context_free(ctx: *xcb_cursor_context_t) void;
