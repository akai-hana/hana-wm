//! Shared types for the tiling window system.

const std = @import("std");
const defs = @import("defs");

pub const Layout = enum {
    master_left,
    monocle,
    grid,
};

pub const TilingState = struct {
    enabled: bool = true,
    layout: Layout = .master_left,
    master_width_factor: f32 = 0.50,
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2,
    border_normal: u32 = 0x383C4A,
    tiled_windows: std.ArrayList(u32),
    master_count: usize = 1,
};
