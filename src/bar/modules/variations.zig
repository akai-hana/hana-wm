//! Layout variation indicator bar segment.
//!
//! Displays the 3-character variation indicator for the active tiling layout.
//! Can be placed independently from the layout icon in the bar layout config.

const core    = @import("core");
const drawing = @import("drawing");
const tiling  = @import("tiling");

pub fn getIndicator(s: *const tiling.State) []const u8 {
    return switch (s.layout) {
        .master => switch (s.layout_variations.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },
        .monocle => switch (s.layout_variations.monocle) {
            .gapless => "<->",
            .gaps    => ">-<",
        },
        .grid => switch (s.layout_variations.grid) {
            .rigid   => "[#]",
            .relaxed => "[~]",
        },
        .fibonacci => &s.fibonacci_indicator,
    };
}

pub fn draw(dc: *drawing.DrawContext, config: core.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getStateOpt() orelse return start_x;
    const indicator = getIndicator(t_state);
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
}
