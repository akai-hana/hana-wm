// Tiling window management — delegates to layout modules.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const constants  = @import("constants");
const focus      = @import("focus");
const workspaces = @import("workspaces");
const bar        = @import("bar");
const Tracking   = @import("tracking").Tracking;
const debug      = @import("debug");
const dpi        = @import("dpi");
const layouts    = @import("layouts");

const master_layout    = @import("master");
const monocle_layout   = @import("monocle");
const grid_layout      = @import("grid");
const fibonacci_layout = @import("fibonacci");

const MAX_MASTER_WIDTH: f32 = 0.95;
const WINDOW_EVENT_MASK     = constants.EventMasks.MANAGED_WINDOW;
// Stack-local buffer size for per-retile workspace window list.
const MAX_WS_WINDOWS: usize = 128;

pub const Layout = enum { master, monocle, grid, fibonacci };

// Variation enums are defined in defs.zig to allow config.zig to parse them
// without a circular import. Re-exported here for convenience.
pub const MasterVariation  = defs.MasterVariation;
pub const MonocleVariation = defs.MonocleVariation;
pub const GridVariation    = defs.GridVariation;

/// Stores the active variation for every layout independently.
/// Each layout remembers its last variation when the user switches away and back.
pub const LayoutVariations = struct {
    master:  MasterVariation  = .lifo,
    monocle: MonocleVariation = .gapless,
    grid:    GridVariation    = .rigid,
};

// Focus ring
// Fixed-capacity circular buffer of recently-focused window IDs.
// Newest entry is always at buffer[head].

const RING_CAP = 16;

const FocusRing = struct {
    buffer: [RING_CAP]u32 = [_]u32{0} ** RING_CAP,
    head:   u8            = 0,
    len:    u8            = 0,

    pub fn push(self: *FocusRing, win: u32) void {
        if (self.len > 0 and self.buffer[self.head] == win) return;

        // Remove any existing occurrence so the ring has no duplicates.
        var i: u8 = 1;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % RING_CAP;
            if (self.buffer[idx] == win) {
                self.compactFrom(i);
                break;
            }
        }

        self.head = if (self.head == 0) RING_CAP - 1 else self.head - 1;
        self.buffer[self.head] = win;
        if (self.len < RING_CAP) self.len += 1;
    }

    pub fn remove(self: *FocusRing, win: u32) void {
        var i: u8 = 0;
        while (i < self.len) : (i += 1) {
            const idx = (self.head + i) % RING_CAP;
            if (self.buffer[idx] != win) continue;
            self.compactFrom(i);
            return;
        }
    }

    inline fn compactFrom(self: *FocusRing, start: u8) void {
        var j = start;
        while (j + 1 < self.len) : (j += 1) {
            const cur  = (self.head + j)     % RING_CAP;
            const next = (self.head + j + 1) % RING_CAP;
            self.buffer[cur] = self.buffer[next];
        }
        self.len -= 1;
    }

    pub fn iter(self: *const FocusRing) Iterator {
        return .{ .ring = &self.buffer, .head = self.head, .len = self.len, .pos = 0 };
    }

    const Iterator = struct {
        ring: *const [RING_CAP]u32,
        head: u8, len: u8, pos: u8,

        pub fn next(self: *Iterator) ?u32 {
            if (self.pos >= self.len) return null;
            const idx = (self.head + self.pos) % RING_CAP;
            self.pos += 1;
            return self.ring[idx];
        }
    };
};

// State

pub const State = struct {
    allocator:        std.mem.Allocator,
    enabled:          bool,
    layout:           Layout,
    layout_variations: LayoutVariations,
    /// 3-character indicator shown in the bar for the fibonacci layout (which has no variations).
    /// Configurable in config.toml; defaults to "NUL".
    fibonacci_indicator: [3]u8,
    master_side:      defs.MasterSide,
    master_width:     f32,
    master_count:     u8,
    gaps:             u16,
    border_width:     u16,
    border_focused:   u32,
    border_unfocused: u32,
    windows:          Tracking,
    dirty:            bool,
    focus_ring:       FocusRing,
    /// Tracks the last geometry sent to the X server per window.
    /// Populated/updated by configureSafe via layouts.armGeomCache.
    /// Lets retile skip configure_window calls for unchanged windows.
    last_retile_screen: utils.Rect,
    geom_cache:       std.AutoHashMapUnmanaged(u32, utils.Rect),
    /// Tracks the last border pixel color sent to the X server per window.
    /// Populated in addWindow (prevents duplicate send on immediate retile)
    /// and kept current by updateBorders / updateBorderForFocusChange.
    border_cache:     std.AutoHashMapUnmanaged(u32, u32),

    pub inline fn margins(self: *const State) utils.Margins {
        return .{ .gap = self.gaps, .border = self.border_width };
    }

    pub inline fn borderColor(self: *const State, wm: *const WM, win: u32) u32 {
        if (wm.fullscreen.isFullscreen(win)) return 0;
        return if (wm.focused_window == win) self.border_focused else self.border_unfocused;
    }

    pub inline fn markDirty(self: *State)  void { self.dirty = true;  }
    pub inline fn clearDirty(self: *State) void { self.dirty = false; }

    pub fn deinit(self: *State) void {
        self.windows.deinit();
        self.geom_cache.deinit(self.allocator);
        self.border_cache.deinit(self.allocator);
    }
};

// Module singleton

var g_state: ?State = null;

pub fn getState() ?*State { return if (g_state != null) &g_state.? else null; }

// Config

/// Compute the normalised master width ratio from the current WM configuration.
/// Returns a value in [MIN_MASTER_WIDTH, MAX_MASTER_WIDTH].
fn computeMasterWidth(wm: *WM) f32 {
    const raw = dpi.scaleMasterWidth(wm.config.tiling.master_width);
    if (raw < 0) {
        const ratio = -raw / @as(f32, @floatFromInt(wm.screen.width_in_pixels));
        return @min(MAX_MASTER_WIDTH, @max(defs.MIN_MASTER_WIDTH, ratio));
    }
    return raw;
}

/// Build a complete State from the current WM configuration.
fn buildState(wm: *WM) State {
    const screen_height = wm.screen.height_in_pixels;

    return .{
        .allocator        = wm.allocator,
        .enabled          = wm.config.tiling.enabled,
        .layout           = std.meta.stringToEnum(Layout, wm.config.tiling.layout) orelse .master,
        .layout_variations = .{
            .master  = wm.config.tiling.master_variation,
            .monocle = wm.config.tiling.monocle_variation,
            .grid    = wm.config.tiling.grid_variation,
        },
        .fibonacci_indicator = wm.config.tiling.fibonacci_indicator,
        .master_side      = wm.config.tiling.master_side,
        .master_width     = computeMasterWidth(wm),
        .master_count     = wm.config.tiling.master_count,
        .gaps             = dpi.scaleGaps(wm.config.tiling.gaps, wm.dpi_info.scale_factor, screen_height),
        .border_width     = dpi.scaleBorderWidth(wm.config.tiling.border_width, wm.dpi_info.scale_factor, screen_height),
        .border_focused   = wm.config.tiling.border_focused,
        .border_unfocused = wm.config.tiling.border_unfocused,
        .windows          = Tracking.init(wm.allocator),
        .dirty            = false,
        .focus_ring       = .{},
        .last_retile_screen = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        .geom_cache       = .{},
        .border_cache     = .{},
    };
}

pub fn init(wm: *WM) void {
    g_state = buildState(wm);
}

pub fn deinit(_: *WM) void {
    if (g_state) |*s| s.deinit();
    g_state = null;
}

pub fn reloadConfig(wm: *WM) void {
    const s = getState() orelse return;

    // Preserve runtime tracking state; rebuild everything else from config.
    const saved_windows    = s.windows;
    const saved_focus_ring = s.focus_ring;

    // Config changes (gaps, border width, colors) invalidate both caches.
    s.geom_cache.deinit(s.allocator);
    s.border_cache.deinit(s.allocator);

    g_state = buildState(wm);
    g_state.?.windows    = saved_windows;
    g_state.?.focus_ring = saved_focus_ring;

    if (g_state.?.enabled) {
        // Push the new border width to every tracked window.  retileCurrentWorkspace
        // only updates geometry (x/y/width/height); BORDER_WIDTH is sent once in
        // addWindow and never again, so existing windows keep their old value after
        // a reload unless we explicitly resend it here.
        // We do this before retileCurrentWorkspace so the geometry recalculation
        // already accounts for the new border width.
        const new_s = &g_state.?;
        for (new_s.windows.items()) |win| {
            _ = xcb.xcb_configure_window(wm.conn, win,
                xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{new_s.border_width});
        }
        retileCurrentWorkspace(wm);
    }
}

// Window management

pub fn addWindow(wm: *WM, window_id: u32) void {
    std.debug.assert(window_id != 0);
    const s = getState() orelse return;
    if (!s.enabled) return;

    // Add window to tracking. In master layout with FIFO variation, new windows
    // go to the front (master position). All other cases append to the end (stack).
    const use_fifo = (s.layout == .master) and (s.layout_variations.master == .fifo);
    if (use_fifo) {
        s.windows.addFront(window_id) catch |err| { debug.logError(err, window_id); return; };
    } else {
        s.windows.add(window_id) catch |err| { debug.logError(err, window_id); return; };
    }
    s.markDirty();

    // Set BORDER_PIXEL only — EVENT_MASK was already applied by handleMapRequest,
    // so sending it again here is a redundant attribute update.
    const border_color = s.borderColor(wm, window_id);
    _ = xcb.xcb_change_window_attributes(wm.conn, window_id,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{border_color});
    _ = xcb.xcb_configure_window(wm.conn, window_id,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{s.border_width});

    // Pre-populate the border cache so the retileCurrentWorkspace call that
    // immediately follows this (in setupTiling) does not re-send the border
    // pixel for this window — it was just set above.
    s.border_cache.put(s.allocator, window_id, border_color) catch {};

}

pub fn removeWindow(window_id: u32) void {
    const s = getState() orelse return;
    if (s.windows.remove(window_id)) {
        s.markDirty();
        s.focus_ring.remove(window_id);
        _ = s.geom_cache.remove(window_id);
        _ = s.border_cache.remove(window_id);
    }
}

/// Restore windows on the current workspace to their cached tiled positions,
/// bypassing the layout algorithm entirely.
///
/// Returns true  — cache is valid and positions have been replayed.
/// Returns false — cache is stale or incomplete; caller must fall back to
///                 retileCurrentWorkspace so the layout reruns.
///
/// The cache is considered stale when:
///   • dirty flag is set (window added/removed/layout changed)
///   • any window on this workspace is absent from the cache
///   • the screen area (bar height/position) differs from when the cache
///     was last populated — handles bar visibility toggles on other workspaces
///     including when the current workspace was fullscreen at toggle time
pub fn restoreWorkspaceGeom(wm: *WM) bool {
    const s = getState() orelse return false;
    if (s.dirty) return false;

    var ws_buf: [MAX_WS_WINDOWS]u32 = undefined;
    const ws_count = filterWorkspaceWindows(s, &ws_buf);
    const ws_windows = ws_buf[0..ws_count];
    if (ws_windows.len == 0) return true;

    // If bar height or position changed since the cache was last written, the
    // stored rects are computed for a different screen area and must not be
    // replayed.  This is the canonical fix for bar-toggle-while-fullscreen:
    // no matter how bar state was changed or through which code path, the
    // screen rect comparison catches it without requiring external hooks.
    const current_screen = calculateScreenArea(wm);
    if (current_screen.x      != s.last_retile_screen.x      or
        current_screen.y      != s.last_retile_screen.y      or
        current_screen.width  != s.last_retile_screen.width  or
        current_screen.height != s.last_retile_screen.height)
    {
        return false;
    }

    // Verify every window on this workspace is in the cache before
    // sending any XCB calls — a single miss means we need a full retile.
    for (ws_windows) |win| {
        if (!s.geom_cache.contains(win)) return false;
    }

    // Fast path: replay cached positions.  No layout math, no XCB round-trips.
    for (ws_windows) |win| {
        const rect = s.geom_cache.get(win).?;
        utils.configureWindow(wm.conn, win, rect);
    }
    updateBorders(wm, ws_windows);
    return true;
}

pub inline fn isWindowTiled(window_id: u32) bool {
    const s = getState() orelse return false;
    return s.windows.contains(window_id);
}

// Screen area

fn calculateScreenArea(wm: *WM) utils.Rect {
    const bar_height: u16 = if (bar.isVisible()) bar.getBarHeight() else 0;
    const bar_at_bottom   = wm.config.bar.vertical_position == .bottom;
    return .{
        .x      = 0,
        .y      = if (bar_at_bottom) 0 else @intCast(bar_height),
        .width  = wm.screen.width_in_pixels,
        .height = wm.screen.height_in_pixels - bar_height,
    };
}

// Retiling

/// Recalculate and send geometry for every tiled window on every workspace.
///
/// Called after bar visibility or position changes so that all offscreen
/// windows on inactive workspaces already have the correct size before the
/// user switches to them — preventing the resize flicker that would otherwise
/// occur at workspace-switch time.
///
/// The current workspace is skipped: bar.setBarState already called
/// retileCurrentWorkspace for it.  Fullscreen workspaces are also skipped:
/// their sibling windows are parked offscreen and will be retiled when the
/// user exits fullscreen, at which point bar state is already correct.
pub fn retileAllWorkspaces(wm: *WM) void {
    const s = getState() orelse return;
    if (!s.enabled) return;

    const screen     = calculateScreenArea(wm);
    const ws_count   = workspaces.getWorkspaceCount();
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    layouts.armGeomCache(&s.geom_cache, s.allocator);

    var ws_idx: u8 = 0;
    while (ws_idx < ws_count) : (ws_idx += 1) {
        // Current workspace: already handled by the bar module's internal
        // retileCurrentWorkspace call.  Skip to avoid a redundant second pass.
        if (ws_idx == current_ws) continue;
        // Fullscreen workspace: sibling windows are offscreen; they'll get the
        // correct geometry when the user exits fullscreen and retile runs then.
        if (wm.fullscreen.getForWorkspace(ws_idx)) |_| continue;

        // Collect tiled windows belonging to this workspace.
        var buf: [MAX_WS_WINDOWS]u32 = undefined;
        var n: usize = 0;
        for (s.windows.items()) |win| {
            if (n >= buf.len) break;
            if (workspaces.getWorkspaceForWindow(win) == ws_idx) {
                buf[n] = win;
                n += 1;
            }
        }
        const ws_windows = buf[0..n];
        if (ws_windows.len == 0) continue;

        const w = screen.width;
        const h = screen.height;
        const y: u16 = @intCast(screen.y);

        switch (s.layout) {
            .master    => master_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
            .monocle   => monocle_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
            .grid      => grid_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
            .fibonacci => fibonacci_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        }
        updateBorders(wm, ws_windows);
    }

    layouts.disarmGeomCache();

    // Update last_retile_screen so restoreWorkspaceGeom's screen-rect check
    // passes for all workspaces after this call.
    s.last_retile_screen = screen;
}

pub fn retileIfDirty(wm: *WM) void {
    const s = getState() orelse return;
    if (!s.enabled or !s.dirty) return;
    retile(wm, calculateScreenArea(wm));
    s.clearDirty();
}

pub fn retileCurrentWorkspace(wm: *WM) void {
    const s = getState() orelse return;
    if (!s.enabled) return;
    retile(wm, calculateScreenArea(wm));
    s.clearDirty();
}

fn retile(wm: *WM, screen: utils.Rect) void {
    const s = getState() orelse return;

    const current_ws = workspaces.getCurrentWorkspace() orelse return;
    if (wm.fullscreen.getForWorkspace(current_ws)) |_| return;

    // Collect windows for the current workspace into a stack-local buffer.
    var ws_buf: [MAX_WS_WINDOWS]u32 = undefined;
    const ws_count = filterWorkspaceWindows(s, &ws_buf);
    const ws_windows = ws_buf[0..ws_count];
    if (ws_windows.len == 0) return;

    const w = screen.width;
    const h = screen.height;
    const y: u16 = @intCast(screen.y);

    // Arm the geometry cache so configureSafe can skip windows whose
    // position/size hasn't changed since the last retile.
    layouts.armGeomCache(&s.geom_cache, s.allocator);
    switch (s.layout) {
        .master    => master_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .monocle   => monocle_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .grid      => grid_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
        .fibonacci => fibonacci_layout.tileWithOffset(wm.conn, s, ws_windows, w, h, y),
    }
    layouts.disarmGeomCache();

    // Record the screen area used for this retile.  restoreWorkspaceGeom
    // compares this against the current screen area on the next workspace
    // switch — a mismatch (bar toggled, position changed, etc.) means the
    // cached rects are stale and a full retile is needed.
    s.last_retile_screen = screen;

    updateBorders(wm, ws_windows);
}

fn updateBorders(wm: *WM, ws_windows: []const u32) void {
    const s = getState() orelse return;
    for (ws_windows) |win| {
        const color = s.borderColor(wm, win);
        // Skip if the border pixel was already sent with this exact color
        // (e.g. pre-populated by addWindow or a previous retile/focus change).
        if (s.border_cache.get(win)) |cached| {
            if (cached == color) continue;
        }
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
        s.border_cache.put(s.allocator, win, color) catch {};
    }
}

// Focus border updates

pub fn updateWindowFocus(wm: *WM, old_focused: ?u32, new_focused: ?u32) void {
    const s = getState() orelse return;
    for ([2]?u32{ old_focused, new_focused }) |opt| {
        const win = opt orelse continue;
        if (!s.windows.contains(win)) continue;
        const color = s.borderColor(wm, win);
        _ = xcb.xcb_change_window_attributes(wm.conn, win, xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
        s.border_cache.put(s.allocator, win, color) catch {};
    }
}

// Window reordering

/// Move the window at `from_idx` to `to_idx` in tiling order.
fn moveWindowToIndex(s: *State, from_idx: usize, to_idx: usize) void {
    if (from_idx == to_idx) return;
    const current = s.windows.items();
    if (current.len == 0) return;

    var temp: [256]u32 = undefined;
    if (current.len > temp.len) {
        debug.warn("moveWindowToIndex: too many windows ({})", .{current.len});
        return;
    }

    const win = current[from_idx];
    var j: usize = 0;
    for (current, 0..) |w, i| {
        if (i == from_idx) continue;
        if (j == to_idx) { temp[j] = win; j += 1; }
        temp[j] = w;
        j += 1;
    }
    if (to_idx >= j) { temp[j] = win; j += 1; }
    s.windows.reorder(temp[0..j]);
}

pub fn swapWithMaster(wm: *WM) void {
    const s = getState() orelse return;
    const focused = wm.focused_window orelse return;
    if (!s.windows.contains(focused) or !workspaces.isOnCurrentWorkspace(focused)) return;

    const all = s.windows.items();
    if (all.len < 2) return;

    const focused_pos = findWindowIndex(all, focused) orelse return;

    // Find first window on current workspace — that's the effective master.
    const master_pos = for (all, 0..) |win, i| {
        if (workspaces.isOnCurrentWorkspace(win)) break i;
    } else return;

    if (focused_pos == master_pos) {
        // Already master: swap with the next workspace window.
        for (all[master_pos + 1..], master_pos + 1..) |win, i| {
            if (workspaces.isOnCurrentWorkspace(win)) {
                moveWindowToIndex(s, i, master_pos);
                break;
            }
        }
    } else {
        moveWindowToIndex(s, focused_pos, master_pos);
    }
    retileCurrentWorkspace(wm);
}

// Layout and master controls

pub fn toggleTiling(wm: *WM) void {
    const s = getState() orelse return;
    s.enabled = !s.enabled;
    if (s.enabled) retileCurrentWorkspace(wm);
    debug.info("Tiling {s}", .{if (s.enabled) "enabled" else "disabled"});
}

pub fn toggleLayout(wm: *WM) void {
    const s = getState() orelse return;
    s.layout = switch (s.layout) {
        .master    => .monocle,
        .monocle   => .grid,
        .grid      => .fibonacci,
        .fibonacci => .master,
    };
    retileCurrentWorkspace(wm);
    debug.info("Layout: {s}", .{@tagName(s.layout)});
}

pub fn toggleLayoutReverse(wm: *WM) void {
    const s = getState() orelse return;
    s.layout = switch (s.layout) {
        .master    => .fibonacci,
        .fibonacci => .grid,
        .grid      => .monocle,
        .monocle   => .master,
    };
    retileCurrentWorkspace(wm);
    debug.info("Layout (reverse): {s}", .{@tagName(s.layout)});
}

pub fn adjustMasterCount(wm: *WM, delta: i8) void {
    const s = getState() orelse return;
    const new: i16 = @as(i16, s.master_count) + delta;
    if (new < 0) return;
    s.master_count = @intCast(@min(new, 10));
    retileCurrentWorkspace(wm);
}

pub inline fn increaseMasterCount(wm: *WM) void { adjustMasterCount(wm,  1); }
pub inline fn decreaseMasterCount(wm: *WM) void { adjustMasterCount(wm, -1); }

pub fn adjustMasterWidth(wm: *WM, delta: f32) void {
    const s = getState() orelse return;
    s.master_width = @max(defs.MIN_MASTER_WIDTH, @min(MAX_MASTER_WIDTH, s.master_width + delta));
    retileCurrentWorkspace(wm);
}

pub inline fn increaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm,  0.025); }
pub inline fn decreaseMasterWidth(wm: *WM) void { adjustMasterWidth(wm, -0.025); }

/// Cycle to the next variation for the currently active layout.
/// Each layout's variation is stored independently, so switching layouts
/// and back preserves each layout's last-used variation.
pub fn cycleLayoutVariation(wm: *WM) void {
    const s = getState() orelse return;
    switch (s.layout) {
        .master => {
            s.layout_variations.master = switch (s.layout_variations.master) {
                .lifo => .fifo,
                .fifo => .lifo,
            };
            debug.info("Master variation: {s}", .{@tagName(s.layout_variations.master)});
        },
        .monocle => {
            s.layout_variations.monocle = switch (s.layout_variations.monocle) {
                .gapless => .gaps,
                .gaps    => .gapless,
            };
            debug.info("Monocle variation: {s}", .{@tagName(s.layout_variations.monocle)});
        },
        .grid => {
            s.layout_variations.grid = switch (s.layout_variations.grid) {
                .rigid   => .relaxed,
                .relaxed => .rigid,
            };
            debug.info("Grid variation: {s}", .{@tagName(s.layout_variations.grid)});
        },
        .fibonacci => {
            debug.info("Fibonacci has no variations", .{});
            return; // Nothing to cycle — skip retile and bar update
        },
    }
    s.markDirty();
    retileCurrentWorkspace(wm);
    bar.markDirty();
}

/// Return the 3-character variation indicator for the current layout.
/// Used by the bar layout segment to display alongside the layout icon.
pub fn getVariationIndicator(s: *const State) []const u8 {
    return switch (s.layout) {
        .master => switch (s.layout_variations.master) {
            .lifo => "[N]",
            .fifo => "=N=",
        },
        .monocle => switch (s.layout_variations.monocle) {
            .gapless => "<->",
            .gaps    => ">-<",
        },
        .grid => switch (s.layout_variations.grid) {
            .rigid   => "[#]",
            .relaxed => "[~]",
        },
        .fibonacci => &s.fibonacci_indicator,
    };
}

// Focus cycling

inline fn switchFocus(wm: *WM, s: *State, to: u32) void {
    std.debug.assert(to != 0 and wm.hasWindow(to));
    focus.setFocus(wm, to, .tiling_operation);
    s.focus_ring.push(to);
}

fn filterWorkspaceWindows(s: *State, buf: []u32) usize {
    var n: usize = 0;
    for (s.windows.items()) |win| {
        if (n >= buf.len) break;
        if (workspaces.isOnCurrentWorkspace(win)) { buf[n] = win; n += 1; }
    }
    return n;
}

inline fn findWindowIndex(windows: []const u32, target: u32) ?usize {
    return std.mem.indexOfScalar(u32, windows, target);
}
