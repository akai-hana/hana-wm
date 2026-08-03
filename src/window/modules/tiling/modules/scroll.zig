//! Scrolling tiling layout
//! Arranges windows in a horizontal strip of equal-width slots (each half the screen width)
//! with a scrollable viewport. New windows snap the viewport right so they appear immediately;
//! manual scrolling and window closes are handled by clamping on every retile.

const std = @import("std");
const core = @import("core");
const utils = @import("utils");
const constants = @import("constants");

const tiling = @import("tiling");
const layouts = @import("layouts");

/// Scroll-layout runtime state. Only meaningful while `layout == .scroll`;
/// otherwise dormant but preserved, so switching back to scroll restores the
/// viewport position the user left it at. Lives here (rather than as a plain
/// field group in tiling.zig) so all scroll-specific state and behavior sit
/// in one module; re-exported as `tiling.ScrollState` for existing callers.
pub const State = struct {
    /// Horizontal pixel offset of the scroll viewport.
    /// Clamped by scroll.tileWithOffset on every retile.
    offset: i32 = 0,
    /// Window count seen on the last scroll retile.
    /// Used to detect new windows and snap the viewport to them.
    prev_n: usize = 0,
    /// The window that held focus just before the current one, inside the
    /// scroll layout.  Updated on every real A→B focus transition.  Used
    /// by takePrevFocused so closing the focused window restores focus to
    /// the previous one rather than falling back to list order.
    prev_focused: ?u32 = null,
};

/// Shift the scroll viewport by one slot. `delta` is +1 (right/forward) or
/// -1 (left/backward). No-op (returns false) when the current layout is not
/// .scroll; the caller should skip retiling in that case. tileWithOffset
/// clamps the result to [0, max_off] on the next retile.
pub fn step(s: *tiling.State, delta: i32) bool {
    if (s.config.layout != .scroll) return false;
    const slot_w: i32 = @intCast(core.getState().screen.width_in_pixels / 2);
    s.scroll.offset += delta * slot_w;
    return true;
}

/// If `win` is not fully in the current viewport, snaps `s.scroll.offset` so
/// `win` occupies either the left or right half-screen slot — whichever
/// requires the smaller offset change. `ws_wins` is the current workspace's
/// filtered window list (the same slice tileWithOffset receives).
///
/// Returns true when the offset actually changed (caller should retile).
///
/// Visibility rule: window at filtered index `fi` has its left (strip) edge
/// at `fi * slot_w`. It is fully visible when that edge falls in [scroll,
/// scroll + slot_w]. Outside that range:
///   • edge > scroll + slot_w  →  window is to the right  →  place on right half:
///     new_scroll = fi*slot_w - slot_w   (predecessor fills left half)
///   • edge < scroll           →  window is to the left   →  place on left half:
///     new_scroll = fi*slot_w            (successor  fills right half)
pub fn snapOffsetToWindow(s: *tiling.State, ws_wins: []const u32, win: u32) bool {
    const fi = std.mem.indexOfScalar(u32, ws_wins, win) orelse return false;

    const fi_i32: i32 = @intCast(fi);
    const screen_w = core.getState().screen.width_in_pixels;
    const slot_w: i32 = @intCast(screen_w / 2);
    const n_i32: i32 = @intCast(ws_wins.len);
    const sw_i32: i32 = @intCast(screen_w);
    const max_off: i32 = @max(0, n_i32 * slot_w - sw_i32);

    const win_left: i32 = fi_i32 * slot_w;
    const scroll_off = s.scroll.offset;

    // Already fully visible — left edge is inside [scroll_off, scroll_off + slot_w].
    if (win_left >= scroll_off and win_left <= scroll_off + slot_w) return false;

    const new_scroll: i32 = if (win_left > scroll_off + slot_w)
        win_left - slot_w
    else
        win_left;

    const clamped = std.math.clamp(new_scroll, 0, max_off);
    if (clamped == scroll_off) return false;
    s.scroll.offset = clamped;
    return true;
}

/// Return and consume the previously focused window so the caller can
/// restore focus to it after the current focused window is closed.
///
/// Returns null when:
///   • the active layout is not .scroll
///   • no previous focus has been recorded yet
///
/// Consuming (clearing) prev_focused prevents a stale value from being
/// reused across multiple successive window closes.
pub fn takePrevFocused(s: *tiling.State) ?u32 {
    if (s.config.layout != .scroll) return null;
    const prev = s.scroll.prev_focused orelse return null;
    s.scroll.prev_focused = null;
    return prev;
}

pub fn tileWithOffset(
    ctx: *const layouts.LayoutCtx,
    state: *tiling.State,
    windows: []const u32,
    screen_w: u16,
    screen_h: u16,
    y_offset: u16,
) void {
    const n = windows.len;
    if (n == 0) return;

    const m = state.margins();

    // Every slot is exactly half the screen width.
    const slot_w: i32 = @intCast(screen_w / 2);

    const n_i32: i32 = @intCast(n);
    const sw_i32: i32 = @intCast(screen_w);

    // Max scroll: reached when the last window's right edge is flush with the screen.
    const max_off: i32 = @max(0, n_i32 * slot_w - sw_i32);

    // New window: snap viewport right so it is immediately visible.
    // Killed window: the clamp below is sufficient.
    if (n > state.scroll.prev_n) {
        state.scroll.offset = max_off;
    }
    state.scroll.prev_n = n;

    // Clamp keeps the offset in [0, max_off] after manual scrolling or kills.
    state.scroll.offset = std.math.clamp(state.scroll.offset, 0, max_off);
    const scroll: i32 = state.scroll.offset;

    const content_h: u16 = layouts.shrinkClamped(screen_h, m.gap *| 2 +| m.border *| 2);
    const win_y: i32 = @as(i32, @intCast(y_offset)) + @as(i32, @intCast(m.gap));

    // Full gap at screen edges; half-gap at interior slot boundaries so that
    // adjacent windows together share exactly one full gap.
    const gap_i32: i32 = @intCast(m.gap);
    const gap_half: i32 = @intCast(m.gap / 2);
    const border2: i32 = 2 * @as(i32, @intCast(m.border));

    // emitOrDefer honors ctx.defer_win — see LayoutCtx.defer_win.
    for (windows, 0..) |win, i| {
        const col: i32 = @intCast(i);

        const slot_left: i32 = col * slot_w - scroll;

        // <= / >= rather than < / > to handle off-by-one from integer-division of odd screen widths.
        const left_inset: i32 = if (slot_left <= 0) gap_i32 else gap_half;
        const right_inset: i32 = if (slot_left + slot_w >= sw_i32) gap_i32 else gap_half;

        const x: i32 = slot_left + left_inset;
        const avail: i32 = slot_w - left_inset - right_inset - border2;
        const content_w: u16 = if (avail > constants.MIN_WINDOW_DIM)
            @intCast(avail)
        else
            constants.MIN_WINDOW_DIM;

        const right: i32 = x + avail + border2;

        // Completely off-screen: park the window at OFFSCREEN_X_POSITION so
        // the cache stays consistent.  Clamp x into i16 range first; values
        // outside that range cannot be sent as a valid configure_window X
        // coordinate and would overflow the u32 cast the X server expects.
        if (x >= sw_i32 or right <= 0) {
            const parked_x: i32 = constants.OFFSCREEN_X_POSITION;
            const rect = utils.Rect{
                .x = @intCast(parked_x),
                .y = @intCast(win_y),
                .width = content_w,
                .height = content_h,
            };
            layouts.emitOrDefer(ctx, win, rect);
            continue;
        }

        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(win_y),
            .width = content_w,
            .height = content_h,
        };
        layouts.emitOrDefer(ctx, win, rect);
    }
}
