// Key definitions

const std = @import("std");

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

pub const Config = struct {
    border_width: u32,
    border_color: u32,
};

pub const WM = struct {
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    root: u32,
    config: Config,
    allocator: std.mem.Allocator,
};

pub const Module = struct {
    name: []const u8,
    init_fn: *const fn (*WM) void,
    handle_fn: *const fn (u8, *anyopaque, *WM) void,

    pub fn init(self: *Module, wm: *WM) void {
        self.init_fn(wm);
    }

    pub fn handleEvent(self: *Module, event_type: u8, event: *anyopaque, wm: *WM) void {
        self.handle_fn(event_type, event, wm);
    }
};
