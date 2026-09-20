//! Pure libxkbcommon keysym-name parsing.
//!
//! Resolving a keysym from its X11 name (`"Super_L"`, `"a"`, `"Up"`, ...) is
//! a plain table lookup inside libxkbcommon: it needs no X connection, no
//! `xkb_state`, and no XKB extension setup. Living in its own module keeps
//! the pure config layer (which resolves binding names at load time) from
//! importing `xkbcommon.zig` — that module owns the live device state and the
//! XKB requests that reach for the X connection, and pulling it into config
//! is exactly the config ↔ input wiring cycle this split prevents.
//!
//! Layer note: xcb-free by construction; importable from the pure layers
//! (see build.zig's layer-purity assertion).

const std = @import("std");

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

const xkb_keysym_case_insensitive = xkb.XKB_KEYSYM_CASE_INSENSITIVE;
pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;

/// Keysym for `name` under case-insensitive lookup (so `"super_l"` and
/// `"Super_L"` agree), or `XKB_KEY_NoSymbol` when the name is unknown. `name`
/// may carry trailing NUL bytes; parsing stops at the first NUL.
pub fn keysymFromName(name: []const u8) u32 {
    const z = std.mem.sliceTo(name, 0);
    return xkb.xkb_keysym_from_name(@ptrCast(z.ptr), xkb_keysym_case_insensitive);
}
