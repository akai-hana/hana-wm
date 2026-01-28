//! Monocle layout

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const batch = @import("batch");
const bar = @import("bar");

const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(b: *batch.Batch, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    _ = state;
    if (windows.len == 0) return;

    const bar_height = bar.getHeight();
    const usable_h = screen_h - bar_height;

    const rect = utils.Rect{
        .x = 0,
        .y = @intCast(bar_height),
        .width = screen_w,
        .height = usable_h,
    };

    for (windows) |win| {
        b.configure(win, rect) catch |err| {
            std.log.err("[monocle] Failed to configure window {}: {}", .{ win, err });
            continue;
        };
    }

    b.raise(windows[windows.len - 1]) catch |err| {
        std.log.err("[monocle] Failed to raise window: {}", .{err});
    };
}
