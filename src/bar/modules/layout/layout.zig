//! Layout icon bar segment
//! Draws the current tiling layout symbol on the status bar.

const core    = @import("core");
const types   = @import("types");
const drawing = @import("drawing");
const build   = @import("build_options");
const tiling  = if (build.has_tiling) @import("tiling");

/// Returns the icon string for the given layout.
/// Uses anytype so this function is only instantiated when tiling is present,
/// keeping the no-tiling build from trying to resolve tiling.Layout.
pub fn getIcon(layout: anytype) []const u8 {
    return switch (layout) {
        .master    => "[]=",
        .monocle   => "[M]",
        .grid      => "[+]",
        .fibonacci => "[@]",
        .scroll    => "[|]",
        .leaf      => "BSP",
        .floating  => "><>",
    };
}

/// Draws the layout icon on the bar. Returns the x position after the drawn segment.
pub fn draw(dc: *drawing.DrawContext, config: types.BarConfig, height: u16, start_x: u16) !u16 {
    // Without tiling all windows are floating by definition.
    if (!build.has_tiling)
        return dc.drawSegment(start_x, height, "><>", config.scaledSegmentPadding(height), config.bg, config.fg);

    const t_state = tiling.getStateOpt() orelse return start_x;
    const icon    = getIcon(t_state.layout);
    return dc.drawSegment(start_x, height, icon, config.scaledSegmentPadding(height), config.bg, config.fg);
}
