//! Floating windows layout
//! Manages placement, movement, and resizing of freely positioned floating windows.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;

const layouts = @import("layouts");

const bar = @import("bar");

// Geometry cookies are all issued before any reply is awaited — one round-trip
// per batch instead of one per window. 64 covers a typical workspace.
const BATCH = 64;

/// Centre any window still at the X default origin (0, 0); windows the user
/// has already moved are left untouched. Centring uses the work area (screen
/// minus bar) so new windows aren't obscured by the bar.
pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
    _: anytype,
    windows: []const u32,
    _: u16,
    _: u16,
    _: u16,
) void {
    const cs = core.getState();
    const work = bar.workAreaRect();
    const sw: i32 = work.width;
    const work_top: i32 = work.y;
    const work_h: i32 = work.height;

    var base: usize = 0;
    while (base < windows.len) {
        const end = @min(base + BATCH, windows.len);
        const batch = windows[base..end];

        // Issue geometry requests for every window not already placed;
        // replies are collected below — only the first reply pays for a round-trip.
        var cookies: [BATCH]xcb.xcb_get_geometry_cookie_t = undefined;
        var pending: [BATCH]usize = undefined;
        var pending_len: usize = 0;
        for (batch, 0..) |win, i| {
            const already_placed = if (ctx.cache.getPtr(win)) |wd| wd.hasValidRect() else false;
            if (already_placed) continue;
            cookies[i] = xcb.xcb_get_geometry(cs.conn, win);
            pending[pending_len] = i;
            pending_len += 1;
        }
        if (pending_len > 0) {
            for (pending[0..pending_len]) |i| {
                const win = batch[i];
                const reply = xcb.xcb_get_geometry_reply(cs.conn, cookies[i], null) orelse continue;
                defer std.c.free(reply);

                // Not at (0,0): user already placed it before this pass — leave it.
                if (reply.*.x != 0 or reply.*.y != 0) continue;

                const w: i32 = reply.*.width;
                const h: i32 = reply.*.height;
                const cx: i32 = @max(0, @divTrunc(sw - w, 2));
                const cy: i32 = work_top + @max(0, @divTrunc(work_h - h, 2));

                // configureWithHints stores the position in the cache so
                // restoreWorkspaceGeom can replay it without a fresh query.
                layouts.configureWithHints(ctx, win, .{
                    .x = @intCast(cx),
                    .y = @intCast(cy),
                    .width = @intCast(w),
                    .height = @intCast(h),
                });
            }
        }

        base = end;
    }
}
