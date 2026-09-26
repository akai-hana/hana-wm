//! Single xcb C header translation, plus the aliases and casts every x11
//! module needs to speak the protocol.
//! Shared by all modules to avoid duplicate @cImport translations, including
//! modules outside core's dependency chain. This is the x11 layer's leaf: the
//! rest of `x11/` names the protocol through here and never through `core`,
//! which keeps the layer a DAG root (core re-exports these decls upward).

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    // Provides xcb_poll_for_reply, used by the x11 request module's poll-first reply collection.
    @cInclude("xcb/xcbext.h");
    // Provides randr refresh-rate detection used by display/dpi.zig and bar pacing.
    @cInclude("xcb/randr.h");
    // Provides xcb_xkb_id (XKB extension opcode lookup) and
    // xcb_xkb_per_client_flags, used to enable detectable auto-repeat so a held
    // key's autorepeat stops emitting interleaved KeyRelease (see
    // XkbState.init).
    @cInclude("xcb/xkb.h");
});

pub const Connection = *xcb.xcb_connection_t;
pub const Screen = *xcb.xcb_screen_t;

/// Narrows a queued `*anyopaque` event to its concrete xcb event type.
/// Lives here, beside the cImport, because the cast is only meaningful
/// against the protocol's own event structs.
pub inline fn eventCast(comptime T: type, event: *anyopaque) T {
    return @ptrCast(@alignCast(event));
}
