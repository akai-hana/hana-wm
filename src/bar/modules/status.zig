///! Status segment for the status bar

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const utils = @import("utils");

const DEFAULT_STATUS = "hana";

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16, status_text: []const u8) !u16 {
    if (status_text.len == 0) return start_x;
    return dc.drawSegment(start_x, height, status_text, config.scaledPadding(), config.bg, config.fg);
}

pub fn update(wm: *defs.WM, status_text: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    const text = try utils.fetchPropertyToBuffer(
        wm.conn, wm.root, xcb.XCB_ATOM_WM_NAME, xcb.XCB_ATOM_STRING,
        status_text, allocator
    );
    if (text.len == 0) {
        try status_text.appendSlice(allocator, DEFAULT_STATUS);
    }
}
