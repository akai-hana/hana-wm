//! Layout variants bar module.
//! Renders the active tiling layout variant as a short text string in the bar.

const core = @import("core");
const types = @import("types");

const drawing = @import("drawing");
const pipeline = @import("pipeline");
const build_options = @import("build_options");

// Last-measured drawn width, read by segment.naturalWidth for the row
// reservation (see the matching note in layout.zig). 0 when the segment
// rendered nothing (tiling disabled, or the active layout has no variants),
// so the non-dirty advance path leaves no phantom 60px hole on those
// layouts.
var cached_width: u16 = 0;

pub fn getCachedWidth() u16 {
    return cached_width;
}

/// Drops the measured width; next draw() re-measures (config reload path).
pub fn invalidate() void {
    cached_width = 0;
}

/// Returns the updated x position after drawing the segment, or the original
/// start_x when tiling is disabled or no indicator is available.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    if (!core.getState().config.tiling.enabled) {
        cached_width = 0;
        return start_x;
    }
    const layout_val = if (build_options.has_tiling) pipeline.getCurrentLayout() else .master;
    const variants = if (build_options.has_tiling) @import("core").layoutVariants() else types.LayoutVariants{};
    const indicator = getIndicator(layout_val, &variants);
    if (indicator.len == 0) {
        cached_width = 0;
        return start_x;
    }
    const end_x = try dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
    cached_width = end_x - start_x;
    return end_x;
}

fn getIndicator(layout: types.Layout, v: *const types.LayoutVariants) []const u8 {
    return switch (layout) {
        .master => switch (v.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },

        .monocle => switch (v.monocle) {
            .gaps => ">-<",
            .gapless => "<->",
        },

        .grid => switch (v.grid) {
            .relaxed => "[~]",
            .rigid => "[#]",
        },

        else => "",
    };
}
