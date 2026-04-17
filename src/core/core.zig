//! Shared type definitions
//! Includes XCB handles, geometry, input state, DPI info, and process-wide globals.

const std = @import("std");

const constants = @import("constants");

// Importing xcb centrally and re-exporting it avoids repeated @cImport translation
// on every compilation unit that needs XCB types.
pub const xcb = @cImport(@cInclude("xcb/xcb.h"));


// X11 keysym constants
//
// Centralised here so key-handling modules reference a single definition and cannot drift.
// Values match <X11/keysymdef.h> (stable since X11R1).
pub const XK_BackSpace : xcb.xcb_keysym_t = 0xff08;
pub const XK_Tab       : xcb.xcb_keysym_t = 0xff09;
pub const XK_Return    : xcb.xcb_keysym_t = 0xff0d;
pub const XK_Escape    : xcb.xcb_keysym_t = 0xff1b;
pub const XK_Delete    : xcb.xcb_keysym_t = 0xffff;
pub const XK_Left      : xcb.xcb_keysym_t = 0xff51;
pub const XK_Right     : xcb.xcb_keysym_t = 0xff53;
pub const XK_Home      : xcb.xcb_keysym_t = 0xff50;
pub const XK_End       : xcb.xcb_keysym_t = 0xff57;

/// Type alias for XCB window identifiers.
pub const WindowId = u32;

// Core geometric type

/// Geometry snapshot used by both fullscreen and minimize.
pub const WindowGeometry = struct {
    x:            i16,
    y:            i16,
    width:        u16,
    height:       u16,
    border_width: u16,
};

/// Focus suppression reason for context-aware behavior.
pub const FocusSuppressReason = enum {
    none,             // normal operation: focus follows mouse
    window_spawn,     // just spawned a window: don't let cursor steal focus
    tiling_operation, // currently tiling: don't let cursor steal focus
};

/// DPI and scale factor detected at startup.
/// Defined here so all modules can reference the type via core without
/// importing scale. scale.zig re-exports this and populates it via detect().
pub const DpiInfo = struct {
    dpi:          f32,
    scale_factor: f32,

    /// Constructs a DpiInfo from a raw DPI value, computing scale_factor relative to BASELINE_DPI.
    pub fn fromDpi(dpi: f32) DpiInfo {
        return .{ .dpi = dpi, .scale_factor = dpi / @import("constants").BASELINE_DPI };
    }
};

// Process-wide singletons, initialised in main before any other module runs.
pub var conn:     *xcb.xcb_connection_t   = undefined;
pub var screen:   *xcb.xcb_screen_t       = undefined;
pub var root:     WindowId                = undefined;
pub var alloc:    std.mem.Allocator       = undefined;
pub var config:   @import("types").Config = undefined;
pub var dpi_info: DpiInfo                 = .{ .dpi = 96.0, .scale_factor = 1.0 };
