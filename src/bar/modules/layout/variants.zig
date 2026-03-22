//! Layout variants indicator bar segment.
//!
//! Displays the 3-character variants indicator for the active tiling layout.
//! Can be placed independently from the layout icon in the bar layout config.

const core       = @import("core");
const drawing    = @import("drawing");
const has_tiling = @import("build_options").has_tiling;
const tiling     = if (has_tiling) @import("tiling") else struct {};

/// Draws the layout variants icon on the bar.
pub fn draw(dc: *drawing.DrawContext, config: core.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getStateOpt() orelse return start_x;
    const indicator = getIndicator(t_state);
    if (indicator.len == 0) return start_x;
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
}

/// Accessor for the icon of each layout's variantss
pub fn getIndicator(s: *const tiling.State) []const u8 {
    return switch (s.layout) {
        .master => switch (s.layout_variants.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },

        .monocle => switch (s.layout_variants.monocle) {
            .gaps    => ">-<",
            .gapless => "<->",
        },

        .grid => switch (s.layout_variants.grid) {
            .relaxed => "[~]",
            .rigid   => "[#]",
        },

        else => ""
    };
}
