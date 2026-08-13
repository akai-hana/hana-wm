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

/// Scroll-layout runtime state. Meaningful only while `layout == .scroll`,
/// but preserved while dormant so switching back restores the viewport
/// position. Lives here so all scroll state sits in one module; re-exported
/// as `tiling.ScrollState`.
pub const State = struct {
    /// Horizontal pixel offset of the scroll viewport.
    /// Clamped by scroll.tileWithOffset on every retile.
    offset: i32 = 0,
    /// Window count seen on the last scroll retile.
    /// Used to detect new windows and snap the viewport to them.
    prev_n: usize = 0,
    /// The window focused just before the current one (updated on each real
    /// A→B transition), so closing the focused window restores focus to the
    /// previous one rather than falling back to list order.
    prev_focused: ?u32 = null,
};

/// Pixel width of one scroll slot: exactly half the screen width. Single
/// source of truth — step, snapOffsetToWindow, and tileWithOffset all derive
/// their geometry from it.
inline fn slotWidth(screen_w: u16) i32 {
    return @intCast(screen_w / 2);
}

/// Maximum scroll offset: reached when the last of `n` windows' right edge
/// is flush with the screen's right edge. Zero (nothing to scroll) when the
/// strip is no wider than the screen.
inline fn maxOffset(n: usize, screen_w: u16) i32 {
    const n_i32: i32 = @intCast(n);
    const sw_i32: i32 = @intCast(screen_w);
    return @max(0, n_i32 * slotWidth(screen_w) - sw_i32);
}

/// Shift the scroll viewport by one slot; `delta` is +1 (right) or -1 (left).
/// No-op (false) when the layout isn't .scroll — the caller should skip
/// retiling then. tileWithOffset clamps to [0, max_off] next retile.
pub fn step(s: *tiling.State, delta: i32) bool {
    if (s.config.layout != .scroll) return false;
    s.scroll.offset += delta * slotWidth(core.getState().screen.width_in_pixels);
    return true;
}

/// If `win` is not fully in the viewport, snaps the offset so `win` occupies
/// the nearer of the two half-screen slots (the smaller offset change), so the
/// next retile shows it. `ws_wins` is the same filtered list tileWithOffset
/// receives. Returns true when the offset changed (caller should retile).
///
/// Window at index `fi` has its strip edge at `fi * slot_w`; it's fully
/// visible when that edge is in [scroll, scroll + slot_w]. Otherwise it's
/// placed on the right half (new_scroll = fi*slot_w - slot_w, predecessor
/// fills the left) or the left half (new_scroll = fi*slot_w, successor fills
/// the right).
pub fn snapOffsetToWindow(s: *tiling.State, ws_wins: []const u32, win: u32) bool {
    const fi = std.mem.indexOfScalar(u32, ws_wins, win) orelse return false;

    const fi_i32: i32 = @intCast(fi);
    const screen_w = core.getState().screen.width_in_pixels;
    const slot_w = slotWidth(screen_w);
    const max_off = maxOffset(ws_wins.len, screen_w);

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

/// Return and consume the previously focused window so the caller can restore
/// focus to it when the current focused window closes. Null when the layout
/// isn't .scroll or no previous focus is recorded. Consuming clears the stale
/// value so it isn't reused across successive closes.
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
    // Windows list is guaranteed non-empty by invokeLayout (see tiling.zig).
    const n = windows.len;

    const m = state.margins();

    // Every slot is exactly half the screen width.
    const slot_w: i32 = slotWidth(screen_w);

    const sw_i32: i32 = @intCast(screen_w);

    // Max scroll: reached when the last window's right edge is flush with the screen.
    const max_off: i32 = maxOffset(n, screen_w);

    // New window: snap viewport right so it is immediately visible.
    // Killed window: the clamp below is sufficient.
    if (n > state.scroll.prev_n) {
        state.scroll.offset = max_off;
    }
    state.scroll.prev_n = n;

    // Clamp keeps the offset in [0, max_off] after manual scrolling or kills.
    state.scroll.offset = std.math.clamp(state.scroll.offset, 0, max_off);
    const scroll: i32 = state.scroll.offset;

    const content_h: u16 = layouts.shrinkClamped(screen_h, m.gap *| 2 +| m.border *| 2, state.config.min_window_dim);
    const win_y: i32 = @as(i32, @intCast(y_offset)) + @as(i32, @intCast(m.gap));

    // Full gap at screen edges; half-gap at interior slot boundaries so that
    // adjacent windows together share exactly one full gap.
    const gap_i32: i32 = @intCast(m.gap);
    const gap_half: i32 = @intCast(m.gap / 2);
    const border2: i32 = @as(i32, utils.doubledBorder(m));

    // emitOrDefer honors ctx.defer_win — see LayoutCtx.defer_win.
    for (windows, 0..) |win, i| {
        const col: i32 = @intCast(i);

        const slot_left: i32 = col * slot_w - scroll;

        // <= / >= rather than < / > to handle off-by-one from integer-division of odd screen widths.
        const left_inset: i32 = if (slot_left <= 0) gap_i32 else gap_half;
        const right_inset: i32 = if (slot_left + slot_w >= sw_i32) gap_i32 else gap_half;

        const x: i32 = slot_left + left_inset;
        const avail: i32 = slot_w - left_inset - right_inset - border2;
        const content_w: u16 = if (avail > state.config.min_window_dim)
            @intCast(avail)
        else
            state.config.min_window_dim;

        const right: i32 = x + avail + border2;

        // Completely off-screen: park at OFFSCREEN_X_POSITION to keep the
        // cache consistent — the computed x can exceed i16 range.
        const effective_x: i32 = if (x >= sw_i32 or right <= 0) constants.OFFSCREEN_X_POSITION else x;
        const rect = utils.Rect{
            .x = @intCast(effective_x),
            .y = @intCast(win_y),
            .width = content_w,
            .height = content_h,
        };
        layouts.emitOrDefer(ctx, win, rect);
    }
}
