//! Shared type definitions
//! Includes XCB handles, geometry, input state, DPI info, and process-wide globals.

const std = @import("std");

// On every @cImport, C code has to be translated to Zig on every compilation.
// That's why importing xcb here, and then making other files import it
// through this file is a tiny bit more efficient.
pub const xcb = @cImport(@cInclude("xcb/xcb.h"));

// Modifier masks
//
// Must be u16 per XCB API; widening to u32 breaks xcb_grab_key.
// Centralised here alongside Keybind so config parsers, input handling,
// and keybinding matching all share a single definition.
pub const MOD_SHIFT:    u16 = xcb.XCB_MOD_MASK_SHIFT;
pub const MOD_CAPSLOCK: u16 = xcb.XCB_MOD_MASK_LOCK;
pub const MOD_CONTROL:  u16 = xcb.XCB_MOD_MASK_CONTROL;
pub const MOD_ALT:      u16 = xcb.XCB_MOD_MASK_1;
pub const MOD_NUMLOCK:  u16 = xcb.XCB_MOD_MASK_2;
pub const MOD_SUPER:    u16 = xcb.XCB_MOD_MASK_4;

/// The only modifier bits the WM uses for keybinding matching.
/// Strips lock-key and pointer-button noise from raw event modifier state.
pub const MOD_MASK_RELEVANT: u16 = MOD_SHIFT | MOD_CONTROL | MOD_ALT | MOD_SUPER;

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

    pub fn fromDpi(dpi: f32) DpiInfo {
        const baseline_dpi: f32 = 96.0;
        return .{ .dpi = dpi, .scale_factor = dpi / baseline_dpi };
    }
};

pub var conn:     *xcb.xcb_connection_t   = undefined;
pub var screen:   *xcb.xcb_screen_t       = undefined;
pub var root:     WindowId                = undefined;
pub var alloc:    std.mem.Allocator       = undefined;
pub var config:   @import("types").Config = undefined;
pub var dpi_info: DpiInfo                 = .{ .dpi = 96.0, .scale_factor = 1.0 };
