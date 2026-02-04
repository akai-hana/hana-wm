//! Enhanced status bar with configurable layout and auto-sizing

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const utils = @import("utils");
const workspaces = @import("workspaces");
const tiling = @import("tiling");

const c = @cImport({
    @cInclude("X11/Xlib.h");
});

const workspaces_segment = @import("tags");
const layout_segment = @import("layout");
const title_segment = @import("title");
const clock_segment = @import("clock");
const status_segment = @import("status");

pub const WORKSPACE_WIDTH: u16 = 40;

const State = struct {
    window: u32,
    width: u16,
    height: u16,
    dc: *drawing.DrawContext,
    conn: *xcb.xcb_connection_t,
    config: defs.BarConfig,
    status_text: std.ArrayList(u8),
    cached_title: std.ArrayList(u8),
    cached_title_window: ?u32,
    dirty: bool,
    dirty_clock: bool,
    last_second: i64,
    alive: bool,
    allocator: std.mem.Allocator,
    cached_clock_width: u16,

    fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t, window: u32, width: u16, height: u16,
            dc: *drawing.DrawContext, config: defs.BarConfig) !*State {
        const s = try allocator.create(State);
        s.* = .{
            .window = window,
            .width = width,
            .height = height,
            .dc = dc,
            .conn = conn,
            .config = config,
            .status_text = .{},  // Simplified initialization
            .cached_title = .{},  // Simplified initialization
            .cached_title_window = null,
            .dirty = false,
            .dirty_clock = false,
            .last_second = 0,
            .alive = true,
            .allocator = allocator,
            .cached_clock_width = dc.textWidth("0000-00-00 00:00:00") + 2 * config.padding,
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
    inline fn clearDirty(self: *State) void { self.dirty = false; self.dirty_clock = false; }
    inline fn isDirty(self: *State) bool { return self.dirty or self.dirty_clock; }
};

var state: ?*State = null;

// Helper function for time checking
inline fn updateClockIfNeeded(s: *State) void {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return;
    if (ts.sec != s.last_second) {
        s.last_second = ts.sec;
        s.markClockDirty();
    }
}

fn loadBarFonts(dc: *drawing.DrawContext, wm: *defs.WM) !void {
    if (wm.config.bar.fonts.items.len > 0) {
        var sized_fonts = std.ArrayList([]const u8){};
        defer {
            for (sized_fonts.items) |s| wm.allocator.free(s);
            sized_fonts.deinit(wm.allocator);
        }
        for (wm.config.bar.fonts.items) |font_name| {
            const sized = if (wm.config.bar.font_size > 0)
                try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ font_name, wm.config.bar.font_size })
            else
                try wm.allocator.dupe(u8, font_name);
            try sized_fonts.append(wm.allocator, sized);
        }
        try dc.loadFonts(sized_fonts.items);
    } else {
        const font_str = if (wm.config.bar.font_size > 0)
            try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
        else
            wm.config.bar.font;
        defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);
        try dc.loadFont(font_str);
    }
}

fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) !void {
    const strut: [12]u32 = if (wm.config.bar.vertical_position == .bottom)
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels }
    else
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels, 0, 0 };

    _ = xcb.xcb_change_property(wm.conn, xcb.XCB_PROP_MODE_REPLACE, window,
        try utils.getAtom(wm.conn, "_NET_WM_STRUT_PARTIAL"), xcb.XCB_ATOM_CARDINAL, 32, 12, &strut);

    _ = xcb.xcb_change_property(wm.conn, xcb.XCB_PROP_MODE_REPLACE, window,
        try utils.getAtom(wm.conn, "_NET_WM_WINDOW_TYPE"), xcb.XCB_ATOM_ATOM, 32, 1,
        &[_]u32{try utils.getAtom(wm.conn, "_NET_WM_WINDOW_TYPE_DOCK")});

    _ = xcb.xcb_change_property(wm.conn, xcb.XCB_PROP_MODE_REPLACE, window,
        try utils.getAtom(wm.conn, "_NET_WM_STATE"), xcb.XCB_ATOM_ATOM, 32, 2,
        &[_]u32{ try utils.getAtom(wm.conn, "_NET_WM_STATE_ABOVE"), try utils.getAtom(wm.conn, "_NET_WM_STATE_STICKY") });
}

fn calculateBarHeight(wm: *defs.WM) !u16 {
    if (wm.config.bar.height) |h| return h;
    
    const temp_win = xcb.xcb_generate_id(wm.conn);
    _ = xcb.xcb_create_window(wm.conn, xcb.XCB_COPY_FROM_PARENT, temp_win, wm.screen.root,
        0, 0, 1, 1, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, wm.screen.root_visual, 0, null);
    defer _ = xcb.xcb_destroy_window(wm.conn, temp_win);
    
    const temp_dc = drawing.DrawContext.init(wm.allocator, temp_win, 1, 1) catch return 24;
    defer temp_dc.deinit();
    loadBarFonts(temp_dc, wm) catch return 24;
    
    const font_height: u32 = @intCast(temp_dc.getAscender() - temp_dc.getDescender());
    return @intCast(std.math.clamp(font_height + 2 * wm.config.bar.padding, 20, 100));
}

pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.show) return error.BarDisabled;

    const screen = wm.screen;
    const width = screen.width_in_pixels;
    const height = try calculateBarHeight(wm);
    const y_pos: i16 = if (wm.config.bar.vertical_position == .bottom)
        @as(i16, @intCast(screen.height_in_pixels)) - @as(i16, @intCast(height))
    else 0;

    const window = xcb.xcb_generate_id(wm.conn);
    _ = xcb.xcb_create_window(
        wm.conn, xcb.XCB_COPY_FROM_PARENT, window, screen.root,
        0, y_pos, width, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, screen.root_visual,
        xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK,
        &[_]u32{ wm.config.bar.bg, xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS },
    );

    try setWindowProperties(wm, window, height);
    _ = xcb.xcb_map_window(wm.conn, window);
    utils.flush(wm.conn);

    const dc = try drawing.DrawContext.init(wm.allocator, window, width, height);
    errdefer dc.deinit();
    try loadBarFonts(dc, wm);

    const s = try State.init(wm.allocator, wm.conn, window, width, height, dc, wm.config.bar);
    try draw(s, wm);
    utils.flush(wm.conn);
    state = s;
}

pub fn deinit() void {
    if (state) |s| {
        const conn, const window = .{ s.conn, s.window };
        s.dc.deinit();
        s.deinit();
        _ = xcb.xcb_destroy_window(conn, window);
        state = null;
    }
}

// Consolidated function for bar visibility changes
fn setBarVisibility(wm: *defs.WM, visible: bool, reason: []const u8) void {
    if (state) |s| {
        if (visible) {
            _ = xcb.xcb_map_window(s.conn, s.window);
            utils.flush(wm.conn);
            _ = c.XSync(@ptrCast(s.dc.display), 0);
            draw(s, wm) catch {};
        } else {
            _ = xcb.xcb_unmap_window(s.conn, s.window);
        }
        utils.flush(wm.conn);
        std.log.info("[bar] Bar {s} ({s})", .{ if (visible) "shown" else "hidden", reason });
        tiling.retileCurrentWorkspace(wm);
    }
}

pub inline fn getBarWindow() u32 { return if (state) |s| s.window else 0; }
pub inline fn isBarWindow(win: u32) bool { return if (state) |s| s.window == win else false; }
pub inline fn markDirty() void { if (state) |s| s.markDirty(); }
pub inline fn raiseBar() void {
    if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}
pub inline fn getBarHeight() u16 { return if (state) |s| s.height else 0; }
pub inline fn getHeight() u16 { return getBarHeight(); }
pub inline fn isBarVisible() bool { return state != null; }

pub fn toggleBar(wm: *defs.WM) void {
    wm.config.bar.show = !wm.config.bar.show;
    setBarVisibility(wm, wm.config.bar.show, "toggle");
}

pub fn hideForFullscreen(wm: *defs.WM) void {
    setBarVisibility(wm, false, "fullscreen");
}

pub fn showForFullscreen(wm: *defs.WM) void {
    if (wm.config.bar.show) setBarVisibility(wm, true, "exit fullscreen");
}

pub fn updateIfDirty(wm: *defs.WM) !void {
    if (state) |s| {
        updateClockIfNeeded(s);
        
        if (s.isDirty()) {
            if (s.dirty) try draw(s, wm) else if (s.dirty_clock) try drawClockOnly(s, wm);
            s.clearDirty();
        }
    }
}

pub fn checkClockUpdate() !void {
    if (state) |s| updateClockIfNeeded(s);
}

fn drawClockOnly(s: *State, wm: *defs.WM) !void {
    // Fast path: only redraw clock if it's in the right layout
    for (s.config.layout.items) |layout| {
        if (layout.position != .right) continue;
        
        var right_x: u16 = s.width;
        var i = layout.segments.items.len;
        while (i > 0) : (i -= 1) {
            const segment = layout.segments.items[i - 1];
            const w = calculateSegmentWidth(s, segment);
            right_x -= w;
            
            if (segment == .clock) {
                _ = try clock_segment.draw(s.dc, s.config, s.height, right_x);
                s.dc.flush();
                return;
            }
            if (i > 1) right_x -= s.config.spacing;
        }
    }
    // Fallback to full redraw if clock not found in right position
    try draw(s, wm);
}

pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
    if (state) |s| if (event.window == s.window and event.count == 0) draw(s, wm) catch {};
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
    if (state) |s| if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
        status_segment.update(wm, &s.status_text, s.allocator) catch {};
        s.markDirty();
    };
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
    if (state) |s| if (event.event == s.window) {
        const ws_state = workspaces.getState() orelse return;
        const clicked_ws: usize = @intCast(@max(0, @divFloor(event.event_x, WORKSPACE_WIDTH)));
        if (clicked_ws < ws_state.workspaces.len) {
            workspaces.switchTo(wm, clicked_ws);
            s.markDirty();
        }
    };
}

fn calculateSegmentWidth(s: *State, segment: defs.BarSegment) u16 {
    return switch (segment) {
        .workspaces => if (workspaces.getState()) |ws| @intCast(ws.workspaces.len * WORKSPACE_WIDTH) else 270,
        .layout => 60,
        .title => 100,
        .clock => s.cached_clock_width,
    };
}

fn draw(s: *State, wm: *defs.WM) !void {
    s.dc.fillRect(0, 0, s.width, s.height, s.config.bg);

    var left_width: u16 = 0;
    var right_width: u16 = 0;
    
    // Pre-calculate widths for each position
    for (s.config.layout.items) |layout| {
        const width_ptr = switch (layout.position) {
            .left => &left_width,
            .right => &right_width,
            .center => continue,
        };
        for (layout.segments.items) |segment| {
            width_ptr.* += calculateSegmentWidth(s, segment) + s.config.spacing;
        }
        if (layout.segments.items.len > 0) width_ptr.* -= s.config.spacing;
    }

    var x: u16 = 0;
    for (s.config.layout.items) |layout| {
        switch (layout.position) {
            .left => for (layout.segments.items) |segment| {
                x = try drawSegment(s, wm, segment, x, null);
                x += s.config.spacing;
            },
            .center => {
                const remaining = if (s.width > x + right_width + s.config.spacing)
                    s.width - x - right_width - s.config.spacing else 100;
                for (layout.segments.items) |segment| {
                    const w = if (segment == .title) remaining else calculateSegmentWidth(s, segment);
                    x = try drawSegment(s, wm, segment, x, w);
                    if (segment != .title) x += s.config.spacing;
                }
            },
            .right => {
                var right_x: u16 = s.width;
                var i = layout.segments.items.len;
                while (i > 0) : (i -= 1) {
                    const w = calculateSegmentWidth(s, layout.segments.items[i - 1]);
                    right_x -= w;
                    _ = try drawSegment(s, wm, layout.segments.items[i - 1], right_x, w);
                    if (i > 1) right_x -= s.config.spacing;
                }
            },
        }
    }
    s.dc.flush();
}

fn drawSegment(s: *State, wm: *defs.WM, segment: defs.BarSegment, x: u16, width: ?u16) !u16 {
    return switch (segment) {
        .workspaces => try workspaces_segment.draw(s.dc, s.config, s.height, x),
        .layout => try layout_segment.draw(s.dc, s.config, s.height, x),
        .title => try title_segment.draw(s.dc, s.config, s.height, x, width orelse 100, wm, &s.cached_title, &s.cached_title_window, s.allocator),
        .clock => try clock_segment.draw(s.dc, s.config, s.height, x),
    };
}
