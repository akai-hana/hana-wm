//! Single xcb C header translation.
//! Shared by all modules to avoid duplicate @cImport translations, including modules outside core's dependency chain.

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    // Provides xcb_poll_for_reply, used by core/x11/wire.zig's poll-first reply collection.
    @cInclude("xcb/xcbext.h");
    // Provides randr refresh-rate detection used by scale.zig and bar pacing.
    @cInclude("xcb/randr.h");
    // Provides xcb_xkb_id for the XKB extension opcode lookup, used to send
    // XkbSetDetectableAutoRepeat so a held key's autorepeat stops emitting
    // interleaved KeyRelease (see XkbState.init).
    @cInclude("xcb/xkb.h");
});
