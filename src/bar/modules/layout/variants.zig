//! Layout variants indicator bar segment
//! Displays the active tiling layout variant as a short indicator string on the bar.

const core = @import("core");
const types = @import("types");

const drawing = @import("drawing");
const tiling = @import("tiling");

/// Draws the layout variants icon on the bar.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    if (!core.config.tiling.enabled) return start_x;
    const t_state = tiling.getStateOpt() orelse return start_x;
    const indicator = getIndicator(t_state);
    if (indicator.len == 0) return start_x;
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
}

/// Accessor for the icon of each layout's variants.
pub fn getIndicator(s: *const tiling.State) []const u8 {
    return switch (s.config.layout) {
        .master => switch (s.config.layout_variants.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },

        .monocle => switch (s.config.layout_variants.monocle) {
            .gaps => ">-<",
            .gapless => "<->",
        },

        .grid => switch (s.config.layout_variants.grid) {
            .relaxed => "[~]",
            .rigid => "[#]",
        },

        else => "",
    };
}
