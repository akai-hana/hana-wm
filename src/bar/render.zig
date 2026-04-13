
//! Manual C bindings for the bar's rendering stack: Cairo, Pango, and GLib.
//!
//! Cairo and Pango are bound together because `pango_cairo_*` functions
//! cross the boundary between the two libraries.  GLib's `g_object_unref`
//! is included here because it is the correct way to release Pango objects
//! that carry a GObject reference count.
//!
//! XCB types are imported from `core` rather than re-declared here.
//! xcb-cursor bindings live in `window/cursor_bindings.zig` — they serve
//! the window/floating layer, not the rendering stack.

const core    = @import("core");
    const xcb = core.xcb;

const xcb_connection_t = xcb.xcb_connection_t;
const xcb_pixmap_t     = xcb.xcb_pixmap_t;
const xcb_visualtype_t = xcb.xcb_visualtype_t;

// Cairo 

pub const cairo_surface_t = opaque {};
pub const cairo_t         = opaque {};

/// Pixel formats understood by Cairo surfaces.
/// Numeric values match the C ABI and must not be changed.
pub const cairo_format_t = enum(c_int) {
    ARGB32    = 0,
    RGB24     = 1,
    A8        = 2,
    A1        = 3,
    RGB16_565 = 4,
    RGB30     = 5,
};

/// Compositing operators used during painting.
/// Trimmed to the two operators Hana actually uses (CLEAR, OVER);
/// the full C enum has 29 variants.  Numeric values are unchanged.
pub const cairo_operator_t = enum(c_int) {
    CLEAR = 0,
    OVER  = 2,
};

/// Creates a Cairo surface backed by an XCB pixmap.
/// The pixmap must outlive the surface; destroy the surface before freeing it.
pub extern fn cairo_xcb_surface_create(
    connection: *xcb_connection_t,
    pixmap:     xcb_pixmap_t,
    visual:     *xcb_visualtype_t,
    width:      c_int,
    height:     c_int,
) ?*cairo_surface_t;

/// Creates an in-memory image surface with no X connection.
/// Used for off-screen font measurement before committing to the screen.
pub extern fn cairo_image_surface_create(
    format: cairo_format_t,
    width:  c_int,
    height: c_int,
) ?*cairo_surface_t;

pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;
/// Flushes pending drawing operations, ensuring the pixmap reflects all paints.
pub extern fn cairo_surface_flush(surface: *cairo_surface_t) void;

pub extern fn cairo_create(surface: *cairo_surface_t) ?*cairo_t;
pub extern fn cairo_destroy(cr: *cairo_t) void;

pub extern fn cairo_set_source_rgba(cr: *cairo_t, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern fn cairo_move_to(cr: *cairo_t, x: f64, y: f64) void;
pub extern fn cairo_set_operator(cr: *cairo_t, op: cairo_operator_t) void;
pub extern fn cairo_paint(cr: *cairo_t) void;

/// Saves the current Cairo graphics state onto an internal stack.
/// Used by the carousel text scroller to isolate clip regions.
pub extern fn cairo_save(cr: *cairo_t) void;
/// Restores the most recently saved graphics state, removing the active clip.
pub extern fn cairo_restore(cr: *cairo_t) void;
pub extern fn cairo_rectangle(cr: *cairo_t, x: f64, y: f64, width: f64, height: f64) void;
pub extern fn cairo_clip(cr: *cairo_t) void;

// Pango 

pub const PangoLayout          = opaque {};
pub const PangoContext         = opaque {};
pub const PangoFontDescription = opaque {};
pub const PangoFontMetrics     = opaque {};

/// Conversion factor between Pango's internal fixed-point units and pixels.
/// Divide a Pango unit value by PANGO_SCALE to get pixels.
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

/// Creates a PangoLayout pre-configured to render onto the given Cairo context.
pub extern fn pango_cairo_create_layout(cr: *cairo_t) ?*PangoLayout;
/// Renders the layout's current text onto the Cairo context at the current point.
pub extern fn pango_cairo_show_layout(cr: *cairo_t, layout: *PangoLayout) void;
/// Sets the DPI used for font resolution on this Pango context.
pub extern fn pango_cairo_context_set_resolution(context: *PangoContext, dpi: f64) void;

pub extern fn pango_layout_set_text(layout: *PangoLayout, text: [*]const u8, length: c_int) void;
pub extern fn pango_layout_set_font_description(layout: *PangoLayout, desc: ?*PangoFontDescription) void;
pub extern fn pango_layout_get_context(layout: *PangoLayout) *PangoContext;
/// Writes the layout's pixel dimensions into `width` and/or `height`.
/// Pass null for either dimension if it is not needed.
pub extern fn pango_layout_get_pixel_size(layout: *PangoLayout, width: ?*c_int, height: ?*c_int) void;
pub extern fn pango_layout_set_width(layout: *PangoLayout, width: c_int) void;
pub extern fn pango_layout_set_ellipsize(layout: *PangoLayout, ellipsize: PangoEllipsizeMode) void;
pub extern fn pango_layout_get_baseline(layout: *PangoLayout) c_int;

/// Parses a Pango font description string (e.g. `"Sans Bold 12"`).
pub extern fn pango_font_description_from_string(str: [*:0]const u8) ?*PangoFontDescription;
pub extern fn pango_font_description_copy(desc: *PangoFontDescription) ?*PangoFontDescription;
pub extern fn pango_font_description_free(desc: *PangoFontDescription) void;
pub extern fn pango_font_description_get_size(desc: *PangoFontDescription) c_int;
pub extern fn pango_font_description_get_size_is_absolute(desc: *PangoFontDescription) c_int;
pub extern fn pango_font_description_set_size(desc: *PangoFontDescription, size: c_int) void;
pub extern fn pango_font_description_set_absolute_size(desc: *PangoFontDescription, size: f64) void;

/// Returns ink and logical extents of the layout in Pango units.
/// Pass null for either rect if it is not needed.
pub extern fn pango_layout_get_extents(
    layout:       *PangoLayout,
    ink_rect:     ?*PangoRectangle,
    logical_rect: ?*PangoRectangle,
) void;

/// Returns font metrics for the given description and context.
/// Pass null for `language` to use the default language.
pub extern fn pango_context_get_metrics(
    context:  *PangoContext,
    desc:     ?*PangoFontDescription,
    language: ?*anyopaque,
) *PangoFontMetrics;

pub extern fn pango_font_metrics_get_ascent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_get_descent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_unref(metrics: *PangoFontMetrics) void;

// GLib / GObject 

/// Decrements the GObject reference count of `object`, freeing it when it
/// reaches zero.  Used to release PangoLayout and other GObject-based types.
pub extern fn g_object_unref(object: *anyopaque) void;
