//! Pure keysym-name parsing (libxkbcommon), no X connection, xkb_state, or XKB
//! extension setup. Isolated to keep the pure config layer (resolves binding
//! names at load time) from importing live-device-state input modules, avoiding
//! a config↔input wiring cycle.
//! Layer note: xcb-free by construction; importable from the pure layers
//! (see build.zig's layer-purity assertion). The libxkbcommon import is
//! borrowed from keymap.zig, the single translation-unit owner for that
//! header, which is itself connection-free.

const std = @import("std");

// Borrowed from the single @cImport owner rather than translated again here
// (19.8): this module and xkbcommon.zig were each compiling the same header.
const xkb = @import("keymap").xkb;

pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;

/// Keysym for `name` under case-insensitive lookup (so `"super_l"` and
/// `"Super_L"` agree), or `XKB_KEY_NoSymbol` when the name is unknown. `name`
/// may carry trailing NUL bytes; parsing stops at the first NUL.
pub fn keysymFromName(name: []const u8) u32 {
    const z = std.mem.sliceTo(name, 0);
    return xkb.xkb_keysym_from_name(z.ptr, xkb.XKB_KEYSYM_CASE_INSENSITIVE);
}

/// XKB name for `keysym` (e.g. XKB_KEY_at -> "at") into `buf`, returning a
/// slice of `buf` holding the name. Used for diagnostic messages.
pub fn keysymGetName(keysym: u32, buf: []u8) []const u8 {
    const n = xkb.xkb_keysym_get_name(keysym, buf.ptr, buf.len);
    const len: usize = if (n < 0) 0 else @min(@as(usize, @intCast(n)), buf.len);
    return buf[0..len];
}
