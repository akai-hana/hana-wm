//! Status bar

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const utils = @import("utils");
const workspaces = @import("workspaces");
const tiling = @import("tiling");

const State = struct {
    window: u32,
    width: u16,
    height: u16,
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    status_text: std.ArrayList(u8),
    cached_title: std.ArrayList(u8),
    cached_title_window: ?u32,
    dirty: bool,
    alive: bool,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, window: u32, width: u16, height: u16,
            dc: *drawing.DrawContext, config: defs.BarConfig) !*State {
        const s = try allocator.create(State);
        s.* = .{
            .window = window,
            .width = width,
            .height = height,
            .dc = dc,
            .config = config,
            .status_text = std.ArrayList(u8){},
            .cached_title = std.ArrayList(u8){},
            .cached_title_window = null,
            .dirty = false,
            .alive = true,
            .allocator = allocator,
        };
        try s.status_text.appendSlice(allocator, "hana");
        return s;
    }

    fn deinit(self: *State) void {
        self.alive = false;
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    inline fn markDirty(self: *State) void { self.dirty = true; }
    inline fn clearDirty(self: *State) void { self.dirty = false; }
    inline fn isDirty(self: *State) bool { return self.dirty; }
    inline fn isAlive(self: *State) bool { return self.alive; }
};

var state: ?*State = null;

pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.show) return error.BarDisabled;

    utils.flush(wm.conn);
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    const screen = wm.screen;
    const width = screen.width_in_pixels;
    const height = wm.config.bar.height;

    const window = xcb.xcb_generate_id(wm.conn);
    const values = [_]u32{
        wm.config.bar.bg,
        xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS,
    };

    _ = xcb.xcb_create_window(
        wm.conn, xcb.XCB_COPY_FROM_PARENT, window, screen.root,
        0, 0, width, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual,
        xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK, &values,
    );

    utils.flush(wm.conn);
    try setWindowProperties(wm.conn, window, height);
    utils.flush(wm.conn);
    _ = xcb.xcb_map_window(wm.conn, window);
    utils.flush(wm.conn);

    const dc = try drawing.DrawContext.init(wm.allocator, wm.conn, screen, window, width, height);
    errdefer dc.deinit();

    const font_loaded = blk: {
        const font_str = if (wm.config.bar.font_size > 0)
            try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
        else
            wm.config.bar.font;
        defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);

        var attempts: u8 = 0;
        while (attempts < 3) : (attempts += 1) {
            if (attempts > 0) std.posix.nanosleep(0, 50 * std.time.ns_per_ms);
            if (dc.loadFont(font_str)) {
                break :blk true;
            } else |_| {}
        }

        const fallback_fonts = [_][]const u8{
            "monospace:size=10",
            "DejaVu Sans Mono:size=10",
            "Liberation Mono:size=10",
            "Courier New:size=10",
            "fixed",
            "6x13",
        };

        for (fallback_fonts) |fallback| {
            std.log.warn("[bar] Failed to load '{s}', trying fallback: {s}", .{ font_str, fallback });
            if (dc.loadFont(fallback)) {
                break :blk true;
            } else |_| {}
        }

        break :blk false;
    };

    if (!font_loaded) {
        std.log.err("[bar] Could not load any font", .{});
        return error.FontLoadFailed;
    }

    const s = try State.init(wm.allocator, window, width, height, dc, wm.config.bar);
    try draw(s, wm);
    utils.flush(wm.conn);

    state = s;
}

pub fn deinit() void {
    if (state) |s| {
        const conn = s.dc.conn;
        const window = s.window;
        s.dc.deinit();
        s.deinit();
        _ = xcb.xcb_destroy_window(@ptrCast(conn), window);
        utils.flush(@ptrCast(conn));
        state = null;
    }
}

fn setWindowProperties(conn: *xcb.xcb_connection_t, window: u32, height: u16) !void {
    const wm_strut_partial = try utils.getAtom(conn, "_NET_WM_STRUT_PARTIAL");
    const strut = [_]u32{ 0, 0, height, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window,
        wm_strut_partial, xcb.XCB_ATOM_CARDINAL, 32, 12, &strut);

    const wm_window_type = try utils.getAtom(conn, "_NET_WM_WINDOW_TYPE");
    const wm_window_type_dock = try utils.getAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK");
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window,
        wm_window_type, xcb.XCB_ATOM_ATOM, 32, 1, &[_]u32{wm_window_type_dock});

    const wm_state = try utils.getAtom(conn, "_NET_WM_STATE");
    const wm_state_above = try utils.getAtom(conn, "_NET_WM_STATE_ABOVE");
    const wm_state_sticky = try utils.getAtom(conn, "_NET_WM_STATE_STICKY");
    const state_values = [_]u32{ wm_state_above, wm_state_sticky };
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, window,
        wm_state, xcb.XCB_ATOM_ATOM, 32, 2, &state_values);
}

pub inline fn getBarWindow() u32 {
    return if (state) |s| s.window else 0;
}

pub inline fn isBarWindow(win: u32) bool {
    return if (state) |s| s.window == win else false;
}

// NO DEBOUNCING - mark dirty immediately
pub inline fn markDirty() void {
    if (state) |s| s.markDirty();
}

pub inline fn raiseBar() void {
    if (state) |s| {
        _ = xcb.xcb_configure_window(@ptrCast(s.dc.conn), s.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}

pub fn updateIfDirty(wm: *defs.WM) !void {
    if (state) |s| {
        if (s.isDirty()) {
            try draw(s, wm);
            s.clearDirty();
        }
    }
}

pub inline fn getHeight() u16 {
    return if (state) |s| s.height else 0;
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
    if (state) |s| {
        if (event.window == s.window and event.count == 0) {
            draw(s, wm) catch {};
        }
    }
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
    if (state) |s| {
        if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
            updateStatus(s, wm) catch {};
            s.markDirty();
        }
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
    if (state) |s| {
        if (event.event == s.window) {
            handleClick(s, wm, event.event_x);
        }
    }
}

fn handleClick(s: *State, wm: *defs.WM, x: i16) void {
    const ws_state = workspaces.getState() orelse return;
    const ws_count = ws_state.workspaces.len;

    const ws_width: i16 = 30;
    const clicked_ws: usize = @intCast(@max(0, @divFloor(x, ws_width)));

    if (clicked_ws < ws_count) {
        workspaces.switchTo(wm, clicked_ws);
        s.markDirty();
    }
}

fn draw(s: *State, wm: *defs.WM) !void {
    if (!s.isAlive()) return error.BarNotAlive;

    s.dc.setColor(s.config.bg);
    s.dc.fillRect(0, 0, s.width, s.height);

    var x: u16 = 0;
    x = try drawWorkspaces(s, x);
    x = try drawLayout(s, x);

    const right_width = calculateRightWidth(s);
    const title_width = if (s.width > x + right_width) s.width - x - right_width else 0;
    if (title_width > 0) {
        try drawTitle(s, wm, x, title_width);
    }

    try drawRightSegments(s);
    s.dc.flush();
}

fn drawWorkspaces(s: *State, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    const current = ws_state.current;

    var x = start_x;
    const ws_width: u16 = 30;

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == current;
        const has_windows = ws.windows.items.len > 0;

        const bg = if (is_current) s.config.selected_bg else s.config.bg;
        const fg = if (is_current)
            s.config.selected_fg
        else if (has_windows)
            s.config.occupied_fg
        else
            s.config.fg;

        s.dc.setColor(bg);
        s.dc.fillRect(x, 0, ws_width, s.height);

        var label_buf: [8]u8 = undefined;
        const label = getWorkspaceLabel(s, i, &label_buf);

        s.dc.setColor(fg);
        const text_w = s.dc.textWidth(label);
        const text_x = x + (ws_width - text_w) / 2;
        const text_y = calculateTextY(s);

        try s.dc.drawText(text_x, text_y, label);

        if (has_windows) {
            try drawIndicator(s, x, is_current, fg);
        }

        x += ws_width;
    }

    return x;
}

fn calculateTextY(s: *State) u16 {
    const ascender: i32 = s.dc.getAscender();
    const half_height: i32 = @divTrunc(@as(i32, s.height), 2);
    const half_ascender: i32 = @divTrunc(ascender, 2);
    const text_y: i32 = half_height + half_ascender;
    return @intCast(@max(ascender, text_y));
}

fn getWorkspaceLabel(s: *State, index: usize, buf: []u8) []const u8 {
    if (index < s.config.workspace_chars.len) {
        const ch = s.config.workspace_chars[index];
        buf[0] = ch;
        return buf[0..1];
    }
    const result = std.fmt.bufPrint(buf, "{}", .{index + 1}) catch "?";
    return result;
}

fn drawIndicator(s: *State, ws_x: u16, is_current: bool, color: u32) !void {
    const size = s.config.indicator_size;
    const x = ws_x + 2;
    const y: u16 = 2;

    s.dc.setColor(color);

    if (is_current) {
        s.dc.fillRect(x, y, size, size);
    } else {
        s.dc.fillRect(x, y, size, 1);
        s.dc.fillRect(x, y + size - 1, size, 1);
        s.dc.fillRect(x, y, 1, size);
        s.dc.fillRect(x + size - 1, y, 1, size);
    }
}

fn drawLayout(s: *State, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;

    const layout_str = switch (t_state.layout) {
        .master => "[]=",
        .monocle => "[M]",
        .grid => "[+]",
    };

    const padding: u16 = 8;
    const text_w = s.dc.textWidth(layout_str);
    const width = text_w + padding * 2;

    s.dc.setColor(s.config.bg);
    s.dc.fillRect(start_x, 0, width, s.height);

    s.dc.setColor(s.config.fg);
    const text_y = calculateTextY(s);

    try s.dc.drawText(start_x + padding, text_y, layout_str);

    return start_x + width;
}

fn drawTitle(s: *State, wm: *defs.WM, start_x: u16, width: u16) !void {
    const ws_state = workspaces.getState() orelse return;
    const has_windows = ws_state.workspaces[ws_state.current].windows.items.len > 0;

    const is_focused = has_windows and wm.focused_window != null;
    const bg = if (is_focused and s.config.title_accent)
        s.config.selected_bg
    else
        s.config.bg;
    const fg = if (is_focused and s.config.title_accent)
        s.config.selected_fg
    else
        s.config.fg;

    s.dc.setColor(bg);
    s.dc.fillRect(start_x, 0, width, s.height);

    if (has_windows) {
        const title = try getFocusedWindowTitle(s, wm);
        defer if (title.len > 0 and s.cached_title.items.ptr != title.ptr) s.allocator.free(title);

        if (title.len > 0) {
            s.dc.setColor(fg);
            const text_y = calculateTextY(s);
            const padding: u16 = 8;
            try s.dc.drawTextEllipsis(start_x + padding, text_y, title, width - padding * 2);
        }
    }
}

fn getFocusedWindowTitle(s: *State, wm: *defs.WM) ![]const u8 {
    const win = wm.focused_window orelse {
        s.cached_title_window = null;
        return "";
    };

    if (s.cached_title_window == win and s.cached_title.items.len > 0) {
        return s.cached_title.items;
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

                s.cached_title.clearRetainingCapacity();
                try s.cached_title.appendSlice(s.allocator, data[0..len]);
                s.cached_title_window = win;

                return s.cached_title.items;
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
        s.cached_title_window = null;
        return "";
    };
    defer std.c.free(reply);

    if (reply.*.format != 8 or reply.*.value_len == 0) {
        s.cached_title_window = null;
        return "";
    }

    const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
    const len: usize = @intCast(reply.*.value_len);

    s.cached_title.clearRetainingCapacity();
    try s.cached_title.appendSlice(s.allocator, data[0..len]);
    s.cached_title_window = win;

    return s.cached_title.items;
}

fn calculateRightWidth(s: *State) u16 {
    const padding: u16 = 8;

    var time_buf: [64]u8 = undefined;
    const time_str = getTimeString(&time_buf) catch return 0;
    const time_w = s.dc.textWidth(time_str);
    const time_width = time_w + padding * 2;

    if (s.status_text.items.len > 0) {
        const separator = " | ";
        const sep_w = s.dc.textWidth(separator);
        const text_w = s.dc.textWidth(s.status_text.items);
        return time_width + text_w + sep_w + padding * 2;
    }

    return time_width;
}

fn drawRightSegments(s: *State) !void {
    var x = s.width;

    x = try drawTimeAt(s, x);

    if (s.status_text.items.len > 0) {
        _ = try drawStatusAt(s, x);
    }
}

fn drawTimeAt(s: *State, end_x: u16) !u16 {
    var time_buf: [64]u8 = undefined;
    const time_str = try getTimeString(&time_buf);

    const padding: u16 = 8;
    const text_w = s.dc.textWidth(time_str);
    const width = text_w + padding * 2;
    const x = end_x - width;

    s.dc.setColor(s.config.bg);
    s.dc.fillRect(x, 0, width, s.height);

    s.dc.setColor(s.config.fg);
    const text_y = calculateTextY(s);

    try s.dc.drawText(x + padding, text_y, time_str);

    return x;
}

fn drawStatusAt(s: *State, end_x: u16) !u16 {
    const padding: u16 = 8;
    const separator = " | ";
    const sep_w = s.dc.textWidth(separator);
    const text_w = s.dc.textWidth(s.status_text.items);
    const width = text_w + sep_w + padding * 2;
    const x = end_x - width;

    s.dc.setColor(s.config.bg);
    s.dc.fillRect(x, 0, width, s.height);

    s.dc.setColor(s.config.fg);
    const text_y = calculateTextY(s);
    try s.dc.drawText(x + padding, text_y, s.status_text.items);
    try s.dc.drawText(x + padding + text_w, text_y, separator);

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

fn updateStatus(s: *State, wm: *defs.WM) !void {
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
        s.status_text.clearRetainingCapacity();
        try s.status_text.appendSlice(s.allocator, "hana");
        return;
    };
    defer std.c.free(reply);

    s.status_text.clearRetainingCapacity();

    if (reply.*.value_len > 0) {
        const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
        const len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
        try s.status_text.appendSlice(s.allocator, data[0..len]);
    } else {
        try s.status_text.appendSlice(s.allocator, "hana");
    }
}
