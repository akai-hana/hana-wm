//! Workspace tag indicator segment.

const std        = @import("std");
const defs       = @import("defs");
const drawing    = @import("drawing");
const workspaces = @import("workspaces");
const bar        = @import("bar");

const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| num.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk nums;
};

/// Draws a filled or hollow square indicator for workspace activity.
inline fn drawIndicator(dc: *drawing.DrawContext, x: u16, size: u16, filled: bool, fg: u32) void {
    const ix, const iy = .{ x + 3, 3 };
    if (filled) {
        dc.fillRect(ix, iy, size, size, fg);
    } else {
        dc.fillRect(ix, iy,              size, 1,          fg);
        dc.fillRect(ix, iy + size - 1,   size, 1,          fg);
        if (size > 2) {
            dc.fillRect(ix,            iy + 1, 1,      size - 2, fg);
            dc.fillRect(ix + size - 1, iy + 1, 1,      size - 2, fg);
        }
    }
}

/// Draws all workspace tags starting at `start_x`, returning the next X position.
pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ws_state            = workspaces.getState() orelse return start_x;
    const scaled_ws_width     = bar.getCachedWorkspaceWidth();
    const scaled_indicator_sz = bar.getCachedIndicatorSize();
    var x = start_x;

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == ws_state.current;
        const bg         = if (is_current) config.selected_bg else config.bg;
        const fg         = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, scaled_ws_width, height, bg);

        const label: []const u8 =
            if (i < config.workspace_icons.items.len) config.workspace_icons.items[i]
            else if (i < static_numbers.len)          static_numbers[i]
            else                                      "?";

        const text_y     = dc.baselineY(height);
        const label_w    = bar.getCachedLabelWidth(i) orelse dc.textWidth(label);
        const text_x     = x + (scaled_ws_width - label_w) / 2;
        try dc.drawText(text_x, text_y, label, fg);

        if (ws.windows.count() > 0) {
            drawIndicator(dc, x, scaled_indicator_sz, is_current, fg);
        }

        x += scaled_ws_width;
    }
    return x;
}
