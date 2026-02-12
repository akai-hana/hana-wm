//! C bindings for Cairo and Pango
//! Manual extern declarations for better compile times and control (and because @cImport gave me lots of trouble)
//! XCB types do come from defs.zig via @cImport

const defs = @import("defs");

// XCB types referenced in Cairo extern declarations below
const xcb_connection_t = defs.xcb.xcb_connection_t;
const xcb_drawable_t   = defs.xcb.xcb_drawable_t;
const xcb_visualtype_t = defs.xcb.xcb_visualtype_t;

// CAIRO TYPES AND FUNCTIONS //

pub const cairo_surface_t = opaque {};
pub const cairo_t = opaque {};

//TODO: the purpose of this function is a bit unclear
pub const cairo_format_t = enum(c_int) {
    ARGB32 = 0,
    RGB24 = 1,
    A8 = 2,
    A1 = 3,
    RGB16_565 = 4,
    RGB30 = 5,
};

// Surface creation and destruction
pub extern fn cairo_xcb_surface_create(
    connection: *xcb_connection_t,
    drawable: xcb_drawable_t,
    visual: *xcb_visualtype_t,
    width: c_int,
    height: c_int,
) ?*cairo_surface_t;

pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;
pub extern fn cairo_surface_flush(surface: *cairo_surface_t) void;

// Surface data access for manual alpha channel manipulation
pub extern fn cairo_image_surface_get_data(surface: *cairo_surface_t) [*]u8;
pub extern fn cairo_image_surface_get_width(surface: *cairo_surface_t) c_int;
pub extern fn cairo_image_surface_get_height(surface: *cairo_surface_t) c_int;
pub extern fn cairo_image_surface_get_stride(surface: *cairo_surface_t) c_int;
pub extern fn cairo_surface_mark_dirty(surface: *cairo_surface_t) void;

// Context creation and destruction
pub extern fn cairo_create(surface: *cairo_surface_t) ?*cairo_t;
pub extern fn cairo_destroy(cr: *cairo_t) void;

// Cairo operator modes enum
pub const cairo_operator_t = enum(c_int) {
    CLEAR = 0,
    SOURCE = 1,
    OVER = 2,
    IN = 3,
    OUT = 4,
    ATOP = 5,
    DEST = 6,
    DEST_OVER = 7,
    DEST_IN = 8,
    DEST_OUT = 9,
    DEST_ATOP = 10,
    XOR = 11,
    ADD = 12,
    SATURATE = 13,
    MULTIPLY = 14,
    SCREEN = 15,
    OVERLAY = 16,
    DARKEN = 17,
    LIGHTEN = 18,
    COLOR_DODGE = 19,
    COLOR_BURN = 20,
    HARD_LIGHT = 21,
    SOFT_LIGHT = 22,
    DIFFERENCE = 23,
    EXCLUSION = 24,
    HSL_HUE = 25,
    HSL_SATURATION = 26,
    HSL_COLOR = 27,
    HSL_LUMINOSITY = 28,
};

// Drawing operations
// TODO: can the "f64"s be made smaller somehow to use less memory?
pub extern fn cairo_set_source_rgb(cr: *cairo_t, red: f64, green: f64, blue: f64) void;
pub extern fn cairo_set_source_rgba(cr: *cairo_t, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern fn cairo_rectangle(cr: *cairo_t, x: f64, y: f64, width: f64, height: f64) void;
pub extern fn cairo_fill(cr: *cairo_t) void;
pub extern fn cairo_move_to(cr: *cairo_t, x: f64, y: f64) void;
pub extern fn cairo_line_to(cr: *cairo_t, x: f64, y: f64) void;
pub extern fn cairo_stroke(cr: *cairo_t) void;
pub extern fn cairo_set_line_width(cr: *cairo_t, width: f64) void;

// State management (save/restore)
pub extern fn cairo_save(cr: *cairo_t) void;
pub extern fn cairo_restore(cr: *cairo_t) void;

// Operator and paint (transparency clearing)
pub extern fn cairo_set_operator(cr: *cairo_t, op: cairo_operator_t) void;
pub extern fn cairo_paint(cr: *cairo_t) void;

// PANGO TYPES AND CONSTANTS //

pub const PangoLayout = opaque {};
pub const PangoContext = opaque {};
pub const PangoFontDescription = opaque {};
pub const PangoFontMetrics = opaque {};
pub const PangoLayoutLine = opaque {};

//TODO: is this really necessary?
pub const PANGO_SCALE: c_int = 1024;

pub const PangoEllipsizeMode = enum(c_int) {
    NONE = 0,
    START = 1,
    MIDDLE = 2,
    END = 3,
};

pub const PangoRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

// Pango-Cairo Functions

pub extern fn pango_cairo_create_layout(cr: *cairo_t) ?*PangoLayout;
pub extern fn pango_cairo_show_layout(cr: *cairo_t, layout: *PangoLayout) void;
pub extern fn pango_cairo_context_set_resolution(context: *PangoContext, dpi: f64) void;

// PANGO LAYOUT FUNCTIONS //

//TODO: i dont quite get all of this. what does all of this below do?
pub extern fn pango_layout_set_text(layout: *PangoLayout, text: [*]const u8, length: c_int) void;
pub extern fn pango_layout_set_markup(layout: *PangoLayout, markup: [*]const u8, length: c_int) void;
pub extern fn pango_layout_set_font_description(layout: *PangoLayout, desc: ?*PangoFontDescription) void;
pub extern fn pango_layout_get_context(layout: *PangoLayout) *PangoContext;
pub extern fn pango_layout_get_pixel_size(layout: *PangoLayout, width: *c_int, height: *c_int) void;
pub extern fn pango_layout_get_pixel_extents(layout: *PangoLayout, ink_rect: ?*PangoRectangle, logical_rect: ?*PangoRectangle) void;
pub extern fn pango_layout_set_width(layout: *PangoLayout, width: c_int) void;
pub extern fn pango_layout_set_ellipsize(layout: *PangoLayout, ellipsize: PangoEllipsizeMode) void;
pub extern fn pango_layout_get_baseline(layout: *PangoLayout) c_int;

// Functions for baselineYForText to get actual font metrics
pub extern fn pango_layout_get_line_readonly(layout: *PangoLayout, line: c_int) ?*const PangoLayoutLine;
pub extern fn pango_layout_line_get_pixel_extents(line: *const PangoLayoutLine, ink_rect: ?*PangoRectangle, logical_rect: ?*PangoRectangle) void;

// Pango Font Functions

pub extern fn pango_font_description_from_string(str: [*:0]const u8) ?*PangoFontDescription;
pub extern fn pango_font_description_free(desc: *PangoFontDescription) void;
pub extern fn pango_font_description_set_size(desc: *PangoFontDescription, size: c_int) void;

pub extern fn pango_context_get_metrics(
    context: *PangoContext,
    desc: ?*PangoFontDescription,
    language: ?*anyopaque,
) *PangoFontMetrics;

pub extern fn pango_font_metrics_get_ascent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_get_descent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_unref(metrics: *PangoFontMetrics) void;

// GLib/GObject Functions (for Pango)

pub extern fn g_object_unref(object: *anyopaque) void;

