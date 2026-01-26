//! Bar rendering functions - Debug version

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const state_mod = @import("state");
const BarState = state_mod.BarState;
const workspaces = @import("workspaces");
const tiling = @import("tiling");

pub fn draw(bar_state: *BarState, wm: *defs.WM) !void {
    if (!bar_state.isAlive()) return error.BarNotAlive;

    // Clear background
    bar_state.dc.setColor(bar_state.config.bg);
    bar_state.dc.fillRect(0, 0, bar_state.width, bar_state.height);

    var x: u16 = 0;

    // Draw workspaces
    x = try drawWorkspaces(bar_state, x);

    // Draw layout indicator
    x = try drawLayout(bar_state, x);

    // Calculate space for right segments
    const right_width = calculateRightWidth(bar_state);

    // Draw window title in remaining space
    const title_width = if (bar_state.width > x + right_width) bar_state.width - x - right_width else 0;
    if (title_width > 0) {
        try drawTitle(bar_state, wm, x, title_width);
    }

    // Draw right segments (status + time)
    try drawRightSegments(bar_state);

    bar_state.dc.flush();

    const now = if (std.posix.clock_gettime(std.posix.CLOCK.REALTIME)) |ts|
        ts.sec
    else |_|
        0;
    bar_state.last_draw_time = now;
}

fn drawWorkspaces(bar_state: *BarState, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    const current = ws_state.current;

    var x = start_x;
    const ws_width: u16 = 30;

    std.log.info("[render] Drawing {} workspaces", .{ws_state.workspaces.len});

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == current;
        const has_windows = ws.windows.items.len > 0;

        const bg = if (is_current) bar_state.config.selected_bg else bar_state.config.bg;
        const fg = if (is_current)
            bar_state.config.selected_fg
        else if (has_windows)
            bar_state.config.occupied_fg
        else
            bar_state.config.fg;

        // Draw background
        bar_state.dc.setColor(bg);
        bar_state.dc.fillRect(x, 0, ws_width, bar_state.height);

        // Draw label
        var label_buf: [8]u8 = undefined;
        const label = getWorkspaceLabel(bar_state, i, &label_buf);

        std.log.info("[render] WS{}: label='{s}', fg=0x{x:0>6}, bg=0x{x:0>6}", .{i+1, label, fg, bg});

        bar_state.dc.setColor(fg);
        const text_w = bar_state.dc.textWidth(label);
        const text_x = x + (ws_width - text_w) / 2;
        
        // Simple positioning - place text in vertical center
        const text_y = bar_state.height / 2 + bar_state.dc.font_height / 3;
        
        std.log.info("[render] WS{}: drawing at x={}, y={}, width={}", .{i+1, text_x, text_y, text_w});

        try bar_state.dc.drawText(text_x, text_y, label);

        // Draw indicator if workspace has windows
        if (has_windows) {
            try drawIndicator(bar_state, x, is_current, fg);
        }

        x += ws_width;
    }

    return x;
}

fn getWorkspaceLabel(bar_state: *BarState, index: usize, buf: []u8) []const u8 {
    if (index < bar_state.config.workspace_chars.len) {
        const ch = bar_state.config.workspace_chars[index];
        buf[0] = ch;
        std.log.info("[render] WS{}: using char '{c}' (0x{x:0>2})", .{index+1, ch, ch});
        return buf[0..1];
    }
    const result = std.fmt.bufPrint(buf, "{}", .{index + 1}) catch "?";
    std.log.info("[render] WS{}: using number '{s}'", .{index+1, result});
    return result;
}

fn drawIndicator(bar_state: *BarState, ws_x: u16, is_current: bool, color: u32) !void {
    const size = bar_state.config.indicator_size;
    const x = ws_x + 2;
    const y: u16 = 2;

    bar_state.dc.setColor(color);

    if (is_current) {
        // Filled square for current workspace
        bar_state.dc.fillRect(x, y, size, size);
    } else {
        // Hollow square for non-current workspace with windows
        bar_state.dc.fillRect(x, y, size, 1);
        bar_state.dc.fillRect(x, y + size - 1, size, 1);
        bar_state.dc.fillRect(x, y, 1, size);
        bar_state.dc.fillRect(x + size - 1, y, 1, size);
    }
}

fn drawLayout(bar_state: *BarState, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;

    const layout_str = switch (t_state.layout) {
        .master => "[]=",
        .monocle => "[M]",
        .grid => "[+]",
    };

    std.log.info("[render] Layout: '{s}'", .{layout_str});

    const padding: u16 = 8;
    const text_w = bar_state.dc.textWidth(layout_str);
    const width = text_w + padding * 2;

    // Draw background
    bar_state.dc.setColor(bar_state.config.bg);
    bar_state.dc.fillRect(start_x, 0, width, bar_state.height);

    // Draw text
    bar_state.dc.setColor(bar_state.config.fg);
    const text_y = bar_state.height / 2 + bar_state.dc.font_height / 3;
    
    std.log.info("[render] Layout: drawing at x={}, y={}", .{start_x + padding, text_y});
    
    try bar_state.dc.drawText(start_x + padding, text_y, layout_str);

    return start_x + width;
}

fn drawTitle(bar_state: *BarState, wm: *defs.WM, start_x: u16, width: u16) !void {
    const title = try getFocusedWindowTitle(bar_state, wm);
    defer if (title.len > 0 and bar_state.cached_title.items.ptr != title.ptr) bar_state.allocator.free(title);

    const is_focused = wm.focused_window != null;
    const bg = if (is_focused and bar_state.config.title_accent)
        bar_state.config.selected_bg
    else
        bar_state.config.bg;
    const fg = if (is_focused and bar_state.config.title_accent)
        bar_state.config.selected_fg
    else
        bar_state.config.fg;

    // Draw background
    bar_state.dc.setColor(bg);
    bar_state.dc.fillRect(start_x, 0, width, bar_state.height);

    // Draw title text if present
    if (title.len > 0) {
        std.log.info("[render] Title: '{s}', fg=0x{x:0>6}", .{title, fg});
        bar_state.dc.setColor(fg);
        const text_y = bar_state.height / 2 + bar_state.dc.font_height / 3;
        const padding: u16 = 8;
        try bar_state.dc.drawTextEllipsis(start_x + padding, text_y, title, width - padding * 2);
    }
}

fn getFocusedWindowTitle(bar_state: *BarState, wm: *defs.WM) ![]const u8 {
    const win = wm.focused_window orelse {
        bar_state.cached_title_window = null;
        return "";
    };

    // Use cache if available
    if (bar_state.cached_title_window == win and bar_state.cached_title.items.len > 0) {
        return bar_state.cached_title.items;
    }

    // Try _NET_WM_NAME first (UTF-8)
    const net_wm_name_atom: ?u32 = blk: {
        const cookie = xcb.xcb_intern_atom(wm.conn, 0, 12, "_NET_WM_NAME");
        const reply = xcb.xcb_intern_atom_reply(wm.conn, cookie, null) orelse break :blk null;
        defer std.c.free(reply);
        break :blk @as(u32, reply.*.atom);
    };

    if (net_wm_name_atom) |atom_u32| {
        const utf8_string_atom: u32 = blk: {
            const cookie = xcb.xcb_intern_atom(wm.conn, 0, 11, "UTF8_STRING");
            const reply = xcb.xcb_intern_atom_reply(wm.conn, cookie, null) orelse break :blk @as(u32, xcb.XCB_ATOM_STRING);
            defer std.c.free(reply);
            break :blk @as(u32, reply.*.atom);
        };

        const cookie = xcb.xcb_get_property(
            wm.conn,
            0,
            win,
            @as(u32, @intCast(atom_u32)),
            @as(u32, @intCast(utf8_string_atom)),
            0,
            256,
        );

        const reply = xcb.xcb_get_property_reply(wm.conn, cookie, null);
        if (reply) |r| {
            defer std.c.free(r);

            if (r.*.format == 8 and r.*.value_len > 0) {
                const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(r));
                const len: usize = @intCast(r.*.value_len);

                bar_state.cached_title.clearRetainingCapacity();
                try bar_state.cached_title.appendSlice(bar_state.allocator, data[0..len]);
                bar_state.cached_title_window = win;

                return bar_state.cached_title.items;
            }
        }
    }

    // Fall back to WM_NAME
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
        bar_state.cached_title_window = null;
        return "";
    };
    defer std.c.free(reply);

    if (reply.*.format != 8 or reply.*.value_len == 0) {
        bar_state.cached_title_window = null;
        return "";
    }

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    bar_state.cached_title.clearRetainingCapacity();
    try bar_state.cached_title.appendSlice(bar_state.allocator, data[0..len]);
    bar_state.cached_title_window = win;

    return bar_state.cached_title.items;
}

fn calculateRightWidth(bar_state: *BarState) u16 {
    const padding: u16 = 8;

    var time_buf: [64]u8 = undefined;
    const time_str = getTimeString(&time_buf) catch return 0;
    const time_w = bar_state.dc.textWidth(time_str);
    const time_width = time_w + padding * 2;

    if (bar_state.status_text.items.len > 0) {
        const separator = " | ";
        const sep_w = bar_state.dc.textWidth(separator);
        const text_w = bar_state.dc.textWidth(bar_state.status_text.items);
        return time_width + text_w + sep_w + padding * 2;
    }

    return time_width;
}

fn drawRightSegments(bar_state: *BarState) !void {
    var x = bar_state.width;

    // Draw time (rightmost)
    x = try drawTimeAt(bar_state, x);

    // Draw status text if present
    if (bar_state.status_text.items.len > 0) {
        _ = try drawStatusAt(bar_state, x);
    }
}

fn drawTimeAt(bar_state: *BarState, end_x: u16) !u16 {
    var time_buf: [64]u8 = undefined;
    const time_str = try getTimeString(&time_buf);

    std.log.info("[render] Time: '{s}'", .{time_str});

    const padding: u16 = 8;
    const text_w = bar_state.dc.textWidth(time_str);
    const width = text_w + padding * 2;
    const x = end_x - width;

    // Draw background
    bar_state.dc.setColor(bar_state.config.bg);
    bar_state.dc.fillRect(x, 0, width, bar_state.height);

    // Draw text
    bar_state.dc.setColor(bar_state.config.fg);
    const text_y = bar_state.height / 2 + bar_state.dc.font_height / 3;
    
    std.log.info("[render] Time: drawing at x={}, y={}, fg=0x{x:0>6}", .{x + padding, text_y, bar_state.config.fg});
    
    try bar_state.dc.drawText(x + padding, text_y, time_str);

    return x;
}

fn drawStatusAt(bar_state: *BarState, end_x: u16) !u16 {
    const padding: u16 = 8;
    const separator = " | ";
    const sep_w = bar_state.dc.textWidth(separator);
    const text_w = bar_state.dc.textWidth(bar_state.status_text.items);
    const width = text_w + sep_w + padding * 2;
    const x = end_x - width;

    std.log.info("[render] Status: '{s}'", .{bar_state.status_text.items});

    // Draw background
    bar_state.dc.setColor(bar_state.config.bg);
    bar_state.dc.fillRect(x, 0, width, bar_state.height);

    // Draw text
    bar_state.dc.setColor(bar_state.config.fg);
    const text_y = bar_state.height / 2 + bar_state.dc.font_height / 3;
    try bar_state.dc.drawText(x + padding, text_y, bar_state.status_text.items);
    try bar_state.dc.drawText(x + padding + text_w, text_y, separator);

    return x;
}

fn getTimeString(buf: []u8) ![]const u8 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
        return try std.fmt.bufPrint(buf, "??:??", .{});
    };

    const epoch_seconds: i64 = ts.sec;
    const epoch_day = @divFloor(epoch_seconds, std.time.s_per_day);
    const day_seconds = @mod(epoch_seconds, std.time.s_per_day);

    const civil_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
    const year_day = civil_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const hours = @divFloor(day_seconds, std.time.s_per_hour);
    const minutes = @divFloor(@mod(day_seconds, std.time.s_per_hour), std.time.s_per_min);

    return try std.fmt.bufPrint(buf, "{d:0>2}/{d:0>2}/{d:0>4} {d:0>2}:{d:0>2}", .{
        month_day.month.numeric(),
        month_day.day_index + 1,
        year_day.year,
        hours,
        minutes,
    });
}

pub fn updateStatus(bar_state: *BarState, wm: *defs.WM) !void {
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
        bar_state.status_text.clearRetainingCapacity();
        try bar_state.status_text.appendSlice(bar_state.allocator, "hana");
        return;
    };
    defer std.c.free(reply);

    bar_state.status_text.clearRetainingCapacity();

    if (reply.*.value_len > 0) {
        const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
        const len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
        try bar_state.status_text.appendSlice(bar_state.allocator, data[0..len]);
    } else {
        try bar_state.status_text.appendSlice(bar_state.allocator, "hana");
    }
}
