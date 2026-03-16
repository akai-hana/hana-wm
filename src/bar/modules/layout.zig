//! Layout icon segment — shows the current tiling layout symbol.
//! For the variation indicator see variations.zig.

const core    = @import("core");
const drawing = @import("drawing");
const tiling  = @import("tiling");

const layout_icons = [_][]const u8{ "[]=", "[M]", "[+]", "[@]" };

pub fn draw(dc: *drawing.DrawContext, config: core.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getStateOpt() orelse return start_x;
    const icon    = layout_icons[@min(@intFromEnum(t_state.layout), layout_icons.len - 1)];
    return dc.drawSegment(start_x, height, icon, config.scaledSegmentPadding(height), config.bg, config.fg);
}
