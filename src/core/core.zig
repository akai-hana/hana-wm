//! Central hub for process-wide XCB state and shared types.
//! All `undefined` globals must be initialised in main before any other module runs.

const std = @import("std");

const constants = @import("constants");
const types     = @import("types");

// Centralised to avoid repeated @cImport translation across compilation units.
pub const xcb = @cImport(@cInclude("xcb/xcb.h"));

/// X11 keysym constants. Values match <X11/keysymdef.h> (stable since X11R1).
/// Cast to xcb_keysym_t with `@intFromEnum`.
pub const XK = enum(u32) {
    BackSpace = 0xff08,
    Tab       = 0xff09,
    Return    = 0xff0d,
    Escape    = 0xff1b,
    Delete    = 0xffff,
    Left      = 0xff51,
    Up        = 0xff52,
    Right     = 0xff53,
    Down      = 0xff54,
    Home      = 0xff50,
    End       = 0xff57,
};

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
    /// Normal operation: focus follows mouse.
    none,
    /// Just spawned a window — suppress cursor focus steal.
    window_spawn,
    /// Tiling in progress — suppress cursor focus steal.
    tiling_operation,
};

/// DPI and scale factor detected at startup.
/// Defined here so modules can reference the type without importing scale
pub const DpiInfo = struct {
    dpi: f32,

    /// Computes scale factor relative to BASELINE_DPI on demand.
    pub fn scaleFactor(self: DpiInfo) f32 {
        return self.dpi / constants.BASELINE_DPI;
    }
};

// Process-wide singletons. `undefined` fields must be set by main() before use;
// behaviour is only safety-checked in Debug/ReleaseSafe builds.
pub var conn:     *xcb.xcb_connection_t = undefined;
pub var screen:   *xcb.xcb_screen_t    = undefined;
pub var root:     WindowId             = undefined;
pub var alloc:    std.mem.Allocator    = undefined;
pub var config:   types.Config         = undefined;
pub var dpi_info: DpiInfo              = .{ .dpi = 96.0 };

/// Returns true if the XCB connection is open and error-free.
pub fn isConnValid() bool {
    return xcb.xcb_connection_has_error(conn) == 0;
}
