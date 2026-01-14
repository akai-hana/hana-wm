// Tiling layout manager - automatic window arrangement

const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const xcb = defs.xcb;
const WM = defs.WM;

pub const Layout = enum {
    tile,      // Master-stack layout
    monocle,   // Fullscreen/tabbed
    grid,      // Grid layout
};

pub const TilingState = struct {
    enabled: bool = true,
    layout: Layout = .tile,
    master_width_factor: f32 = 0.55,  // Master takes 55% of screen
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2,    // Blue
    border_normal: u32 = 0x383C4A,     // Dark gray
    
    // Track tiled windows in order
    tiled_windows: std.ArrayList(u32),
    master_count: usize = 1,  // Number of windows in master area
};

var tiling_state: ?*TilingState = null;

pub fn init(wm: *WM) void {
    const state = wm.allocator.create(TilingState) catch {
        std.log.err("Failed to allocate tiling state", .{});
        return;
    };
    
    state.* = .{
        .tiled_windows = std.ArrayList(u32){},
    };
    
    tiling_state = state;
    
    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Module initialized - layout: tile, gaps: {}px\n", 
            .{state.gaps});
    }
}

pub fn deinit(wm: *WM) void {
    if (tiling_state) |state| {
        state.tiled_windows.deinit(wm.allocator);
        wm.allocator.destroy(state);
        tiling_state = null;
    }
}

pub fn handleEvent(event_type: u8, event: *anyopaque, wm: *WM) void {
    const state = tiling_state orelse return;
    if (!state.enabled) return;
    
    switch (event_type & 0x7F) {
        xcb.XCB_MAP_REQUEST => {
            const ev: *const xcb.xcb_map_request_event_t = @ptrCast(@alignCast(event));
            handleMapRequest(ev, wm, state);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const ev: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
            handleDestroyNotify(ev, wm, state);
        },
        else => {},
    }
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM, state: *TilingState) void {
    // Add window to tiling list
    state.tiled_windows.append(wm.allocator, event.window) catch {
        std.log.err("Failed to add window to tiling list", .{});
        return;
    };
    
    // Map the window
    _ = xcb.xcb_map_window(wm.conn, event.window);
    
    // Set border
    _ = xcb.xcb_change_window_attributes(wm.conn, event.window, 
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{state.border_normal});
    _ = xcb.xcb_configure_window(wm.conn, event.window, 
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{state.border_width});
    
    // Retile all windows
    retile(wm, state);
    
    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Window {x} added, total windows: {}\n", 
            .{event.window, state.tiled_windows.items.len});
    }
}

fn handleDestroyNotify(event: *const xcb.xcb_destroy_notify_event_t, wm: *WM, state: *TilingState) void {
    // Remove from tiling list
    for (state.tiled_windows.items, 0..) |win, i| {
        if (win == event.window) {
            _ = state.tiled_windows.orderedRemove(i);
            break;
        }
    }
    
    // Retile remaining windows
    if (state.tiled_windows.items.len > 0) {
        retile(wm, state);
    }
    
    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Window {x} removed, remaining: {}\n", 
            .{event.window, state.tiled_windows.items.len});
    }
}

fn retile(wm: *WM, state: *TilingState) void {
    const windows = state.tiled_windows.items;
    if (windows.len == 0) return;
    
    const screen = wm.screen;
    const screen_width = screen.width_in_pixels;
    const screen_height = screen.height_in_pixels;
    
    switch (state.layout) {
        .tile => tileMasterStack(wm, state, windows, screen_width, screen_height),
        .monocle => tileMonocle(wm, state, windows, screen_width, screen_height),
        .grid => tileGrid(wm, state, windows, screen_width, screen_height),
    }
    
    _ = xcb.xcb_flush(wm.conn);
}

fn tileMasterStack(wm: *WM, state: *TilingState, windows: []const u32, 
                   screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const master_count = @min(state.master_count, windows.len);
    
    if (windows.len == 1) {
        // Single window - fullscreen with gaps
        configureWindow(wm, windows[0], 
            gap, gap, 
            screen_w - 2 * gap, 
            screen_h - 2 * gap);
        return;
    }
    
    const master_width = @as(u16, @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor));
    const stack_width = screen_w - master_width;
    
    // Layout master windows
    if (master_count > 0) {
        const master_height = screen_h / @as(u16, @intCast(master_count));
        for (windows[0..master_count], 0..) |win, i| {
            const y = @as(u16, @intCast(i)) * master_height;
            configureWindow(wm, win,
                gap, y + gap,
                master_width - 2 * gap,
                master_height - 2 * gap);
        }
    }
    
    // Layout stack windows
    const stack_count = windows.len - master_count;
    if (stack_count > 0) {
        const stack_height = screen_h / @as(u16, @intCast(stack_count));
        for (windows[master_count..], 0..) |win, i| {
            const y = @as(u16, @intCast(i)) * stack_height;
            configureWindow(wm, win,
                master_width + gap, y + gap,
                stack_width - 2 * gap,
                stack_height - 2 * gap);
        }
    }
}

fn tileMonocle(wm: *WM, state: *TilingState, windows: []const u32,
               screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    
    // All windows fullscreen, stacked (last window on top)
    for (windows) |win| {
        configureWindow(wm, win,
            gap, gap,
            screen_w - 2 * gap,
            screen_h - 2 * gap);
    }
    
    // Raise last window to top
    if (windows.len > 0) {
        _ = xcb.xcb_configure_window(wm.conn, windows[windows.len - 1],
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}

fn tileGrid(wm: *WM, state: *TilingState, windows: []const u32,
            screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const n = windows.len;
    
    // Calculate grid dimensions
    const cols = @as(u16, @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(n))))));
    const rows = @as(u16, @intCast((n + cols - 1) / cols));
    
    const cell_width = screen_w / cols;
    const cell_height = screen_h / rows;
    
    for (windows, 0..) |win, i| {
        const idx: u16 = @intCast(i);
        const col = idx % cols;
        const row = idx / cols;
        
        configureWindow(wm, win,
            col * cell_width + gap,
            row * cell_height + gap,
            cell_width - 2 * gap,
            cell_height - 2 * gap);
    }
}

fn configureWindow(wm: *WM, window: u32, x: u16, y: u16, width: u16, height: u16) void {
    const values = [_]u32{
        x,
        y,
        @max(1, width),
        @max(1, height),
    };
    
    _ = xcb.xcb_configure_window(wm.conn, window,
        xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
        &values);
}

// Public API for keybindings

pub fn toggleLayout(wm: *WM) void {
    const state = tiling_state orelse return;
    
    state.layout = switch (state.layout) {
        .tile => .monocle,
        .monocle => .grid,
        .grid => .tile,
    };
    
    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Layout changed to: {s}\n", .{@tagName(state.layout)});
    }
    
    retile(wm, state);
}

pub fn increaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_width_factor = @min(0.95, state.master_width_factor + 0.05);
    retile(wm, state);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_width_factor = @max(0.05, state.master_width_factor - 0.05);
    retile(wm, state);
}

pub fn increaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @min(state.tiled_windows.items.len, state.master_count + 1);
    retile(wm, state);
}

pub fn decreaseMasterCount(wm: *WM) void {
    const state = tiling_state orelse return;
    state.master_count = @max(1, state.master_count - 1);
    retile(wm, state);
}

pub fn toggleTiling(wm: *WM) void {
    const state = tiling_state orelse return;
    state.enabled = !state.enabled;
    
    if (builtin.mode == .Debug) {
        const status = if (state.enabled) "enabled" else "disabled";
        std.debug.print("[tiling] Tiling {s}\n", .{status});
    }
    
    if (state.enabled) {
        retile(wm, state);
    }
}

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
};

pub fn createModule() defs.Module {
    return defs.Module{
        .name = "tiling",
        .event_types = &EVENT_TYPES,
        .init_fn = init,
        .handle_fn = handleEvent,
        .deinit_fn = deinit,
    };
}
