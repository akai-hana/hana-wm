//! Layout icon segment — shows the current tiling layout symbol.
//! For the variants indicator see variantss.zig.

const core          = @import("core");
const drawing       = @import("drawing");
const build_options = @import("build_options");
const tiling        = if (build_options.has_tiling) @import("tiling") else struct {};

/// Returns the icon string for the given layout.
/// Uses anytype so this function is only instantiated when tiling is present,
/// keeping the no-tiling build from trying to resolve tiling.Layout.
pub fn getIcon(layout: anytype) []const u8 {
    return switch (layout) {
        .master    => "[]=",
        .monocle   => "[M]",
        .grid      => "[+]",
        .fibonacci => "[@]",
        .floating  => "><>",
    };
}

pub fn draw(dc: *drawing.DrawContext, config: core.BarConfig, height: u16, start_x: u16) !u16 {
    if (comptime build_options.has_tiling) {
        const t_state = tiling.getStateOpt() orelse return start_x;
        const icon    = getIcon(t_state.layout);
        return dc.drawSegment(start_x, height, icon, config.scaledSegmentPadding(height), config.bg, config.fg);
    }
    // Without tiling all windows are floating by definition.
    return dc.drawSegment(start_x, height, "><>", config.scaledSegmentPadding(height), config.bg, config.fg);
}
