//! Status bar — renders segments via Cairo/Pango into an XCB override-redirect window.

const std  = @import("std");
const defs = @import("defs");
const xcb  = defs.xcb;

const utils      = @import("utils");
const drawing    = @import("drawing");
const tiling     = @import("tiling");
const debug      = @import("debug");
const cache      = @import("cache");
const workspaces = @import("workspaces");

const workspaces_segment = @import("tags");
const layout_segment     = @import("layout");
const variations_segment = @import("variations");
const title_segment      = @import("title");
const clock_segment      = @import("clock");
const status_segment     = @import("status");

// Placeholder matching the clock output length, used to pre-compute the clock segment width.
const CLOCK_FORMAT = "0000-00-00 00:00:00";

const MIN_BAR_HEIGHT:           u32 = 20;
const MAX_BAR_HEIGHT:           u32 = 200;
const DEFAULT_BAR_HEIGHT:       u16 = 24;
const FALLBACK_WORKSPACES_WIDTH: u16 = 270;
const LAYOUT_SEGMENT_WIDTH:      u16 = 60;
const TITLE_SEGMENT_MIN_WIDTH:   u16 = 100;

// State

const State = struct {
    window:               u32,
    width:                u16,
    height:               u16,
    dc:                   *drawing.DrawContext,
    conn:                 *xcb.xcb_connection_t,
    config:               defs.BarConfig,
    status_text:          std.ArrayList(u8),
    cached_title:         std.ArrayList(u8),
    cached_title_window:  ?u32,
    dirty:                bool,
    dirty_clock:          bool,
    // visible: current mapped state; global_visible: desired state when not fullscreen.
    visible:              bool,
    global_visible:       bool,
    has_transparency:     bool,
    allocator:            std.mem.Allocator,
    cached_clock_width:   u16,
    cached_clock_x:       ?u16,
    cached_ws_width:      u16,
    cached_workspace_x:   u16,
    cached_indicator_size: u16,
    has_clock_segment:    bool,
    cache_manager:        cache.CacheManager,

    fn init(
        allocator:       std.mem.Allocator,
        conn:            *xcb.xcb_connection_t,
        window:          u32,
        width:           u16,
        height:          u16,
        dc:              *drawing.DrawContext,
        config:          defs.BarConfig,
        has_transparency: bool,
    ) !*State {
        const s              = try allocator.create(State);
        const scaled_padding = config.scaledPadding();
        s.* = State{
            .window               = window,
            .width                = width,
            .height               = height,
            .dc                   = dc,
            .conn                 = conn,
            .config               = config,
            .status_text          = std.ArrayList(u8).empty,
            .cached_title         = std.ArrayList(u8).empty,
            .cached_title_window  = null,
            .dirty                = false,
            .dirty_clock          = false,
            .visible              = true,
            .global_visible       = true,
            .has_transparency     = has_transparency,
            .allocator            = allocator,
            .cached_clock_width   = dc.textWidth(CLOCK_FORMAT) + 2 * scaled_padding,
            .cached_clock_x       = null,
            .cached_ws_width      = config.scaledWorkspaceWidth(),
            .cached_workspace_x   = 0,
            .cached_indicator_size = config.scaledIndicatorSize(),
            .has_clock_segment    = detectClockSegment(&config),
            .cache_manager        = cache.CacheManager.init(),
        };
        try s.status_text.ensureTotalCapacity(allocator, 256);
        try s.cached_title.ensureTotalCapacity(allocator, 256);
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
        self.cached_clock_x = null; // Invalidate so drawClockOnly recalculates position.
    }
    fn markClockDirty(self: *State) void { self.dirty_clock = true; }
    fn clearDirty(self: *State) void { self.dirty = false; self.dirty_clock = false; }
    fn isDirty(self: *State) bool { return self.dirty or self.dirty_clock; }
};

/// Scans the bar layout config for a clock segment.
fn detectClockSegment(config: *const defs.BarConfig) bool {
    for (config.layout.items) |layout| {
        for (layout.segments.items) |seg| {
            if (seg == .clock) return true;
        }
    }
    return false;
}

/// Single-threaded — only accessed from the main event loop.
var state: ?*State = null;

// Window creation helpers 

/// Computes the bar Y position for the given `height` and position config.
fn barYPos(wm: *defs.WM, height: u16) i16 {
    return if (wm.config.bar.vertical_position == .bottom)
        @intCast(@as(i32, wm.screen.height_in_pixels) - height)
    else
        0;
}

/// Result of `createBarWindow`.
const BarWindowSetup = struct {
    window:   u32,
    visual_id: u32,
    has_argb: bool,
};

/// Creates and configures an XCB window for the bar (unmapped).
/// Allocates an ARGB colormap when transparency is requested.
fn createBarWindow(wm: *defs.WM, height: u16, y_pos: i16) BarWindowSetup {
    const want_transparency = wm.config.bar.getAlpha16() < 0xFFFF;
    const visual_info       = if (want_transparency)
        drawing.findVisualByDepth(wm.screen, 32)
    else
        drawing.VisualInfo{ .visual_type = null, .visual_id = wm.screen.root_visual };
    const depth:    u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
    const visual_id    = visual_info.visual_id;

    // Colormap is required for ARGB visuals; the slot is always present in value_list
    // but ignored by XCB when the XCB_CW_COLORMAP bit is absent from value_mask.
    const colormap: u32 = if (want_transparency) blk: {
        const cmap = xcb.xcb_generate_id(wm.conn);
        _ = xcb.xcb_create_colormap(wm.conn, xcb.XCB_COLORMAP_ALLOC_NONE, cmap, wm.screen.root, visual_id);
        break :blk cmap;
    } else 0;

    const window     = xcb.xcb_generate_id(wm.conn);
    const value_mask = xcb.XCB_CW_BACK_PIXEL | xcb.XCB_CW_BORDER_PIXEL |
                       xcb.XCB_CW_OVERRIDE_REDIRECT | xcb.XCB_CW_EVENT_MASK |
                       if (want_transparency) xcb.XCB_CW_COLORMAP else 0;
    const value_list = [_]u32{
        0,                                                              // XCB_CW_BACK_PIXEL
        0,                                                              // XCB_CW_BORDER_PIXEL
        1,                                                              // XCB_CW_OVERRIDE_REDIRECT
        xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS, // XCB_CW_EVENT_MASK
        colormap,                                                       // XCB_CW_COLORMAP
    };
    _ = xcb.xcb_create_window(wm.conn, depth, window, wm.screen.root,
        0, y_pos, wm.screen.width_in_pixels, height, 0,
        xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id,
        @intCast(value_mask), &value_list);

    return .{ .window = window, .visual_id = visual_id, .has_argb = want_transparency };
}

// Font helpers

/// Appends `:size=N` to `font` when `size > 0`. The caller must free the returned
/// slice when non-null; when null the original `font` pointer should be used directly.
fn sizeFont(alloc: std.mem.Allocator, font: []const u8, size: u16) !?[]const u8 {
    if (size == 0) return null;
    return @as(?[]const u8, try std.fmt.allocPrint(alloc, "{s}:size={}", .{ font, size }));
}

/// Loads bar fonts into `dc`, appending the configured size suffix when present.
fn loadBarFonts(dc: *drawing.DrawContext, wm: *defs.WM) !void {
    const cfg          = wm.config.bar;
    const alloc        = wm.allocator;
    const scaled_size  = cfg.scaledFontSize();

    if (cfg.fonts.items.len > 0) {
        var sized = std.ArrayList([]const u8){};
        defer {
            for (sized.items, 0..) |s, i| if (s.ptr != cfg.fonts.items[i].ptr) alloc.free(s);
            sized.deinit(alloc);
        }
        for (cfg.fonts.items) |f| try sized.append(alloc, (try sizeFont(alloc, f, scaled_size)) orelse f);
        return dc.loadFonts(sized.items);
    }

    const font_str = (try sizeFont(alloc, cfg.font, scaled_size)) orelse cfg.font;
    defer if (font_str.ptr != cfg.font.ptr) alloc.free(font_str);
    try dc.loadFont(font_str);
}

// X11 property helpers 

/// Sets an XCB window property from an array.
inline fn setProp(conn: *xcb.xcb_connection_t, win: u32, name: []const u8, type_: u32, data: anytype) !void {
    _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win,
        try utils.getAtom(conn, name), type_, 32, data.len, data);
}

/// Applies dock/strut/state properties so the bar is treated correctly by compositors.
/// Transparency is handled by picom, not via _NET_WM_WINDOW_OPACITY, keeping consistent
/// rendering between the bar and window borders.
fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) !void {
    const strut: [12]u32 = if (wm.config.bar.vertical_position == .bottom)
        .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels }
    else
        .{ 0, 0, height, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels, 0, 0 };

    try setProp(wm.conn, window, "_NET_WM_STRUT_PARTIAL", xcb.XCB_ATOM_CARDINAL, &strut);
    try setProp(wm.conn, window, "_NET_WM_WINDOW_TYPE",   xcb.XCB_ATOM_ATOM,
        &[_]u32{try utils.getAtom(wm.conn, "_NET_WM_WINDOW_TYPE_DOCK")});
    try setProp(wm.conn, window, "_NET_WM_STATE",         xcb.XCB_ATOM_ATOM,
        &[_]u32{
            try utils.getAtom(wm.conn, "_NET_WM_STATE_ABOVE"),
            try utils.getAtom(wm.conn, "_NET_WM_STATE_STICKY"),
        });
    try setProp(wm.conn, window, "_NET_WM_ALLOWED_ACTIONS", xcb.XCB_ATOM_ATOM,
        &[_]u32{
            try utils.getAtom(wm.conn, "_NET_WM_ACTION_CLOSE"),
            try utils.getAtom(wm.conn, "_NET_WM_ACTION_ABOVE"),
            try utils.getAtom(wm.conn, "_NET_WM_ACTION_STICK"),
        });
}

// Bar height

/// Calculates bar height from font metrics and configured padding, clamped to sane bounds.
/// Creates a temporary off-screen window to measure font height when no explicit height is set.
fn calculateBarHeight(wm: *defs.WM) !u16 {
    if (wm.config.bar.height) |h| return h;

    const temp_win = xcb.xcb_generate_id(wm.conn);
    _ = xcb.xcb_create_window(wm.conn, xcb.XCB_COPY_FROM_PARENT, temp_win, wm.screen.root,
        0, 0, 1, 1, 0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, wm.screen.root_visual, 0, null);
    defer _ = xcb.xcb_destroy_window(wm.conn, temp_win);

    const temp_dc = drawing.DrawContext.init(wm.allocator, wm.conn, temp_win, 1, 1, wm.dpi_info.dpi) catch |e| {
        debug.warnOnErr(e, "DrawContext.init in calculateBarHeight");
        return DEFAULT_BAR_HEIGHT;
    };
    defer temp_dc.deinit();

    loadBarFonts(temp_dc, wm) catch {
        debug.warn("Failed to load fonts for height calculation, using default", .{});
        return DEFAULT_BAR_HEIGHT;
    };

    const asc, const desc   = temp_dc.getMetrics();
    const font_height: u32  = @intCast(asc + desc);
    const scaled_padding: u32 = @intCast(wm.config.bar.scaledPadding());
    const computed: u32     = font_height + 2 * scaled_padding;
    return @intCast(@min(@max(computed, MIN_BAR_HEIGHT), MAX_BAR_HEIGHT));
}

// Lifecycle

/// Creates the bar window, loads fonts, and performs the first draw.
pub fn init(wm: *defs.WM) !void {
    if (!wm.config.bar.enabled) return error.BarDisabled;

    const height       = try calculateBarHeight(wm);
    const y_pos        = barYPos(wm, height);
    const setup        = createBarWindow(wm, height, y_pos);
    errdefer _ = xcb.xcb_destroy_window(wm.conn, setup.window);

    try setWindowProperties(wm, setup.window, height);
    _ = xcb.xcb_map_window(wm.conn, setup.window);
    utils.flush(wm.conn);

    const dc = try drawing.DrawContext.initWithVisual(
        wm.allocator, wm.conn, setup.window, wm.screen.width_in_pixels, height,
        setup.visual_id, wm.dpi_info.dpi, setup.has_argb, wm.config.bar.transparency,
    );
    errdefer dc.deinit();
    try loadBarFonts(dc, wm);

    debug.info("Bar transparency: {s}", .{if (setup.has_argb) "enabled (ARGB)" else "disabled (opaque)"});

    state = try State.init(wm.allocator, wm.conn, setup.window, wm.screen.width_in_pixels,
        height, dc, wm.config.bar, setup.has_argb);
    state.?.markDirty();
}

/// Destroys the bar window and frees all associated resources.
pub fn deinit() void {
    if (state) |s| {
        // Explicitly destroy the X11 window to prevent ghost windows on hot-reload.
        // Without this, each reload leaves an invisible ARGB window; picom composites
        // all of them, and N partially-transparent copies accumulate into a white bar.
        _ = xcb.xcb_destroy_window(s.conn, s.window);
        s.dc.deinit();
        s.deinit();
        state = null;
    }
}

/// Seamless hot-reload: builds and fully paints the new bar window before touching the
/// old one, then swaps them atomically under a server grab to avoid compositor flicker.
///
/// Sequence:
///   1. Create + configure the new window (unmapped — invisible to the compositor).
///   2. Draw its initial contents into the Cairo surface off-screen.
///   3. Grab the X server.
///   4. Map the new window; destroy the old one.
///   5. Flush + ungrab — compositor sees exactly one frame transition.
pub fn reload(wm: *defs.WM) void {
    const old = state orelse {
        init(wm) catch |err| {
            if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
        };
        return;
    };

    if (!wm.config.bar.enabled) { deinit(); return; }

    const height  = calculateBarHeight(wm) catch DEFAULT_BAR_HEIGHT;
    const y_pos   = barYPos(wm, height);
    const setup   = createBarWindow(wm, height, y_pos);

    setWindowProperties(wm, setup.window, height) catch {
        _ = xcb.xcb_destroy_window(wm.conn, setup.window);
        debug.err("Bar reload: setWindowProperties failed, keeping old bar", .{});
        return;
    };

    const new_dc = drawing.DrawContext.initWithVisual(
        wm.allocator, wm.conn, setup.window, wm.screen.width_in_pixels, height,
        setup.visual_id, wm.dpi_info.dpi, setup.has_argb, wm.config.bar.transparency,
    ) catch {
        _ = xcb.xcb_destroy_window(wm.conn, setup.window);
        debug.err("Bar reload: DrawContext init failed, keeping old bar", .{});
        return;
    };

    loadBarFonts(new_dc, wm) catch {
        new_dc.deinit();
        _ = xcb.xcb_destroy_window(wm.conn, setup.window);
        debug.err("Bar reload: font load failed, keeping old bar", .{});
        return;
    };

    const new_state = State.init(wm.allocator, wm.conn, setup.window, wm.screen.width_in_pixels,
        height, new_dc, wm.config.bar, setup.has_argb) catch {
        new_dc.deinit();
        _ = xcb.xcb_destroy_window(wm.conn, setup.window);
        debug.err("Bar reload: State.init failed, keeping old bar", .{});
        return;
    };

    new_state.visible        = old.visible;
    new_state.global_visible = old.global_visible;

    state = new_state;
    draw(new_state, wm) catch {};
    new_dc.flush();
    utils.flush(wm.conn);

    _ = xcb.xcb_grab_server(wm.conn);
    if (new_state.visible) _ = xcb.xcb_map_window(wm.conn, setup.window);
    _ = xcb.xcb_destroy_window(wm.conn, old.window);
    _ = xcb.xcb_flush(wm.conn);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);

    old.dc.deinit();
    old.deinit();
}

// Public API

/// Toggles bar position between top and bottom, retiling the current workspace.
pub fn toggleBarPosition(wm: *defs.WM) !void {
    if (state) |s| {
        wm.config.bar.vertical_position = switch (wm.config.bar.vertical_position) {
            .top    => .bottom,
            .bottom => .top,
        };

        const new_y: i16 = if (wm.config.bar.vertical_position == .bottom)
            @as(i16, @intCast(wm.screen.height_in_pixels)) - @as(i16, @intCast(s.height))
        else 0;

        // setWindowProperties makes blocking round-trips (getAtom); do this
        // before the grab so we never block inside an active server grab.
        try setWindowProperties(wm, s.window, s.height);

        // Bar Y move and retile must be atomic: picom must not composite a
        // frame where the bar is at its new position but windows are still
        // sized for the old position.
        _ = xcb.xcb_grab_server(wm.conn);
        _ = xcb.xcb_configure_window(s.conn, s.window, xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});

        const current_ws = workspaces.getCurrentWorkspace() orelse {
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
            return;
        };
        if (wm.fullscreen.getForWorkspace(current_ws) == null) {
            tiling.retileCurrentWorkspace(wm);
        }
        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);

        debug.info("Bar position toggled to: {s}", .{@tagName(wm.config.bar.vertical_position)});
    }
}

pub fn getBarWindow() u32      { return if (state) |s| s.window else 0; }
pub fn isBarWindow(win: u32) bool { return if (state) |s| s.window == win else false; }
pub fn getBarHeight() u16      { return if (state) |s| s.height else 0; }
pub fn isBarInitialized() bool { return state != null; }

pub fn getCachedWorkspaceWidth() u16 { return if (state) |s| s.cached_ws_width else 50; }
pub fn getCachedIndicatorSize() u16  { return if (state) |s| s.cached_indicator_size else 5; }
/// Returns the cached label width for workspace `index`, or null on cache miss.
pub fn getCachedLabelWidth(index: usize) ?u16 {
    const w = if (state) |s| s.cache_manager.getWorkspaceLabelWidth(index) else return null;
    return if (w > 0) w else null;
}

pub fn hasClockSegment() bool { return if (state) |s| s.has_clock_segment else false; }

pub inline fn markDirty() void { if (state) |s| s.markDirty(); }

/// Redraw the bar immediately and mark it clean.
/// Used inside server grabs (e.g. workspace switch) so picom composites the
/// correct bar content the moment it unfreezes — rather than the stale content
/// from the previous frame that markDirty+deferred-draw would produce.
/// Drawing inside a grab is safe: Cairo/XCB rendering commands go to the bar
/// window's backing pixmap; picom composites the updated content on ungrab.
pub fn redrawImmediate(wm: *defs.WM) void {
    const s = state orelse return;
    if (!s.visible) return;
    draw(s, wm) catch |e| debug.warnOnErr(e, "draw in redrawImmediate");
    s.clearDirty();
}
pub inline fn raiseBar() void {
    if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
}

pub fn isVisible() bool           { return if (state) |s| s.visible else false; }
pub fn getGlobalVisibility() bool { return if (state) |s| s.global_visible else false; }
pub fn setGlobalVisibility(visible: bool) void { if (state) |s| s.global_visible = visible; }

pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

/// Controls bar visibility.
///   - `.toggle`: flips global visibility (user-initiated), retiles all workspaces.
///   - `.hide_fullscreen`: hides without changing global state.
///   - `.show_fullscreen`: restores global state when exiting fullscreen.
pub fn setBarState(wm: *defs.WM, action: BarAction) void {
    const s          = state orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse 0;
    const is_fullscreen = wm.fullscreen.getForWorkspace(current_ws) != null;

    const show = switch (action) {
        .toggle => blk: {
            s.global_visible = !s.global_visible;
            break :blk if (is_fullscreen) false else s.global_visible;
        },
        .hide_fullscreen => false,
        .show_fullscreen => if (is_fullscreen) false else s.global_visible,
    };

    if (s.visible == show and action != .toggle) return;

    s.visible = show;

    if (action == .toggle) {
        // For a user-initiated toggle the bar visibility change and the
        // full-workspace retile must be atomic: picom must never composite
        // a frame where the bar has appeared/disappeared but the window
        // positions still reflect the old bar height.
        //
        // Drawing happens BEFORE the grab because Cairo's dc.flush() may
        // trigger XCB calls; doing those inside the grab adds latency and
        // makes reasoning about grab scope harder.  The drawn content is
        // already committed to the bar window's backing store by the time
        // the map lands, so the compositor sees correct content immediately.
        if (show) draw(s, wm) catch |e| debug.warnOnErr(e, "draw in setBarState");

        _ = xcb.xcb_grab_server(wm.conn);
        if (show) _ = xcb.xcb_map_window(s.conn, s.window)
        else      _ = xcb.xcb_unmap_window(s.conn, s.window);

        // When toggling while fullscreened, s.visible stays false (bar is
        // physically hidden by fullscreen), but inactive workspaces must be
        // retiled using the *intended* future bar height — the height that will
        // apply the moment they become active.  calculateScreenArea reads
        // bar.isVisible() (i.e. s.visible), so we briefly expose global_visible
        // through it for the duration of the retile, then restore the true value.
        //
        // Without this, toggling hidden→shown while fullscreened retiles other
        // workspaces with bar_height=0 geometry.  On switch, the bar appears and
        // the screen rect no longer matches last_retile_screen, forcing a full
        // retile at switch time and causing the exact flicker we want to avoid.
        const retile_visible_save = s.visible;
        if (is_fullscreen) s.visible = s.global_visible;
        retileAllWorkspacesNoGrab(wm);
        if (is_fullscreen) s.visible = retile_visible_save;

        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);
    } else {
        // hide_fullscreen / show_fullscreen: these are always called from
        // within the fullscreen module's own server grab, so the flush here
        // happens while picom is already frozen — harmless.  The retile
        // commands queued by retileCurrentWorkspace will be flushed together
        // with the grab release in the outer caller.
        if (show) {
            _ = xcb.xcb_map_window(s.conn, s.window);
            draw(s, wm) catch |e| debug.warnOnErr(e, "draw in setBarState");
        } else {
            _ = xcb.xcb_unmap_window(s.conn, s.window);
        }
        utils.flush(wm.conn);
        tiling.retileCurrentWorkspace(wm);
    }

    debug.info("Bar {s} ({s})", .{ if (show) "shown" else "hidden", @tagName(action) });
    clock_segment.updateTimerState(wm);
}

// Update loop

/// Redraws the bar if any dirty flag is set. Called each iteration of the event loop.
pub fn updateIfDirty(wm: *defs.WM) !void {
    if (state) |s| {
        if (s.isDirty()) {
            if (s.dirty) try draw(s, wm) else if (s.dirty_clock) try drawClockOnly(s, wm);
            s.clearDirty();
        }
    }
}

/// Marks the clock dirty so it redraws on the next event loop iteration.
pub fn checkClockUpdate() void {
    if (state) |s| if (s.visible) s.markClockDirty();
}

/// Handles window expose events by redrawing the bar.
pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
    if (state) |s| if (event.window == s.window and event.count == 0) {
        if (wm.drag_state.active) {
            // During a drag, the resized/moved window continuously uncovers
            // and re-covers parts of the bar, generating a rapid stream of
            // Expose events.  A full Cairo redraw on each one causes visible
            // flickering with zero benefit — nothing bar-visible changes
            // during a drag.  Schedule a single deferred redraw instead;
            // it fires on the first event-loop iteration after the drag ends.
            s.markDirty();
        } else {
            draw(s, wm) catch |e| debug.warnOnErr(e, "draw in handleExpose");
        }
    };
}

/// Handles property change events: updates status text or invalidates the title cache.
pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
    const s = state orelse return;

    if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
        status_segment.update(wm, &s.status_text, s.allocator) catch |e| debug.warnOnErr(e, "status_segment.update");
        s.markDirty();
        return;
    }

    if (wm.focused_window) |focused_win| {
        if (event.window == focused_win and
            (event.atom == xcb.XCB_ATOM_WM_NAME or
             event.atom == (utils.getAtomCached("_NET_WM_NAME") catch |e| {
                 debug.warnOnErr(e, "getAtomCached _NET_WM_NAME in handlePropertyNotify");
                 return;
             })))
        {
            s.cached_title_window = null;
            s.markDirty();
        }
    }
}

/// Subscribes to PropertyNotify events on the focused window so title changes are detected.
pub fn monitorFocusedWindow(wm: *defs.WM) void {
    const win = wm.focused_window orelse return;
    const values = [_]u32{xcb.XCB_EVENT_MASK_PROPERTY_CHANGE};
    _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &values);
}

/// Routes a button press to workspace switching if clicked on the workspace segment.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
    if (state) |s| if (event.event == s.window) {
        const ws_state       = workspaces.getState() orelse return;
        const scaled_ws_width = s.config.scaledWorkspaceWidth();
        const click_x        = @max(0, event.event_x - s.cached_workspace_x);
        const clicked_ws: usize = @intCast(@divFloor(click_x, scaled_ws_width));
        if (clicked_ws < ws_state.workspaces.len) {
            workspaces.switchTo(wm, clicked_ws);
            s.markDirty();
        }
    };
}

// Drawing

/// Returns the pixel width of a single bar segment.
fn calculateSegmentWidth(s: *State, segment: defs.BarSegment) u16 {
    return switch (segment) {
        .workspaces => if (workspaces.getState()) |ws|
            @intCast(ws.workspaces.len * s.cached_ws_width)
        else
            FALLBACK_WORKSPACES_WIDTH,
        .layout     => LAYOUT_SEGMENT_WIDTH,
        .variations => LAYOUT_SEGMENT_WIDTH,
        .title      => TITLE_SEGMENT_MIN_WIDTH,
        .clock      => s.cached_clock_width,
    };
}

/// Draws right-aligned segments in reverse order.
fn drawRightSegments(s: *State, wm: *defs.WM, segments: []const defs.BarSegment) !void {
    var right_x          = s.width;
    const scaled_spacing = s.config.scaledSpacing();
    for (0..segments.len) |i| {
        const idx = segments.len - 1 - i;
        right_x -= calculateSegmentWidth(s, segments[idx]);
        if (segments[idx] == .clock) s.cached_clock_x = right_x;
        _ = try drawSegment(s, wm, segments[idx], right_x, null);
        if (i < segments.len - 1) right_x -= scaled_spacing;
    }
}

/// Full bar redraw. For transparency, clears to fully transparent before painting.
fn draw(s: *State, wm: *defs.WM) !void {
    if (s.has_transparency) s.dc.clearTransparent();
    s.dc.fillRect(0, 0, s.width, s.height, s.config.bg);

    const scaled_spacing = s.config.scaledSpacing();
    var widths = [_]u16{0} ** 2; // [0] = left total, [1] = right total
    for (s.config.layout.items) |layout| {
        const idx: usize = switch (layout.position) {
            .left   => 0,
            .right  => 1,
            .center => continue,
        };
        for (layout.segments.items) |seg| widths[idx] += calculateSegmentWidth(s, seg) + scaled_spacing;
        if (layout.segments.items.len > 0) widths[idx] -= scaled_spacing;
    }

    var x: u16 = 0;
    for (s.config.layout.items) |layout| {
        switch (layout.position) {
            .left => for (layout.segments.items) |seg| {
                x  = try drawSegment(s, wm, seg, x, null);
                x += scaled_spacing;
            },
            .center => {
                const remaining = @max(100, s.width -| x -| widths[1] -| scaled_spacing);
                for (layout.segments.items) |seg| {
                    const w = if (seg == .title) remaining else calculateSegmentWidth(s, seg);
                    x = try drawSegment(s, wm, seg, x, w);
                    if (seg != .title) x += scaled_spacing;
                }
            },
            .right => try drawRightSegments(s, wm, layout.segments.items),
        }
    }
    s.dc.flush();
}

/// Optimised clock-only redraw using the cached X position to skip layout recalculation.
fn drawClockOnly(s: *State, wm: *defs.WM) !void {
    if (s.cached_clock_x) |clock_x| {
        _ = try clock_segment.draw(s.dc, s.config, s.height, clock_x);
        s.dc.flush();
        return;
    }
    // Cache not populated yet — fall through to a full redraw.
    try draw(s, wm);
}

/// Dispatches a single segment to its draw function, returning the next X position.
/// Caches the workspace segment's X offset for click-hit testing.
fn drawSegment(s: *State, wm: *defs.WM, segment: defs.BarSegment, x: u16, width: ?u16) !u16 {
    if (segment == .workspaces) s.cached_workspace_x = x;
    return switch (segment) {
        .workspaces => try workspaces_segment.draw(s.dc, s.config, s.height, x),
        .layout     => try layout_segment.draw(s.dc, s.config, s.height, x),
        .variations => try variations_segment.draw(s.dc, s.config, s.height, x),
        .title      => try title_segment.draw(s.dc, s.config, s.height, x,
            width orelse 100, wm, &s.cached_title, &s.cached_title_window, s.allocator),
        .clock      => try clock_segment.draw(s.dc, s.config, s.height, x),
    };
}

// Workspace retiling 

/// Retiles all workspaces — queue-only, no grab, no flush.
/// Caller is responsible for the grab/ungrab/flush envelope.
/// Temporarily swaps ws_state.current per workspace so retileCurrentWorkspace
/// filters the right window set; restores it before returning.
fn retileAllWorkspacesNoGrab(wm: *defs.WM) void {
    const ws_state      = workspaces.getState() orelse return;
    const tiling_active = wm.config.tiling.enabled and
        if (tiling.getState()) |t| t.enabled else false;

    if (!tiling_active) {
        tiling.retileCurrentWorkspace(wm);
        return;
    }

    const original_ws = ws_state.current;

    for (ws_state.workspaces, 0..) |*ws, idx| {
        if (ws.windows.items().len == 0) continue;
        if (wm.fullscreen.getForWorkspace(@intCast(idx)) != null) continue;

        ws_state.current = @intCast(idx);
        tiling.retileCurrentWorkspace(wm);

        // Push non-current-workspace windows back off-screen so they are not
        // visible while their workspace is inactive.  The grab held by the
        // caller means picom never composites the briefly-on-screen positions.
        //
        // Crucially, also invalidate each window's geom_cache entry.  The retile
        // above just stored the tiled position in the cache, but we're about to
        // move the window to OFFSCREEN_X.  If we don't invalidate, the cache
        // holds a position that matches what the next retile will compute →
        // configureSafe gets a hit → skips configure_window → window stays
        // offscreen when the user switches back (if the fallback retile path runs).
        if (@as(u8, @intCast(idx)) != original_ws) {
            for (ws.windows.items()) |win| {
                _ = xcb.xcb_configure_window(wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, -4000))});
                tiling.invalidateGeomCache(win);
            }
        }
        // No intermediate flush — caller owns the flush.
    }

    ws_state.current = original_ws;
    // No grab/ungrab/flush — caller owns those.
}

/// Retiles all workspaces when the bar is toggled, keeping off-screen workspaces
/// off-screen after the geometry update. This prevents geometry staleness and
/// visual flicker when switching workspaces after a bar show/hide.
fn retileAllWorkspaces(wm: *defs.WM) void {
    // Grab → retile all workspaces → ungrab → single flush.
    // Queuing the ungrab before the flush is critical: it ensures that
    // grab + all retile commands + ungrab all land on the X server in one
    // write, so picom is frozen for the entire batch and composites only the
    // fully-retiled final state.
    _ = xcb.xcb_grab_server(wm.conn);
    retileAllWorkspacesNoGrab(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}
