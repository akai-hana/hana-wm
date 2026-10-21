//! Title-segment vocabulary: the stable per-render context, the per-window
//! entry record, and the per-frame snapshot shared by the title renderer,
//! geom.zig's hit-test, and the bar. Lives as a private sibling of
//! `title.zig` (same as geom.zig/carousel.zig): the build registry leaves it
//! alone.

const std = @import("std");
const drawing = @import("drawing");
const types = @import("types");
const bar_config = @import("bar_config");
const model = @import("model");

/// Stable per-call rendering context: geometry and draw state. Carries no X
/// connection: the title draw had one only to call
/// `hz.ensureRefreshRateDetected`, which boot primes at startup, and a
/// render that mutates global detection state is a phase violation.
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: bar_config.Config,
    height: u16,
    start_x: u16,
    width: u16,
};

/// One current-workspace window as the title segment sees it: id, borrowed
/// title, and the sync truth-rect for the frame. The whole record travels as
/// one value, so the snapshot cannot hand the draw one array's length and
/// another's contents.
pub const TitleEntry = struct {
    window: u32,
    /// Borrowed from the WM-owned title cache (window_facts.peekTitle); the
    /// bar refreshes every entry each frame before the draw.
    title: []const u8,
    geom: ?model.Rect,
};

/// Per-frame volatile snapshot captured before drawing.
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    /// The current workspace's windows in frame order.
    entries: []const TitleEntry,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),
};
