//! Layout variants indicator bar segment
//! Displays the active tiling layout variant as a short indicator string on the bar.

const build = @import("build_options");

const core  = @import("core");
const types = @import("types");

const drawing = @import("drawing");
const tiling  = if (build.has_tiling) @import("tiling");

/// Draws the layout variants icon on the bar.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    if (!build.has_tiling) return start_x;
    const t_state = tiling.getStateOpt() orelse return start_x;
    const indicator = getIndicator(t_state);
    if (indicator.len == 0) return start_x;
    return dc.drawSegment(start_x, height, indicator, config.scaledSegmentPadding(height), config.bg, config.fg);
}

/// Accessor for the icon of each layout's variants.
/// Uses anytype so this function is only instantiated when tiling is present,
/// keeping the no-tiling build from trying to resolve tiling.State.
pub fn getIndicator(s: anytype) []const u8 {
    return switch (s.config.layout) {
        .master => switch (s.config.layout_variants.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },

        .monocle => switch (s.config.layout_variants.monocle) {
            .gaps    => ">-<",
            .gapless => "<->",
        },

        .grid => switch (s.config.layout_variants.grid) {
            .relaxed => "[~]",
            .rigid   => "[#]",
        },

        else => ""
    };
}
