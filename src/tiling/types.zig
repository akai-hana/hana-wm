//! Shared types for the tiling window system.
//!
//! This module is intentionally minimal - most tiling state lives in tiling.zig.
//! These types are exported for use by layout implementations.

const std = @import("std");
const defs = @import("defs");

/// Layout algorithms available in the tiling system
pub const Layout = enum {
    master_left,
    monocle,
    grid,
};

/// Runtime state for the tiling system
/// Note: This is duplicated in tiling.zig - consider consolidating
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
