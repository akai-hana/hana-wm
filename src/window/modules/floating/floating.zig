//! Floating layout — windows are left at their current positions.
//!
//! Switching to this layout lets windows be moved and resized freely without
//! any tiling engine interference.  The layout engine is still active (windows
//! remain tracked in tiling.State), so switching back to a tiling layout
//! retiles all tracked windows immediately.
//!
//! Interface
//!
//! floating follows the same tileWithOffset interface as every other layout
//! module.  Windows that have already been positioned (x or y ≠ 0) are left
//! untouched.  Windows still at the X default origin (0, 0) — i.e. freshly
//! spawned while floating was active — are centred on the screen.
//!
//! Prev-layout state
//!
//! The layout to restore when floating is exited is stored in tiling.State
//! (State.prev_layout) rather than here, so this module stays free of a
//! circular dependency with tiling.zig.

const std     = @import("std");
const layouts = @import("layouts");
const core    = @import("core");
const xcb     = core.xcb;

// Geometry requests are batched so that all cookies are issued before any
// reply is awaited. This turns n sequential X round-trips into one flight of
// n requests followed by n local reads — important on forwarded connections
// where each round-trip carries non-trivial latency.
const BATCH = 64;

/// Centre any window that is still at the X default origin (0, 0).
/// Windows the user has already moved are left untouched.
pub fn tileWithOffset(
    _: *const layouts.LayoutCtx,
    _: anytype,
    windows: []const u32,
    _: u16, _: u16, _: u16,
) void {
    const sw: i32 = core.screen.width_in_pixels;
    const sh: i32 = core.screen.height_in_pixels;

    var base: usize = 0;
    while (base < windows.len) {
        const end   = @min(base + BATCH, windows.len);
        const batch = windows[base..end];

        // Phase 1 — issue all geometry requests without waiting for replies.
        var cookies: [BATCH]xcb.xcb_get_geometry_cookie_t = undefined;
        for (batch, 0..) |win, i| {
            cookies[i] = xcb.xcb_get_geometry(core.conn, win);
        }

        // Phase 2 — collect replies; the server has been working on all of
        // them since phase 1, so only the first reply incurs a round-trip.
        for (batch, 0..) |win, i| {
            const reply = xcb.xcb_get_geometry_reply(
                core.conn,
                cookies[i],
                null,
            ) orelse continue;
            defer std.c.free(reply);

            // Skip windows that have already been positioned by the user or by
            // a prior tiling pass — only the X default origin (0, 0) needs fixing.
            if (reply.*.x != 0 or reply.*.y != 0) continue;

            const w: i32 = reply.*.width;
            const h: i32 = reply.*.height;
            const cx: i32 = @max(0, @divTrunc(sw - w, 2));
            const cy: i32 = @max(0, @divTrunc(sh - h, 2));

            const vals = [_]u32{ @bitCast(cx), @bitCast(cy) };
            _ = xcb.xcb_configure_window(
                core.conn, win,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &vals,
            );
        }

        base = end;
    }
}
