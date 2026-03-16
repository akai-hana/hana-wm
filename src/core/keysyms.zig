//! X11 keysym constants shared across the WM.
//!
//! Centralised so vim.zig, drun.zig, and any future key-handling
//! modules reference a single definition and cannot drift.
//!
//! Values match <X11/keysymdef.h> (stable since X11R1).

const xcb = @import("core").xcb;

pub const XK_BackSpace : xcb.xcb_keysym_t = 0xff08;
pub const XK_Tab       : xcb.xcb_keysym_t = 0xff09;
pub const XK_Return    : xcb.xcb_keysym_t = 0xff0d;
pub const XK_Escape    : xcb.xcb_keysym_t = 0xff1b;
pub const XK_Delete    : xcb.xcb_keysym_t = 0xffff;
pub const XK_Left      : xcb.xcb_keysym_t = 0xff51;
pub const XK_Right     : xcb.xcb_keysym_t = 0xff53;
pub const XK_Home      : xcb.xcb_keysym_t = 0xff50;
pub const XK_End       : xcb.xcb_keysym_t = 0xff57;
