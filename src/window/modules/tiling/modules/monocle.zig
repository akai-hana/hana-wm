//! Monocle tiling layout
//! Stacks all windows fullscreen, showing only the topmost one, with optional gap insets.

const core      = @import("core");
const constants = @import("constants");
const utils     = @import("utils");
const layouts   = @import("layouts");
const tiling    = @import("tiling");
const State     = tiling.State;
const xcb       = core.xcb;

/// Tile `windows` into monocle mode using the given screen area.
pub fn tileWithOffset(
    ctx:      *const layouts.LayoutCtx,
    state:    *State,
    windows:  []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    if (windows.len == 0) return;

    const m      = state.margins();
    const inset: u16 = if (state.layout_variants.monocle == .gaps) m.gap else 0;
    const total_margin = m.border * 2 + inset * 2;

    const top_win  = windows[windows.len - 1];
    const top_rect = utils.Rect{
        .x      = @intCast(inset),
        .y      = @intCast(y_offset +| inset),
        .width  = if (screen_w > total_margin) screen_w - total_margin else constants.MIN_WINDOW_DIM,
        .height = if (screen_h > total_margin) screen_h - total_margin else constants.MIN_WINDOW_DIM,
    };

    layouts.configureWithHintsAndRaise(ctx, top_win, top_rect);

    pushBackgroundWindowsOffscreen(ctx, windows[0 .. windows.len - 1]);
}

// ============================================================================
// Private helpers
// ============================================================================

/// Push non-top windows off the visible screen area so they never show through
/// a transparent top window. Skips windows already known to be offscreen to
/// avoid redundant round-trips; invalidates their cache rect so
/// `restoreWorkspaceGeom` does not replay a stale on-screen position.
fn pushBackgroundWindowsOffscreen(ctx: *const layouts.LayoutCtx, background: []const u32) void {
    for (background) |win| {
        if (ctx.cache.getPtr(win)) |wd| {
            if (!wd.hasValidRect()) continue; // already offscreen — skip round-trip
            wd.rect = tiling.zero_rect;       // invalidate before sending
        }
        utils.pushWindowOffscreen(ctx.conn, win);
    }
}
