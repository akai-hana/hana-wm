//! Central hub for process-wide XCB state and shared types.
//! All `undefined` globals must be initialised in main before any other module runs.

const std = @import("std");

const constants = @import("constants");
const types     = @import("types");

// Centralised to avoid repeated @cImport translation across compilation units.
pub const xcb = @cImport(@cInclude("xcb/xcb.h"));

// X11 keysym constants
// Values match <X11/keysymdef.h> (stable since X11R1).
pub const XK_BackSpace : xcb.xcb_keysym_t = 0xff08;
pub const XK_Tab       : xcb.xcb_keysym_t = 0xff09;
pub const XK_Return    : xcb.xcb_keysym_t = 0xff0d;
pub const XK_Escape    : xcb.xcb_keysym_t = 0xff1b;
pub const XK_Delete    : xcb.xcb_keysym_t = 0xffff;
pub const XK_Left      : xcb.xcb_keysym_t = 0xff51;
pub const XK_Up        : xcb.xcb_keysym_t = 0xff52;
pub const XK_Right     : xcb.xcb_keysym_t = 0xff53;
pub const XK_Down      : xcb.xcb_keysym_t = 0xff54;
pub const XK_Home      : xcb.xcb_keysym_t = 0xff50;
pub const XK_End       : xcb.xcb_keysym_t = 0xff57;

/// Equivalent to xcb.xcb_window_t (uint32_t); named for readability.
pub const WindowId = u32;

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
/// Defined here so modules can reference the type without importing scale
pub const DpiInfo = struct {
    dpi:          f32,
    scale_factor: f32,

    /// Computes scale_factor relative to BASELINE_DPI.
    pub fn fromDpi(dpi: f32) DpiInfo {
        return .{ .dpi = dpi, .scale_factor = dpi / constants.BASELINE_DPI };
    }
};

// Process-wide singletons. `undefined` fields must be set by main() before use;
// behaviour is only safety-checked in Debug/ReleaseSafe builds.
pub var conn:     *xcb.xcb_connection_t = undefined;
pub var screen:   *xcb.xcb_screen_t    = undefined;
pub var root:     WindowId             = undefined;
pub var alloc:    std.mem.Allocator    = undefined;
pub var config:   types.Config         = undefined;
pub var dpi_info: DpiInfo              = .{ .dpi = 96.0, .scale_factor = 1.0 };

/// Returns true if the XCB connection is open and error-free.
pub fn isConnValid() bool {
    return xcb.xcb_connection_has_error(conn) == 0;
}
