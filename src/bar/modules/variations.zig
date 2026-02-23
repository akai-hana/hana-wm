//! Layout variation indicator bar segment.
//!
//! Displays the 3-character variation indicator for the active tiling layout.
//! Can be placed independently from the layout icon in the bar layout config,
//! e.g. in [bar.layout.left], [bar.layout.center], or [bar.layout.right].
//!
//! Available segment name: "variations"

const defs    = @import("defs");
const drawing = @import("drawing");
const tiling  = @import("tiling");

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;
    const indicator = tiling.getVariationIndicator(t_state);
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
}
