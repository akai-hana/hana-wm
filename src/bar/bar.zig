//! Status bar
//! Taking inspiration from dwm
//! Now with transparency support and position toggling

const std     = @import("std");
const defs    = @import("defs");
    const xcb = defs.xcb;
const utils   = @import("utils");
const dpi     = @import("dpi");

const drawing = @import("drawing");
const tiling  = @import("tiling");
const debug   = @import("debug");
const timer   = @import("timer");

const workspaces             = @import("workspaces");
    const workspaces_segment = @import("tags");
    const layout_segment     = @import("layout");
    const title_segment      = @import("title");
    const clock_segment      = @import("clock");
    const status_segment     = @import("status");

// TODO: make adjustable through config.toml, adjust workspace width based off of monitor DPI
pub const WORKSPACE_WIDTH: u8 = 50;

/// Result of finding a visual - contains both the structure and ID
const VisualInfo = struct {
    visual_type: ?*xcb.xcb_visualtype_t,
    visual_id: u32,
};

/// Find a visual with the given depth, returning both structure and ID
fn findVisualByDepth(screen: *xcb.xcb_screen_t, depth: u8) VisualInfo {
    var depth_iter = xcb.xcb_screen_allowed_depths_iterator(screen);
    while (depth_iter.rem > 0) : (xcb.xcb_depth_next(&depth_iter)) {
        if (depth_iter.data.*.depth == depth) {
            var visual_iter = xcb.xcb_depth_visuals_iterator(depth_iter.data);
            if (visual_iter.rem > 0) {
                const vt = visual_iter.data;
                return .{ .visual_type = vt, .visual_id = vt.*.visual_id };
            }
        }
    }
    // Fallback to root visual
    return .{ .visual_type = null, .visual_id = screen.root_visual };
}

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
    visible: bool,  // OPTIMIZATION: Track actual visibility for timer control
    has_transparency: bool,  // Track if transparency is enabled
    allocator: std.mem.Allocator,
    cached_clock_width: u16,

    fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t, window: u32, width: u16, height: u16,
            dc: *drawing.DrawContext, config: defs.BarConfig, has_transparency: bool) !*State {
        const s = try allocator.create(State);
        const scaled_padding = config.scaledPadding();
        s.* = State{
            .window = window, .width = width, .height = height, .dc = dc, .conn = conn,
            .config = config,
            .status_text = .{},
            .cached_title = .{},
            .cached_title_window = null,
            .dirty = false, .dirty_clock = false, .last_second = 0, .alive = true,
            .visible = true,  // OPTIMIZATION: Start visible, setBarState will update
            .has_transparency = has_transparency,
            .allocator = allocator,
            .cached_clock_width = dc.textWidth("0000-00-00 00:00:00") + 2 * scaled_padding,
        };
        try s.status_text.appendSlice(allocator, "hana");
        return s;
    }

    fn deinit(self: *State) void {
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn markDirty(self: *State) void { self.dirty = true; }
    fn markClockDirty(self: *State) void { self.dirty_clock = true; }
    fn clearDirty(self: *State) void { self.dirty = false; self.dirty_clock = false; }
    fn isDirty(self: *State) bool { return self.dirty or self.dirty_clock; }
};

var state: ?*State = null;

fn updateClockIfNeeded(s: *State) void {
    // OPTIMIZATION: Skip clock update if bar is hidden (idle CPU reduction)
    if (!s.visible) return;
    
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return;
    if (ts.sec != s.last_second) {
        s.last_second = ts.sec;
        s.markClockDirty();
    }
}

fn sizeFont(alloc: std.mem.Allocator, font: []const u8, size: u16) ![]const u8 {
    return if (size > 0) try std.fmt.allocPrint(alloc, "{s}:size={}", .{font, size}) else font;
}

fn loadBarFonts(dc: *drawing.DrawContext, wm: *defs.WM) !void {
    const cfg = wm.config.bar;
    const alloc = wm.allocator;
    const scaled_size = cfg.scaledFontSize();
    
    if (cfg.fonts.items.len > 0) {
        var sized = std.ArrayList([]const u8){};
        defer {
            for (sized.items) |s| if (scaled_size > 0) alloc.free(s);
            sized.deinit(alloc);
        }
        for (cfg.fonts.items) |f| try sized.append(alloc, try sizeFont(alloc, f, scaled_size));
        return dc.loadFonts(sized.items);
    }
    
    const font_str = try sizeFont(alloc, cfg.font, scaled_size);
    defer if (scaled_size > 0) alloc.free(font_str);
    try dc.loadFont(font_str);
}

inline fn setProp(conn: *xcb.xcb_connection_t, win: u32, name: []const u8, type_: u32, data: anytype) !void {
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win,
        try utils.getAtom(conn, name), type_, 32, data.len, data);
}

fn setWindowProperties(wm: *defs.WM, window: u32, height: u16, want_transparency: bool, alpha: u16) !void {
    const strut: [12]u32 = if (wm.config.bar.vertical_position == .bottom)
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels }
    else
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels, 0, 0 };

    try setProp(wm.conn, window, "_NET_WM_STRUT_PARTIAL", xcb.XCB_ATOM_CARDINAL, &strut);
    try setProp(wm.conn, window, "_NET_WM_WINDOW_TYPE", xcb.XCB_ATOM_ATOM, 
        &[_]u32{try utils.getAtom(wm.conn, "_NET_WM_WINDOW_TYPE_DOCK")});
    try setProp(wm.conn, window, "_NET_WM_STATE", xcb.XCB_ATOM_ATOM,
        &[_]u32{try utils.getAtom(wm.conn, "_NET_WM_STATE_ABOVE"), try utils.getAtom(wm.conn, "_NET_WM_STATE_STICKY")});
    
    // Set window opacity for compositor - this makes picom apply transparency + blur
    if (want_transparency) {
        const opacity_32: u32 = @as(u32, alpha) << 16 | alpha;
        try setProp(wm.conn, window, "_NET_WM_WINDOW_OPACITY", xcb.XCB_ATOM_CARDINAL, &[_]u32{opacity_32});
        debug.info("Set _NET_WM_WINDOW_OPACITY: 0x{x:0>8} ({d:.1}%)", .{opacity_32, (@as(f32, @floatFromInt(alpha)) / 0xFFFF) * 100.0});
    }
    
    // CRITICAL: Prevent bar from being moved or resized
    const allowed_actions = [_]u32{
        try utils.getAtom(wm.conn, "_NET_WM_ACTION_CLOSE"),
        try utils.getAtom(wm.conn, "_NET_WM_ACTION_ABOVE"),
        try utils.getAtom(wm.conn, "_NET_WM_ACTION_STICK"),
    };
    try setProp(wm.conn, window, "_NET_WM_ALLOWED_ACTIONS", xcb.XCB_ATOM_ATOM, &allowed_actions);
}

fn calculateBarHeight(wm: *defs.WM) !u16 {
    if (wm.config.bar.height) |h| return h;
    
    const temp_win = xcb.xcb_generate_id(wm.conn);
    _ = xcb.xcb_create_window(wm.conn, xcb.XCB_COPY_FROM_PARENT, temp_win, wm.screen.root,
        0, 0, 1, 1, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, wm.screen.root_visual, 0, null);
    defer _ = xcb.xcb_destroy_window(wm.conn, temp_win);
    
    const temp_dc = drawing.DrawContext.init(wm.allocator, wm.conn, temp_win, 1, 1, wm.dpi_info.dpi) catch return 24;
    defer temp_dc.deinit();
    loadBarFonts(temp_dc, wm) catch return 24;
    
    const asc, const desc = temp_dc.getMetrics();
    const font_height: u32 = @intCast(asc + desc);  // Both are positive, add them
    const scaled_padding = wm.config.bar.scaledPadding();
    return @intCast(std.math.clamp(font_height + 2 * scaled_padding, 20, 200));
}

pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.show) return error.BarDisabled;

    // Detect DPI and set scale factor
    const dpi_info = try dpi.detect(wm.conn, wm.screen);
    wm.config.bar.scale_factor = dpi_info.scale_factor;
    debug.info("DPI: {d:.1}, Scale factor: {d:.2}x", .{dpi_info.dpi, dpi_info.scale_factor});

    const screen = wm.screen;
    const width = screen.width_in_pixels;
    const height = try calculateBarHeight(wm);
    const y_pos: i16 = if (wm.config.bar.vertical_position == .bottom)
        @as(i16, @intCast(screen.height_in_pixels)) - @as(i16, @intCast(height))
    else 0;

    // Get alpha value for transparency
    const alpha = wm.config.bar.getAlpha16();
    const want_transparency = alpha < 0xFFFF;
    
    debug.info("Bar transparency config: {d:.2}% (want={}, alpha16=0x{x:0>4})", 
        .{wm.config.bar.transparency * 100.0, want_transparency, alpha});
    
    const window = xcb.xcb_generate_id(wm.conn);
    
    // Create regular 24-bit window - picom will handle transparency via _NET_WM_WINDOW_OPACITY
    _ = xcb.xcb_create_window(
        wm.conn, 
        xcb.XCB_COPY_FROM_PARENT,
        window, 
        screen.root,
        0, y_pos, width, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, 
        screen.root_visual,
        xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK,
        &[_]u32{ wm.config.bar.bg, xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS },
    );
    
    debug.info("Bar window created (id=0x{x}, transparency={d:.1}%)", .{window, wm.config.bar.transparency * 100.0});

    try setWindowProperties(wm, window, height, want_transparency, alpha);
    _ = xcb.xcb_map_window(wm.conn, window);
    utils.flush(wm.conn);

    // Create DrawContext with regular visual - draw everything opaque
    const dc = try drawing.DrawContext.init(wm.allocator, wm.conn, window, width, height, wm.dpi_info.dpi);
    errdefer dc.deinit();
    try loadBarFonts(dc, wm);

    const s = try State.init(wm.allocator, wm.conn, window, width, height, dc, wm.config.bar, false);
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

fn setBarVisibility(wm: *defs.WM, visible: bool, reason: []const u8) void {
    if (state) |s| {
        // OPTIMIZATION: Update visibility state for timer control
        s.visible = visible;
        
        if (visible) {
            _ = xcb.xcb_map_window(s.conn, s.window);
            utils.flush(wm.conn);
            draw(s, wm) catch {};
        } else {
            _ = xcb.xcb_unmap_window(s.conn, s.window);
        }
        utils.flush(wm.conn);
        debug.info("Bar {s} ({s})", .{ if (visible) "shown" else "hidden", reason });
        
        // OPTIMIZATION: Update timer state when visibility changes
        timer.updateTimerState(wm);
        
        tiling.retileCurrentWorkspace(wm);
    }
}

// NEW: Toggle bar position between top and bottom
pub fn toggleBarPosition(wm: *defs.WM) !void {
    if (state) |s| {
        // Toggle the position in config
        wm.config.bar.vertical_position = switch (wm.config.bar.vertical_position) {
            .top => .bottom,
            .bottom => .top,
        };
        
        // Calculate new y position
        const new_y: i16 = if (wm.config.bar.vertical_position == .bottom)
            @as(i16, @intCast(wm.screen.height_in_pixels)) - @as(i16, @intCast(s.height))
        else 0;
        
        // Move the window to new position
        const values = [_]u32{@as(u32, @bitCast(@as(i32, new_y)))};
        _ = xcb.xcb_configure_window(s.conn, s.window, 
            xcb.XCB_CONFIG_WINDOW_Y, &values);
        
        // Update window properties for new position
        const alpha = wm.config.bar.getAlpha16();
        const want_transparency = alpha < 0xFFFF;
        try setWindowProperties(wm, s.window, s.height, want_transparency, alpha);
        
        utils.flush(wm.conn);
        debug.info("Bar position toggled to: {s}", .{@tagName(wm.config.bar.vertical_position)});
        
        // Retile workspace to adjust for new bar position
        tiling.retileCurrentWorkspace(wm);
    }
}

pub fn getBarWindow() u32 { return if (state) |s| s.window else 0; }
pub fn isBarWindow(win: u32) bool { return if (state) |s| s.window == win else false; }
pub fn markDirty() void { if (state) |s| s.markDirty(); }
pub fn raiseBar() void {
    if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}
pub fn getBarHeight() u16 { return if (state) |s| s.height else 0; }
pub fn isBarVisible() bool { return state != null; }

// OPTIMIZATION: Check if bar is actually visible (not just created)
pub fn isVisible() bool {
    if (state) |s| return s.visible;
    return false;
}

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

pub fn setBarState(wm: *defs.WM, action: BarAction) void {
    const show = switch (action) {
        .toggle => blk: { wm.config.bar.show = !wm.config.bar.show; break :blk wm.config.bar.show; },
        .hide_fullscreen => false,
        .show_fullscreen => wm.config.bar.show,
    };
    const reason = switch (action) {
        .toggle => "toggle",
        .hide_fullscreen => "fullscreen",
        .show_fullscreen => "exit fullscreen",
    };
    if (action != .show_fullscreen or wm.config.bar.show) {
        setBarVisibility(wm, show, reason);
    }
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
    for (s.config.layout.items) |layout| {
        if (layout.position != .right) continue;
        
        var right_x: u16 = s.width;
        var i = layout.segments.items.len;
        while (i > 0) : (i -= 1) {
            const segment = layout.segments.items[i - 1];
            right_x -= calculateSegmentWidth(s, segment);
            
            if (segment == .clock) {
                _ = try clock_segment.draw(s.dc, s.config, s.height, right_x);
                s.dc.flush();
                return;
            }
            if (i > 1) right_x -= s.config.spacing;
        }
    }
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
        const scaled_ws_width = s.config.scaledWorkspaceWidth();
        const clicked_ws: usize = @intCast(@max(0, @divFloor(event.event_x, scaled_ws_width)));
        if (clicked_ws < ws_state.workspaces.len) {
            workspaces.switchTo(wm, clicked_ws);
            s.markDirty();
        }
    };
}

fn calculateSegmentWidth(s: *State, segment: defs.BarSegment) u16 {
    return switch (segment) {
        .workspaces => if (workspaces.getState()) |ws| @intCast(ws.workspaces.len * s.config.scaledWorkspaceWidth()) else 270,
        .layout => 60,
        .title => 100,
        .clock => s.cached_clock_width,
    };
}

fn drawRightSegments(s: *State, wm: *defs.WM, segments: []const defs.BarSegment) !void {
    var right_x: u16 = s.width;
    const scaled_spacing = s.config.scaledSpacing();
    for (0..segments.len) |i| {
        const idx = segments.len - 1 - i;
        right_x -= calculateSegmentWidth(s, segments[idx]);
        _ = try drawSegment(s, wm, segments[idx], right_x, null);
        if (i < segments.len - 1) right_x -= scaled_spacing;
    }
}

fn draw(s: *State, wm: *defs.WM) !void {
    // CRITICAL: Clear the surface to transparent before drawing (for ARGB windows)
    // This initializes the alpha channel properly
    if (s.has_transparency) {
        s.dc.clearTransparent();
    }
    
    s.dc.fillRect(0, 0, s.width, s.height, s.config.bg);

    // Pre-calculate widths
    const scaled_spacing = s.config.scaledSpacing();
    var widths = [_]u16{0} ** 2; // [left, right]
    for (s.config.layout.items) |layout| {
        const idx: usize = switch (layout.position) {
            .left => 0,
            .right => 1,
            .center => continue,
        };
        for (layout.segments.items) |segment| widths[idx] += calculateSegmentWidth(s, segment) + scaled_spacing;
        if (layout.segments.items.len > 0) widths[idx] -= scaled_spacing;
    }

    var x: u16 = 0;
    for (s.config.layout.items) |layout| {
        switch (layout.position) {
            .left => for (layout.segments.items) |segment| {
                x = try drawSegment(s, wm, segment, x, null);
                x += scaled_spacing;
            },
            .center => {
                const remaining = @max(100, s.width -| x -| widths[1] -| scaled_spacing);
                for (layout.segments.items) |segment| {
                    const w = if (segment == .title) remaining else calculateSegmentWidth(s, segment);
                    x = try drawSegment(s, wm, segment, x, w);
                    if (segment != .title) x += scaled_spacing;
                }
            },
            .right => try drawRightSegments(s, wm, layout.segments.items),
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
