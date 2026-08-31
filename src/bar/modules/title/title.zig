//! Title bar segment
//! Displays the focused window title on the status bar, with a split view when minimized windows are present.
//!
//! The title render/snapshot machinery and the `DrawCtx`/`Frame` vocabulary
//! live in `segment.zig` (shared across bar segments); this module only owns
//! the rendering of the title slot and the prompt overlay (D9).

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const refresh = @import("refresh");
const debug = @import("debug");

const constants = @import("constants");
const types = @import("types");

const drawing = @import("drawing");
const build_options = @import("build_options");
const segmod = @import("segment");
const carousel = if (build_options.has_seg_carousel) @import("carousel") else struct {
    pub const gap_px: u16 = 0;
    pub fn scrollingActive() bool {
        return false;
    }
    pub fn offsetFor(
        win: u32,
        title: []const u8,
        text_w: u16,
        avail_w: u16,
        enabled: bool,
        speed_px_s: u16,
        now_ms: i64,
    ) f32 {
        _ = win;
        _ = title;
        _ = text_w;
        _ = avail_w;
        _ = enabled;
        _ = speed_px_s;
        _ = now_ms;
        return 0;
    }
};
// The prompt overlays this slot when active (D9): this module delegates its
// draw/click to it rather than the bar adapting the title slot.
const prompt = if (build_options.has_seg_prompt) @import("prompt") else struct {
    pub fn isActive() bool {
        return false;
    }
    pub fn toggle() void {}
    pub fn draw(_: *segmod.DrawCtx, x: u16) !u16 {
        return x;
    }
};
// The minimized-state service (set synthesis + per-window checks) is provided
// by the window module registry and forwarded through the shared DrawCtx by
// the bar (D12); the title segment just reads `snapshot.minimized_set`.

const SegmentGeometry = struct {
    seg_x: u16,
    seg_w: u16,
    text_x: u16,
    avail_w: u16,
};

/// Fixed left indent applied inside every title cell, independent of
/// `scaledSegmentPadding`.
const title_lead_px: u16 = 4;

/// Shared body of all title draw entry points.
fn drawInner(
    ctx: segmod.TitleRenderContext,
    snapshot: segmod.TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !u16 {
    refresh.ensureRefreshRateDetected(ctx.conn);
    std.debug.assert((ctx.cached_title != null) == (ctx.cached_title_window != null));
    const window_count = snapshot.current_ws_wins.len;
    if (emptyWorkspace(ctx, window_count)) |end_x| return end_x;

    if (window_count == 1) {
        try drawSingleWindow(ctx, snapshot, allocator, title_invalidated);
    } else {
        try drawSegmentedTitles(ctx, snapshot, allocator);
    }

    return ctx.start_x + ctx.width;
}

/// Render the title slot at `x` (its reserved width is in `ctx.width`),
/// delegating to the active prompt overlay when open.
fn renderTitle(ctx: *segmod.DrawCtx, x: u16) !u16 {
    return drawInner(ctx.titleRenderContext(x, ctx.width), ctx.titleSnapshot(), ctx.allocator, false);
}

/// Draw a window resolved via DrawCtx as the single-window case.
fn drawSingleWindow(
    ctx: segmod.TitleRenderContext,
    snapshot: segmod.TitleSnapshot,
    allocator: std.mem.Allocator,
    title_invalidated: bool,
) !void {
    const single_win = snapshot.current_ws_wins[0];
    const is_minimized = snapshot.minimized_set.contains(single_win);
    const workspace_has_focus = snapshot.focused_window != null;

    const accent = if (is_minimized)
        ctx.config.title_minimized_accent
    else if (workspace_has_focus)
        ctx.config.title_accent_color
    else
        ctx.config.bg;
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, accent);

    const baseline_y = ctx.dc.baselineY(ctx.height);
    const geom = titleTextGeom(ctx, ctx.start_x, ctx.width);

    if (is_minimized) {
        if (snapshot.minimized_title.len > 0)
            try drawFittedTitle(
                ctx,
                baseline_y,
                geom,
                single_win,
                snapshot.minimized_title,
                ctx.dc.measureTextWidth(snapshot.minimized_title),
                ctx.config.fg,
                false,
            );
        return;
    }

    if (snapshot.focused_title.len == 0) return;

    if (ctx.cached_title) |buf| {
        const window_slot = ctx.cached_title_window.?;
        if (title_invalidated or window_slot.* != snapshot.focused_window) {
            buf.clearRetainingCapacity();
            buf.appendSlice(allocator, snapshot.focused_title) catch {};
            window_slot.* = snapshot.focused_window;
        }
    }

    const fg = if (workspace_has_focus) ctx.config.selected_fg else ctx.config.fg;
    try drawFittedTitle(
        ctx,
        baseline_y,
        geom,
        single_win,
        snapshot.focused_title,
        ctx.dc.measureTextWidth(snapshot.focused_title),
        fg,
        workspace_has_focus,
    );
}

/// Draws the focused window's overflowing title as a marquee cell.
fn drawMarqueeCell(
    ctx: segmod.TitleRenderContext,
    baseline_y: u16,
    geom: SegmentGeometry,
    win: u32,
    txt: []const u8,
    text_w: u16,
    fg: u32,
    now: i64,
) !void {
    const off = carousel.offsetFor(
        win,
        txt,
        text_w,
        geom.avail_w,
        ctx.config.carousel_enabled,
        ctx.config.carousel_speed_px_s,
        now,
    );
    if (!carousel.scrollingActive()) {
        try ctx.dc.drawTextEllipsis(geom.text_x, baseline_y, txt, geom.avail_w, fg);
        return;
    }
    const cycle: f32 = @as(f32, @floatFromInt(text_w)) + @as(f32, carousel.gap_px);
    // Anchor the scroll at the padded text start (same spot static mode uses),
    // so enabling the carousel continues seamlessly from where the head sat.
    const x0: f64 = @as(f64, @floatFromInt(geom.text_x)) - off;
    try ctx.dc.drawTextScrolled(geom.seg_x, geom.seg_w, baseline_y, .{ x0, x0 + cycle }, txt, fg);
}

fn nowMs() i64 {
    return @intCast(utils.monotonicNs() / std.time.ns_per_ms);
}

/// Pixel-perfect tiling: segment i of `count` spans [i*W/count, (i+1)*W/count).
fn segmentBounds(total_width: u16, i: usize, count: u32) struct { x: u16, w: u16 } {
    const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i)) * total_width, count));
    const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * total_width, count));
    return .{ .x = x0, .w = x1 - x0 };
}

/// Accent colour for a title segment: focused wins, then minimized, then the
/// unfocused fallback.
inline fn accentFor(config: types.BarConfig, is_focused: bool, is_minimized: bool) u32 {
    return if (is_focused)
        config.title_accent_color
    else if (is_minimized)
        config.title_minimized_accent
    else
        config.title_unfocused_accent;
}

fn titleTextGeom(ctx: segmod.TitleRenderContext, seg_x: u16, seg_w: u16) SegmentGeometry {
    const scaled_padding = ctx.config.scaledSegmentPadding(ctx.height);
    return .{
        .seg_x = seg_x,
        .seg_w = seg_w,
        .text_x = seg_x + scaled_padding + title_lead_px,
        .avail_w = seg_w -| scaled_padding *| 2 -| title_lead_px,
    };
}

fn drawFittedTitle(
    ctx: segmod.TitleRenderContext,
    baseline_y: u16,
    geom: SegmentGeometry,
    window: u32,
    title: []const u8,
    text_w: u16,
    text_fg: u32,
    scroll_enabled: bool,
) !void {
    const now = nowMs();
    if (text_w <= geom.avail_w) {
        // Focused cell that no longer overflows: retire any active scroll so
        // the carousel state machine (and with it the poll deadline and the
        // needsRepaint query) stops requesting frames for a static cell.
        // Unfocused cells never touch the carousel: it tracks exactly one
        // cell per frame, the focused one.
        if (scroll_enabled) {
            _ = carousel.offsetFor(window, title, text_w, geom.avail_w, false, 0, now);
        }
        try ctx.dc.drawText(geom.text_x, baseline_y, title, text_fg);
    } else if (scroll_enabled)
        try drawMarqueeCell(ctx, baseline_y, geom, window, title, text_w, text_fg, now)
    else
        try ctx.dc.drawTextEllipsis(geom.text_x, baseline_y, title, geom.avail_w, text_fg);
}

/// Renders one title segment per window in a horizontal split-view layout.
fn drawSegmentedTitles(
    ctx: segmod.TitleRenderContext,
    snapshot: segmod.TitleSnapshot,
    allocator: std.mem.Allocator,
) !void {
    const windows = snapshot.current_ws_wins;
    if (windows.len > 128)
        debug.warn("Workspace has {} windows; only the first 128 are rendered in split-view", .{windows.len});
    const win_count = @min(windows.len, 128);

    var scratch: segmod.GatherScratch = .{};
    defer scratch.freeBorrowedTitles(snapshot, win_count, allocator);
    const sorted = (try scratch.gather(ctx, snapshot, allocator, windows, win_count)) orelse return;

    const window_count: u32 = @intCast(sorted.len);
    const baseline_y = ctx.dc.baselineY(ctx.height);
    const min_cell_w = ctx.config.scaledSegmentPadding(ctx.height) *| 2;

    for (sorted, 0..) |info, i| {
        const bounds = segmentBounds(ctx.width, i, window_count);
        if (bounds.w == 0) continue;
        const segment_x = ctx.start_x + bounds.x;

        const is_focused_win = snapshot.focused_window == info.window;
        const accent = accentFor(ctx.config, is_focused_win, info.minimized);
        ctx.dc.fillRect(segment_x, 0, bounds.w, ctx.height, accent);

        if (info.title.len == 0 or bounds.w <= min_cell_w) continue;

        const text_fg = if (is_focused_win) ctx.config.selected_fg else ctx.config.fg;
        try drawFittedTitle(
            ctx,
            baseline_y,
            titleTextGeom(ctx, segment_x, bounds.w),
            info.window,
            info.title,
            ctx.dc.measureTextWidth(info.title),
            text_fg,
            is_focused_win,
        );
    }
}

/// If `count` is zero: fills the segment background and returns the segment's end x.
inline fn emptyWorkspace(ctx: segmod.TitleRenderContext, count: usize) ?u16 {
    if (count != 0) return null;
    ctx.dc.fillRect(ctx.start_x, 0, ctx.width, ctx.height, ctx.config.bg);
    return ctx.start_x + ctx.width;
}

fn monotonicMs() i64 {
    return @intCast(utils.monotonicNs() / std.time.ns_per_ms);
}

// -- Segment hooks -----------------------------------------------------------

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const c: *segmod.DrawCtx = @ptrCast(@alignCast(ctx));
    if (prompt.isActive()) return prompt.draw(c, x);
    return renderTitle(c, x);
}

fn onClickHook(
    offset: u16,
    left: bool,
    right: bool,
    state_ptr: *anyopaque,
    title_click: *const fn (*anyopaque, u16) void,
    redraw: *const fn () void,
) bool {
    _ = left;
    _ = redraw;
    if (right) {
        if (!prompt.isActive()) prompt.toggle();
    } else if (!prompt.isActive()) {
        title_click(state_ptr, offset);
    }
    return true;
}

fn naturalWidthHook(_: *const anyopaque, _: u16) u16 {
    return segmod.title_min_width;
}

fn pollTimeoutMsHook() i32 {
    // The prompt covers the whole title slot (draw delegates to prompt), so
    // no marquee is visible; contribute no wakeup instead of leaving the
    // carousel polling hidden pixels. The next visible draw re-arms motion
    // via offsetFor. Title owns this decision, so prompt never reaches into
    // the carousel to pause it.
    if (prompt.isActive()) return -1;
    return carousel.pollDeadlineMs(
        monotonicMs(),
        core.getState().config.bar.carousel_enabled,
        refresh.detectedHz(),
    );
}

/// Marquee repaint query for the bar's uniform frame loop (the Segment
/// needsRepaint capability): while the carousel is actively scrolling its
/// motion only advances while the title draw runs, so the bar must repaint
/// this segment on every draw submission even when change detection marks
/// nothing dirty. The prompt covers the whole slot while open, so it reports
/// inactive then (the overlay owns the repaint; the draw delegation already
/// routes around the carousel).
fn needsRepaintHook() bool {
    if (prompt.isActive()) return false;
    return carousel.scrollingActive();
}

/// This module's bar-segment contribution (registry binding).
pub const module: @import("plugin").Segment = .{
    .name = "title",
    .center_slot = true,
    .dirty_sources = .{ .focus = true, .frame = true },
    .needsRepaint = needsRepaintHook,
    .pollTimeoutMs = pollTimeoutMsHook,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
    .onClick = onClickHook,
};
