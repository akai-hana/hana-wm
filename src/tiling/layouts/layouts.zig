/// Common layout interface and utilities
/// Eliminates duplication across all layout modules

const std = @import("std");
const batch = @import("batch");
const utils = @import("utils");
const tiling = @import("tiling");
const debug = @import("debug");

const State = tiling.State;

/// Unified error-handling wrapper for configure operations
/// Provides consistent error logging across all layouts
pub inline fn configureSafe(
    b: *batch.Batch, 
    win: u32, 
    rect: utils.Rect
) void {
    b.configure(win, rect) catch |err| {
        debug.err("Failed to configure window 0x{x}: {}", 
            .{ win, err });
    };
}

/// Generic tile wrapper that delegates to tileWithOffset
/// Eliminates duplicate tile() function across all layouts
pub inline fn tileWrapper(
    comptime tileWithOffsetFn: anytype,
    b: *batch.Batch,
    state: *State,
    windows: []const u32,
    screen_w: u16,
    screen_h: u16,
) void {
    tileWithOffsetFn(b, state, windows, screen_w, screen_h, 0);
}
