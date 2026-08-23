//! Single xcb C header translation.
//! Shared by all modules to avoid duplicate @cImport translations, including modules outside core's dependency chain.

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    // Provides xcb_poll_for_reply, used by the bench probe in src/test/bench.zig.
    @cInclude("xcb/xcbext.h");
    // Provides randr refresh-rate detection used by scale.zig and bar pacing.
    @cInclude("xcb/randr.h");
});
