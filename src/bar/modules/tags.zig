///! Tag workspace indicators segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const bar = @import("bar");

const WORKSPACE_WIDTH = bar.WORKSPACE_WIDTH;

// Generate number strings at compile time
const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| {
        num.* = std.fmt.comptimePrint("{d}", .{i});
    }
    break :blk nums;
};

// Helper to draw hollow or filled rectangle indicator
inline fn drawIndicator(dc: *drawing.DrawContext, x: u16, y: u16, size: u16, fg: u32, filled: bool) void {
    if (filled) {
        dc.fillRect(x, y, size, size, fg);
    } else {
        // Hollow rectangle: top, bottom, left, right edges
        dc.fillRect(x, y, size, 1, fg);  // Top
        dc.fillRect(x, y + size - 1, size, 1, fg);  // Bottom
        if (size > 2) {
            dc.fillRect(x, y + 1, 1, size - 2, fg);  // Left
            dc.fillRect(x + size - 1, y + 1, 1, size - 2, fg);  // Right
        }
    }
}

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    var x = start_x;
    const text_y = dc.baselineY(height);

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == ws_state.current;
        const bg = if (is_current) config.selected_bg else config.bg;
        const fg = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, WORKSPACE_WIDTH, height, bg);
        
        // Get label: custom icon, static number, or fallback
        const label = if (i < config.workspace_icons.items.len) 
            config.workspace_icons.items[i]
        else if (i < static_numbers.len) 
            static_numbers[i] 
        else 
            "?";
        
        try dc.drawText(x + (WORKSPACE_WIDTH - dc.textWidth(label)) / 2, text_y, label, fg);

        // Draw window presence indicator
        if (ws.windows.list.items.len > 0) {
            const size = @max(config.indicator_size, 2);
            drawIndicator(dc, x + 3, 3, size, fg, is_current);
        }
        
        x += WORKSPACE_WIDTH;
    }
    return x;
}
