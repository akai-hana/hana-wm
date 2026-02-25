//! Status bar — renders segments via Cairo/Pango into an XCB override-redirect window.
//!
//! Comptime dispatch: when no segment module files are present on disk,
//! `has_any_segment` is false, all public functions become no-ops, and
//! `init` always returns `error.BarDisabled`. Because `BarFull` is never
//! analyzed by Zig's lazy evaluator in that case, `drawing.zig` is never
//! compiled and cairo/pango are not linked.

const std   = @import("std");
const defs  = @import("defs");
const xcb   = defs.xcb;
const debug = @import("debug");

const bar_flags = @import("bar_flags");

// Public type exposed to callers regardless of whether segments are compiled in.
pub const BarAction = enum { toggle, hide_fullscreen, show_fullscreen };

// Comptime selection of full vs stub implementation.
// BarFull is never analyzed when has_any_segment is false — so drawing.zig
// and all cairo/pango symbols are never referenced.
const Impl = if (bar_flags.has_any_segment) BarFull else BarStub;

// Public API — thin delegation so callers never need to know which Impl is active.

pub fn init(wm: *defs.WM) !void                                     { return Impl.init(wm); }
pub fn deinit() void                                                  { Impl.deinit(); }
pub fn reload(wm: *defs.WM) void                                     { Impl.reload(wm); }
pub fn toggleBarPosition(wm: *defs.WM) !void                         { return Impl.toggleBarPosition(wm); }
pub fn getBarWindow() u32                                             { return Impl.getBarWindow(); }
pub fn isBarWindow(win: u32) bool                                    { return Impl.isBarWindow(win); }
pub fn getBarHeight() u16                                             { return Impl.getBarHeight(); }
pub fn isBarInitialized() bool                                       { return Impl.isBarInitialized(); }
pub fn hasClockSegment() bool                                        { return Impl.hasClockSegment(); }
pub fn markDirty() void                                               { Impl.markDirty(); }
pub fn redrawImmediate(wm: *defs.WM) void                            { Impl.redrawImmediate(wm); }
pub fn raiseBar() void                                                { Impl.raiseBar(); }
pub fn isVisible() bool                                               { return Impl.isVisible(); }
pub fn getGlobalVisibility() bool                                    { return Impl.getGlobalVisibility(); }
pub fn setGlobalVisibility(visible: bool) void                       { Impl.setGlobalVisibility(visible); }
pub fn setBarState(wm: *defs.WM, action: BarAction) void             { Impl.setBarState(wm, action); }
pub fn updateIfDirty(wm: *defs.WM) !void                             { return Impl.updateIfDirty(wm); }
pub fn checkClockUpdate() void                                        { Impl.checkClockUpdate(); }
pub fn handleExpose(ev: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
    Impl.handleExpose(ev, wm);
}
pub fn handlePropertyNotify(ev: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
    Impl.handlePropertyNotify(ev, wm);
}
pub fn monitorFocusedWindow(wm: *defs.WM) void                       { Impl.monitorFocusedWindow(wm); }
pub fn handleButtonPress(ev: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
    Impl.handleButtonPress(ev, wm);
}

// Stub — zero-segment build. init signals BarDisabled; everything else is a no-op.
const BarStub = struct {
    pub fn init(_: *defs.WM) error{BarDisabled}!void { return error.BarDisabled; }
    pub fn deinit() void {}
    pub fn reload(_: *defs.WM) void {}
    pub fn toggleBarPosition(_: *defs.WM) !void {}
    pub fn getBarWindow() u32                         { return 0; }
    pub fn isBarWindow(_: u32) bool                  { return false; }
    pub fn getBarHeight() u16                         { return 0; }
    pub fn isBarInitialized() bool                   { return false; }
    pub fn hasClockSegment() bool                    { return false; }
    pub fn markDirty() void {}
    pub fn redrawImmediate(_: *defs.WM) void {}
    pub fn raiseBar() void {}
    pub fn isVisible() bool                           { return false; }
    pub fn getGlobalVisibility() bool                { return false; }
    pub fn setGlobalVisibility(_: bool) void {}
    pub fn setBarState(_: *defs.WM, _: BarAction) void {}
    pub fn updateIfDirty(_: *defs.WM) !void {}
    pub fn checkClockUpdate() void {}
    pub fn handleExpose(_: *const xcb.xcb_expose_event_t, _: *defs.WM) void {}
    pub fn handlePropertyNotify(_: *const xcb.xcb_property_notify_event_t, _: *defs.WM) void {}
    pub fn monitorFocusedWindow(_: *defs.WM) void {}
    pub fn handleButtonPress(_: *const xcb.xcb_button_press_event_t, _: *defs.WM) void {}
};

// Full implementation — only analyzed when has_any_segment is true.
//
// All bar-specific imports (drawing, cairo, pango) live inside this struct so
// they are never evaluated when the stub is selected. Per-segment imports each
// use their own flag with an inline stub fallback, so deleting any individual
// segment file just silently renders that segment as nothing.
const BarFull = struct {
    // Bar-specific imports — cairo/pango pulled in transitively via drawing.
    const drawing    = @import("drawing");
    const tiling     = @import("tiling");
    const utils      = @import("utils");
    const workspaces = @import("workspaces");
    const constants  = @import("constants");
    const dpi_mod    = @import("dpi");

    // Per-segment conditional imports with inline stubs.
    // A missing file sets its flag to false; the stub draws nothing (returns start_x).

    const workspaces_segment = if (bar_flags.has_tags) @import("tags") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
        pub fn invalidate() void {}
        pub fn getCachedWorkspaceWidth() u16 { return 0; }
    };

    const layout_segment = if (bar_flags.has_layout) @import("layout") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
    };

    const variations_segment = if (bar_flags.has_variations) @import("variations") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
    };

    const title_segment = if (bar_flags.has_title) @import("title") else struct {
        pub fn draw(
            _: *drawing.DrawContext, _: defs.BarConfig, _: u16,
            x: u16, w: u16,
            _: *defs.WM, _: *std.ArrayList(u8), _: *?u32, _: std.mem.Allocator,
        ) !u16 { return x + w; }
    };

    const clock_segment = if (bar_flags.has_clock) @import("clock") else struct {
        pub const SAMPLE_STRING: []const u8 = "";
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16) !u16 { return x; }
        pub fn setTimerFd(_: i32) void {}
        pub fn updateTimerState() void {}
    };

    const status_segment = if (bar_flags.has_status) @import("status") else struct {
        pub fn draw(_: *drawing.DrawContext, _: defs.BarConfig, _: u16, x: u16, _: []const u8) !u16 { return x; }
        pub fn update(_: *defs.WM, _: *std.ArrayList(u8), _: std.mem.Allocator) !void {}
    };

    // Constants

    const MIN_BAR_HEIGHT:            u32 = 20;
    const MAX_BAR_HEIGHT:            u32 = 200;
    const DEFAULT_BAR_HEIGHT:        u16 = 24;
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
        cached_workspace_x:   u16,
        has_clock_segment:    bool,

        fn init(
            allocator:        std.mem.Allocator,
            conn:             *xcb.xcb_connection_t,
            window:           u32,
            width:            u16,
            height:           u16,
            dc:               *drawing.DrawContext,
            config:           defs.BarConfig,
            has_transparency: bool,
        ) !*State {
            const s = try allocator.create(State);
            s.* = .{
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
                .cached_clock_width   = dc.textWidth(clock_segment.SAMPLE_STRING) + 2 * config.scaledSegmentPadding(height),
                .cached_clock_x       = null,
                .cached_workspace_x   = 0,
                .has_clock_segment    = detectClockSegment(&config),
            };
            try s.status_text.ensureTotalCapacity(allocator, 256);
            try s.cached_title.ensureTotalCapacity(allocator, 256);
            workspaces_segment.invalidate();
            return s;
        }

        fn deinit(self: *State) void {
            self.status_text.deinit(self.allocator);
            self.cached_title.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        fn markDirty(self: *State) void {
            self.dirty = true;
            self.cached_clock_x = null;
        }
        fn markClockDirty(self: *State) void { self.dirty_clock = true; }
        fn clearDirty(self: *State) void { self.dirty = false; self.dirty_clock = false; }
    };

    /// Scans the bar layout config for a clock segment.
    /// Short-circuits to false at comptime when the clock module is absent.
    fn detectClockSegment(config: *const defs.BarConfig) bool {
        if (comptime !bar_flags.has_clock) return false;
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

    fn barYPos(wm: *defs.WM, height: u16) i16 {
        return if (wm.config.bar.vertical_position == .bottom)
            @intCast(@as(i32, wm.screen.height_in_pixels) - height)
        else
            0;
    }

    const BarWindowSetup = struct { window: u32, visual_id: u32, has_argb: bool };

    fn createBarWindow(wm: *defs.WM, height: u16, y_pos: i16) BarWindowSetup {
        const want_transparency = wm.config.bar.getAlpha16() < 0xFFFF;
        const visual_info       = if (want_transparency)
            drawing.findVisualByDepth(wm.screen, 32)
        else
            drawing.VisualInfo{ .visual_type = null, .visual_id = wm.screen.root_visual };
        const depth:    u8 = if (want_transparency) 32 else xcb.XCB_COPY_FROM_PARENT;
        const visual_id    = visual_info.visual_id;

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
            0,                                                              // back pixel
            0,                                                              // border pixel
            1,                                                              // override-redirect
            xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_BUTTON_PRESS, // event mask
            colormap,                                                       // colormap (ARGB only)
        };
        _ = xcb.xcb_create_window(wm.conn, depth, window, wm.screen.root,
            0, y_pos, wm.screen.width_in_pixels, height, 0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual_id,
            @intCast(value_mask), &value_list);

        return .{ .window = window, .visual_id = visual_id, .has_argb = want_transparency };
    }

    // Font helpers

    fn sizeFont(alloc: std.mem.Allocator, font: []const u8, size: u16) !?[]const u8 {
        if (size == 0) return null;
        return try std.fmt.allocPrint(alloc, "{s}:size={}", .{ font, size });
    }

    fn loadBarFonts(dc: *drawing.DrawContext, wm: *defs.WM) !void {
        const cfg         = wm.config.bar;
        const alloc       = wm.allocator;
        const scaled_size = cfg.scaledFontSize();

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

    inline fn setPropAtom(conn: *xcb.xcb_connection_t, win: u32, prop: u32, type_: u32, data: anytype) void {
        _ = xcb.xcb_change_property(conn, xcb.XCB_PROP_MODE_REPLACE, win, prop, type_, 32, data.len, data);
    }

    fn setWindowProperties(wm: *defs.WM, window: u32, height: u16) !void {
        const strut: [12]u32 = if (wm.config.bar.vertical_position == .bottom)
            .{ 0, 0, 0, height, 0, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels }
        else
            .{ 0, 0, height, 0, 0, 0, 0, 0, 0, wm.screen.width_in_pixels, 0, 0 };

        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_STRUT_PARTIAL"), xcb.XCB_ATOM_CARDINAL, &strut);
        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_WINDOW_TYPE"), xcb.XCB_ATOM_ATOM,
            &[_]u32{try utils.getAtomCached("_NET_WM_WINDOW_TYPE_DOCK")});
        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_STATE"), xcb.XCB_ATOM_ATOM,
            &[_]u32{
                try utils.getAtomCached("_NET_WM_STATE_ABOVE"),
                try utils.getAtomCached("_NET_WM_STATE_STICKY"),
            });
        setPropAtom(wm.conn, window,
            try utils.getAtomCached("_NET_WM_ALLOWED_ACTIONS"), xcb.XCB_ATOM_ATOM,
            &[_]u32{
                try utils.getAtomCached("_NET_WM_ACTION_CLOSE"),
                try utils.getAtomCached("_NET_WM_ACTION_ABOVE"),
                try utils.getAtomCached("_NET_WM_ACTION_STICK"),
            });
    }

    // Bar height

    /// Loads fonts at a trial point size, measures glyph height, and back-calculates
    /// the Pango point size that exactly fills `bar_height`. Returns null on failure.
    fn resolvePercentageFontSize(wm: *defs.WM, bar_height: u16) ?u16 {
        const TRIAL_PT: u16 = 100;

        const saved_size = wm.config.bar.scaled_font_size;
        wm.config.bar.scaled_font_size = TRIAL_PT;
        defer wm.config.bar.scaled_font_size = saved_size;

        const temp_dc = drawing.DrawContext.initOffscreen(wm.allocator, wm.conn, wm.dpi_info.dpi) catch |e| {
            debug.warnOnErr(e, "DrawContext.initOffscreen in resolvePercentageFontSize");
            return null;
        };
        defer temp_dc.deinit();

        loadBarFonts(temp_dc, wm) catch return null;

        const asc, const desc = temp_dc.getMetrics();
        const font_px: f32    = @floatFromInt(@max(1, asc + desc));
        const px_per_pt: f32  = font_px / @as(f32, @floatFromInt(TRIAL_PT));
        const height_f: f32   = @floatFromInt(bar_height);

        const max_size_pt = height_f / px_per_pt;
        const final_size  = max_size_pt * (wm.config.bar.font_size.value / 100.0);
        return @max(1, @as(u16, @intFromFloat(@round(final_size))));
    }

    fn calculateBarHeight(wm: *defs.WM) !u16 {
        if (wm.config.bar.height) |h| {
            const height = dpi_mod.scaleBarHeight(h, wm.screen.height_in_pixels);
            if (wm.config.bar.font_size.is_percentage) {
                if (resolvePercentageFontSize(wm, height)) |sz|
                    wm.config.bar.scaled_font_size = sz;
            }
            return height;
        }

        const temp_dc = drawing.DrawContext.initOffscreen(wm.allocator, wm.conn, wm.dpi_info.dpi) catch |e| {
            debug.warnOnErr(e, "DrawContext.initOffscreen in calculateBarHeight");
            return DEFAULT_BAR_HEIGHT;
        };
        defer temp_dc.deinit();

        loadBarFonts(temp_dc, wm) catch {
            debug.warn("Failed to load fonts for height calculation, using default", .{});
            return DEFAULT_BAR_HEIGHT;
        };

        const asc, const desc  = temp_dc.getMetrics();
        const font_height: u32 = @intCast(asc + desc);
        return @intCast(std.math.clamp(font_height, MIN_BAR_HEIGHT, MAX_BAR_HEIGHT));
    }

    // Lifecycle

    pub fn init(wm: *defs.WM) !void {
        if (!wm.config.bar.enabled) return error.BarDisabled;

        const height = try calculateBarHeight(wm);
        const y_pos  = barYPos(wm, height);
        const setup  = createBarWindow(wm, height, y_pos);
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

    pub fn deinit() void {
        if (state) |s| {
            // Explicitly destroy the X11 window to prevent ghost windows on hot-reload.
            _ = xcb.xcb_destroy_window(s.conn, s.window);
            s.dc.deinit();
            s.deinit();
            state = null;
        }
    }

    pub fn reload(wm: *defs.WM) void {
        const old = state orelse {
            BarFull.init(wm) catch |err| {
                if (err != error.BarDisabled) debug.err("Bar init failed: {}", .{err});
            };
            return;
        };

        if (!wm.config.bar.enabled) { BarFull.deinit(); return; }

        const height = calculateBarHeight(wm) catch DEFAULT_BAR_HEIGHT;
        const y_pos  = barYPos(wm, height);
        const setup  = createBarWindow(wm, height, y_pos);

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

    pub fn toggleBarPosition(wm: *defs.WM) !void {
        if (state) |s| {
            wm.config.bar.vertical_position = switch (wm.config.bar.vertical_position) {
                .top    => .bottom,
                .bottom => .top,
            };
            const new_y = barYPos(wm, s.height);
            // setWindowProperties makes blocking round-trips; do this before the grab.
            try setWindowProperties(wm, s.window, s.height);
            _ = xcb.xcb_grab_server(wm.conn);
            _ = xcb.xcb_configure_window(s.conn, s.window, xcb.XCB_CONFIG_WINDOW_Y,
                &[_]u32{@as(u32, @bitCast(@as(i32, new_y)))});
            const current_ws = workspaces.getCurrentWorkspace() orelse {
                _ = xcb.xcb_ungrab_server(wm.conn);
                utils.flush(wm.conn);
                return;
            };
            if (wm.fullscreen.getForWorkspace(current_ws) == null)
                tiling.retileCurrentWorkspace(wm);
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
            debug.info("Bar position toggled to: {s}", .{@tagName(wm.config.bar.vertical_position)});
        }
    }

    pub fn getBarWindow() u32         { return if (state) |s| s.window else 0; }
    pub fn isBarWindow(win: u32) bool  { return if (state) |s| s.window == win else false; }
    pub fn getBarHeight() u16          { return if (state) |s| s.height else 0; }
    pub fn isBarInitialized() bool     { return state != null; }
    pub fn hasClockSegment() bool      { return if (state) |s| s.has_clock_segment else false; }
    pub fn markDirty() void            { if (state) |s| s.markDirty(); }

    pub fn redrawImmediate(wm: *defs.WM) void {
        const s = state orelse return;
        if (!s.visible) return;
        draw(s, wm) catch |e| debug.warnOnErr(e, "draw in redrawImmediate");
        s.clearDirty();
    }

    pub fn raiseBar() void {
        if (state) |s| _ = xcb.xcb_configure_window(s.conn, s.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    pub fn isVisible() bool            { return if (state) |s| s.visible else false; }
    pub fn getGlobalVisibility() bool  { return if (state) |s| s.global_visible else false; }
    pub fn setGlobalVisibility(visible: bool) void { if (state) |s| s.global_visible = visible; }

    pub fn setBarState(wm: *defs.WM, action: BarAction) void {
        const s = state orelse return;

        if (action == .toggle) s.global_visible = !s.global_visible;
        const is_fullscreen = switch (action) {
            .hide_fullscreen => false,
            else => wm.fullscreen.getForWorkspace(workspaces.getCurrentWorkspace() orelse 0) != null,
        };
        const show = !is_fullscreen and s.global_visible and action != .hide_fullscreen;
        if (s.visible == show and action != .toggle) return;

        s.visible = show;

        if (action == .toggle) {
            // Draw before grab — Cairo calls inside a grab add latency.
            if (show) draw(s, wm) catch |e| debug.warnOnErr(e, "draw in setBarState");
            _ = xcb.xcb_grab_server(wm.conn);
            if (show) _ = xcb.xcb_map_window(s.conn, s.window)
            else      _ = xcb.xcb_unmap_window(s.conn, s.window);
            // Briefly expose global_visible through isVisible() for the retile so
            // calculateScreenArea uses the intended future bar height on non-current workspaces.
            const saved = s.visible;
            if (is_fullscreen) s.visible = s.global_visible;
            retileAllWorkspacesNoGrab(wm);
            if (is_fullscreen) s.visible = saved;
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
        } else {
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
        clock_segment.updateTimerState();
    }

    // Update loop

    pub fn updateIfDirty(wm: *defs.WM) !void {
        const s = state orelse return;
        if (s.dirty) {
            try draw(s, wm);
            s.clearDirty();
        } else if (s.dirty_clock) {
            try drawClockOnly(s, wm);
            s.clearDirty();
        }
    }

    pub fn checkClockUpdate() void {
        if (state) |s| if (s.visible) s.markClockDirty();
    }

    pub fn handleExpose(event: *const xcb.xcb_expose_event_t, wm: *defs.WM) void {
        if (state) |s| if (event.window == s.window and event.count == 0) {
            if (wm.drag_state.active) {
                // Defer during drag — Expose events stream continuously with no bar change.
                s.markDirty();
            } else {
                draw(s, wm) catch |e| debug.warnOnErr(e, "draw in handleExpose");
            }
        };
    }

    pub fn handlePropertyNotify(event: *const xcb.xcb_property_notify_event_t, wm: *defs.WM) void {
        const s = state orelse return;

        if (event.window == wm.root and event.atom == xcb.XCB_ATOM_WM_NAME) {
            status_segment.update(wm, &s.status_text, s.allocator) catch |e|
                debug.warnOnErr(e, "status_segment.update");
            s.markDirty();
            return;
        }

        if (wm.focused_window) |focused_win| {
            if (event.window != focused_win) return;
            const net_wm_name = utils.getAtomCached("_NET_WM_NAME") catch |e| {
                debug.warnOnErr(e, "getAtomCached _NET_WM_NAME in handlePropertyNotify");
                return;
            };
            if (event.atom == xcb.XCB_ATOM_WM_NAME or event.atom == net_wm_name) {
                s.cached_title_window = null;
                s.markDirty();
            }
        }
    }

    pub fn monitorFocusedWindow(wm: *defs.WM) void {
        const win = wm.focused_window orelse return;
        const values = [_]u32{xcb.XCB_EVENT_MASK_PROPERTY_CHANGE};
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_EVENT_MASK, &values);
    }

    pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t, wm: *defs.WM) void {
        if (state) |s| if (event.event == s.window) {
            const ws_state          = workspaces.getState() orelse return;
            const click_x           = @max(0, event.event_x - s.cached_workspace_x);
            const clicked_ws: usize = @intCast(@divFloor(click_x, workspaces_segment.getCachedWorkspaceWidth()));
            if (clicked_ws < ws_state.workspaces.len) {
                workspaces.switchTo(wm, clicked_ws);
                s.markDirty();
            }
        };
    }

    // Drawing

    fn calculateSegmentWidth(s: *State, segment: defs.BarSegment) u16 {
        return switch (segment) {
            .workspaces => if (workspaces.getState()) |ws|
                @intCast(ws.workspaces.len * workspaces_segment.getCachedWorkspaceWidth())
            else
                FALLBACK_WORKSPACES_WIDTH,
            .layout     => LAYOUT_SEGMENT_WIDTH,
            .variations => LAYOUT_SEGMENT_WIDTH,
            .title      => TITLE_SEGMENT_MIN_WIDTH,
            .clock      => s.cached_clock_width,
        };
    }

    fn drawRightSegments(s: *State, wm: *defs.WM, segments: []const defs.BarSegment) !void {
        var right_x          = s.width;
        const scaled_spacing = s.config.scaledSpacing(s.height);
        for (0..segments.len) |i| {
            const idx = segments.len - 1 - i;
            right_x -= calculateSegmentWidth(s, segments[idx]);
            if (segments[idx] == .clock) s.cached_clock_x = right_x;
            _ = try drawSegment(s, wm, segments[idx], right_x, null);
            if (i < segments.len - 1) right_x -= scaled_spacing;
        }
    }

    fn draw(s: *State, wm: *defs.WM) !void {
        if (s.has_transparency) s.dc.clearTransparent();
        s.dc.fillRect(0, 0, s.width, s.height, s.config.bg);

        const scaled_spacing = s.config.scaledSpacing(s.height);
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

    fn drawClockOnly(s: *State, wm: *defs.WM) !void {
        if (s.cached_clock_x) |clock_x| {
            _ = try clock_segment.draw(s.dc, s.config, s.height, clock_x);
            s.dc.flush();
            return;
        }
        try draw(s, wm);
    }

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

            // Push non-current windows off-screen and invalidate geom cache so a
            // subsequent switch doesn't get a stale cache hit and leave them off-screen.
            if (@as(u8, @intCast(idx)) != original_ws) {
                for (ws.windows.items()) |win| {
                    _ = xcb.xcb_configure_window(wm.conn, win,
                        xcb.XCB_CONFIG_WINDOW_X, &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
                    tiling.invalidateGeomCache(win);
                }
            }
        }

        ws_state.current = original_ws;
    }
};
