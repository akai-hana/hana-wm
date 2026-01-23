//! Monocle layout: fullscreen stacked windows.

const std = @import("std");
const defs = @import("defs");
const utils = @import("utils");
const atomic = @import("atomic");

const tiling = @import("tiling");
const State = tiling.State;

pub fn tile(tx: *atomic.Transaction, state: *State, windows: []const u32, screen_w: u16, screen_h: u16) void {
    if (windows.len == 0) return;

    const inner = state.margins().innerRect(screen_w, screen_h);

    for (windows) |win| {
        tx.configureWindow(win, inner) catch continue;
    }

    tx.raiseWindow(windows[windows.len - 1]) catch {};
}
