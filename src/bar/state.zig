//! Bar state management

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");

pub const BarState = struct {
    window: u32,
    width: u16,
    height: u16,
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    status_text: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cached_title: std.ArrayList(u8),
    cached_title_window: ?u32,
    last_draw_time: i64,
    update_pending: std.atomic.Value(bool),
    alive: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, window: u32, width: u16, height: u16, dc: *drawing.DrawContext, config: defs.BarConfig) !*BarState {
        const state = try allocator.create(BarState);
        errdefer allocator.destroy(state);

        state.* = .{
            .window = window,
            .width = width,
            .height = height,
            .dc = dc,
            .config = config,
            .status_text = std.ArrayList(u8){},
            .allocator = allocator,
            .cached_title = std.ArrayList(u8){},
            .cached_title_window = null,
            .last_draw_time = 0,
            .update_pending = std.atomic.Value(bool).init(false),
            .alive = std.atomic.Value(bool).init(true),
        };

        try state.status_text.appendSlice(allocator, "hana");

        return state;
    }

    pub fn deinit(self: *BarState) void {
        self.alive.store(false, .release);
        self.status_text.deinit(self.allocator);
        self.cached_title.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn requestUpdate(self: *BarState) void {
        if (self.alive.load(.acquire)) {
            self.update_pending.store(true, .release);
        }
    }

    pub fn hasPendingUpdate(self: *BarState) bool {
        return self.update_pending.load(.acquire);
    }

    pub fn clearPendingUpdate(self: *BarState) void {
        self.update_pending.store(false, .release);
    }

    pub fn invalidateTitleCache(self: *BarState) void {
        self.cached_title_window = null;
    }

    pub fn isAlive(self: *BarState) bool {
        return self.alive.load(.acquire);
    }
};
