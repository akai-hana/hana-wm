//! Enhanced status bar with configurable layout and auto-sizing

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
    dirty_clock: bool,
    last_second: i64,
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
            .dirty_clock = false,
            .last_second = 0,
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
    inline fn markClockDirty(self: *State) void { self.dirty_clock = true; }
    inline fn clearDirty(self: *State) void { 
        self.dirty = false;
        self.dirty_clock = false;
    }
    inline fn isDirty(self: *State) bool { return self.dirty or self.dirty_clock; }
    inline fn isAlive(self: *State) bool { return self.alive; }
};

var state: ?*State = null;

pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.show) return error.BarDisabled;

    utils.flush(wm.conn);
    std.posix.nanosleep(0, 50 * std.time.ns_per_ms);

    const screen = wm.screen;
    const width = screen.width_in_pixels;
    
    // Calculate height: auto-adapt to font or use configured height
    const height = try calculateBarHeight(wm);

    // Calculate Y position based on vertical_position
    const y_pos: i16 = if (wm.config.bar.vertical_position == .bottom)
        @as(i16, @intCast(screen.height_in_pixels)) - @as(i16, @intCast(height))
    else
        0;

    const window = xcb.xcb_generate_id(wm.conn);
    const values = [_]u32{
        wm.config.bar.bg,
        xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS,
    };

    _ = xcb.xcb_create_window(
        wm.conn, xcb.XCB_COPY_FROM_PARENT, window, screen.root,
        0, y_pos, width, height, 0,
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

    const font_str = if (wm.config.bar.font_size > 0)
        try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
    else
        wm.config.bar.font;
    defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);

    dc.loadFont(font_str) catch |err| {
        std.log.err("[bar] Failed to load font '{s}': {}", .{ font_str, err });
        return err;
    };

    const s = try State.init(wm.allocator, window, width, height, dc, wm.config.bar);
    try draw(s, wm);
    utils.flush(wm.conn);

    state = s;
}

fn calculateBarHeight(wm: *defs.WM) !u16 {
    // If height is configured, use it
    if (wm.config.bar.height) |h| {
        return h;
    }
    
    // Otherwise, calculate based on font size
    // For auto-sizing, we need to create a temporary DC to measure font
    const temp_win = xcb.xcb_generate_id(wm.conn);
    const screen = wm.screen;
    
    _ = xcb.xcb_create_window(
        wm.conn, xcb.XCB_COPY_FROM_PARENT, temp_win, screen.root,
        0, 0, 1, 1, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual,
        0, null,
    );
    defer _ = xcb.xcb_destroy_window(wm.conn, temp_win);
    
    const temp_dc = drawing.DrawContext.init(wm.allocator, wm.conn, screen, temp_win, 1, 1) catch {
        // Fallback to default if we can't create temp DC
        return 24;
    };
    defer temp_dc.deinit();
    
    const font_str = if (wm.config.bar.font_size > 0)
        try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
    else
        wm.config.bar.font;
    defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);
    
    temp_dc.loadFont(font_str) catch {
        return 24; // Fallback
    };
    
    const ascender: i32 = temp_dc.getAscender();
    const descender: i32 = temp_dc.getDescender();
    const font_height: u32 = @intCast(ascender - descender);
    
    // Add padding (top and bottom)
    const total_height: u32 = font_height + 2 * wm.config.bar.padding;
    
    return @intCast(std.math.clamp(total_height, 20, 100));
}

pub fn deinit() void {
    if (state) |s| {
        const conn = s.dc.display;
        const window = s.window;
        s.dc.deinit();
        s.deinit();
        _ = xcb.xcb_destroy_window(@ptrCast(conn), window);
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

pub inline fn markDirty() void {
    if (state) |s| s.markDirty();
}

pub inline fn raiseBar() void {
    if (state) |s| {
        _ = xcb.xcb_configure_window(@ptrCast(s.dc.display), s.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}

pub fn toggleBar(wm: *defs.WM) void {
    if (state) |s| {
        // Toggle the visibility
        wm.config.bar.show = !wm.config.bar.show;
        
        if (wm.config.bar.show) {
            // Show the bar
            _ = xcb.xcb_map_window(@ptrCast(s.dc.display), s.window);
            std.log.info("[bar] Bar shown", .{});
        } else {
            // Hide the bar
            _ = xcb.xcb_unmap_window(@ptrCast(s.dc.display), s.window);
            std.log.info("[bar] Bar hidden", .{});
        }
        
        utils.flush(wm.conn);
        
        // Retile to account for gained/lost screen space
        @import("tiling").retileCurrentWorkspace(wm);
    }
}

pub fn isBarVisible() bool {
    return if (state) |_| true else false;
}

pub fn getBarHeight() u16 {
    return if (state) |s| s.height else 0;
}

pub fn checkClockUpdate() !void {
    if (state) |s| {
        const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return;
        const current_second = ts.sec;
        
        if (current_second != s.last_second) {
            s.last_second = current_second;
            s.markClockDirty();
        }
    }
}

pub fn updateIfDirty(wm: *defs.WM) !void {
    if (state) |s| {
        // Check if clock needs updating (once per second)
        checkClockUpdateInternal(s);
        
        if (s.isDirty()) {
            if (s.dirty) {
                // Full redraw
                try draw(s, wm);
            } else if (s.dirty_clock) {
                // Only redraw clock
                try drawClockOnly(s, wm);
            }
            s.clearDirty();
        }
    }
}

fn checkClockUpdateInternal(s: *State) void {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return;
    const current_second = ts.sec;
    
    if (current_second != s.last_second) {
        s.last_second = current_second;
        s.markClockDirty();
    }
}

fn drawClockOnly(s: *State, wm: *defs.WM) !void {
    // Find clock position and redraw only that segment
    for (s.config.layout.items) |layout| {
        if (layout.position == .right) {
            // Calculate right segments to find clock position
            var right_x: u16 = s.width;
            var i: usize = layout.segments.items.len;
            while (i > 0) {
                i -= 1;
                const segment = layout.segments.items[i];
                const seg_width = calculateSegmentWidth(s, wm, segment);
                right_x -= seg_width;
                
                if (segment == .clock) {
                    // Redraw only the clock segment
                    _ = try drawClock(s, right_x);
                    s.dc.flush();
                    return;
                }
                
                if (i > 0) {
                    right_x -= s.config.spacing;
                }
            }
        }
    }
    
    // If clock not found in right, check other positions
    // For now, fall back to full draw if clock position is complex
    try draw(s, wm);
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

    const ws_width: i16 = 40; // Increased from 30 for better spacing
    const clicked_ws: usize = @intCast(@max(0, @divFloor(x, ws_width)));

    if (clicked_ws < ws_count) {
        workspaces.switchTo(wm, clicked_ws);
        s.markDirty();
    }
}

// Main draw function with configurable layout
fn draw(s: *State, wm: *defs.WM) !void {
    if (!s.isAlive()) return error.BarNotAlive;

    // Clear background
    s.dc.fillRect(0, 0, s.width, s.height, s.config.bg);

    // Calculate widths for all segments first
    var left_width: u16 = 0;
    var right_width: u16 = 0;
    
    // Calculate left segments width
    for (s.config.layout.items) |layout| {
        if (layout.position == .left) {
            for (layout.segments.items) |segment| {
                left_width += calculateSegmentWidth(s, wm, segment);
                left_width += s.config.spacing;
            }
            if (layout.segments.items.len > 0) {
                left_width -= s.config.spacing; // Remove last spacing
            }
        }
    }
    
    // Calculate right segments width
    for (s.config.layout.items) |layout| {
        if (layout.position == .right) {
            for (layout.segments.items) |segment| {
                right_width += calculateSegmentWidth(s, wm, segment);
                right_width += s.config.spacing;
            }
            if (layout.segments.items.len > 0) {
                right_width -= s.config.spacing; // Remove last spacing
            }
        }
    }

    // Draw left segments
    var left_x: u16 = 0;
    for (s.config.layout.items) |layout| {
        if (layout.position == .left) {
            for (layout.segments.items) |segment| {
                left_x = try drawSegment(s, wm, segment, left_x, s.config.getWorkspaceAccent(), null);
                left_x += s.config.spacing;
            }
        }
    }

    // Draw center segments (title gets remaining space)
    for (s.config.layout.items) |layout| {
        if (layout.position == .center) {
            // Calculate remaining space for center
            // left_x already includes left segments + their spacing
            // Subtract space needed for right segments and spacing before them
            const space_for_right = if (right_width > 0) right_width + s.config.spacing else 0;
            const remaining_width = if (s.width > left_x + space_for_right) 
                s.width - left_x - space_for_right 
            else 
                100;
            
            var center_x = left_x;
            for (layout.segments.items) |segment| {
                if (segment == .title) {
                    // Title gets all remaining space
                    _ = try drawSegment(s, wm, segment, center_x, s.config.getTitleAccent(), remaining_width);
                } else {
                    // Other center segments use calculated width
                    const seg_width = calculateSegmentWidth(s, wm, segment);
                    _ = try drawSegment(s, wm, segment, center_x, s.config.getTitleAccent(), seg_width);
                    center_x += seg_width + s.config.spacing;
                }
            }
        }
    }

    // Draw right segments (from right to left)
    var right_x: u16 = s.width;
    for (s.config.layout.items) |layout| {
        if (layout.position == .right) {
            var i: usize = layout.segments.items.len;
            while (i > 0) {
                i -= 1;
                const segment = layout.segments.items[i];
                const seg_width = calculateSegmentWidth(s, wm, segment);
                right_x -= seg_width;
                _ = try drawSegment(s, wm, segment, right_x, s.config.getClockAccent(), seg_width);
                if (i > 0) {
                    right_x -= s.config.spacing;
                }
            }
        }
    }

    s.dc.flush();
}

fn calculateSegmentWidth(s: *State, wm: *defs.WM, segment: defs.BarSegment) u16 {
    _ = wm; // May be needed for future dynamic width calculations
    return switch (segment) {
        .workspaces => blk: {
            const ws_state = workspaces.getState() orelse break :blk 270;
            break :blk @intCast(ws_state.workspaces.len * 40); // 40px per workspace
        },
        .layout => 60,
        .title => 100, // Minimal default - will be overridden by remaining space
        .clock => blk: {
            var buf: [64]u8 = undefined;
            const time_str = formatTime(s, &buf) catch "0000-00-00 00:00:00";
            const text_w = s.dc.textWidth(time_str);
            break :blk text_w + 2 * s.config.padding;
        },
    };
}

fn drawSegment(s: *State, wm: *defs.WM, segment: defs.BarSegment, x: u16, accent: u32, width: ?u16) !u16 {
    const seg_width = width orelse calculateSegmentWidth(s, wm, segment);
    return switch (segment) {
        .workspaces => try drawWorkspaces(s, x, accent),
        .layout => try drawLayout(s, x),
        .title => try drawTitle(s, wm, x, seg_width),
        .clock => try drawClock(s, x),
    };
}

fn drawWorkspaces(s: *State, start_x: u16, accent: u32) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    const current = ws_state.current;

    var x = start_x;
    const ws_width: u16 = 40; // Increased from 30 for better spacing

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == current;
        const has_windows = ws.windows.items.len > 0;

        const bg = if (is_current) accent else s.config.bg;
        const fg = if (is_current)
            s.config.selected_fg
        else if (has_windows)
            s.config.occupied_fg
        else
            s.config.fg;

        s.dc.fillRect(x, 0, ws_width, s.height, bg);

        const label = getWorkspaceLabel(s, i);
        const text_w = s.dc.textWidth(label);
        const text_x = x + (ws_width - text_w) / 2;
        const text_y = calculateTextY(s);

        try s.dc.drawText(text_x, text_y, label, fg);

        if (has_windows) {
            try drawIndicator(s, x, is_current, fg);
        }

        x += ws_width;
    }

    return x;
}

fn calculateTextY(s: *State) u16 {
    const ascender: i32 = s.dc.getAscender();
    const descender: i32 = s.dc.getDescender();

    const font_height: i32 = ascender - descender;
    const vertical_padding: i32 = @divTrunc(@as(i32, s.height) - font_height, 2);
    const baseline_y: i32 = vertical_padding + ascender;

    return @intCast(@max(ascender, baseline_y));
}

fn getWorkspaceLabel(s: *State, index: usize) []const u8 {
    if (index < s.config.workspace_icons.items.len) {
        return s.config.workspace_icons.items[index];
    }
    
    // Fallback to number
    var buf: [8]u8 = undefined;
    return std.fmt.bufPrint(&buf, "{}", .{index + 1}) catch "?";
}

fn drawIndicator(s: *State, ws_x: u16, is_current: bool, color: u32) !void {
    const size = s.config.indicator_size;
    const x = ws_x + 3;
    const y: u16 = 3;

    if (is_current) {
        s.dc.fillRect(x, y, size, size, color);
    } else {
        s.dc.fillRect(x, y, size, 1, color);
        s.dc.fillRect(x, y + size - 1, size, 1, color);
        s.dc.fillRect(x, y, 1, size, color);
        s.dc.fillRect(x + size - 1, y, 1, size, color);
    }
}

fn drawLayout(s: *State, start_x: u16) !u16 {
    const t_state = tiling.getState() orelse return start_x;

    const layout_str = switch (t_state.layout) {
        .master => "[]=",
        .monocle => "[M]",
        .grid => "[+]",
    };

    const text_w = s.dc.textWidth(layout_str);
    const width = text_w + s.config.padding * 2;

    s.dc.fillRect(start_x, 0, width, s.height, s.config.bg);

    const text_y = calculateTextY(s);
    try s.dc.drawText(start_x + s.config.padding, text_y, layout_str, s.config.fg);

    return start_x + width;
}

fn drawTitle(s: *State, wm: *defs.WM, start_x: u16, width: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x + width;
    const has_windows = ws_state.workspaces[ws_state.current].windows.items.len > 0;

    const is_focused = has_windows and wm.focused_window != null;
    const bg = if (is_focused and s.config.title_accent)
        s.config.getTitleAccent()
    else
        s.config.bg;
    const fg = if (is_focused and s.config.title_accent)
        s.config.selected_fg
    else
        s.config.fg;

    s.dc.fillRect(start_x, 0, width, s.height, bg);

    if (has_windows) {
        const title = try getFocusedWindowTitle(s, wm);
        defer if (title.len > 0 and s.cached_title.items.ptr != title.ptr) s.allocator.free(title);

        if (title.len > 0) {
            const text_y = calculateTextY(s);
            try s.dc.drawTextEllipsis(start_x + s.config.padding, text_y, title, width - s.config.padding * 2, fg);
        }
    }
    
    return start_x + width;
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

fn drawClock(s: *State, start_x: u16) !u16 {
    var time_buf: [64]u8 = undefined;
    const time_str = try formatTime(s, &time_buf);

    const text_w = s.dc.textWidth(time_str);
    const width = text_w + s.config.padding * 2;

    s.dc.fillRect(start_x, 0, width, s.height, s.config.bg);

    const text_y = calculateTextY(s);
    try s.dc.drawText(start_x + s.config.padding, text_y, time_str, s.config.fg);

    return start_x + width;
}

fn formatTime(s: *State, buf: []u8) ![]const u8 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch {
        return try std.fmt.bufPrint(buf, "????-??-?? ??:??:??", .{});
    };

    const epoch_seconds: i64 = ts.sec;
    const epoch_day = @divFloor(epoch_seconds, std.time.s_per_day);
    const day_seconds = @mod(epoch_seconds, std.time.s_per_day);

    const civil_day = std.time.epoch.EpochDay{ .day = @intCast(epoch_day) };
    const year_day = civil_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const hours: u32 = @intCast(@divFloor(day_seconds, std.time.s_per_hour));
    const minutes: u32 = @intCast(@divFloor(@mod(day_seconds, std.time.s_per_hour), std.time.s_per_min));
    const seconds: u32 = @intCast(@mod(day_seconds, std.time.s_per_min));

    // Simple format string parsing - only supports basic patterns
    _ = s; // config available if needed for format
    
    // YYYY-MM-DD HH:MM:SS format with unsigned integers (no + symbols)
    return try std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        hours,
        minutes,
        seconds,
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
