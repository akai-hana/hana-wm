//! Status bar implementation similar to dwm
//!
//! Displays:
//! - Workspace indicators (clickable)
//! - Layout indicator
//! - Window title
//! - Time
//! - Status text (set via xsetroot -name)

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const BarConfig = defs.BarConfig;
const utils = @import("utils");
const workspaces = @import("workspaces");
const tiling = @import("tiling");
const drawing = @import("drawing");

pub const Bar = struct {
    window: u32,
    width: u16,
    height: u16,
    dc: *drawing.DrawContext,
    config: BarConfig,
    status_text: std.ArrayList(u8),
    wm: *WM,
    allocator: std.mem.Allocator,

    pub fn init(wm: *WM, config: BarConfig) !*Bar {
        if (!config.show) return error.BarDisabled;

        const b = try wm.allocator.create(Bar);
        errdefer wm.allocator.destroy(b);

        const screen = wm.screen;
        const width = screen.width_in_pixels;
        const height = config.height;

        const window = xcb.xcb_generate_id(wm.conn);

        const values = [_]u32{
            config.bg,
            xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS,
        };

        _ = xcb.xcb_create_window(
            wm.conn,
            xcb.XCB_COPY_FROM_PARENT,
            window,
            screen.root,
            0,
            0,
            width,
            height,
            0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.root_visual,
            xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK,
            &values,
        );

        try setWindowProperties(wm.conn, window, height);

        _ = xcb.xcb_map_window(wm.conn, window);

        const dc = try drawing.DrawContext.init(wm.allocator, wm.conn, screen, window, width, height);
        errdefer dc.deinit();

        try dc.loadFont(config.font);

        b.* = .{
            .window = window,
            .width = width,
            .height = height,
            .dc = dc,
            .config = config,
            .status_text = std.ArrayList(u8){},
            .wm = wm,
            .allocator = wm.allocator,
        };

        try b.status_text.appendSlice(wm.allocator, "hana");

        try b.draw();

        return b;
    }

    pub fn deinit(self: *Bar) void {
        self.status_text.deinit(self.allocator);
        self.dc.deinit();
        _ = xcb.xcb_destroy_window(self.wm.conn, self.window);
        self.allocator.destroy(self);
    }

    fn setWindowProperties(conn: *xcb.xcb_connection_t, window: u32, height: u16) !void {
        const wm_name = "hana-bar";
        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            window,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(wm_name.len),
            wm_name.ptr,
        );

        const wm_class = "hana-bar\x00hana-bar\x00";
        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            window,
            xcb.XCB_ATOM_WM_CLASS,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(wm_class.len),
            wm_class.ptr,
        );

        const net_wm_window_type = try getAtom(conn, "_NET_WM_WINDOW_TYPE");
        const net_wm_window_type_dock = try getAtom(conn, "_NET_WM_WINDOW_TYPE_DOCK");
        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            window,
            net_wm_window_type,
            xcb.XCB_ATOM_ATOM,
            32,
            1,
            &net_wm_window_type_dock,
        );

        const net_wm_state = try getAtom(conn, "_NET_WM_STATE");
        const net_wm_state_above = try getAtom(conn, "_NET_WM_STATE_ABOVE");
        const net_wm_state_sticky = try getAtom(conn, "_NET_WM_STATE_STICKY");
        const states = [_]u32{ net_wm_state_above, net_wm_state_sticky };
        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            window,
            net_wm_state,
            xcb.XCB_ATOM_ATOM,
            32,
            2,
            &states,
        );

        const net_wm_strut_partial = try getAtom(conn, "_NET_WM_STRUT_PARTIAL");
        const strut = [_]u32{ 0, 0, height, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            window,
            net_wm_strut_partial,
            xcb.XCB_ATOM_CARDINAL,
            32,
            12,
            &strut,
        );
    }

    fn getAtom(conn: *xcb.xcb_connection_t, name: []const u8) !u32 {
        const cookie = xcb.xcb_intern_atom(conn, 0, @intCast(name.len), name.ptr);
        const reply = xcb.xcb_intern_atom_reply(conn, cookie, null) orelse return error.AtomFailed;
        defer std.c.free(reply);
        return reply.*.atom;
    }

    pub fn draw(self: *Bar) !void {
        self.dc.setColor(self.config.bg);
        self.dc.fillRect(0, 0, self.width, self.height);

        var x: u16 = 0;

        x = try self.drawWorkspaces(x);
        x = try self.drawLayout(x);

        const right_width = self.calculateRightWidth();
        const title_width = if (self.width > x + right_width) self.width - x - right_width else 0;

        if (title_width > 0) {
            try self.drawTitle(x, title_width);
        }

        try self.drawRightSegments();

        self.dc.flush();
    }

    fn calculateRightWidth(self: *Bar) u16 {
        const padding: u16 = 8;

        var time_buf: [64]u8 = undefined;
        const time_str = self.getTimeString(&time_buf) catch return 0;
        const time_w = self.dc.textWidth(time_str);
        const time_width = time_w + padding * 2;

        if (self.status_text.items.len > 0) {
            const separator = " | ";
            const sep_w = self.dc.textWidth(separator);
            const text_w = self.dc.textWidth(self.status_text.items);
            return time_width + text_w + sep_w + padding * 2;
        }

        return time_width;
    }

    fn getTimeString(self: *Bar, buf: []u8) ![]const u8 {
        _ = self;
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
            return try std.fmt.bufPrint(buf, "00/00/0000 00:00", .{});
        };

        const epoch_seconds = ts.sec;
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

    fn drawRightSegments(self: *Bar) !void {
        var x = self.width;

        x = try self.drawTimeAt(x);

        if (self.status_text.items.len > 0) {
            _ = try self.drawStatusAt(x);
        }
    }

    fn drawTimeAt(self: *Bar, end_x: u16) !u16 {
        var time_buf: [64]u8 = undefined;
        const time_str = try self.getTimeString(&time_buf);

        const padding: u16 = 8;
        const text_w = self.dc.textWidth(time_str);
        const width = text_w + padding * 2;
        const x = end_x - width;

        self.dc.setColor(self.config.bg);
        self.dc.fillRect(x, 0, width, self.height);

        self.dc.setColor(self.config.fg);
        const text_y = (self.height + self.dc.font_height) / 2 - 2;
        try self.dc.drawText(x + padding, text_y, time_str);

        return x;
    }

    fn drawStatusAt(self: *Bar, end_x: u16) !u16 {
        const padding: u16 = 8;
        const separator = " | ";
        const sep_w = self.dc.textWidth(separator);
        const text_w = self.dc.textWidth(self.status_text.items);
        const width = text_w + sep_w + padding * 2;
        const x = end_x - width;

        self.dc.setColor(self.config.bg);
        self.dc.fillRect(x, 0, width, self.height);

        self.dc.setColor(self.config.fg);
        const text_y = (self.height + self.dc.font_height) / 2 - 2;
        try self.dc.drawText(x + padding, text_y, self.status_text.items);
        try self.dc.drawText(x + padding + text_w, text_y, separator);

        return x;
    }

    fn drawWorkspaces(self: *Bar, start_x: u16) !u16 {
        const ws_state = workspaces.getState() orelse return start_x;
        const current = ws_state.current;

        var x = start_x;
        const ws_width: u16 = 30;

        for (ws_state.workspaces, 0..) |*ws, i| {
            const is_current = i == current;
            const has_windows = ws.windows.items.len > 0;

            const bg = if (is_current) self.config.selected_bg else self.config.bg;
            const fg = if (is_current)
                self.config.selected_fg
            else if (has_windows)
                self.config.occupied_fg
            else
                self.config.fg;

            self.dc.setColor(bg);
            self.dc.fillRect(x, 0, ws_width, self.height);

            var label_buf: [8]u8 = undefined;
            const label = try std.fmt.bufPrint(&label_buf, "{}", .{i + 1});

            self.dc.setColor(fg);
            const text_w = self.dc.textWidth(label);
            const text_x = x + (ws_width - text_w) / 2;
            const text_y = (self.height + self.dc.font_height) / 2 - 2;

            try self.dc.drawText(text_x, text_y, label);

            x += ws_width;
        }

        return x;
    }

    fn drawLayout(self: *Bar, start_x: u16) !u16 {
        const t_state = tiling.getState() orelse return start_x;

        const layout_str = switch (t_state.layout) {
            .master => "[]=",
            .monocle => "[M]",
            .grid => "[+]",
        };

        const padding: u16 = 8;
        const text_w = self.dc.textWidth(layout_str);
        const width = text_w + padding * 2;

        self.dc.setColor(self.config.bg);
        self.dc.fillRect(start_x, 0, width, self.height);

        self.dc.setColor(self.config.fg);
        const text_y = (self.height + self.dc.font_height) / 2 - 2;
        try self.dc.drawText(start_x + padding, text_y, layout_str);

        return start_x + width;
    }

    fn drawTitle(self: *Bar, start_x: u16, width: u16) !void {
        const title = try self.getFocusedWindowTitle();
        defer if (title.len > 0) self.allocator.free(title);

        self.dc.setColor(self.config.bg);
        self.dc.fillRect(start_x, 0, width, self.height);

        if (title.len > 0) {
            self.dc.setColor(self.config.fg);
            const text_y = (self.height + self.dc.font_height) / 2 - 2;
            const padding: u16 = 8;
            try self.dc.drawTextEllipsis(start_x + padding, text_y, title, width - padding * 2);
        }
    }

    fn getFocusedWindowTitle(self: *Bar) ![]const u8 {
        const win = self.wm.focused_window orelse return "";

        const cookie = xcb.xcb_get_property(
            self.wm.conn,
            0,
            win,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            0,
            256,
        );

        const reply = xcb.xcb_get_property_reply(self.wm.conn, cookie, null) orelse return "";
        defer std.c.free(reply);

        if (reply.*.value_len == 0) return "";

        const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
        const len: usize = @intCast(xcb.xcb_get_property_value_length(reply));

        return try self.allocator.dupe(u8, data[0..len]);
    }

    pub fn updateStatus(self: *Bar) !void {
        const cookie = xcb.xcb_get_property(
            self.wm.conn,
            0,
            self.wm.root,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            0,
            256,
        );

        const reply = xcb.xcb_get_property_reply(self.wm.conn, cookie, null) orelse {
            self.status_text.clearRetainingCapacity();
            try self.status_text.appendSlice(self.allocator, "hana");
            return;
        };
        defer std.c.free(reply);

        self.status_text.clearRetainingCapacity();

        if (reply.*.value_len > 0) {
            const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
            const len: usize = @intCast(xcb.xcb_get_property_value_length(reply));
            try self.status_text.appendSlice(self.allocator, data[0..len]);
        } else {
            try self.status_text.appendSlice(self.allocator, "hana");
        }
    }

    pub fn handleClick(self: *Bar, x: i16) void {
        if (x < 0) return;

        const ws_state = workspaces.getState() orelse return;
        const ws_width: u16 = 30;
        const ws_count: u16 = @intCast(ws_state.workspaces.len);
        const total_ws_width = ws_width * ws_count;

        if (x < total_ws_width) {
            const clicked_ws: usize = @intCast(@divFloor(x, ws_width));
            if (clicked_ws < ws_state.workspaces.len) {
                workspaces.switchTo(self.wm, clicked_ws);
            }
        }
    }

    pub fn handleExpose(self: *Bar) !void {
        try self.draw();
    }
};

var bar: ?*Bar = null;

pub fn init(wm: *WM) !void {
    if (!wm.config.bar.show) return;

    bar = try Bar.init(wm, wm.config.bar);
}

pub fn deinit() void {
    if (bar) |b| {
        b.deinit();
        bar = null;
    }
}

pub fn getBar() ?*Bar {
    return bar;
}

pub fn update() !void {
    if (bar) |b| {
        try b.draw();
    }
}

pub fn updateStatus() !void {
    if (bar) |b| {
        try b.updateStatus();
        try b.draw();
    }
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    if (bar) |b| {
        if (event.event == b.window) {
            b.handleClick(event.event_x);
        }
    }
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t) void {
    if (bar) |b| {
        if (event.window == b.window) {
            b.handleExpose() catch |err| {
                std.log.err("[bar] Failed to handle expose: {}", .{err});
            };
        }
    }
}

pub fn getHeight() u16 {
    if (bar) |b| {
        return b.height;
    }
    return 0;
}
