//! Monocle layout: fullscreen stacked windows.

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const atomic = @import("atomic");
const bar = @import("bar");

const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(tx: *atomic.Transaction, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    if (windows.len == 0) return;

    const bar_height = bar.getHeight();
    const usable_h = screen_h - bar_height;

    const m = state.margins();
    const inner = m.innerRect(screen_w, usable_h);

    const adjusted_rect = utils.Rect{
        .x = inner.x,
        .y = @intCast(@as(i32, inner.y) + @as(i32, bar_height)),
        .width = inner.width,
        .height = inner.height,
    };

    for (windows) |win| {
        tx.configureWindow(win, adjusted_rect) catch |err| {
            std.log.err("[monocle] Failed to configure window {}: {}", .{ win, err });
            continue;
        };
    }

    tx.raiseWindow(windows[windows.len - 1]) catch |err| {
        std.log.err("[monocle] Failed to raise window: {}", .{err});
    };
}
