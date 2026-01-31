///! Title segment

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const utils = @import("utils");

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    wm: *defs.WM,
    cached_title: *std.ArrayList(u8),
    cached_title_window: *?u32,
    allocator: std.mem.Allocator,
) !u16 {
    const ws_state = workspaces.getState() orelse return start_x + width;
    const has_windows = ws_state.workspaces[ws_state.current].windows.items.len > 0;

    const is_focused = has_windows and wm.focused_window != null;
    const bg = if (is_focused and config.title_accent)
        config.getTitleAccent()
    else
        config.bg;
    const fg = if (is_focused and config.title_accent)
        config.selected_fg
    else
        config.fg;

    dc.fillRect(start_x, 0, width, height, bg);

    if (has_windows) {
        const title = try getFocusedWindowTitle(wm, cached_title, cached_title_window, allocator);
        defer if (title.len > 0 and cached_title.items.ptr != title.ptr) allocator.free(title);

        if (title.len > 0) {
            const text_y = calculateTextY(dc, height);
            try dc.drawTextEllipsis(start_x + config.padding, text_y, title, width - config.padding * 2, fg);
        }
    }
    
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

fn getFocusedWindowTitle(
    wm: *defs.WM,
    cached_title: *std.ArrayList(u8),
    cached_title_window: *?u32,
    allocator: std.mem.Allocator,
) ![]const u8 {
    const win = wm.focused_window orelse {
        cached_title_window.* = null;
        return "";
    };

    if (cached_title_window.* == win and cached_title.items.len > 0) {
        return cached_title.items;
    }

    if (utils.getAtom(wm.conn, "_NET_WM_NAME")) |net_wm_name_atom| {
        const utf8_atom = utils.getAtom(wm.conn, "UTF8_STRING") catch xcb.XCB_ATOM_STRING;

        const cookie = xcb.xcb_get_property(
            wm.conn,
            0,
            win,
            net_wm_name_atom,
            utf8_atom,
            0,
            256,
        );

        if (xcb.xcb_get_property_reply(wm.conn, cookie, null)) |reply| {
            defer std.c.free(reply);

            if (reply.*.format == 8 and reply.*.value_len > 0) {
                const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
                const len: usize = @intCast(reply.*.value_len);

                cached_title.clearRetainingCapacity();
                try cached_title.appendSlice(allocator, data[0..len]);
                cached_title_window.* = win;

                return cached_title.items;
            }
        }
    } else |_| {}

    const cookie = xcb.xcb_get_property(
        wm.conn,
        0,
        win,
        xcb.XCB_ATOM_WM_NAME,
        xcb.XCB_ATOM_STRING,
        0,
        256,
    );

    const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null) orelse {
        cached_title_window.* = null;
        return "";
    };
    defer std.c.free(reply);

    if (reply.*.format != 8 or reply.*.value_len == 0) {
        cached_title_window.* = null;
        return "";
    }

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    cached_title.clearRetainingCapacity();
    try cached_title.appendSlice(allocator, data[0..len]);
    cached_title_window.* = win;

    return cached_title.items;
}
