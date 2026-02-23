//! Layout icon segment — shows the current tiling layout symbol.
//! For the variation indicator see variations.zig.

const defs    = @import("defs");
const drawing = @import("drawing");
const tiling  = @import("tiling");

const layout_icons = [_][]const u8{ "[]=", "[M]", "[+]", "[@]" };

/// Draws the current layout icon at `start_x`, returning the next X position.
pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;
    const icon    = layout_icons[@min(@intFromEnum(t_state.layout), layout_icons.len - 1)];
    return dc.drawSegment(start_x, height, icon, config.scaledSegmentPadding(height), config.bg, config.fg);
}
