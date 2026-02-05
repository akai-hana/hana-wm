//! Monocle layout - All windows fullscreen, stacked

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const batch = @import("batch");
const layouts = @import("layouts");
const debug = @import("debug");

const tiling = @import("tiling");
const State = tiling.State;

pub fn tileWithOffset(b: *batch.Batch, state: *State, windows: []const u32, screen_w: u16, screen_h: u16, y_offset: u16) void {
    _ = state;
    if (windows.len == 0) return;

    const rect = utils.Rect{
        .x = 0,
        .y = @intCast(y_offset),
        .width = screen_w,
        .height = screen_h,
    };

    // Configure all windows to fullscreen
    for (windows) |win| {
        layouts.configureSafe(b, win, rect);
    }

    // Raise the last window (most recently focused in tiled_windows order)
    const top_win = windows[windows.len - 1];
    b.raise(top_win) catch |err| {
        debug.err("Failed to raise window 0x{x}: {}", .{ top_win, err });
    };
}
