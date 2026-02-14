///! Current layout indicator segment

const std     = @import("std");
const defs    = @import("defs");
const drawing = @import("drawing");
const tiling  = @import("tiling");

const layouts = [_][]const u8{ "[]=", "[M]", "[+]", "[@]" };

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;
    const layout_idx = @intFromEnum(t_state.layout);
    
    // Clamp to valid range for defensive programming
    const safe_idx = @min(layout_idx, layouts.len - 1);
    const layout_str = layouts[safe_idx];
    return dc.drawSegment(start_x, height, layout_str, config.scaledPadding(), config.bg, config.fg);
}
