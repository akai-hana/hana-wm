//! Single translation of the xcb C headers, shared by every module.
//!
//! Centralized here (rather than in core.zig) so modules that must stay free
//! of a dependency on core, like constants.zig, which is imported by
//! core's own dependency chain, can still reference the one xcb namespace
//! instead of producing a second, byte-identical @cImport translation.
//! core.zig re-exports this as `pub const xcb` for modules that already
//! import core.

pub const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xcbext.h"); // xcb_poll_for_reply, bench probe (src/test/bench.zig)
    @cInclude("xcb/randr.h"); // Refresh-rate detection for the carousel (scale.zig).
});
