///! Current layout indicator segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const tiling = @import("tiling");

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
) !u16 {
    const t_state = tiling.getState() orelse return start_x;

    const layout_str = switch (t_state.layout) {
        .master => "[]=",
        .monocle => "[M]",
        .grid => "[+]",
    };

    const text_w = dc.textWidth(layout_str);
    const width = text_w + config.padding * 2;

    dc.fillRect(start_x, 0, width, height, config.bg);

    const text_y = calculateTextY(dc, height);
    try dc.drawText(start_x + config.padding, text_y, layout_str, config.fg);

    return start_x + width;
}

fn calculateTextY(dc: *drawing.DrawContext, height: u16) u16 {
    const ascender: i32 = dc.getAscender();
    const descender: i32 = dc.getDescender();

    const font_height: i32 = ascender - descender;
    const vertical_padding: i32 = @divTrunc(@as(i32, height) - font_height, 2);
    const baseline_y: i32 = vertical_padding + ascender;

    return @intCast(@max(ascender, baseline_y));
}
