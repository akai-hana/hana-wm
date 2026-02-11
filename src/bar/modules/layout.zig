///! Current layout indicator segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const tiling = @import("tiling");

const layouts = [_][]const u8{ "[]=", "[M]", "[+]", "[@]" };

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;
    const layout_str = layouts[@intFromEnum(t_state.layout)];
    const scaled_padding = config.scaledPadding();
    const width = dc.textWidth(layout_str) + scaled_padding * 2;
    dc.fillRect(start_x, 0, width, height, config.bg);
    try dc.drawText(start_x + scaled_padding, dc.baselineY(height), layout_str, config.fg);
    return start_x + width;
}
