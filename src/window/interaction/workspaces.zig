//! Workspace management - Optimized with batch operations

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");
const focus = @import("focus");
const bar = @import("bar");

pub const Workspace = struct {
    id: usize,
    windows: std.ArrayList(u32),
    window_set: std.AutoHashMap(u32, void),
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, id: usize, name: []const u8) !Workspace {
        return .{
            .id = id,
            .windows = std.ArrayList(u32){},
            .window_set = std.AutoHashMap(u32, void).init(allocator),
            .name = name,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.windows.deinit(self.allocator);
        self.window_set.deinit();
    }

    pub fn contains(self: *const Workspace, win: u32) bool {
        return self.window_set.contains(win);
    }

    pub fn add(self: *Workspace, win: u32) !void {
        if (!self.contains(win)) {
            try self.windows.append(self.allocator, win);
            try self.window_set.put(win, {});
        }
    }

    pub fn remove(self: *Workspace, win: u32) bool {
        if (!self.window_set.remove(win)) return false;

        for (self.windows.items, 0..) |w, i| {
            if (w == win) {
                _ = self.windows.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

pub const State = struct {
    workspaces: []Workspace,
    current: usize,
    window_to_workspace: std.AutoHashMap(u32, usize),
    allocator: std.mem.Allocator,
    wm: *WM,
};

var state: ?*State = null;

pub fn init(wm: *WM) void {
    const s = wm.allocator.create(State) catch {
        std.log.err("[workspaces] Failed to allocate state", .{});
        return;
    };
    s.allocator = wm.allocator;
    s.current = 0;
    s.window_to_workspace = std.AutoHashMap(u32, usize).init(wm.allocator);
    s.wm = wm;

    const count = wm.config.workspaces.count;
    s.workspaces = wm.allocator.alloc(Workspace, count) catch {
        std.log.err("[workspaces] Failed to allocate workspaces", .{});
        wm.allocator.destroy(s);
        return;
    };

    for (s.workspaces, 0..) |*ws, i| {
        const name = std.fmt.allocPrint(wm.allocator, "{}", .{i + 1}) catch "?";
        ws.* = Workspace.init(wm.allocator, i, name) catch {
            std.log.err("[workspaces] Failed to init workspace {}", .{i});
            for (s.workspaces[0..i]) |*prev_ws| {
                prev_ws.deinit();
                wm.allocator.free(prev_ws.name);
            }
            wm.allocator.free(s.workspaces);
            wm.allocator.destroy(s);
            return;
        };
    }

    state = s;
}

pub fn deinit(wm: *WM) void {
    if (state) |s| {
        for (s.workspaces) |*ws| {
            ws.deinit();
            wm.allocator.free(ws.name);
        }
        wm.allocator.free(s.workspaces);
        s.window_to_workspace.deinit();
        wm.allocator.destroy(s);
        state = null;
    }
}

pub fn addWindowToCurrentWorkspace(_: *WM, win: u32) void {
    const s = state orelse return;
    if (@import("bar").isBarWindow(win)) return;

    const ws = &s.workspaces[s.current];
    ws.add(win) catch |err| {
        std.log.err("[workspaces] Failed to add window {x}: {}", .{ win, err });
        return;
    };
    s.window_to_workspace.put(win, s.current) catch |err| {
        std.log.warn("[workspaces] Failed to update window map for {x}: {}", .{ win, err });
    };
}

pub fn removeWindow(win: u32) void {
    const s = state orelse return;

    if (s.window_to_workspace.fetchRemove(win)) |entry| {
        const ws_idx = entry.value;
        if (ws_idx < s.workspaces.len) {
            _ = s.workspaces[ws_idx].remove(win);
        }
    }
}

pub fn moveWindowTo(wm: *WM, win: u32, target_ws: usize) void {
    const s = state orelse return;

    if (target_ws >= s.workspaces.len) {
        std.log.err("[workspaces] Invalid target workspace: {}", .{target_ws});
        return;
    }

    // Find current workspace for this window
    const from_ws = s.window_to_workspace.get(win) orelse blk: {
        // Window not in map, search for it
        for (s.workspaces, 0..) |*ws, i| {
            if (ws.contains(win)) {
                s.window_to_workspace.put(win, i) catch {};
                break :blk i;
            }
        } else {
            // Window not found anywhere, just add to target
            s.workspaces[target_ws].add(win) catch |err| {
                std.log.err("[workspaces] Failed to add window to workspace {}: {}", .{ target_ws, err });
            };
            s.window_to_workspace.put(win, target_ws) catch {};
            return;
        }
    };

    if (from_ws == target_ws) return;

    // Move window between workspaces
    _ = s.workspaces[from_ws].remove(win);
    s.workspaces[target_ws].add(win) catch |err| {
        std.log.err("[workspaces] Failed to add window to workspace {}: {}", .{ target_ws, err });
        // Try to add back to original workspace
        s.workspaces[from_ws].add(win) catch {};
        return;
    };
    s.window_to_workspace.put(win, target_ws) catch {};

    // Handle visibility changes
    if (from_ws == s.current) {
        _ = xcb.xcb_unmap_window(wm.conn, win);

        if (wm.focused_window == win) {
            focus.clearFocus(wm);
        }

        // ISSUE #1 FIX: Retile current workspace when removing a window
        if (wm.config.tiling.enabled) {
            const tiling_mod = @import("tiling");
            if (tiling_mod.getState()) |ts| {
                ts.markDirty();
            }
        }
    } else if (target_ws == s.current) {
        // Moving to current workspace - mark tiling dirty
        if (wm.config.tiling.enabled) {
            const tiling_mod = @import("tiling");
            if (tiling_mod.getState()) |ts| {
                ts.markDirty();
            }
        }
    }
}

pub fn switchTo(wm: *WM, ws_id: usize) void {
    const s = state orelse return;

    if (ws_id >= s.workspaces.len or ws_id == s.current) return;

    const old_ws = s.current;
    // Advance current before the switch so that retileCurrentWorkspace,
    // called inside executeSwitch, lays out the new workspace's windows.
    s.current = ws_id;
    executeSwitch(wm, old_ws, ws_id);
}

// Flicker-free workspace switch.
//
// WHY map/unmap flickers
// -----------------------
// xcb_unmap_window destroys a window's rendered content on the server (unless
// the application requested backing_store = Always, which most do not).
// xcb_map_window on that window then triggers a server-side clear + Expose.
// Until the application handles the Expose and redraws — an asynchronous
// round-trip — the window shows its bare background pixel.  Meanwhile the
// old-workspace windows have already vanished.  Gaps in the tiling layout
// expose the root window (wallpaper) for that one frame.  Doing the map
// *before* the unmap does not help: the server still needs to asynchronously
// redraw the remapped window's content.
//
// WHY moving off-screen works
// ---------------------------
// A window that is *moved* (configured to x >= screen_width) stays mapped.
// A mapped window retains its content in the server indefinitely.  When the
// window is moved back on-screen later, its content is already there — no
// Expose, no redraw, no blank frame.
//
// The sequence
// ------------
//   (a) Queue xcb_configure_window (x = screen_width) for every old-ws window.
//       They leave the viewport but stay mapped.  Content is preserved.
//   (b) Queue xcb_map_window for every new-ws window.  This is a no-op for
//       windows that are already mapped (off-screen from a previous switch).
//       It is only a real map on the very first visit to a workspace.
//   (c) If the new workspace has a fullscreen window, queue its geometry
//       restore here.  retileCurrentWorkspace skips fullscreen windows, so
//       they must be handled explicitly.
//   (d) Call retileCurrentWorkspace.  It queues configure requests that move
//       the tiled windows to their correct on-screen positions, then calls
//       b.execute() which flushes.  Because XCB uses a single output buffer,
//       that flush drains (a)+(b)+(c)+(d) in one shot.  The server sees the
//       entire batch before it paints — no intermediate layout is rendered.
//   (e) A safety flush in case retile returned early (no tiled windows, etc.).
//   (f) Raise the bar above any fullscreen window, then set input focus.
fn executeSwitch(wm: *WM, old_ws: usize, new_ws: usize) void {
    const s = state orelse return;

    const old_workspace = &s.workspaces[old_ws];
    const new_workspace = &s.workspaces[new_ws];
    const screen = wm.screen;

    // Pre-set focused_window so the retile assigns the correct border
    // colour to the window that will receive focus.
    if (new_workspace.windows.items.len > 0) {
        wm.focused_window = new_workspace.windows.items[0];
    } else {
        wm.focused_window = null;
    }

    // (a) Move old-workspace windows off-screen.  configure, not unmap —
    //     this keeps them mapped so their rendered content is preserved for
    //     the next time we switch back to this workspace.
    for (old_workspace.windows.items) |win| {
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X,
            &[_]u32{@intCast(screen.width_in_pixels)});
    }

    // (b) Ensure new-workspace windows are mapped.  No-op for windows that
    //     are already mapped (off-screen).  A real map only on first visit.
    for (new_workspace.windows.items) |win| {
        _ = xcb.xcb_map_window(wm.conn, win);
    }

    // (c) Restore fullscreen window on the new workspace.  retile skips
    //     fullscreen windows, so we restore geometry explicitly here so the
    //     request travels in the same flush as everything else.
    if (wm.fullscreen.getForWorkspace(new_ws)) |fs_info| {
        _ = xcb.xcb_configure_window(wm.conn, fs_info.window,
            xcb.XCB_CONFIG_WINDOW_X |
            xcb.XCB_CONFIG_WINDOW_Y |
            xcb.XCB_CONFIG_WINDOW_WIDTH |
            xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{
                0,                                      // x
                0,                                      // y
                @intCast(screen.width_in_pixels),       // width
                @intCast(screen.height_in_pixels),      // height
                0,                                      // border_width
            });
        _ = xcb.xcb_configure_window(wm.conn, fs_info.window,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    // (d) Retile: configures tiled windows at their on-screen positions and
    //     flushes.  Everything queued in (a)-(c) is still sitting in XCB's
    //     output buffer and gets sent in the same flush.
    if (wm.config.tiling.enabled) {
        const tiling_mod = @import("tiling");
        tiling_mod.retileCurrentWorkspace(wm);
    }

    // (e) Safety flush — covers the case where retile returned early or
    //     tiling is disabled.  If retile already flushed, the buffer is
    //     empty and this is a no-op.
    utils.flush(wm.conn);
    
    // Check if new workspace has fullscreen window and adjust bar visibility
    if (wm.fullscreen.getForWorkspace(new_ws)) |_| {
        // New workspace has fullscreen - hide bar
        bar.hideForFullscreen(wm);
    } else {
        // New workspace has no fullscreen - show bar (if enabled in config)
        bar.showForFullscreen(wm);
    }

    // (f) Raise bar above fullscreen window (must happen after the main
    //     flush to avoid splitting the atomic batch), then set focus.
    if (wm.fullscreen.getForWorkspace(new_ws)) |_| {
        bar.raiseBar();
    }

    if (new_workspace.windows.items.len > 0) {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            wm.focused_window.?, xcb.XCB_CURRENT_TIME);
    } else {
        _ = xcb.xcb_set_input_focus(wm.conn, xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
            wm.root, xcb.XCB_CURRENT_TIME);
    }
    utils.flush(wm.conn);

    bar.markDirty();
}

pub fn getCurrentWindowsView() ?[]const u32 {
    const s = state orelse return null;
    return s.workspaces[s.current].windows.items;
}

pub fn getCurrentWorkspace() ?usize {
    const s = state orelse return null;
    return s.current;
}

pub fn isOnCurrentWorkspace(win: u32) bool {
    const s = state orelse return false;
    return s.workspaces[s.current].contains(win);
}

pub fn getState() ?*State {
    return state;
}

pub fn getCurrentWorkspaceObject() ?*Workspace {
    const s = state orelse return null;
    return &s.workspaces[s.current];
}
