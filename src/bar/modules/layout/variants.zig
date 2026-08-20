//! Layout variants bar module.
//! Renders the active tiling layout variant as a short text string in the bar.

const core = @import("core");
const types = @import("types");

const drawing = @import("drawing");
const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else null;

/// Returns the updated x position after drawing the segment, or the original
/// start_x when tiling is disabled or no indicator is available.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    if (!core.getState().config.tiling.enabled) return start_x;
    const layout_val = if (build_options.has_tiling) tiling.getCurrentLayout() else .master;
    const variants = if (build_options.has_tiling) tiling.getLayoutVariants() else types.LayoutVariants{};
    const indicator = getIndicator(layout_val, &variants);
    if (indicator.len == 0) return start_x;
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
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
