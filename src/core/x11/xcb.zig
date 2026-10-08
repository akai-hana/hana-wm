//! XCB C header translation and protocol aliases/casts shared across x11 modules.
//! Single @cImport of xcb/xcbext/randr/xkb; leaf layer so other x11 modules name
//! protocol here rather than through core.

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    // Provides xcb_poll_for_reply, used by the x11 request module's poll-first reply collection.
    @cInclude("xcb/xcbext.h");
    // Provides randr refresh-rate detection used by display/hz.zig and bar pacing.
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
