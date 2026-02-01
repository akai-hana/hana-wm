//! Enhanced status bar with configurable layout and auto-sizing

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const drawing = @import("drawing");
const utils = @import("utils");
const workspaces = @import("workspaces");
const tiling = @import("tiling");

// X11 for XSync (to fix bar toggle lag)
const c = @cImport({
    @cInclude("X11/Xlib.h");
});

// Segment modules
const workspaces_segment = @import("tags");
const layout_segment = @import("layout");
const title_segment = @import("title");
const clock_segment = @import("clock");
const status_segment = @import("status");

const State = struct {
    window: u32,
    width: u16,
    height: u16,
    dc: *drawing.DrawContext,
    conn: *xcb.xcb_connection_t,  // CRITICAL FIX: Store real XCB connection
    config: defs.BarConfig,
    status_text: std.ArrayList(u8),
    cached_title: std.ArrayList(u8),
    cached_title_window: ?u32,
    dirty: bool,
    dirty_clock: bool,
    last_second: i64,
    alive: bool,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t, window: u32, width: u16, height: u16,
            dc: *drawing.DrawContext, config: defs.BarConfig) !*State {
        const s = try allocator.create(State);
        s.* = .{
            .window = window,
            .width = width,
            .height = height,
            .dc = dc,
            .conn = conn,  // Store the real connection
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
    try setWindowProperties(wm, window, height);
    utils.flush(wm.conn);
    _ = xcb.xcb_map_window(wm.conn, window);
    utils.flush(wm.conn);

    const dc = try drawing.DrawContext.init(wm.allocator, wm.conn, screen, window, width, height);
    errdefer dc.deinit();

    // Load fonts - support multi-font for CJK characters
    if (wm.config.bar.fonts.items.len > 0) {
        // Build per-font sized name array and call loadFonts for true per-glyph fallback
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
        // Fallback to single font (backwards compatibility)
        const font_str = if (wm.config.bar.font_size > 0)
            try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
        else
            wm.config.bar.font;
        defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);

        dc.loadFont(font_str) catch |err| {
            std.log.err("[bar] Failed to load font '{s}': {}", .{ font_str, err });
            return err;
        };
    }

    const s = try State.init(wm.allocator, wm.conn, window, width, height, dc, wm.config.bar);
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
    
    // Load fonts for measurement - use same logic as main bar
    if (wm.config.bar.fonts.items.len > 0) {
        var sized_fonts = std.ArrayList([]const u8){};
        defer {
            for (sized_fonts.items) |s| wm.allocator.free(s);
            sized_fonts.deinit(wm.allocator);
        }
        
        for (wm.config.bar.fonts.items) |font_name| {
            const sized = std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ font_name, wm.config.bar.font_size }) catch {
                return 24;
            };
            sized_fonts.append(wm.allocator, sized) catch {
                wm.allocator.free(sized);
                return 24;
            };
        }
        
        temp_dc.loadFonts(sized_fonts.items) catch {
            return 24; // Fallback
        };
    } else {
        const font_str = if (wm.config.bar.font_size > 0)
            try std.fmt.allocPrint(wm.allocator, "{s}:size={}", .{ wm.config.bar.font, wm.config.bar.font_size })
        else
            wm.config.bar.font;
        defer if (wm.config.bar.font_size > 0) wm.allocator.free(font_str);
        
        temp_dc.loadFont(font_str) catch {
            return 24; // Fallback
        };
    }
    
    const ascender: i32 = temp_dc.getAscender();
    const descender: i32 = temp_dc.getDescender();
    const font_height: u32 = @intCast(ascender - descender);
    
    // Add padding (top and bottom)
    const total_height: u32 = font_height + 2 * wm.config.bar.padding;
    
    return @intCast(std.math.clamp(total_height, 20, 100));
}

pub fn deinit() void {
    if (state) |s| {
        const conn = s.conn;  // Use real XCB connection
        const window = s.window;
        s.dc.deinit();
        s.deinit();
        _ = xcb.xcb_destroy_window(conn, window);
        state = null;
    }
}

fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) !void {
    const conn = wm.conn;
    const screen_w = wm.screen.width_in_pixels;

    const wm_strut_partial = try utils.getAtom(conn, "_NET_WM_STRUT_PARTIAL");
    // _NET_WM_STRUT_PARTIAL layout:
    //   [0-3]   left, right, top, bottom          — reserved pixel counts per edge
    //   [4-5]   left_start_y,  left_end_y         — Y range the left strut occupies
    //   [6-7]   right_start_y, right_end_y        — Y range the right strut occupies
    //   [8-9]   top_start_x,   top_end_x          — X range the top strut occupies
    //   [10-11] bottom_start_x, bottom_end_x      — X range the bottom strut occupies
    const strut: [12]u32 = if (wm.config.bar.vertical_position == .bottom)
        .{ 0, 0, 0, height,  0, 0, 0, 0,  0, 0,  0, screen_w }
    else
        .{ 0, 0, height, 0,  0, 0, 0, 0,  0, screen_w,  0, 0 };

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
        _ = xcb.xcb_configure_window(s.conn, s.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}

pub fn toggleBar(wm: *defs.WM) void {
    if (state) |s| {
        // Toggle the visibility
        wm.config.bar.show = !wm.config.bar.show;
        
        if (wm.config.bar.show) {
            // Show the bar
            _ = xcb.xcb_map_window(s.conn, s.window);
            utils.flush(wm.conn);
            
            // CRITICAL FIX: Sync with X server to ensure window is fully mapped
            // before drawing. This prevents segment lag where the bar appears
            // but segments are blank until Expose event arrives.
            _ = c.XSync(@as(?*c.struct__XDisplay, @ptrCast(s.dc.display)), 0);
            
            // Immediately redraw to avoid blank bar during Expose event delay
            draw(s, wm) catch {};
            std.log.info("[bar] Bar shown", .{});
        } else {
            // Hide the bar
            _ = xcb.xcb_unmap_window(s.conn, s.window);
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

/// Hide bar temporarily (e.g., for fullscreen) without changing config
pub fn hideForFullscreen(wm: *defs.WM) void {
    if (state) |s| {
        _ = xcb.xcb_unmap_window(s.conn, s.window);
        utils.flush(wm.conn);
        std.log.info("[bar] Bar hidden (fullscreen)", .{});
        
        // Retile to use full screen space
        @import("tiling").retileCurrentWorkspace(wm);
    }
}

/// Show bar after exiting fullscreen (only if bar is enabled in config)
pub fn showForFullscreen(wm: *defs.WM) void {
    if (state) |s| {
        if (wm.config.bar.show) {  // Only show if bar is enabled in config
            _ = xcb.xcb_map_window(s.conn, s.window);
            draw(s, wm) catch {};
            utils.flush(wm.conn);
            std.log.info("[bar] Bar shown (exit fullscreen)", .{});
            
            // Retile to account for bar space
            @import("tiling").retileCurrentWorkspace(wm);
        }
    }
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
                    _ = try clock_segment.draw(s.dc, s.config, s.height, right_x);
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
            status_segment.update(wm, &s.status_text, s.allocator) catch {};
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
            // Use dummy time string to calculate width
            const time_str = "0000-00-00 00:00:00";
            const text_w = s.dc.textWidth(time_str);
            break :blk text_w + 2 * s.config.padding;
        },
    };
}

fn drawSegment(s: *State, wm: *defs.WM, segment: defs.BarSegment, x: u16, accent: u32, width: ?u16) !u16 {
    _ = accent; // Not currently used by segment modules
    const seg_width = width orelse calculateSegmentWidth(s, wm, segment);
    return switch (segment) {
        .workspaces => try workspaces_segment.draw(s.dc, s.config, s.height, x),
        .layout => try layout_segment.draw(s.dc, s.config, s.height, x),
        .title => try title_segment.draw(s.dc, s.config, s.height, x, seg_width, wm, &s.cached_title, &s.cached_title_window, s.allocator),
        .clock => try clock_segment.draw(s.dc, s.config, s.height, x),
    };
}
