//! Status bar
//! Taking inspiration from dwm
//! Now with transparency support and position toggling

const std     = @import("std");
const defs    = @import("defs");
    const xcb = defs.xcb;
const utils   = @import("utils");

const drawing = @import("drawing");
const tiling  = @import("tiling");
const debug   = @import("debug");
const cache   = @import("cache");

const workspaces             = @import("workspaces");
    const workspaces_segment = @import("tags");
    const layout_segment     = @import("layout");
    const title_segment      = @import("title");
    const clock_segment      = @import("clock");
    const status_segment     = @import("status");

// Clock format string constant for width calculation
const CLOCK_FORMAT = "0000-00-00 00:00:00";

// Minimum allowed bar height in pixels
const MIN_BAR_HEIGHT: u32 = 20;

/// Maximum allowed bar height in pixels
const MAX_BAR_HEIGHT: u32 = 200;

/// Default bar height if font metrics cannot be determined
const DEFAULT_BAR_HEIGHT: u16 = 24;

// Segment width constants
const FALLBACK_WORKSPACES_WIDTH: u16 = 270;
const LAYOUT_SEGMENT_WIDTH: u16 = 60;
const TITLE_SEGMENT_MIN_WIDTH: u16 = 100;

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
    visible: bool,  // Current actual visibility (whether bar is mapped)
    global_visible: bool,  // Global bar state - what visibility should be when not fullscreen
    has_transparency: bool,  // Track if transparency is enabled
    allocator: std.mem.Allocator,
    cached_clock_width: u16,
    cached_clock_x: ?u16,  // Cache clock X position to skip width calculation
    cached_ws_width: u16,
    cached_workspace_x: u16,  // Cache workspace segment X offset for click handling
    cached_indicator_size: u16,
    has_clock_segment: bool,
    cache_manager: cache.CacheManager,  // Embedded by value — State is already heap-allocated

    fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t, window: u32, width: u16, height: u16,
            dc: *drawing.DrawContext, config: defs.BarConfig, has_transparency: bool) !*State {
        const s = try allocator.create(State);
        const scaled_padding = config.scaledPadding();
        
        s.* = State{
            .window = window, .width = width, .height = height, .dc = dc, .conn = conn,
            .config = config,
            .status_text = std.ArrayList(u8).empty,
            .cached_title = std.ArrayList(u8).empty,
            .cached_title_window = null,
            .dirty = false, .dirty_clock = false,
            .visible = true,
            .global_visible = true,  // Initialize global state to true (bar shown by default)
            .has_transparency = has_transparency,
            .allocator = allocator,
            .cached_clock_width = dc.textWidth(CLOCK_FORMAT) + 2 * scaled_padding,
            .cached_clock_x = null,
            .cached_ws_width = config.scaledWorkspaceWidth(),
            .cached_workspace_x = 0,
            .cached_indicator_size = config.scaledIndicatorSize(),
            .has_clock_segment = State.detectClockSegment(&config),
            .cache_manager = cache.CacheManager.init(),
        };
        
        // Pre-allocate capacity for performance
        try s.status_text.ensureTotalCapacity(allocator, 256);
        try s.cached_title.ensureTotalCapacity(allocator, 256);
        
        // Initialize workspace label cache
        try s.cache_manager.updateWorkspaceLabels(dc, &config);
        
        return s;
    }

    fn deinit(self: *State) void {
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn markDirty(self: *State) void { 
        self.dirty = true; 
        self.cached_clock_x = null;  // Invalidate clock position cache
    }
    fn markClockDirty(self: *State) void { self.dirty_clock = true; }
    fn clearDirty(self: *State) void { self.dirty = false; self.dirty_clock = false; }
    fn isDirty(self: *State) bool { return self.dirty or self.dirty_clock; }
    
    fn detectClockSegment(config: *const defs.BarConfig) bool {
        for (config.layout.items) |layout| {
            for (layout.segments.items) |seg| {
                if (seg == .clock) return true;
            }
        }
        return false;
    }
};

/// Single-threaded: Only accessed from main event loop
/// NOT thread-safe: Do not access from signal handlers or other threads
var state: ?*State = null;

/// Append `:size=N` to a font name when size > 0.
/// Returns null when no modification is needed (use original font name as-is).
/// Caller must free the returned slice when it is non-null.
fn sizeFont(alloc: std.mem.Allocator, font: []const u8, size: u16) !?[]const u8 {
    if (size == 0) return null;
    return @as(?[]const u8, try std.fmt.allocPrint(alloc, "{s}:size={}", .{ font, size }));
}

fn loadBarFonts(dc: *drawing.DrawContext, wm: *defs.WM) !void {
    const cfg        = wm.config.bar;
    const alloc      = wm.allocator;
    const scaled_size = cfg.scaledFontSize();

    if (cfg.fonts.items.len > 0) {
        var sized = std.ArrayList([]const u8){};
        defer {
            for (sized.items, 0..) |s, i| if (s.ptr != cfg.fonts.items[i].ptr) alloc.free(s);
            sized.deinit(alloc);
        }
        for (cfg.fonts.items) |f| {
            const s = (try sizeFont(alloc, f, scaled_size)) orelse f;
            try sized.append(alloc, s);
        }
        return dc.loadFonts(sized.items);
    }

    const font_str = (try sizeFont(alloc, cfg.font, scaled_size)) orelse cfg.font;
    defer if (font_str.ptr != cfg.font.ptr) alloc.free(font_str);
    try dc.loadFont(font_str);
}

inline fn setProp(conn: *xcb.xcb_connection_t, win: u32, name: []const u8, type_: u32, data: anytype) !void {
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win,
        try utils.getAtom(conn, name), type_, 32, data.len, data);
}

fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) !void {
    
    const strut: [12]u32 = if (wm.config.bar.vertical_position == .bottom)
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels }
    else
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels, 0, 0 };

    try setProp(wm.conn, window, "_NET_WM_STRUT_PARTIAL", xcb.XCB_ATOM_CARDINAL, &strut);
    try setProp(wm.conn, window, "_NET_WM_WINDOW_TYPE", xcb.XCB_ATOM_ATOM, 
        &[_]u32{try utils.getAtom(wm.conn, "_NET_WM_WINDOW_TYPE_DOCK")});
    try setProp(wm.conn, window, "_NET_WM_STATE", xcb.XCB_ATOM_ATOM,
        &[_]u32{try utils.getAtom(wm.conn, "_NET_WM_STATE_ABOVE"), try utils.getAtom(wm.conn, "_NET_WM_STATE_STICKY")});
    
    // DON'T set _NET_WM_WINDOW_OPACITY - let picom handle transparency like it does for borders
    // This ensures the bar and borders render the same way
    
    // Prevent bar from being moved or resized by restricting allowed actions
    const allowed_actions = [_]u32{
        try utils.getAtom(wm.conn, "_NET_WM_ACTION_CLOSE"),
        try utils.getAtom(wm.conn, "_NET_WM_ACTION_ABOVE"),
        try utils.getAtom(wm.conn, "_NET_WM_ACTION_STICK"),
    };
    try setProp(wm.conn, window, "_NET_WM_ALLOWED_ACTIONS", xcb.XCB_ATOM_ATOM, &allowed_actions);
}

fn calculateBarHeight(wm: *defs.WM) !u16 {
    if (wm.config.bar.height) |h| return h;
    
    // Create a temporary window to measure font height, then calculate bar height.
    // Optimization: Could create the real bar window with a provisional height,
    // measure on the real DrawContext, then resize if needed.
    const temp_win = xcb.xcb_generate_id(wm.conn);
    _ = xcb.xcb_create_window(wm.conn, xcb.XCB_COPY_FROM_PARENT, temp_win, wm.screen.root,
        0, 0, 1, 1, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, wm.screen.root_visual, 0, null);
    defer _ = xcb.xcb_destroy_window(wm.conn, temp_win);
    
    const temp_dc = drawing.DrawContext.init(wm.allocator, wm.conn, temp_win, 1, 1, wm.dpi_info.dpi) catch |e| {
        debug.warnOnErr(e, "DrawContext.init in measureBarHeight");
        return DEFAULT_BAR_HEIGHT;
    };
    defer temp_dc.deinit();
    loadBarFonts(temp_dc, wm) catch {
        // If font loading fails, return default height instead of failing
        debug.warn("Failed to load fonts for height calculation, using default", .{});
        return DEFAULT_BAR_HEIGHT;
    };
    
    // Get actual font height
    const asc, const desc = temp_dc.getMetrics();
    const font_height: u32 = @intCast(asc + desc);
    const scaled_padding: u32 = @intCast(wm.config.bar.scaledPadding());
    
    // Calculate bar height with padding
    const computed_height: u32 = font_height + (2 * scaled_padding);
    
    // Clamp to reasonable bounds
    return @intCast(@min(@max(computed_height, MIN_BAR_HEIGHT), MAX_BAR_HEIGHT));
}

pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.enabled) return error.BarDisabled;
    
    const height = try calculateBarHeight(wm);
    const screen_width = wm.screen.width_in_pixels;
    const y_pos: i16 = if (wm.config.bar.vertical_position == .bottom)
        @intCast(@as(i32, wm.screen.height_in_pixels) - height)
    else
        0;
    
    // Setup transparency support
    const alpha = wm.config.bar.getAlpha16();
    const want_transparency = alpha < 0xFFFF;
    
    // Find appropriate visual and depth for transparency
    const visual_info = if (want_transparency) 
        drawing.findVisualByDepth(wm.screen, 32)
    else 
        drawing.VisualInfo{ .visual_type = null, .visual_id = wm.screen.root_visual };
    
    const depth: u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
    const visual_id = visual_info.visual_id;
    const has_argb_visual = want_transparency;
    
    debug.info("Bar transparency: {s}", .{if (want_transparency) "enabled (ARGB, compositor-driven)" else "disabled (opaque)"});
    
    // Create colormap for ARGB visual if needed
    const colormap = if (has_argb_visual) blk: {
        const cmap = xcb.xcb_generate_id(wm.conn);
        _ = xcb.xcb_create_colormap(wm.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, wm.screen.root, visual_id);
        break :blk cmap;
    } else 0;
    // Don't defer free colormap - window needs it
    
    const window = xcb.xcb_generate_id(wm.conn);
    
    const value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL | 
                       xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK |
                       if (has_argb_visual) xcb.XCB_CW_COLORMAP else 0;
    const value_list = [_]u32{ 
        0, // XCB_CW_BACK_PIXEL
        0, // XCB_CW_BORDER_PIXEL
        1, // XCB_CW_OVERRIDE_REDIRECT
        xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS, // XCB_CW_EVENT_MASK
        colormap, // XCB_CW_COLORMAP (ignored if not has_argb_visual)
    };
    
    _ = xcb.xcb_create_window(wm.conn, depth, window, wm.screen.root,
        0, y_pos, screen_width, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id,
        @intCast(value_mask), &value_list);
    
    try setWindowProperties(wm, window, height);
    _ = xcb.xcb_map_window(wm.conn, window);
    utils.flush(wm.conn);
    
    const dc = try drawing.DrawContext.initWithVisual(
        wm.allocator, wm.conn, window, screen_width, height,
        visual_id, wm.dpi_info.dpi,
        has_argb_visual, wm.config.bar.transparency,
    );
    errdefer dc.deinit();
    try loadBarFonts(dc, wm);
    
    state = try State.init(wm.allocator, wm.conn, window, screen_width, height, dc, wm.config.bar, has_argb_visual);
    state.?.markDirty();
}

pub fn deinit() void {
    if (state) |s| {
        s.dc.deinit();
        s.deinit();
        state = null;
    }
}

// Public API functions ─────────────────────────────────────────────────────

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
        try setWindowProperties(wm, s.window, s.height);
        
        utils.flush(wm.conn);
        debug.info("Bar position toggled to: {s}", .{@tagName(wm.config.bar.vertical_position)});
        
        // Retile workspace to adjust for new bar position
        const current_ws = workspaces.getCurrentWorkspace() orelse return;
        if (wm.fullscreen.getForWorkspace(current_ws) == null) {
            tiling.retileCurrentWorkspace(wm, true);
        }
    }
}

pub fn getBarWindow() u32 { return if (state) |s| s.window else 0; }
pub fn isBarWindow(win: u32) bool { return if (state) |s| s.window == win else false; }
pub fn getBarHeight() u16 { return if (state) |s| s.height else 0; }
pub fn isBarInitialized() bool { return state != null; }

// Cached dimension accessors for performance
pub fn getCachedWorkspaceWidth() u16 { return if (state) |s| s.cached_ws_width else 50; }
pub fn getCachedIndicatorSize() u16 { return if (state) |s| s.cached_indicator_size else 5; }
pub fn getCachedLabelWidth(index: usize) ?u16 {
    if (state) |s| {
        const width = s.cache_manager.getWorkspaceLabelWidth(index);
        return if (width > 0) width else null;
    }
    return null;
}

pub fn hasClockSegment() bool { return if (state) |s| s.has_clock_segment else false; }

pub inline fn markDirty() void { if (state) |s| s.markDirty(); }
pub inline fn raiseBar() void {
    if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub fn isVisible() bool {
    return if (state) |s| s.visible else false;
}

pub fn getGlobalVisibility() bool {
    return if (state) |s| s.global_visible else false;
}

pub fn setGlobalVisibility(visible: bool) void {
    if (state) |s| {
        s.global_visible = visible;
    }
}

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

/// Set bar visibility state
/// - toggle: Toggle global bar visibility (user-initiated) - retiles ALL workspaces
/// - hide_fullscreen: Temporarily hide bar due to fullscreen (doesn't change global state)
/// - show_fullscreen: Show bar based on global state when exiting fullscreen
pub fn setBarState(wm: *defs.WM, action: BarAction) void {
    const s = state orelse return;
    
    // Check if current workspace is fullscreen
    const current_ws = workspaces.getCurrentWorkspace() orelse 0;
    const is_fullscreen = wm.fullscreen.getForWorkspace(current_ws) != null;
    
    const show = switch (action) {
        .toggle => blk: {
            // Toggle global state
            s.global_visible = !s.global_visible;
            // If we're in a fullscreen workspace, keep bar hidden regardless of global state
            break :blk if (is_fullscreen) false else s.global_visible;
        },
        .hide_fullscreen => false,  // Temporarily hide, don't change global state
        .show_fullscreen => if (is_fullscreen) false else s.global_visible,  // Use global state, but respect fullscreen
    };

    // Only update if visibility actually changes
    if (s.visible == show and action != .toggle) return;
    
    s.visible = show;
    if (show) {
        _ = xcb.xcb_map_window(s.conn, s.window);
        draw(s, wm) catch |e| debug.warnOnErr(e, "draw in setBarState");
    } else {
        _ = xcb.xcb_unmap_window(s.conn, s.window);
    }
    utils.flush(wm.conn);
    debug.info("Bar {s} ({s})", .{
        if (show) "shown" else "hidden",
        @tagName(action),
    });
    clock_segment.updateTimerState(wm);
    
    // For toggle: retile ALL workspaces to prevent flicker when switching
    // For fullscreen show/hide: only retile current workspace
    if (action == .toggle) {
        retileAllWorkspaces(wm);
    } else {
        tiling.retileCurrentWorkspace(wm, true);
    }
}

/// Retile all workspaces when bar is toggled, keeping non-current workspaces off-screen
/// This ensures windows have correct geometry when switching workspaces (prevents flicker)
fn retileAllWorkspaces(wm: *defs.WM) void {
    const ws_state = workspaces.getState() orelse return;
    const ts = if (wm.config.tiling.enabled) tiling.getState() else null;
    const tiling_active = if (ts) |t| t.enabled else false;
    
    if (!tiling_active) {
        // For floating mode, just retile current workspace
        tiling.retileCurrentWorkspace(wm, true);
        return;
    }
    
    const original_ws = ws_state.current;
    
    // Grab server so all geometry updates are atomic - prevents windows from flashing on screen
    _ = xcb.xcb_grab_server(wm.conn);
    
    // Retile each workspace
    for (ws_state.workspaces, 0..) |*ws, idx| {
        if (ws.windows.items().len == 0) continue;
        
        // Skip fullscreen workspaces - they don't need geometry updates
        if (wm.fullscreen.getForWorkspace(@intCast(idx)) != null) continue;
        
        // Temporarily switch to this workspace
        ws_state.current = @intCast(idx);
        
        // Retile to update geometry (calculates correct Y position and height for bar state)
        tiling.retileCurrentWorkspace(wm, true);
        
        // If this isn't the original workspace, move windows back off-screen
        // They now have correct Y/height but need to stay invisible
        if (@as(u8, @intCast(idx)) != original_ws) {
            for (ws.windows.items()) |win| {
                _ = xcb.xcb_configure_window(wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, -4000))});
            }
        }
        
        // Flush geometry changes for this workspace immediately
        _ = xcb.xcb_flush(wm.conn);
    }
    
    // Restore original workspace
    ws_state.current = original_ws;
    
    // Final flush while server is still grabbed to ensure all commands are sent
    _ = xcb.xcb_flush(wm.conn);
    
    // Now ungrab - all changes will appear atomically
    _ = xcb.xcb_ungrab_server(wm.conn);
    
    // CRITICAL: Wait for X server to process all geometry updates before returning
    // This ensures windows have correct geometry immediately
    const cookie = xcb.xcb_get_input_focus(wm.conn);
    const reply = xcb.xcb_get_input_focus_reply(wm.conn, cookie, null);
    if (reply != null) std.c.free(reply);
    
    // Final flush
    utils.flush(wm.conn);
}

pub fn updateIfDirty(wm: *defs.WM) !void {
    if (state) |s| {
        if (s.isDirty()) {
            if (s.dirty) try draw(s, wm) else if (s.dirty_clock) try drawClockOnly(s, wm);
            s.clearDirty();
        }
    }
}

pub fn checkClockUpdate() void {
    if (state) |s| if (s.visible) s.markClockDirty();
}

fn drawClockOnly(s: *State, wm: *defs.WM) !void {
    // Use cached clock position if available to avoid recalculating layout
    if (s.cached_clock_x) |clock_x| {
        _ = try clock_segment.draw(s.dc, s.config, s.height, clock_x);
        s.dc.flush();
        return;
    }
    
    // Fallback if cache not populated yet (shouldn't happen normally)
    for (s.config.layout.items) |layout| {
        if (layout.position != .right) continue;
        
        var right_x: u16 = s.width;
        var i = layout.segments.items.len;
        while (i > 0) : (i -= 1) {
            const segment = layout.segments.items[i - 1];
            right_x -= calculateSegmentWidth(s, segment);
            
            if (segment == .clock) {
                s.cached_clock_x = right_x;  // Cache for next time
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
    if (state) |s| if (event.window == s.window and event.count == 0) draw(s, wm) catch |e| debug.warnOnErr(e, "draw in handleExpose");
}

pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
    const s = state orelse return;
    
    // Handle root window property changes (status bar)
    if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
        status_segment.update(wm, &s.status_text, s.allocator) catch |e| debug.warnOnErr(e, "status_segment.update");
        s.markDirty();
        return;
    }
    
    // Handle focused window title changes
    if (wm.focused_window) |focused_win| {
        if (event.window == focused_win and 
            (event.atom == xcb.XCB_ATOM_WM_NAME or 
             event.atom == (utils.getAtomCached("_NET_WM_NAME") catch |e| {
                debug.warnOnErr(e, "getAtomCached _NET_WM_NAME in handlePropertyNotify");
                return;
            }))) {
            // Invalidate cached title to force re-fetch on next draw
            s.cached_title_window = null;
            s.markDirty();
        }
    }
}

/// Enable property change monitoring for the focused window
/// Call this when a window gains focus to receive title change events
pub fn monitorFocusedWindow(wm: *defs.WM) void {
    const win = wm.focused_window orelse return;
    
    // Add XCB_EVENT_MASK_PROPERTY_CHANGE to the window's event mask
    // This ensures we receive PropertyNotify events when the window's title changes
    const mask = xcb.XCB_CW_EVENT_MASK;
    const values = [_]u32{xcb.XCB_EVENT_MASK_PROPERTY_CHANGE};
    _ = xcb.xcb_change_window_attributes(wm.conn, win, mask, &values);
}

pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
    if (state) |s| if (event.event == s.window) {
        const ws_state = workspaces.getState() orelse return;
        const scaled_ws_width = s.config.scaledWorkspaceWidth();
        // Account for left-side segments before workspace segment
        const click_x = @max(0, event.event_x - s.cached_workspace_x);
        const clicked_ws: usize = @intCast(@divFloor(click_x, scaled_ws_width));
        if (clicked_ws < ws_state.workspaces.len) {
            workspaces.switchTo(wm, clicked_ws);
            s.markDirty();
        }
    };
}

fn calculateSegmentWidth(s: *State, segment: defs.BarSegment) u16 {
    return switch (segment) {
        .workspaces => if (workspaces.getState()) |ws| @intCast(ws.workspaces.len * s.cached_ws_width) else FALLBACK_WORKSPACES_WIDTH,
        .layout => LAYOUT_SEGMENT_WIDTH,
        .title => TITLE_SEGMENT_MIN_WIDTH,
        .clock => s.cached_clock_width,
    };
}

fn drawRightSegments(s: *State, wm: *defs.WM, segments: []const defs.BarSegment) !void {
    var right_x: u16 = s.width;
    const scaled_spacing = s.config.scaledSpacing();
    for (0..segments.len) |i| {
        const idx = segments.len - 1 - i;
        right_x -= calculateSegmentWidth(s, segments[idx]);
        // Cache clock position for drawClockOnly optimization
        if (segments[idx] == .clock) {
            s.cached_clock_x = right_x;
        }
        _ = try drawSegment(s, wm, segments[idx], right_x, null);
        if (i < segments.len - 1) right_x -= scaled_spacing;
    }
}

fn draw(s: *State, wm: *defs.WM) !void {
    // For ARGB windows, clear to transparent first (critical for proper rendering)
    if (s.has_transparency) {
        s.dc.clearTransparent();
    }
    
    // Draw background (fillRect automatically adds proper alpha for ARGB windows)
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
    // Cache workspace segment X offset for click handling
    if (segment == .workspaces) {
        s.cached_workspace_x = x;
    }
    return switch (segment) {
        .workspaces => try workspaces_segment.draw(s.dc, s.config, s.height, x),
        .layout => try layout_segment.draw(s.dc, s.config, s.height, x),
        .title => try title_segment.draw(s.dc, s.config, s.height, x, width orelse 100, wm, &s.cached_title, &s.cached_title_window, s.allocator),
        .clock => try clock_segment.draw(s.dc, s.config, s.height, x),
    };
}
