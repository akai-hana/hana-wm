// Tiling layout manager - automatic window arrangement
const std = @import("std");
const defs = @import("defs");
const builtin = @import("builtin");
const xcb = defs.xcb;
const WM = defs.WM;
pub const Layout = enum {
    tile, // Master-stack layout
    monocle, // Fullscreen/tabbed
    grid, // Grid layout
};
pub const TilingState = struct {
    enabled: bool = true,
    layout: Layout = .tile,
    master_width_factor: f32 = 0.55, // Master takes 55% of screen
    gaps: u16 = 10,
    border_width: u16 = 2,
    border_focused: u32 = 0x5294E2, // Blue
    border_normal: u32 = 0x383C4A, // Dark gray
   
    // Track tiled windows in order
    tiled_windows: std.ArrayList(u32),
    master_count: usize = 1, // Number of windows in master area
};
var tiling_state: ?*TilingState = null;
pub fn init(wm: *WM) void {
    const state = wm.allocator.create(TilingState) catch {
        std.log.err("Failed to allocate tiling state", .{});
        return;
    };
   
    // Explicitly initialize the field
    state.* = .{
        .tiled_windows = .{},
        .master_count = 1,
        .enabled = true,
        .layout = .tile,
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
            handleRemoveWindow(ev.window, wm, state);
        },
        xcb.XCB_UNMAP_NOTIFY => {
            const ev: *const xcb.xcb_unmap_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(ev.window, wm, state);
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
fn handleRemoveWindow(window: u32, wm: *WM, state: *TilingState) void {
    // Remove from tiling list
    var found = false;
    for (state.tiled_windows.items, 0..) |win, i| {
        if (win == window) {
            _ = state.tiled_windows.orderedRemove(i);
            found = true;
            break;
        }
    }
    if (!found) return;
   
    // Retile remaining windows
    if (state.tiled_windows.items.len > 0) {
        retile(wm, state);
    }
   
    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Window {x} removed, remaining: {}\n",
            .{window, state.tiled_windows.items.len});
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
    const n = @as(u16, @intCast(windows.len));
    if (n == 0) return;

    const gap = state.gaps;
    const bw = state.border_width;

    // 1. Determine Window Split
    var m_count = @min(@as(u16, @intCast(state.master_count)), n);
    if (m_count == 0) m_count = 1;
    const s_count = n - m_count;

    // 2. Calculate the "Master Width" (the total space the master column occupies)
    // If there's no stack, the master column occupies the full screen width.
    const master_area_w: u16 = if (s_count == 0) 
        screen_w 
    else 
        @intFromFloat(@as(f32, @floatFromInt(screen_w)) * state.master_width_factor);

    for (windows, 0..) |win, idx_usize| {
        const i = @as(u16, @intCast(idx_usize));
        
        var tile_x: u16 = 0;
        var tile_y: u16 = 0;
        var tile_w: u16 = 0;
        var tile_h: u16 = 0;

        if (i < m_count) {
            // --- MASTER COLUMN ---
            tile_x = 0;
            tile_w = master_area_w;
            
            const rows = m_count;
            tile_h = screen_h / rows;
            tile_y = i * tile_h;
        } else {
            // --- STACK COLUMN ---
            tile_x = master_area_w;
            tile_w = screen_w - master_area_w;
            
            const rows = s_count;
            const s_idx = i - m_count;
            tile_h = screen_h / rows;
            tile_y = s_idx * tile_h;
        }

        // 3. APPLY GAPS AND BORDERS (The "Shrink" Step)
        // We take the theoretical 'tile' and move the window inside it.
        
        // X and Y: Offset by gap, then offset by border because X/Y is outer corner
        const final_x = tile_x + gap;
        const final_y = tile_y + gap;

        // Width and Height: 
        // We subtract the gap on the left of the window AND the gap on the right.
        // We also MUST subtract 2*bw because X11 adds the border to the width.
        const final_w = if (tile_w > (2 * gap + 2 * bw)) 
            tile_w - (2 * gap) - (2 * bw) 
        else 
            1;
            
        const final_h = if (tile_h > (2 * gap + 2 * bw)) 
            tile_h - (2 * gap) - (2 * bw) 
        else 
            1;

        configureWindow(wm, win, final_x, final_y, final_w, final_h);
    }
}

fn tileMonocle(wm: *WM, state: *TilingState, windows: []const u32, screen_w: u16, screen_h: u16) void {
    const gap = state.gaps;
    const bw = state.border_width;
    // All windows fullscreen, stacked (last window on top)
    for (windows) |win| {
        configureWindow(wm, win,
            gap,
            gap,
            screen_w - 2 * gap - 2 * bw,
            screen_h - 2 * gap - 2 * bw);
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
    const bw = state.border_width;
    const n = windows.len;
   
    // Calculate grid dimensions
    const cols_f = @ceil(@sqrt(@as(f32, @floatFromInt(n))));
    const cols = @as(u16, @intFromFloat(cols_f));
    const rows = @as(u16, @intCast((n + cols - 1) / cols));
   
    const inner_gaps_w = (cols - 1) * gap;
    const inner_gaps_h = (rows - 1) * gap;
    const borders_w = cols * 2 * bw;
    const borders_h = rows * 2 * bw;
    const usable_w = screen_w - 2 * gap - inner_gaps_w - borders_w;
    const usable_h = screen_h - 2 * gap - inner_gaps_h - borders_h;
    const cell_client_w = if (cols > 0) usable_w / cols else 1;
    const cell_client_h = if (rows > 0) usable_h / rows else 1;
   
    for (windows, 0..) |win, idx| {
        const col = @as(u16, @intCast(idx % cols));
        const row = @as(u16, @intCast(idx / cols));
        const wx = gap + col * (cell_client_w + gap + 2 * bw);
        const wy = gap + row * (cell_client_h + gap + 2 * bw);
        configureWindow(wm, win,
            wx,
            wy,
            @max(1, cell_client_w),
            @max(1, cell_client_h));
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
    state.master_count = @max(0, state.master_count - 1); // Allow 0
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
    xcb.XCB_UNMAP_NOTIFY,
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
