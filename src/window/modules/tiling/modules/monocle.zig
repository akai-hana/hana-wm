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

    // Raise the focused window.  ctx.focused_win is set by makeLayoutCtx via
    // focus.getFocused() and is always a window present in the current workspace
    // window list when valid.  If it is null (e.g. during restoreWorkspaceGeom,
    // which constructs a bare LayoutCtx without focus information) or names a
    // window not in this workspace's list, fall back to the list tail so that
    // monocle still shows *something* rather than raising nothing.
    //
    // The old behaviour of unconditionally using windows[len-1] was wrong:
    // closing the visible window in monocle could surface an arbitrary background
    // window instead of the one the user previously interacted with.
    const top_win: u32 = blk: {
        if (ctx.focused_win) |f| {
            for (windows) |w| {
                if (w == f) break :blk f;
            }
        }
        break :blk windows[windows.len - 1];
    };

    const top_rect = utils.Rect{
        .x      = @intCast(inset),
        .y      = @intCast(y_offset +| inset),
        .width  = if (screen_w > total_margin) screen_w - total_margin else constants.MIN_WINDOW_DIM,
        .height = if (screen_h > total_margin) screen_h - total_margin else constants.MIN_WINDOW_DIM,
    };

    layouts.configureWithHintsAndRaise(ctx, top_win, top_rect);

    pushBackgroundWindowsOffscreen(ctx, windows, top_win);
}

/// Push all windows except `top_win` off the visible screen area so they never
/// show through a transparent top window.  Skips windows already known to be
/// offscreen to avoid redundant round-trips; invalidates their cache rect so
/// `restoreWorkspaceGeom` does not replay a stale on-screen position.
///
/// Accepts the full `windows` slice and skips `top_win` by ID rather than
/// requiring the caller to pre-slice — this avoids the previous assumption that
/// top_win is always the last element, which was no longer true once focus-
/// tracking was introduced.
fn pushBackgroundWindowsOffscreen(
    ctx:     *const layouts.LayoutCtx,
    windows: []const u32,
    top_win: u32,
) void {
    for (windows) |win| {
        if (win == top_win) continue;
        if (ctx.cache.getPtr(win)) |wd| {
            if (!wd.hasValidRect()) continue; // already offscreen — skip round-trip
            wd.rect = tiling.zero_rect;       // invalidate before sending
        }
        utils.pushWindowOffscreen(ctx.conn, win);
    }
}
