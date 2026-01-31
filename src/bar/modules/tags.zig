///! Tag workspace indicators segment

const std = @import("std");
const defs = @import("defs");
const drawing = @import("drawing");
const workspaces = @import("workspaces");

pub fn draw(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    height: u16,
    start_x: u16,
) !u16 {
    const ws_state = workspaces.getState() orelse return start_x;
    
    const ws_width: u16 = 40; // 40px per workspace
    var x = start_x;

    for (ws_state.workspaces, 0..) |*ws, i| {
        const is_current = (i == ws_state.current);
        const has_windows = ws.windows.items.len > 0;

        const bg = if (is_current)
            config.selected_bg
        else
            config.bg;

        const fg = if (is_current)
            config.selected_fg
        else
            config.fg;

        dc.fillRect(x, 0, ws_width, height, bg);

        const label = getWorkspaceLabel(config, i);
        const text_w = dc.textWidth(label);
        const text_x = x + (ws_width - text_w) / 2;
        const text_y = calculateTextY(dc, height);

        try dc.drawText(text_x, text_y, label, fg);

        if (has_windows) {
            try drawIndicator(dc, config, x, is_current, fg);
        }

        x += ws_width;
    }

    return x;
}

fn calculateTextY(dc: *drawing.DrawContext, height: u16) u16 {
    const ascender: i32 = dc.getAscender();
    const descender: i32 = dc.getDescender();

    const font_height: i32 = ascender - descender;
    const vertical_padding: i32 = @divTrunc(@as(i32, height) - font_height, 2);
    const baseline_y: i32 = vertical_padding + ascender;

    return @intCast(@max(ascender, baseline_y));
}

fn getWorkspaceLabel(config: defs.BarConfig, index: usize) []const u8 {
    if (index < config.workspace_icons.items.len) {
        return config.workspace_icons.items[index];
    }
    
    // Fallback to number - FIX: Use static strings instead of stack-local buffer
    const static_numbers = [_][]const u8{
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
        "11", "12", "13", "14", "15", "16", "17", "18", "19", "20"
    };
    
    if (index < static_numbers.len) {
        return static_numbers[index];
    }
    
    return "?";
}

fn drawIndicator(
    dc: *drawing.DrawContext,
    config: defs.BarConfig,
    ws_x: u16,
    is_current: bool,
    color: u32,
) !void {
    const size = config.indicator_size;
    const x = ws_x + 3;
    const y: u16 = 3;

    if (is_current) {
        dc.fillRect(x, y, size, size, color);
    } else {
        dc.fillRect(x, y, size, 1, color);
        dc.fillRect(x, y + size - 1, size, 1, color);
        dc.fillRect(x, y, 1, size, color);
        dc.fillRect(x + size - 1, y, 1, size, color);
    }
}
