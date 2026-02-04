///! Tag workspace indicators segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const workspaces = @import("workspaces");
const bar = @import("bar");

const WORKSPACE_WIDTH = bar.WORKSPACE_WIDTH;

const static_numbers = blk: {
    var nums: [20][]const u8 = undefined;
    for (&nums, 1..) |*num, i| num.* = std.fmt.comptimePrint("{d}", .{i});
    break :blk nums;
};

pub fn draw(dc: *drawing.DrawContext, config: defs.BarConfig, height: u16, start_x: u16) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    var x = start_x;
    const text_y = dc.baselineY(height);

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = i == ws_state.current;
        const bg = if (is_current) config.selected_bg else config.bg;
        const fg = if (is_current) config.selected_fg else config.fg;

        dc.fillRect(x, 0, WORKSPACE_WIDTH, height, bg);
        
        const label = if (i < config.workspace_icons.items.len) 
            config.workspace_icons.items[i]
        else if (i < static_numbers.len) 
            static_numbers[i] 
        else "?";
        
        try dc.drawText(x + (WORKSPACE_WIDTH - dc.textWidth(label)) / 2, text_y, label, fg);

        // Draw window presence indicator
        if (ws.windows.list.items.len > 0) {
            const size = @max(config.indicator_size, 2);
            const ix = x + 3;
            const iy: u16 = 3;
            
            if (is_current) {
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
        
        x += WORKSPACE_WIDTH;
    }
    return x;
}
