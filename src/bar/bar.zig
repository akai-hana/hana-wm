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

// TODO: make adjustable through config.toml, adjust workspace width based off of monitor DPI
pub const WORKSPACE_WIDTH: u8 = 50;

// Clock format string constant for width calculation
const CLOCK_FORMAT = "0000-00-00 00:00:00";

// FIXED: Magic numbers replaced with named constants
/// Minimum allowed bar height in pixels
const MIN_BAR_HEIGHT: u32 = 20;

/// Maximum allowed bar height in pixels
const MAX_BAR_HEIGHT: u32 = 200;

/// Default bar height if font metrics cannot be determined
const DEFAULT_BAR_HEIGHT: u16 = 24;

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
    visible: bool,  // OPTIMIZATION: Track actual visibility for timer control
    has_transparency: bool,  // Track if transparency is enabled
    allocator: std.mem.Allocator,
    cached_clock_width: u16,
    cached_ws_width: u16,
    cached_indicator_size: u16,
    has_clock_segment: bool,
    cache_manager: *cache.CacheManager,  // Unified caching layer

    fn init(allocator: std.mem.Allocator, conn: *xcb.xcb_connection_t, window: u32, width: u16, height: u16,
            dc: *drawing.DrawContext, config: defs.BarConfig, has_transparency: bool) !*State {
        const s = try allocator.create(State);
        const scaled_padding = config.scaledPadding();
        
        // Create cache manager
        const cache_mgr = try cache.CacheManager.init(allocator);
        errdefer cache_mgr.deinit();
        
        s.* = State{
            .window = window, .width = width, .height = height, .dc = dc, .conn = conn,
            .config = config,
            .status_text = std.ArrayList(u8).empty,
            .cached_title = std.ArrayList(u8).empty,
            .cached_title_window = null,
            .dirty = false, .dirty_clock = false, .last_second = 0,
            .visible = true,  // OPTIMIZATION: Start visible, setBarState will update
            .has_transparency = has_transparency,
            .allocator = allocator,
            .cached_clock_width = dc.textWidth(CLOCK_FORMAT) + 2 * scaled_padding,
            .cached_ws_width = config.scaledWorkspaceWidth(),
            .cached_indicator_size = config.scaledIndicatorSize(),
            .has_clock_segment = State.detectClockSegment(&config),
            .cache_manager = cache_mgr,
        };
        
        // Pre-allocate capacity for performance
        try s.status_text.ensureTotalCapacity(allocator, 256);
        try s.cached_title.ensureTotalCapacity(allocator, 256);
        
        try s.status_text.appendSlice(allocator, "hana");
        
        // Initialize workspace label cache
        try s.cache_manager.updateWorkspaceLabels(dc, &config);
        
        return s;
    }

    fn deinit(self: *State) void {
        self.cache_manager.deinit();
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn markDirty(self: *State) void { self.dirty = true; }
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

// FIXED: Document thread safety - single-threaded access only
/// Single-threaded: Only accessed from main event loop
/// NOT thread-safe: Do not access from signal handlers or other threads
var state: ?*State = null;

fn updateClockIfNeeded(s: *State) void {
    // OPTIMIZATION: Skip clock update if bar is hidden (idle CPU reduction)
    if (!s.visible) return;
    
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch |e| {
        debug.warnOnErr(e, "clock_gettime in updateClockIfNeeded");
        return;
    };
    if (ts.sec != s.last_second) {
        s.last_second = ts.sec;
        s.markClockDirty();
    }
}

// FIXED: Use stack buffer for common case to avoid heap allocation
fn sizeFont(alloc: std.mem.Allocator, font: []const u8, size: u16) ![]const u8 {
    if (size == 0) return font;
    
    // Try stack buffer first (most font strings with size fit in 256 bytes)
    var buf: [256]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{s}:size={}", .{font, size}) catch {
        // Fall back to heap allocation for very long font names
        return std.fmt.allocPrint(alloc, "{s}:size={}", .{font, size});
    };
    return try alloc.dupe(u8, result);
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
    _ = want_transparency;
    _ = alpha;
    
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
    
    // CRITICAL: Prevent bar from being moved or resized
    // Set allowed actions to only allow closing (for shutdown), but not move/resize
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
    
    const temp_dc = drawing.DrawContext.init(wm.allocator, wm.conn, temp_win, 1, 1, wm.dpi_info.dpi) catch |e| {
        debug.warnOnErr(e, "DrawContext.init in measureBarHeight");
        return DEFAULT_BAR_HEIGHT;
    };
    defer temp_dc.deinit();
    loadBarFonts(temp_dc, wm) catch {
        // If font loading fails, return default height instead of failing
        debug.warn("Failed to load bar fonts for height calculation, using default", .{});
        return DEFAULT_BAR_HEIGHT;
    };
    
    const asc, const desc = temp_dc.getMetrics();
    const font_height: u32 = @intCast(asc + desc);  // Both are positive, add them
    const scaled_padding = wm.config.bar.scaledPadding();
    return @intCast(std.math.clamp(font_height + 2 * scaled_padding, MIN_BAR_HEIGHT, MAX_BAR_HEIGHT));
}

// Helper functions for init() refactoring (Batch 2.1)

fn setupDPI(wm: *defs.WM) void {
    wm.config.bar.scale_factor = wm.dpi_info.scale_factor;
    debug.info("DPI: {d:.1}, Scale factor: {d:.2}x", .{wm.dpi_info.dpi, wm.dpi_info.scale_factor});
}

const VisualSetup = struct {
    depth: u8,
    visual_id: u32,
    has_transparency: bool,
    colormap: u32,
};

fn setupVisual(wm: *defs.WM) VisualSetup {
    const alpha = wm.config.bar.getAlpha16();
    const want_transparency = alpha < 0xFFFF;
    
    if (want_transparency) {
        debug.info("Bar transparency: {d:.2}% (handled by compositor, not window opacity)", 
            .{wm.config.bar.transparency * 100.0});
    } else {
        debug.info("Bar transparency: disabled (fully opaque)", .{});
    }
    
    // Find appropriate visual and depth for transparency
    const visual_info = if (want_transparency) 
        drawing.findVisualByDepth(wm.screen, 32)
    else 
        drawing.VisualInfo{ .visual_type = null, .visual_id = wm.screen.root_visual };
    
    const depth: u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
    
    // Create colormap for ARGB visual if needed
    const colormap = if (want_transparency) blk: {
        const cmap = xcb.xcb_generate_id(wm.conn);
        _ = xcb.xcb_create_colormap(wm.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, wm.screen.root, visual_info.visual_id);
        break :blk cmap;
    } else 0;
    
    if (want_transparency) {
        debug.info("Created 32-bit ARGB window for transparency (handled by compositor like borders)", .{});
    } else {
        debug.info("Created RGB window (fully opaque)", .{});
    }
    
    return .{
        .depth = depth,
        .visual_id = visual_info.visual_id,
        .has_transparency = want_transparency,
        .colormap = colormap,
    };
}

fn createBarWindow(wm: *defs.WM, height: u16, visual_setup: VisualSetup) u32 {
    const screen = wm.screen;
    const width = screen.width_in_pixels;
    const y_pos: i16 = if (wm.config.bar.vertical_position == .bottom)
        @as(i16, @intCast(screen.height_in_pixels)) - @as(i16, @intCast(height))
    else 0;
    
    const window = xcb.xcb_generate_id(wm.conn);
    
    if (visual_setup.has_transparency) {
        const bg_color = 0xFF000000 | wm.config.bar.bg;
        const values = [_]u32{ 
            bg_color, 
            0, 
            xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS, 
            visual_setup.colormap 
        };
        _ = xcb.xcb_create_window(
            wm.conn, 
            visual_setup.depth,
            window, 
            screen.root,
            0, y_pos, width, height, 0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, 
            visual_setup.visual_id,
            xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL | xcb.XCB_CW_EVENT_MASK | xcb.XCB_CW_COLORMAP,
            &values,
        );
    } else {
        const values = [_]u32{ 
            wm.config.bar.bg, 
            xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS 
        };
        _ = xcb.xcb_create_window(
            wm.conn, 
            visual_setup.depth,
            window, 
            screen.root,
            0, y_pos, width, height, 0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, 
            visual_setup.visual_id,
            xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_EVENT_MASK,
            &values,
        );
    }
    
    return window;
}

fn initDrawContext(wm: *defs.WM, window: u32, width: u16, height: u16, visual_setup: VisualSetup) !*drawing.DrawContext {
    return drawing.DrawContext.initWithVisual(
        wm.allocator, 
        wm.conn, 
        window, 
        width, 
        height, 
        visual_setup.visual_id,
        wm.dpi_info.dpi,
        visual_setup.has_transparency,
        wm.config.bar.transparency
    );
}

pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.enabled) return error.BarDisabled;

    // Step 1: Setup DPI
    setupDPI(wm);

    // Step 2: Calculate bar height
    const height = try calculateBarHeight(wm);
    
    // Step 3: Setup visual for transparency
    const visual_setup = setupVisual(wm);

    // Step 4: Create bar window
    const window = createBarWindow(wm, height, visual_setup);
    
    // Step 5: Set window properties
    try setWindowProperties(wm, window, height, visual_setup.has_transparency, wm.config.bar.getAlpha16());
    _ = xcb.xcb_map_window(wm.conn, window);
    utils.flush(wm.conn);

    // Step 6: Initialize draw context
    const dc = try initDrawContext(wm, window, wm.screen.width_in_pixels, height, visual_setup);
    errdefer dc.deinit();
    
    // Step 7: Load fonts
    try loadBarFonts(dc, wm);
    debug.info("Bar uses XCB rendering for backgrounds (like borders), Pango for text", .{});

    // Step 8: Create state and perform initial draw
    const s = try State.init(wm.allocator, wm.conn, window, wm.screen.width_in_pixels, height, dc, wm.config.bar, visual_setup.has_transparency);
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
            draw(s, wm) catch |e| debug.warnOnErr(e, "draw in setVisibility");
        } else {
            _ = xcb.xcb_unmap_window(s.conn, s.window);
        }
        utils.flush(wm.conn);
        debug.info("Bar {s} ({s})", .{ if (visible) "shown" else "hidden", reason });
        
        // OPTIMIZATION: Update timer state when visibility changes
        clock_segment.updateTimerState(wm);
        
        tiling.retileCurrentWorkspace(wm, true);
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
        // BUGFIX: Don't retile if there's a fullscreen window on the current workspace
        // Fullscreen windows should remain fullscreen and not have their geometry updated
        const current_ws = workspaces.getCurrentWorkspace() orelse return;
        if (wm.fullscreen.getForWorkspace(current_ws) == null) {
            tiling.retileCurrentWorkspace(wm, true);
        }
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

// OPTIMIZATION: Cached workspace dimensions for fast access
pub fn getCachedWorkspaceWidth() u16 { return if (state) |s| s.cached_ws_width else 50; }
pub fn getCachedIndicatorSize() u16 { return if (state) |s| s.cached_indicator_size else 5; }

// OPTIMIZATION: Cached workspace label width
pub fn getCachedLabelWidth(index: usize) ?u16 {
    if (state) |s| {
        const width = s.cache_manager.getWorkspaceLabelWidth(index);
        return if (width > 0) width else null;
    }
    return null;
}

// OPTIMIZATION: Cached clock segment detection
pub fn hasClockSegment() bool { return if (state) |s| s.has_clock_segment else false; }

// OPTIMIZATION: Check if bar is actually visible (not just created)
pub fn isVisible() bool {
    if (state) |s| return s.visible;
    return false;
}

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

pub fn setBarState(wm: *defs.WM, action: BarAction) void {
    const show = switch (action) {
        .toggle => blk: { wm.config.bar.enabled = !wm.config.bar.enabled; break :blk wm.config.bar.enabled; },
        .hide_fullscreen => false,
        .show_fullscreen => wm.config.bar.enabled,
    };
    const reason = switch (action) {
        .toggle => "toggle",
        .hide_fullscreen => "fullscreen",
        .show_fullscreen => "exit fullscreen",
    };
    if (action != .show_fullscreen or wm.config.bar.enabled) {
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
            // Only mark dirty - the title will be re-rendered on next draw
            s.markDirty();
        }
    }
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
        .workspaces => if (workspaces.getState()) |ws| @intCast(ws.workspaces.len * s.cached_ws_width) else 270,
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
    return switch (segment) {
        .workspaces => try workspaces_segment.draw(s.dc, s.config, s.height, x),
        .layout => try layout_segment.draw(s.dc, s.config, s.height, x),
        .title => try title_segment.draw(s.dc, s.config, s.height, x, width orelse 100, wm, &s.cached_title, &s.cached_title_window, s.allocator),
        .clock => try clock_segment.draw(s.dc, s.config, s.height, x),
    };
}
