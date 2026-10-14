//! Title-segment vocabulary: the stable per-render context, the per-window
//! entry record, and the per-frame snapshot shared by the title renderer,
//! geom.zig's hit-test, and the bar (state.zig stores the entries,
//! segment.zig's `DrawCtx` carries the filled slots).
//!
//! It lived in bar/segment.zig with the vocabulary every segment shares, but
//! only the title render path names these types. A private sibling of
//! `title.zig` in the `modules/` tree -- same arrangement as geom.zig and
//! carousel.zig, and for the same reason: the build registry leaves it alone.

const std = @import("std");
const drawing = @import("drawing");
const types = @import("types");
const model = @import("model");

// The title segment's geometry -- its window list, the pixel-perfect tiling
// shared by its draw and the bar's hit-test -- is not shared segment
// vocabulary. It lives in `geom.zig`, next to the only thing that
// renders it.

/// Stable per-call rendering context: geometry and draw state. It carries no
/// X connection: the title draw had one only to call
/// `hz.ensureRefreshRateDetected`, which boot (`main`) primes at startup, and
/// a render that mutates global detection state is a phase violation.
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
};

/// One current-workspace window as the title segment sees it: id, borrowed
/// title, and the sync truth-rect for the frame. The AoS replacement for the
/// three parallel arrays (`frame.wins` / `titles_buf` / `geoms_buf`, exposed
/// as `current_ws_wins`/`titles`/`geoms`) that shared only an index -- a
/// window's whole record now travels as one value, so the snapshot cannot
/// hand the draw one array's length and another's contents.
pub const TitleEntry = struct {
    window: u32,
    /// Borrowed from the WM-owned title cache (wincache.peekTitle); the bar
    /// refreshes every entry each frame before the draw.
    title: []const u8,
    geom: ?model.Rect,
};

/// Per-frame volatile snapshot captured before drawing.
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    /// The current workspace's windows in frame order (see TitleEntry).
    entries: []const TitleEntry,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),
};
