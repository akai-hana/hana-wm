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
//! spawned while floating was active — are centred on the work area.
//!
//! Heuristic limitation: a window the user has intentionally dragged to
//! position (0, 0) is indistinguishable from an unplaced window and will be
//! re-centred on the next layout pass.  The correct fix is a `manually_placed`
//! flag in the window cache; until that is added, (0, 0) remains the
//! "unplaced" sentinel.
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
const bar     = @import("bar");

// Geometry requests are batched so that all cookies are issued before any
// reply is awaited. This turns n sequential X round-trips into one flight of
// n requests followed by n local reads — important on forwarded connections
// where each round-trip carries non-trivial latency.
//
// 64 covers the typical maximum window count on a single workspace while
// keeping the two per-batch stack arrays (needs_query + cookies) well under
// 1 KB of combined stack space.
const BATCH = 64;

/// Centre any window that is still at the X default origin (0, 0).
/// Windows the user has already moved are left untouched.
///
/// Centring is relative to the work area (screen minus bar height) so that
/// freshly spawned windows are not obscured by the bar.
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

    // Work-area geometry: exclude the bar so that centred windows land in
    // the visible portion of the screen rather than behind the bar.
    const bh: i32       = if (bar.isVisible()) bar.getBarHeight() else 0;
    const bar_at_bottom = core.config.bar.vertical_position == .bottom;
    const work_top: i32 = if (bar_at_bottom) 0 else bh;
    const work_h: i32   = sh - bh;

    var base: usize = 0;
    while (base < windows.len) {
        const end   = @min(base + BATCH, windows.len);
        const batch = windows[base..end];

        // Phase 0 — cache check.
        // A window with a valid cached rect at a non-zero origin has already
        // been positioned (by the user or by a previous tiling pass).  Skip
        // the geometry query entirely for those windows.
        // Default false: a window is assumed to need a query until the cache
        // check below proves otherwise.
        var needs_query = [_]bool{false} ** BATCH;
        var any_needs: bool = false;
        for (batch, 0..) |win, i| {
            const already_placed = blk: {
                const wd = ctx.cache.get(win) orelse break :blk false;
                if (!wd.hasValidRect()) break :blk false;
                break :blk (wd.rect.x != 0 or wd.rect.y != 0);
            };
            needs_query[i] = !already_placed;
            // any_needs lets us skip the phase-1/2 loops entirely when every
            // window in this batch is already cached and placed.
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

            // Use w/h throughout to avoid re-reading the reply fields after
            // the widening conversion.  @intCast back to u16 is safe: XCB
            // width/height are u16 so w and h are always in [1, 65535].
            const w: i32 = reply.*.width;
            const h: i32 = reply.*.height;

            // Centre within the work area.  @max(0, …) clamps windows larger
            // than the work area to the near edge instead of going negative.
            const cx: i32 = @max(0, @divTrunc(sw     - w, 2));
            const cy: i32 = work_top + @max(0, @divTrunc(work_h - h, 2));

            // Use configureSafe so the centred position is stored in the cache.
            // This ensures restoreWorkspaceGeom can replay it on workspace
            // switch without issuing a fresh get_geometry round-trip.
            layouts.configureSafe(ctx, win, .{
                .x      = @intCast(cx),
                .y      = @intCast(cy),
                .width  = @intCast(w),
                .height = @intCast(h),
            });
        }

        base = end;
    }
}
