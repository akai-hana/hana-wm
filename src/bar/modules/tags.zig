//! Workspace tag indicator.
//! Renders workspace labels and activity glyphs on the status bar.

const types = @import("types");
const drawing = @import("drawing");
const tracking = @import("tracking");
const actions = @import("actions");
const focus = @import("focus");
const build_options = @import("build_options");
const segmod = @import("segment");

/// Reserved row width when no workspaces are configured (moved here from
/// bar.zig: width policy belongs to the segment that owns the pixels).
pub const fallback_width: u16 = 270;

// Sized to workspace_labels, the largest label source. Every workspace index
// is bounded by tracking.getWorkspaceCount() (<= max_workspaces), so no
// fallback path exists.
var label_widths: [tracking.workspace_labels.len]u16 = [_]u16{0} ** tracking.workspace_labels.len;
var ws_width: u16 = 0;
var cache_valid: bool = false;
// Cached horizontal offset of the indicator glyph within a workspace cell.
// Added to the cell's start_x at draw time; constant for all cells.
var cached_ind_x_off: u16 = 0;
// Cached vertical top position of the indicator glyph; constant for all cells.
var cached_ind_y: u16 = 0;

// Returns the display label for workspace `i`, falling back through icons, labels, and "?".
inline fn getLabel(i: usize, config: types.BarConfig) []const u8 {
    if (i < config.workspace_icons.items.len) return config.workspace_icons.items[i];
    if (i < tracking.workspace_labels.len) return tracking.workspace_labels[i];
    return "?";
}

// Invalidates the segment cache; next draw() call will remeasure labels and cell widths.
pub fn invalidate() void {
    cache_valid = false;
}

// Returns the last-computed workspace cell width in pixels (0 until first draw).
pub fn getCachedWorkspaceWidth() u16 {
    return ws_width;
}

// Rebuilds the label-width and geometry cache if stale.
fn ensureCache(dc: *drawing.DrawContext, config: types.BarConfig, height: u16) void {
    if (cache_valid) return;
    const count = @min(tracking.getWorkspaceCount(), label_widths.len);
    for (label_widths[0..count], 0..) |*w, i| w.* = dc.measureTextWidth(getLabel(i, config));
    ws_width = config.scaledWorkspaceWidth(height);
    cache_valid = true;

    // All geometry inputs are constant between reloads, so the indicator
    // position holds until the next invalidate() + ensureCache() cycle.
    const ind_size = config.scaledIndicatorSize(height);
    const pos = indicatorPos(
        ws_width,
        height,
        ind_size,
        ind_size,
        config.indicator_location,
        config.indicator_padding,
    );
    // pos.x is already the intra-cell offset (computed without a cell_x base).
    cached_ind_x_off = pos.x;
    cached_ind_y = pos.y;
}

// Computes the top-left pixel position of an indicator item within a workspace cell.
fn indicatorPos(
    cell_w: u16,
    bar_height: u16,
    item_w: u16,
    item_h: u16,
    location: types.IndicatorLocation,
    padding: f32,
) struct { x: u16, y: u16 } {
    const cw: f32 = @floatFromInt(cell_w);
    const bh: f32 = @floatFromInt(bar_height);

    const Corner = struct { x: f32, y: f32 };
    const corner: Corner = switch (location) {
        .left => .{ .x = 0.0, .y = 0.5 },
        .right => .{ .x = 1.0, .y = 0.5 },
        .up => .{ .x = 0.5, .y = 0.0 },
        .down => .{ .x = 0.5, .y = 1.0 },
        .up_left => .{ .x = 0.0, .y = 0.0 },
        .up_right => .{ .x = 1.0, .y = 0.0 },
        .down_left => .{ .x = 0.0, .y = 1.0 },
        .down_right => .{ .x = 1.0, .y = 1.0 },
    };

    const ax: f32 = corner.x + padding * (0.5 - corner.x);
    const ay: f32 = corner.y + padding * (0.5 - corner.y);

    const iw: f32 = @floatFromInt(item_w);
    const ih: f32 = @floatFromInt(item_h);
    const ix: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ax * cw - iw / 2.0)))));
    const iy: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ay * bh - ih / 2.0)))));
    return .{ .x = ix, .y = iy };
}

// Draw workspace tags.
//
// `ws_current`: index of the currently active workspace. `ws_has_windows`:
// one bool per workspace; true when it has at least one window (drives the
// indicator glyph).
pub fn draw(
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    ws_current: u8,
    ws_has_windows: []const bool,
    ws_all_active: bool,
) !u16 {
    if (ws_has_windows.len == 0) return start_x;
    ensureCache(dc, config, height);
    const ind_size = config.scaledIndicatorSize(height);
    var x = start_x;

    // baselineY returns the same value for every cell; hoist it once outside the loop.
    const baseline_y = dc.baselineY(height);

    for (ws_has_windows, 0..) |has_windows, i| {
        const is_current = ws_all_active or (i == ws_current);
        const bg = if (is_current) config.selected_bg else config.bg;
        const fg = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, ws_width, height, bg);

        const label = getLabel(i, config);
        const label_w = label_widths[i];
        const text_x = x + (ws_width -| label_w) / 2;
        try dc.drawText(text_x, baseline_y, label, fg);

        if (has_windows) {
            const glyph = if (is_current)
                config.indicator_focused orelse types.default_indicator_focused
            else
                config.indicator_unfocused orelse types.default_indicator_unfocused;
            const color = config.indicator_color orelse fg;
            // Use the pre-cached intra-cell offset; avoids per-workspace float arithmetic.
            try dc.drawTextSized(x + cached_ind_x_off, cached_ind_y, glyph, ind_size, color);
        }

        x += ws_width;
    }
    return x;
}

/// This module's bar-segment contribution (registry binding).
fn naturalWidthHook(frame: *const anyopaque, _: u16) u16 {
    const f: *const segmod.Frame = @ptrCast(@alignCast(frame));
    if (f.workspace_count > 0)
        return @intCast(f.workspace_count * getCachedWorkspaceWidth());
    return fallback_width;
}

fn drawHook(ctx: *anyopaque, x: u16) !u16 {
    const c = segmod.castDraw(ctx);
    return draw(
        c.dc,
        c.config,
        c.height,
        x,
        c.frame.current_workspace,
        c.frame.workspace_has_windows,
        c.frame.is_all_view_active,
    );
}

fn resolveWorkspaceClick(offset: u16) ?usize {
    const cell_w = getCachedWorkspaceWidth();
    if (cell_w == 0) return null;
    if (!build_options.has_workspaces) return null;
    const idx: usize = @intCast(offset / cell_w);
    if (idx >= tracking.getWorkspaceCount()) return null;
    return idx;
}

fn onClickHook(
    offset: u16,
    left: bool,
    right: bool,
    _: *anyopaque,
    _: *const fn (*anyopaque, u16) void,
    _: *const fn () void,
) bool {
    const idx = resolveWorkspaceClick(offset) orelse return true;
    if (left) {
        actions.switchTo(@intCast(idx));
    } else if (right) {
        const win = focus.getFocused() orelse return true;
        actions.moveWindowTo(win, @intCast(idx));
    }
    return true;
}

pub const module: @import("plugin").Segment = .{
    .name = "workspaces",
    .dirty_sources = .{ .frame = true },
    .invalidate = invalidate,
    .naturalWidth = naturalWidthHook,
    .draw = drawHook,
    .onClick = onClickHook,
};
