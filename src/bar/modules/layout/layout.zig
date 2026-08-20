//! Layout icon bar segment.
//! Displays the active tiling layout symbol on the status bar.

const core = @import("core");
const types = @import("types");
const drawing = @import("drawing");
const build_options = @import("build_options");
const tiling = if (build_options.has_tiling) @import("tiling") else null;

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
    if (!core.getState().config.tiling.enabled)
        return dc.drawSegment(start_x, height, getIcon(.floating), config.scaledSegmentPadding(height), config.bg, config.fg);

    const icon = getIcon(if (build_options.has_tiling) tiling.getCurrentLayout() else .master);
    return dc.drawSegment(start_x, height, icon, config.scaledSegmentPadding(height), config.bg, config.fg);
}
