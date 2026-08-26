const std = @import("std");
const utils = @import("utils");
const types = @import("types");
const drawing = @import("drawing");
const core = @import("core");

pub const min_width: u16 = 0;
pub const offscreen_rect: utils.Rect = .{ .x = std.math.maxInt(i16), .y = std.math.maxInt(i16), .width = 0, .height = 0 };
pub const TitleRenderContext = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    width: u16,
    conn: core.Connection,
    cached_title: ?*std.ArrayListUnmanaged(u8) = null,
    cached_title_window: ?*?u32 = null,
};
pub const TitleSnapshot = struct {
    focused_window: ?u32,
    focused_title: []const u8,
    minimized_title: []const u8,
    current_ws_wins: []const u32,
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void),
    titles: []const []const u8 = &.{},
    geoms: []const ?utils.Rect = &.{},
};
pub const ClickTarget = struct { window: u32, minimized: bool };
pub fn fetchWindowTitleInto(_: anytype, _: anytype, _: anytype, _: anytype) !void {}
pub fn fetchTitlesAndGeoms(_: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype) void {}
pub fn hitTest(_: anytype, _: anytype, _: anytype, _: anytype) !?ClickTarget { return null; }
pub fn draw(_: anytype, _: anytype, _: anytype, _: anytype) !u16 { return 0; }
