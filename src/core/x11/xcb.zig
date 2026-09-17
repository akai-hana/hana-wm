//! Single xcb C header translation.
//! Shared by all modules to avoid duplicate @cImport translations, including
//! modules outside core's dependency chain.

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    // Provides xcb_poll_for_reply, used by the x11 wire module's poll-first reply collection.
    @cInclude("xcb/xcbext.h");
    // Provides randr refresh-rate detection used by scale.zig and bar pacing.
    @cInclude("xcb/randr.h");
    // Provides xcb_xkb_id (XKB extension opcode lookup) and
    // xcb_xkb_per_client_flags, used to enable detectable auto-repeat so a held
    // key's autorepeat stops emitting interleaved KeyRelease (see
    // XkbState.init).
    @cInclude("xcb/xkb.h");
});
