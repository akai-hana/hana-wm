//! Floating layout — windows are left at their current positions.
//!
//! Switching to this layout lets windows be moved and resized freely without
//! any tiling engine interference.  The layout engine is still active (windows
//! remain tracked in tiling.State), so switching back to a tiling layout
//! retiles all tracked windows immediately.
//!
//! Interface
//! ─────────
//! floating follows the same tileWithOffset interface as every other layout
//! module.  The implementation is intentionally a no-op: when dispatched, the
//! layout engine simply does not move or resize any window, leaving them at
//! whatever positions they held when floating was entered.
//!
//! Prev-layout state
//! ─────────────────
//! The layout to restore when floating is exited is stored in tiling.State
//! (State.prev_layout) rather than here, so this module stays import-free and
//! avoids a circular dependency with tiling.zig.

const layouts = @import("layouts");

/// No-op tile pass.  Windows are not moved or resized while the floating
/// layout is active.
pub fn tileWithOffset(
    _: *const layouts.LayoutCtx,
    _: anytype,
    _: []const u32,
    _: u16, _: u16, _: u16,
) void {}
