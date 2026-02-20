//! Fibonacci (spiral) Tiling Layout
//!
//! Creates a true fibonacci spiral pattern where windows spiral around the center
//! in a counter-clockwise direction: right → down → left → up → repeat

const std = @import("std");
const xcb = @import("defs").xcb;
const utils = @import("utils");

const Direction = enum {
    right,  // Split vertically, window on left, remaining on right
    down,   // Split horizontally, window on top, remaining below
    left,   // Split vertically, window on right, remaining on left
    up,     // Split horizontally, window on bottom, remaining above
    
    fn next(self: Direction) Direction {
        return switch (self) {
            .right => .down,
            .down => .left,
            .left => .up,
            .up => .right,
        };
    }
};

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
    
    // True Fibonacci spiral layout starting from the right direction
    tileFibonacci(conn, visible, 
        @intCast(gap), 
        @intCast(y_offset + gap), 
        screen_width - gap * 2, 
        available_height - gap * 2,
        gap, border, 0, .right);
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
    direction: Direction,
) void {
    if (index >= windows.len) return;
    if (width < gap * 2 + border * 2 or height < gap * 2 + border * 2) {
        // The remaining area is too small to keep splitting.  Instead of
        // leaving these windows untiled (floating), stack all of them on top
        // of each other in whatever space is still available.  They remain
        // part of the tiled layer — just overlapping — exactly like a
        // single-cell monocle for the overflow windows.
        const clamped_w = if (width > border * 2) width - border * 2 else 1;
        const clamped_h = if (height > border * 2) height - border * 2 else 1;
        const rect = utils.Rect{
            .x = @intCast(x),
            .y = @intCast(y),
            .width  = clamped_w,
            .height = clamped_h,
        };
        var i = index;
        while (i < windows.len) : (i += 1) {
            utils.configureWindow(conn, windows[i], rect);
        }
        return;
    }
    
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
    
    // Split the space according to spiral direction
    switch (direction) {
        .right => {
            // Split vertically: window on left, remaining on right
            const half_width = width / 2;
            const win_width = half_width -| gap;
            
            const rect = utils.Rect{
                .x = @intCast(x),
                .y = @intCast(y),
                .width = win_width -| border * 2,
                .height = height -| border * 2,
            };
            utils.configureWindow(conn, win, rect);
            
            // Remaining windows spiral to the right
            const remaining_x = x + @as(i32, @intCast(win_width + gap));
            const remaining_width = width -| (win_width + gap);
            tileFibonacci(conn, windows, remaining_x, y, remaining_width, height, 
                gap, border, index + 1, direction.next());
        },
        .down => {
            // Split horizontally: window on top, remaining below
            const half_height = height / 2;
            const win_height = half_height -| gap;
            
            const rect = utils.Rect{
                .x = @intCast(x),
                .y = @intCast(y),
                .width = width -| border * 2,
                .height = win_height -| border * 2,
            };
            utils.configureWindow(conn, win, rect);
            
            // Remaining windows spiral downward
            const remaining_y = y + @as(i32, @intCast(win_height + gap));
            const remaining_height = height -| (win_height + gap);
            tileFibonacci(conn, windows, x, remaining_y, width, remaining_height, 
                gap, border, index + 1, direction.next());
        },
        .left => {
            // Split vertically: window on right, remaining on left
            const half_width = width / 2;
            const win_width = half_width -| gap;
            
            const rect = utils.Rect{
                .x = @intCast(x + @as(i32, @intCast(width - win_width))),
                .y = @intCast(y),
                .width = win_width -| border * 2,
                .height = height -| border * 2,
            };
            utils.configureWindow(conn, win, rect);
            
            // Remaining windows spiral to the left
            const remaining_width = width -| (win_width + gap);
            tileFibonacci(conn, windows, x, y, remaining_width, height, 
                gap, border, index + 1, direction.next());
        },
        .up => {
            // Split horizontally: window on bottom, remaining above
            const half_height = height / 2;
            const win_height = half_height -| gap;
            
            const rect = utils.Rect{
                .x = @intCast(x),
                .y = @intCast(y + @as(i32, @intCast(height - win_height))),
                .width = width -| border * 2,
                .height = win_height -| border * 2,
            };
            utils.configureWindow(conn, win, rect);
            
            // Remaining windows spiral upward
            const remaining_height = height -| (win_height + gap);
            tileFibonacci(conn, windows, x, y, width, remaining_height, 
                gap, border, index + 1, direction.next());
        },
    }
}
