//! Workspace tag indicator segment.
//!
//! Owns the workspace segment cache that was previously split across cache.zig
//! and bar.State: label pixel-widths and workspace cell width.
//! Call `invalidate()` whenever the font, config, or DPI changes (i.e. on bar
//! reload) so the next draw remeasures everything with the fresh DrawContext.

const std        = @import("std");
const defs       = @import("defs");
const drawing    = @import("drawing");
const workspaces = @import("workspaces");

// Module-level cache

/// Comptime-generated label strings "1".."20". Never heap-allocated.
const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| num.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk nums;
};

var label_widths: [20]u16 = [_]u16{0} ** 20;
var ws_width:     u16     = 0;
var cache_valid:  bool    = false;

/// Returns the display label for workspace `i` — configured icon, fallback number, or "?".
inline fn getLabel(i: usize, config: defs.BarConfig) []const u8 {
    if (i < config.workspace_icons.items.len) return config.workspace_icons.items[i];
    if (i < static_numbers.len)               return static_numbers[i];
    return "?";
}

/// Marks the cache stale. Call on bar reload (font/config/DPI change) so the
/// next draw remeasures label widths and re-derives layout constants.
pub fn invalidate() void { cache_valid = false; }

/// Returns the cached workspace cell width (pixels). Valid after first draw.
/// Used by bar.zig for segment width calculation and click hit-testing.
pub fn getCachedWorkspaceWidth() u16 { return ws_width; }

// Private helpers

/// Populates label_widths and ws_width from the current DrawContext and config.
/// No-ops when cache_valid is already true.
fn ensureCache(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16) void {
    if (cache_valid) return;
    for (&label_widths, 0..) |*w, i| w.* = dc.textWidth(getLabel(i, config));
    ws_width    = config.scaledWorkspaceWidth(height);
    cache_valid = true;
}

/// Computes the top-left pixel position of an indicator item within a workspace cell.
/// The anchor lerps between the location's corner (padding=0) and the cell center (padding=1).
/// The item is then centered on that anchor.
fn indicatorPos(
    cell_x:     u16,
    cell_w:     u16,
    bar_height: u16,
    item_w:     u16,
    item_h:     u16,
    location:   defs.IndicatorLocation,
    padding:    f32,
) struct { x: u16, y: u16 } {
    const cw: f32 = @floatFromInt(cell_w);
    const bh: f32 = @floatFromInt(bar_height);

    // Corner position for each location (as a fraction of cell dimensions).
    const corner_x: f32 = switch (location) {
        .left, .up_left, .down_left    => 0.0,
        .up, .down                     => 0.5,
        .right, .up_right, .down_right => 1.0,
    };
    const corner_y: f32 = switch (location) {
        .up, .up_left, .up_right       => 0.0,
        .left, .right                  => 0.5,
        .down, .down_left, .down_right => 1.0,
    };

    // Lerp toward center (0.5, 0.5) by padding amount.
    const ax: f32 = corner_x + padding * (0.5 - corner_x);
    const ay: f32 = corner_y + padding * (0.5 - corner_y);

    // Convert to pixels and center the item on the anchor.
    const iw: f32 = @floatFromInt(item_w);
    const ih: f32 = @floatFromInt(item_h);
    const ix: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ax * cw - iw / 2.0)))));
    const iy: u16 = @intCast(@max(0, @as(i32, @intFromFloat(@round(ay * bh - ih / 2.0)))));
    return .{ .x = cell_x + ix, .y = iy };
}

/// Draws all workspace tags starting at `start_x`, returning the next X position.
pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    ensureCache(dc, config, height);
    const ind_size = config.scaledIndicatorSize(height);
    const loc      = config.indicator_location;
    var x = start_x;

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == ws_state.current;
        const bg         = if (is_current) config.selected_bg else config.bg;
        const fg         = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, ws_width, height, bg);

        const label   = getLabel(i, config);
        const label_w = if (i < label_widths.len) label_widths[i] else dc.textWidth(label);
        const text_x  = x + (ws_width - label_w) / 2;
        try dc.drawText(text_x, dc.baselineY(height), label, fg);

        if (ws.windows.count() > 0) {
            const glyph = if (is_current) config.indicator_focused else config.indicator_unfocused;
            const color = config.indicator_color orelse fg;
            // Use ind_size for both dimensions — glyphs are roughly square,
            // and this avoids measuring at the wrong (bar) font size.
            const pos   = indicatorPos(x, ws_width, height, ind_size, ind_size, loc, config.indicator_padding);
            try dc.drawTextSized(pos.x, pos.y, glyph, ind_size, color);
        }

        x += ws_width;
    }
    return x;
}
