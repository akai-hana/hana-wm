///! Status segment for the status bar

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");

const DEFAULT_STATUS = "hana";

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16, status_text: []const u8) !u16 {
    if (status_text.len == 0) return start_x;
    const width = dc.textWidth(status_text) + config.padding * 2;
    dc.fillRect(start_x, 0, width, height, config.bg);
    try dc.drawText(start_x + config.padding, dc.baselineY(height), status_text, config.fg);
    return start_x + width;
}

pub fn update(wm: *defs.WM, status_text: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const reply = xcb.xcb_get_property_reply(wm.conn,
        xcb.xcb_get_property(wm.conn, 0, wm.root, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING, 0, 256), null);
    defer if (reply) |r| std.c.free(r);

    status_text.clearRetainingCapacity();
    
    const text = if (reply) |r| blk: {
        if (r.*.value_len > 0) {
            const ptr: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
            break :blk ptr[0..@intCast(xcb.xcb_get_property_value_length(r))];
        }
        break :blk DEFAULT_STATUS;
    } else DEFAULT_STATUS;
    
    try status_text.appendSlice(allocator, text);
}
