///! Status segment for the status bar

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
    status_text: []const u8,
) !u16 {
    if (status_text.len == 0) return start_x;

    const text_w = dc.textWidth(status_text);
    const width = text_w + config.padding * 2;

    dc.fillRect(start_x, 0, width, height, config.bg);

    const text_y = calculateTextY(dc, height);
    try dc.drawText(start_x + config.padding, text_y, status_text, config.fg);

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

pub fn update(wm: *defs.WM, status_text: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const cookie = xcb.xcb_get_property(
        wm.conn,
        0,
        wm.root,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        0,
        256,
    );

    const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null) orelse {
        status_text.clearRetainingCapacity();
        try status_text.appendSlice(allocator, "hana");
        return;
    };
    defer std.c.free(reply);

    status_text.clearRetainingCapacity();

    if (reply.*.value_len > 0) {
        const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
        const len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
        try status_text.appendSlice(allocator, data[0..len]);
    } else {
        try status_text.appendSlice(allocator, "hana");
    }
}
