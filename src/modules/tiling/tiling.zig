// Central tiling manager - delegates to specific layout algorithms
const std     = @import("std");
const defs    = @import("defs");
const builtin = @import("builtin");
const xcb     = defs.xcb;
const WM      = defs.WM;

// Import shared types
const tiling_types = @import("tiling_types");
pub const Layout = tiling_types.Layout;
pub const TilingState = tiling_types.TilingState;

// Import layout modules
const master_left = @import("master-left");
const monocle     = @import("monocle");
const grid        = @import("grid");

var tiling_state: ?*TilingState = null;

fn parseLayout(layout_str: []const u8) Layout {
    if (std.mem.eql(u8, layout_str, "monocle")) return .monocle;
    if (std.mem.eql(u8, layout_str, "grid")) return .grid;
    if (std.mem.eql(u8, layout_str, "master_left")) return .master_left;
    
    // Try case-insensitive matching
    var buf: [32]u8 = undefined;
    if (layout_str.len > buf.len) return .master_left;
    
    const lower = std.ascii.lowerString(&buf, layout_str);
    if (std.mem.eql(u8, lower, "monocle")) return .monocle;
    if (std.mem.eql(u8, lower, "grid")) return .grid;
    
    std.log.warn("[tiling] Unknown layout '{s}', defaulting to master_left", .{layout_str});
    return .master_left;
}

pub fn init(wm: *WM) void {
    const state = wm.allocator.create(TilingState) catch {
        std.log.err("Failed to allocate tiling state", .{});
        return;
    };

    state.tiled_windows = .{};
    state.enabled = wm.config.tiling.enabled;
    state.layout = parseLayout(wm.config.tiling.layout);
    state.master_width_factor = wm.config.tiling.master_width_factor;
    state.master_count = wm.config.tiling.master_count;
    state.gaps = wm.config.tiling.gaps;
    state.border_width = wm.config.tiling.border_width;
    state.border_focused = wm.config.tiling.border_focused;
    state.border_normal = wm.config.tiling.border_normal;

    tiling_state = state;

    std.log.info("[tiling] ============ TILING CONFIGURATION ============", .{});
    std.log.info("[tiling] Enabled: {}", .{state.enabled});
    std.log.info("[tiling] Layout: {s} (from config: '{s}')", .{@tagName(state.layout), wm.config.tiling.layout});
    std.log.info("[tiling] Master count: {}", .{state.master_count});
    std.log.info("[tiling] Master width factor: {d:.2}%", .{state.master_width_factor * 100});
    std.log.info("[tiling] Gaps: {}px", .{state.gaps});
    std.log.info("[tiling] Border width: {}px", .{state.border_width});
    std.log.info("[tiling] Border focused: #0x{x:0>6}", .{state.border_focused});
    std.log.info("[tiling] Border normal: #0x{x:0>6}", .{state.border_normal});
    std.log.info("[tiling] ===============================================", .{});
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
        xcb.XCB_CONFIGURE_REQUEST => {
            const ev: *const xcb.xcb_configure_request_event_t = @ptrCast(@alignCast(event));
            handleConfigureRequest(ev, wm, state);
        },
        xcb.XCB_DESTROY_NOTIFY => {
            const ev: *const xcb.xcb_destroy_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(ev.window, wm, state);
        },
        xcb.XCB_UNMAP_NOTIFY => {
            const ev: *const xcb.xcb_unmap_notify_event_t = @ptrCast(@alignCast(event));
            handleRemoveWindow(ev.window, wm, state);
        },
        xcb.XCB_FOCUS_IN => {
            const ev: *const xcb.xcb_focus_in_event_t = @ptrCast(@alignCast(event));
            updateBorderColors(ev.event, wm, state);
        },
        else => {},
    }
}

fn updateBorderColors(focused_window: u32, wm: *WM, state: *TilingState) void {
    // Update all tiled windows' borders based on focus
    for (state.tiled_windows.items) |win| {
        const color = if (win == focused_window) state.border_focused else state.border_normal;
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
    }
    _ = xcb.xcb_flush(wm.conn);
}

fn handleMapRequest(event: *const xcb.xcb_map_request_event_t, wm: *WM, state: *TilingState) void {
    // Check if window is already in the tiling list
    for (state.tiled_windows.items) |win| {
        if (win == event.window) {
            _ = xcb.xcb_map_window(wm.conn, event.window);
            return;
        }
    }

    // Add window to tiling list
    state.tiled_windows.append(wm.allocator, event.window) catch {
        std.log.err("Failed to add window to tiling list", .{});
        return;
    };

    // Map the window
    _ = xcb.xcb_map_window(wm.conn, event.window);

    // Set border (will be updated by focus events)
    const initial_color = if (wm.focused_window == event.window) 
        state.border_focused 
    else 
        state.border_normal;
    
    _ = xcb.xcb_change_window_attributes(wm.conn, event.window,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{initial_color});
    _ = xcb.xcb_configure_window(wm.conn, event.window,
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{state.border_width});

    // Retile all windows
    retile(wm, state);

    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Window {x} added, total windows: {}\n",
            .{event.window, state.tiled_windows.items.len});
    }
}

fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t, wm: *WM, state: *TilingState) void {
    // Check if this window is tiled
    var is_tiled = false;
    for (state.tiled_windows.items) |win| {
        if (win == event.window) {
            is_tiled = true;
            break;
        }
    }

    if (is_tiled) {
        // For tiled windows, ignore resize requests and re-tile
        if (builtin.mode == .Debug) {
            std.debug.print("[tiling] Ignoring configure request from tiled window {x}\n", .{event.window});
        }
        retile(wm, state);
    } else {
        // For non-tiled windows, allow the configuration
        const values = [_]u32{
            @as(u32, @intCast(@max(0, event.x))),
            @as(u32, @intCast(@max(0, event.y))),
            event.width,
            event.height,
        };
        _ = xcb.xcb_configure_window(wm.conn, event.window,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
            &values);
    }
}

fn handleRemoveWindow(window: u32, wm: *WM, state: *TilingState) void {
    var found = false;
    for (state.tiled_windows.items, 0..) |win, i| {
        if (win == window) {
            _ = state.tiled_windows.orderedRemove(i);
            found = true;
            break;
        }
    }
    if (!found) return;

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

    // Delegate to the active layout
    switch (state.layout) {
        .master_left => master_left.tile(wm, state, windows, screen_width, screen_height),
        .monocle => monocle.tile(wm, state, windows, screen_width, screen_height),
        .grid => grid.tile(wm, state, windows, screen_width, screen_height),
    }

    // Update border colors after retiling
    if (wm.focused_window) |focused| {
        updateBorderColors(focused, wm, state);
    }

    _ = xcb.xcb_flush(wm.conn);
}

// Public API for keybindings
pub fn toggleLayout(wm: *WM) void {
    const state = tiling_state orelse return;

    state.layout = switch (state.layout) {
        .master_left => .monocle,
        .monocle => .grid,
        .grid => .master_left,
    };

    if (builtin.mode == .Debug) {
        std.debug.print("[tiling] Layout changed to: {s}\n", .{@tagName(state.layout)});
    }

    retile(wm, state);
}

pub fn increaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    const old_factor = state.master_width_factor;
    state.master_width_factor = @min(0.95, state.master_width_factor + 0.05);
    std.log.info("[tiling] Master width: {d:.2}% → {d:.2}%", .{old_factor * 100, state.master_width_factor * 100});
    retile(wm, state);
}

pub fn decreaseMasterWidth(wm: *WM) void {
    const state = tiling_state orelse return;
    const old_factor = state.master_width_factor;
    state.master_width_factor = @max(0.05, state.master_width_factor - 0.05);
    std.log.info("[tiling] Master width: {d:.2}% → {d:.2}%", .{old_factor * 100, state.master_width_factor * 100});
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

// Public API for other modules to notify about focus changes
pub fn updateWindowFocus(wm: *WM, focused_window: u32) void {
    const state = tiling_state orelse return;
    if (!state.enabled) return;
    updateBorderColors(focused_window, wm, state);
}

pub const EVENT_TYPES = [_]u8{
    xcb.XCB_MAP_REQUEST,
    xcb.XCB_CONFIGURE_REQUEST,
    xcb.XCB_DESTROY_NOTIFY,
    xcb.XCB_UNMAP_NOTIFY,
    xcb.XCB_FOCUS_IN,  // Added to handle focus changes
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
