//! Floating window management
//!
//! Provides utilities for managing windows in floating mode, including
//! toggling between tiled and floating states, and maintaining floating
//! window geometry.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");

/// Floating window state tracking
pub const FloatingState = struct {
    floating_windows: std.AutoHashMap(u32, utils.Rect),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FloatingState {
        return .{
            .floating_windows = std.AutoHashMap(u32, utils.Rect).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FloatingState) void {
        self.floating_windows.deinit();
    }

    pub fn isFloating(self: *const FloatingState, win: u32) bool {
        return self.floating_windows.contains(win);
    }

    pub fn addFloating(self: *FloatingState, win: u32, rect: utils.Rect) !void {
        try self.floating_windows.put(win, rect);
    }

    pub fn removeFloating(self: *FloatingState, win: u32) void {
        _ = self.floating_windows.remove(win);
    }

    pub fn getGeometry(self: *const FloatingState, win: u32) ?utils.Rect {
        return self.floating_windows.get(win);
    }
};

var state: ?*FloatingState = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(FloatingState) catch {
        std.log.err("[floating] Failed to allocate state", .{});
        return;
    };
    s.* = FloatingState.init(wm.allocator);
    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        s.deinit();
        wm.allocator.destroy(s);
        state = null;
    }
}

/// Toggle a window between tiled and floating modes
pub fn toggleFloating(wm: *WM, win: u32) void {
    const s = state orelse return;
    const tiling = @import("tiling");

    if (s.isFloating(win)) {
        // Make window tiled
        s.removeFloating(win);
        if (wm.config.tiling.enabled and !tiling.isWindowTiled(win)) {
            tiling.notifyWindowMapped(wm, win);
        }
    } else {
        // Make window floating
        if (utils.getGeometry(wm.conn, win)) |rect| {
            s.addFloating(win, rect) catch |err| {
                std.log.err("[floating] Failed to add floating window: {}", .{err});
                return;
            };
        }

        // Remove from tiling if present
        if (tiling.isWindowTiled(win)) {
            tiling.notifyWindowDestroyed(wm, win);
        }
    }
}

/// Center a floating window on screen
pub fn centerWindow(wm: *WM, win: u32) void {
    const s = state orelse return;
    if (!s.isFloating(win)) return;

    const geom = utils.getGeometry(wm.conn, win) orelse return;
    const screen = wm.screen;

    const new_rect = utils.Rect{
        .x = @intCast(@as(i32, screen.width_in_pixels) / 2 - @as(i32, geom.width) / 2),
        .y = @intCast(@as(i32, screen.height_in_pixels) / 2 - @as(i32, geom.height) / 2),
        .width = geom.width,
        .height = geom.height,
    };

    utils.configureWindow(wm.conn, win, new_rect);
    _ = s.floating_windows.put(win, new_rect) catch {};
    utils.flush(wm.conn);
}

/// Check if a window is floating
pub fn isFloating(win: u32) bool {
    const s = state orelse return false;
    return s.isFloating(win);
}

pub fn getState() ?*FloatingState {
    return state;
}
