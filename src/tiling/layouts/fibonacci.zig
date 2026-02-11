//! Fibonacci (Spiral) Tiling Layout
//!
//! Creates a fibonacci spiral pattern where each window occupies approximately
//! half of the remaining space, alternating between horizontal and vertical splits.

const std = @import("std");
const xcb = @import("defs").xcb;
const utils = @import("utils");

pub fn tileWithOffset(
    conn: *xcb.xcb_connection_t,
    s: anytype,
    visible: []const u32,
    screen_width: u16,
    available_height: u16,
    y_offset: u16,
) void {
    const margin = s.margins();
    const gap = margin.gap;
    const border = margin.border;
    
    if (visible.len == 0) return;
    if (visible.len == 1) {
        // Single window - fill entire screen
        const rect = utils.Rect{
            .x = @intCast(gap),
            .y = @intCast(y_offset + gap),
            .width = screen_width - gap * 2 - border * 2,
            .height = available_height - gap * 2 - border * 2,
        };
        utils.configureWindow(conn, visible[0], rect);
        return;
    }
    
    // Fibonacci spiral layout
    // Start with full screen area and split recursively
    tileFibonacci(conn, visible, 
        @intCast(gap), 
        @intCast(y_offset + gap), 
        screen_width - gap * 2, 
        available_height - gap * 2,
        gap, border, 0, true);
}

fn tileFibonacci(
    conn: *xcb.xcb_connection_t,
    windows: []const u32,
    x: i32,
    y: i32,
    width: u16,
    height: u16,
    gap: u16,
    border: u16,
    index: usize,
    horizontal: bool, // true = split horizontally, false = split vertically
) void {
    if (index >= windows.len) return;
    if (width < gap * 2 + border * 2 or height < gap * 2 + border * 2) return;
    
    const win = windows[index];
    
    if (index == windows.len - 1) {
        // Last window gets remaining space
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = width -| border * 2,
            .height = height -| border * 2,
        };
        utils.configureWindow(conn, win, rect);
        return;
    }
    
    // Split the space: current window gets ~half, rest goes to remaining windows
    if (horizontal) {
        // Horizontal split: current window on top, rest below
        const half_height = height / 2;
        const win_height = half_height -| gap;
        
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = width -| border * 2,
            .height = win_height -| border * 2,
        };
        utils.configureWindow(conn, win, rect);
        
        // Recursively tile remaining windows in bottom half
        const remaining_y = y + @as(i32, @intCast(win_height + gap));
        const remaining_height = height -| (win_height + gap);
        tileFibonacci(conn, windows, x, remaining_y, width, remaining_height, gap, border, index + 1, !horizontal);
    } else {
        // Vertical split: current window on left, rest on right
        const half_width = width / 2;
        const win_width = half_width -| gap;
        
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = win_width -| border * 2,
            .height = height -| border * 2,
        };
        utils.configureWindow(conn, win, rect);
        
        // Recursively tile remaining windows in right half
        const remaining_x = x + @as(i32, @intCast(win_width + gap));
        const remaining_width = width -| (win_width + gap);
        tileFibonacci(conn, windows, remaining_x, y, remaining_width, height, gap, border, index + 1, !horizontal);
    }
}
