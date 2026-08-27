//! Layout icon bar segment.
//! Displays the active tiling layout symbol on the status bar.

const core = @import("core");
const types = @import("types");
const drawing = @import("drawing");
const pipeline = @import("pipeline");
const build_options = @import("build_options");

// Reserved row width (moved here from bar.zig — width policy belongs to
// the segment that owns the pixels).
//
// This is the ACTUAL drawn width from the last render, not a constant:
// bar.zig advances x by the reserved width on non-dirty frames, so any
// mismatch between the reservation and what was really painted makes every
// downstream segment (title included) jump on partial redraws. The icon
// renders at its measured text width once per frame, so caching that number
// here keeps reserved == painted and the row layout stable.
var cached_width: u16 = 0;

/// Last-measured drawn width, read by segment.naturalWidth for the row
/// reservation (0 until the first draw).
pub fn getCachedWidth() u16 {
    return cached_width;
}

/// Drops the measured width; next draw() re-measures (config reload path).
pub fn invalidate() void {
    cached_width = 0;
}

fn getIcon(layout: types.Layout) []const u8 {
    return switch (layout) {
        .master => "[]=",
        .monocle => "[M]",
        .grid => "[+]",
        .fibonacci => "[@]",
        .scroll => "[|]",
        .leaf => "BSP",
        .floating => "><>",
    };
}

/// Returns the x coordinate immediately after the drawn segment.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    // Without tiling all windows are floating by definition.
    const icon = if (!core.getState().config.tiling.enabled)
        getIcon(.floating)
    else
        getIcon(if (build_options.has_tiling) pipeline.getCurrentLayout() else .floating);
    const end_x = try dc.drawSegment(start_x, height, icon, config.scaledSegmentPadding(height), config.bg, config.fg);
    cached_width = end_x - start_x;
    return end_x;
}
