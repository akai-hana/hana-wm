//! Workspace tag indicator segment.
//!
//! Owns the workspace segment cache: label pixel-widths and workspace cell width.
//! Call `invalidate()` whenever the font, config, or DPI changes (i.e. on bar
//! reload) so the next draw remeasures everything with the fresh DrawContext.
//!
//! draw() receives pre-computed workspace state from a BarSnapshot rather
//! than reading the workspaces singleton directly, avoiding a data race with
//! the main thread.

const std     = @import("std");
const core    = @import("core");
const types   = @import("types");
const drawing = @import("drawing");
const tracking = @import("tracking");

// Both arrays are capped at 20 entries, matching tracking.WORKSPACE_LABELS.
// Workspaces beyond index 20 still render correctly: draw() falls back to
// dc.measureTextWidth(label) on a cache miss.
// Raise this cap if workspace count ever exceeds 20.
var label_widths: [20]u16 = [_]u16{0} ** 20;
var ws_width:          u16     = 0;
var cache_valid:       bool    = false;
/// Cached horizontal offset of the indicator glyph within a workspace cell.
/// Added to the cell's start_x at draw time. Constant for all cells.
var cached_ind_x_off:  u16     = 0;
/// Cached vertical top position of the indicator glyph. Constant for all cells.
var cached_ind_y:      u16     = 0;

inline fn getLabel(i: usize, config: types.BarConfig) []const u8 {
    if (i < config.workspace_icons.items.len) return config.workspace_icons.items[i];
    if (i < tracking.WORKSPACE_LABELS.len)    return tracking.WORKSPACE_LABELS[i];
    return "?";
}

pub fn invalidate() void { cache_valid = false; }

pub fn getCachedWorkspaceWidth() u16 { return ws_width; }

fn ensureCache(dc: *drawing.DrawContext, config: types.BarConfig, height: u16) void {
    if (cache_valid) return;
    for (&label_widths, 0..) |*w, i| w.* = dc.measureTextWidth(getLabel(i, config));
    ws_width    = config.scaledWorkspaceWidth(height);
    cache_valid = true;

    // Precompute the indicator glyph position within a cell. All geometry
    // inputs (cell width, bar height, indicator size, location, padding) are
    // constant between reloads, so the result is valid for the entire session
    // until the next invalidate() + ensureCache() cycle.
    const ind_size = config.scaledIndicatorSize(height);
    const pos = indicatorPos(0, ws_width, height, ind_size, ind_size,
        config.indicator_location, config.indicator_padding);
    // pos.x is computed with cell_x = 0, so it is already the intra-cell offset.
    cached_ind_x_off = pos.x;
    cached_ind_y     = pos.y;
}

/// Computes the top-left pixel position of an indicator item within a workspace cell.
fn indicatorPos(
    cell_x:     u16,
    cell_w:     u16,
    bar_height: u16,
    item_w:     u16,
    item_h:     u16,
    location:   types.IndicatorLocation,
    padding:    f32,
) struct { x: u16, y: u16 } {
    const cw: f32 = @floatFromInt(cell_w);
    const bh: f32 = @floatFromInt(bar_height);

    const Corner = struct { x: f32, y: f32 };
    const corner: Corner = switch (location) {
        .left       => .{ .x = 0.0, .y = 0.5 },
        .right      => .{ .x = 1.0, .y = 0.5 },
        .up         => .{ .x = 0.5, .y = 0.0 },
        .down       => .{ .x = 0.5, .y = 1.0 },
        .up_left    => .{ .x = 0.0, .y = 0.0 },
        .up_right   => .{ .x = 1.0, .y = 0.0 },
        .down_left  => .{ .x = 0.0, .y = 1.0 },
        .down_right => .{ .x = 1.0, .y = 1.0 },
    };

    const ax: f32 = corner.x + padding * (0.5 - corner.x);
    const ay: f32 = corner.y + padding * (0.5 - corner.y);

    const iw: f32 = @floatFromInt(item_w);
    const ih: f32 = @floatFromInt(item_h);
    const ix: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ax * cw - iw / 2.0)))));
    const iy: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ay * bh - ih / 2.0)))));
    return .{ .x = cell_x + ix, .y = iy };
}

/// Draw workspace tags.
///
/// `ws_current`     — index of the currently active workspace.
/// `ws_has_windows` — one bool per workspace; true when that workspace has
///                    at least one window (used to draw the indicator glyph).
pub fn draw(
    dc:             *drawing.DrawContext,
    config:         types.BarConfig,
    height:         u16,
    start_x:        u16,
    ws_current:     u8,
    ws_has_windows: []const bool,
    ws_all_active:  bool,
) !u16 {
    if (ws_has_windows.len == 0) return start_x;
    ensureCache(dc, config, height);
    const ind_size = config.scaledIndicatorSize(height);
    var x = start_x;

    // baselineY returns the same value for every cell — hoist it once outside the loop.
    const baseline_y = dc.baselineY(height);

    for (ws_has_windows, 0..) |has_windows, i| {
        // Advance the cursor unconditionally, even when we skip indicator drawing below.
        defer x += ws_width;

        const is_current = ws_all_active or (i == ws_current);
        const bg         = if (is_current) config.selected_bg else config.bg;
        const fg         = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, ws_width, height, bg);

        const label   = getLabel(i, config);
        const label_w = if (i < label_widths.len) label_widths[i] else dc.measureTextWidth(label);
        const text_x  = x + (ws_width - label_w) / 2;
        try dc.drawText(text_x, baseline_y, label, fg);

        // No windows on this workspace — nothing more to draw for this cell.
        if (!has_windows) continue;

        const glyph = if (is_current) config.indicator_focused else config.indicator_unfocused;
        const color = config.indicator_color orelse fg;
        // Use the pre-cached intra-cell offset; avoids per-workspace float arithmetic.
        try dc.drawTextSized(x + cached_ind_x_off, cached_ind_y, glyph, ind_size, color);
    }
    return x;
}
