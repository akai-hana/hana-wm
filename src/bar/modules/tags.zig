///! Tag workspace indicators segment

const std        = @import("std");
const defs       = @import("defs");
const drawing    = @import("drawing");
const workspaces = @import("workspaces");
const bar        = @import("bar");

// const WORKSPACE_WIDTH = bar.WORKSPACE_WIDTH;

const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| num.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk nums;
};

inline fn drawIndicator(dc: *drawing.DrawContext, x: u16, size: u16, filled: bool, fg: u32) void {
    const ix, const iy = .{ x + 3, 3 };
    if (filled) {
        dc.fillRect(ix, iy, size, size, fg);
    } else {
        dc.fillRect(ix, iy, size, 1, fg);
        dc.fillRect(ix, iy + size - 1, size, 1, fg);
        if (size > 2) {
            dc.fillRect(ix, iy + 1, 1, size - 2, fg);
            dc.fillRect(ix + size - 1, iy + 1, 1, size - 2, fg);
        }
    }
}

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    var x = start_x;
    const scaled_ws_width = config.scaledWorkspaceWidth();
    const scaled_indicator_size = config.scaledIndicatorSize();

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == ws_state.current;
        const bg = if (is_current) config.selected_bg else config.bg;
        const fg = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, scaled_ws_width, height, bg);
        
        const label = if (i < config.workspace_icons.items.len) 
            config.workspace_icons.items[i]
        else if (i < static_numbers.len) 
            static_numbers[i] 
        else "?";
        
        // Use consistent baseline calculation for all segments to maintain alignment
        // Even if fallback fonts are used, align to the primary font's baseline
        const text_y = dc.baselineY(height);
        
        try dc.drawText(x + (scaled_ws_width - dc.textWidth(label)) / 2, text_y, label, fg);

        // FIXED: Use count() method instead of .list.items.len
        // This works with both small-array and large tracking implementations
        if (ws.windows.count() > 0) {
            drawIndicator(dc, x, scaled_indicator_size, is_current, fg);
        }
        
        x += scaled_ws_width;
    }
    return x;
}
