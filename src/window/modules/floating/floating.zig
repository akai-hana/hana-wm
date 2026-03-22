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
///
/// Cache-first optimisation: windows with a valid cached rect at a non-zero
/// origin are skipped entirely — no geometry round-trip is needed.  This
/// matters after a retile-to-floating transition where every window was just
/// positioned by the tiling engine and all their rects are already cached.
///
/// For windows that do require centering, configureSafe is used instead of a
/// raw xcb_configure_window so the cache is populated with the new position.
/// This lets restoreWorkspaceGeom replay centred positions on workspace switch
/// without a fresh geometry round-trip.
pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
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

        // Phase 0 — cache check.
        // A window with a valid cached rect at a non-zero origin has already
        // been positioned (by the user or by a previous tiling pass).  Skip
        // the geometry query entirely for those windows.
        var needs_query: [BATCH]bool = undefined;
        var any_needs: bool = false;
        for (batch, 0..) |win, i| {
            const already_placed = blk: {
                const wd = ctx.cache.get(win) orelse break :blk false;
                if (!wd.hasValidRect()) break :blk false;
                break :blk (wd.rect.x != 0 or wd.rect.y != 0);
            };
            needs_query[i] = !already_placed;
            if (!already_placed) any_needs = true;
        }

        if (!any_needs) { base = end; continue; }

        // Phase 1 — issue geometry requests only for uncached / origin windows.
        var cookies: [BATCH]xcb.xcb_get_geometry_cookie_t = undefined;
        for (batch, 0..) |win, i| {
            if (needs_query[i])
                cookies[i] = xcb.xcb_get_geometry(core.conn, win);
        }

        // Phase 2 — collect replies; the server has been working on all of
        // them since phase 1, so only the first reply incurs a round-trip.
        for (batch, 0..) |win, i| {
            if (!needs_query[i]) continue;
            const reply = xcb.xcb_get_geometry_reply(
                core.conn, cookies[i], null,
            ) orelse continue;
            defer std.c.free(reply);

            // A window not at (0,0) was placed by the user before this layout
            // pass (the cache check above missed it because the entry was
            // absent or zeroed). Leave it untouched.
            if (reply.*.x != 0 or reply.*.y != 0) continue;

            const w: i32 = reply.*.width;
            const h: i32 = reply.*.height;
            const cx: i32 = @max(0, @divTrunc(sw - w, 2));
            const cy: i32 = @max(0, @divTrunc(sh - h, 2));

            // Use configureSafe so the centred position is stored in the cache.
            // This ensures restoreWorkspaceGeom can replay it on workspace
            // switch without issuing a fresh get_geometry round-trip.
            layouts.configureSafe(ctx, win, .{
                .x      = @intCast(cx),
                .y      = @intCast(cy),
                .width  = reply.*.width,
                .height = reply.*.height,
            });
        }

        base = end;
    }
}
