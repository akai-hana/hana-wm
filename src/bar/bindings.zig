//! Cairo/Pango/GLib C bindings for bar rendering.
//!
//! Leaf bindings file, on the `core/x11/xcb.zig` precedent: the
//! raw `extern` declarations live apart from the drawing logic so
//! `drawing.zig` is a layer of logic over them, not a file whose
//! first fifth is a C-header translation. Nothing outside the bar
//! drawing layer names these bindings; `drawing.zig` is their sole
//! consumer and qualifies every use through this module.

const core = @import("core");
const xcb = core.xcb;

const xcb_connection_t = xcb.xcb_connection_t;
const xcb_pixmap_t = xcb.xcb_pixmap_t;
const xcb_visualtype_t = xcb.xcb_visualtype_t;

// Declared as `pub extern fn` because library headers may not be present
// in all build environments.

// Cairo

pub const cairo_surface_t = opaque {};
pub const cairo_t = opaque {};

/// Numeric values match the C ABI; do not change them.
pub const cairo_format_t = enum(c_int) {
    ARGB32 = 0,
};

/// Pixmap must outlive the surface; destroy the surface before freeing the pixmap.
pub extern fn cairo_xcb_surface_create(
    connection: *xcb_connection_t,
    pixmap: xcb_pixmap_t,
    visual: *xcb_visualtype_t,
    width: c_int,
    height: c_int,
) ?*cairo_surface_t;

/// Used for font measurement without an X connection.
pub extern fn cairo_image_surface_create(
    format: cairo_format_t,
    width: c_int,
    height: c_int,
) ?*cairo_surface_t;

pub extern fn cairo_surface_destroy(surface: *cairo_surface_t) void;
pub extern fn cairo_surface_flush(surface: *cairo_surface_t) void;

pub extern fn cairo_create(surface: *cairo_surface_t) ?*cairo_t;
pub extern fn cairo_destroy(cr: *cairo_t) void;

pub extern fn cairo_set_source_rgba(cr: *cairo_t, red: f64, green: f64, blue: f64, alpha: f64) void;
pub extern fn cairo_move_to(cr: *cairo_t, x: f64, y: f64) void;

// Clipping, for region-scoped text (title marquee).
pub extern fn cairo_save(cr: *cairo_t) void;
pub extern fn cairo_restore(cr: *cairo_t) void;
pub extern fn cairo_rectangle(cr: *cairo_t, x: f64, y: f64, width: f64, height: f64) void;
pub extern fn cairo_clip(cr: *cairo_t) void;

// Pango

pub const PangoLayout = opaque {};
pub const PangoContext = opaque {};
pub const PangoFontDescription = opaque {};
pub const PangoFontMetrics = opaque {};
pub const PangoAttrList = opaque {};
// (22.1) PangoAttribute was opaque, which was fine while every attribute was
// created by Pango and only ever inserted whole. A foreground attribute over a
// SUB-RANGE needs its start_index/end_index set by us, so the leading fields
// (the type/kop and the two range fields) are now declared. Pango's own header
// is the authority for this layout: PangoAttributeType type; PangoAttributeFlags
// flags; guint32 start_index; guint32 end_index; -- and a color attribute's
// payload is a 4-byte PangoColor we set through the constructor, never by hand.
pub const PangoAttribute = extern struct {
    /// PangoAttributeType; only used for debugging/logging, never compared.
    attribute_type: c_int = 0,
    /// PangoAttributeFlags bitfield.
    flags: c_int = 0,
    /// Byte range into the laid-out text this attribute applies to.
    start_index: c_uint = 0,
    end_index: c_uint = 0,
};

/// Divide Pango units by pango_scale to get pixels.
pub const pango_scale: c_int = 1024;

pub const PangoEllipsizeMode = enum(c_int) {
    NONE = 0,
    END = 3,
};

pub const PangoRectangle = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
};

pub extern fn pango_cairo_create_layout(cr: *cairo_t) ?*PangoLayout;
pub extern fn pango_cairo_show_layout(cr: *cairo_t, layout: *PangoLayout) void;
pub extern fn pango_cairo_context_set_resolution(context: *PangoContext, dpi: f64) void;

pub extern fn pango_layout_set_text(layout: *PangoLayout, text: [*]const u8, length: c_int) void;
pub extern fn pango_layout_set_font_description(
    layout: *PangoLayout,
    desc: ?*PangoFontDescription,
) void;
pub extern fn pango_layout_get_context(layout: *PangoLayout) *PangoContext;
/// (22.7) Creates a fresh layout sharing `ctx`. This is what lets a text run
/// own its own layout without building a cairo surface and context per run.
pub extern fn pango_layout_new(ctx: *PangoContext) ?*PangoLayout;
/// Pass null for either dimension if not needed.
pub extern fn pango_layout_get_pixel_size(
    layout: *PangoLayout,
    width: ?*c_int,
    height: ?*c_int,
) void;
pub extern fn pango_layout_set_width(layout: *PangoLayout, width: c_int) void;
pub extern fn pango_layout_set_ellipsize(layout: *PangoLayout, ellipsize: PangoEllipsizeMode) void;
pub extern fn pango_layout_get_baseline(layout: *PangoLayout) c_int;

/// Accepts strings like `"Sans Bold 12"`.
pub extern fn pango_font_description_from_string(str: [*:0]const u8) ?*PangoFontDescription;
pub extern fn pango_font_description_copy(desc: *PangoFontDescription) ?*PangoFontDescription;
pub extern fn pango_font_description_free(desc: *PangoFontDescription) void;
pub extern fn pango_font_description_set_absolute_size(desc: *PangoFontDescription, size: f64) void;

/// Returns Pango units. Pass null for either rect if not needed.
pub extern fn pango_layout_get_extents(
    layout: *PangoLayout,
    ink_rect: ?*PangoRectangle,
    logical_rect: ?*PangoRectangle,
) void;

/// Pass null for `language` to use the default language.
pub extern fn pango_context_get_metrics(
    context: *PangoContext,
    desc: ?*PangoFontDescription,
    language: ?*anyopaque,
) *PangoFontMetrics;

pub extern fn pango_font_metrics_get_ascent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_get_descent(metrics: *PangoFontMetrics) c_int;
pub extern fn pango_font_metrics_unref(metrics: *PangoFontMetrics) void;

/// Numeric values match the C ABI; do not change them.
pub const pango_underline_t = enum(c_int) {
    NONE = 0,
    SINGLE = 1,
    DOUBLE = 2,
    LOW = 3,
    ERROR = 4,
};

/// Numeric values match the C ABI; do not change them.
pub const pango_weight_t = enum(c_int) {
    THIN = 100,
    LIGHT = 300,
    NORMAL = 400,
    MEDIUM = 500,
    SEMIBOLD = 600,
    BOLD = 700,
    ULTRABOLD = 800,
    HEAVY = 900,
};

/// Numeric values match the C ABI; do not change them.
pub const pango_style_t = enum(c_int) {
    NORMAL = 0,
    OBLIQUE = 1,
    ITALIC = 2,
};

pub extern fn pango_attr_underline_new(underline: pango_underline_t) ?*PangoAttribute;
pub extern fn pango_attr_weight_new(weight: pango_weight_t) ?*PangoAttribute;
pub extern fn pango_attr_style_new(style: pango_style_t) ?*PangoAttribute;

/// An attribute list owns its attributes; every attribute `insert`-ed must
/// NOT be freed by the caller.
/// Creates a foreground-colour attribute. (22.1)
/// Takes r/g/b in 0..65535 (Pango's scale) rather than hana's 0xRRGGBB.
pub extern fn pango_attr_foreground_new(red: u16, green: u16, blue: u16) ?*PangoAttribute;
pub extern fn pango_attr_list_new() ?*PangoAttrList;
pub extern fn pango_attr_list_insert(list: *PangoAttrList, attr: *PangoAttribute) void;
pub extern fn pango_attr_list_unref(list: *PangoAttrList) void;
pub extern fn pango_layout_set_attributes(layout: *PangoLayout, attrs: ?*PangoAttrList) void;

/// The Pango layout does NOT take ownership of the list; the list must stay
/// alive while set, and be unref'd afterwards. (22.7) A `TextRun` now owns both
/// the list and the layout it is attached to and unrefs them together in
/// `deinit`, so that lifetime is structural rather than a pairing callers have
/// to remember.

// GLib / GObject

/// Decrements the reference count. All GObject-based types in this file must
/// be freed through this function.
pub extern fn g_object_unref(object: *anyopaque) void;
