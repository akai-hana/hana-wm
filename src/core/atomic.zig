//! Atomic operation wrapper for window manager state changes.

const std = @import("std");
const defs = @import("defs");
const xcb = defs.xcb;
const WM = defs.WM;
const utils = @import("utils");

const XcbOp = union(enum) {
    map: u32,
    unmap: u32,
    configure: struct { win: u32, rect: utils.Rect },
    set_border: struct { win: u32, color: u32 },
    set_focus: u32,
    raise: u32,
};

const StateOp = union(enum) {
    add_window: struct { ws: usize, win: u32 },
    remove_window: struct { ws: usize, win: u32 },
    add_tiled: u32,
    remove_tiled: u32,
    set_focused: ?u32,
    mark_retile: void,
};

/// Transaction context for atomic window operations
pub const Transaction = struct {
    wm: *WM,
    xcb_ops: std.ArrayListUnmanaged(XcbOp) = .{},
    state_ops: std.ArrayListUnmanaged(StateOp) = .{},
    committed: bool = false,
    allocator: std.mem.Allocator,

    pub fn begin(wm: *WM) !Transaction {
        return .{
            .wm = wm,
            .xcb_ops = .{},
            .state_ops = .{},
            .committed = false,
            .allocator = wm.allocator,
        };
    }

    pub fn deinit(self: *Transaction) void {
        self.xcb_ops.deinit(self.allocator);
        self.state_ops.deinit(self.allocator);
    }

    // XCB operations
    pub fn mapWindow(self: *Transaction, win: u32) !void {
        try self.xcb_ops.append(self.allocator, .{ .map = win });
    }

    pub fn unmapWindow(self: *Transaction, win: u32) !void {
        try self.xcb_ops.append(self.allocator, .{ .unmap = win });
    }

    pub fn configureWindow(self: *Transaction, win: u32, rect: utils.Rect) !void {
        try self.xcb_ops.append(self.allocator, .{ .configure = .{ .win = win, .rect = rect } });
    }

    pub fn setBorder(self: *Transaction, win: u32, color: u32) !void {
        try self.xcb_ops.append(self.allocator, .{ .set_border = .{ .win = win, .color = color } });
    }

    pub fn setFocus(self: *Transaction, win: u32) !void {
        try self.xcb_ops.append(self.allocator, .{ .set_focus = win });
    }

    pub fn raiseWindow(self: *Transaction, win: u32) !void {
        try self.xcb_ops.append(self.allocator, .{ .raise = win });
    }

    // State operations
    pub fn addWindowToWorkspace(self: *Transaction, ws: usize, win: u32) !void {
        try self.state_ops.append(self.allocator, .{ .add_window = .{ .ws = ws, .win = win } });
    }

    pub fn removeWindowFromWorkspace(self: *Transaction, ws: usize, win: u32) !void {
        try self.state_ops.append(self.allocator, .{ .remove_window = .{ .ws = ws, .win = win } });
    }

    pub fn addTiledWindow(self: *Transaction, win: u32) !void {
        try self.state_ops.append(self.allocator, .{ .add_tiled = win });
    }

    pub fn removeTiledWindow(self: *Transaction, win: u32) !void {
        try self.state_ops.append(self.allocator, .{ .remove_tiled = win });
    }

    pub fn updateFocus(self: *Transaction, win: ?u32) !void {
        try self.state_ops.append(self.allocator, .{ .set_focused = win });
    }

    pub fn markRetile(self: *Transaction) !void {
        try self.state_ops.append(self.allocator, .{ .mark_retile = {} });
    }

    /// Commit all operations atomically
    pub fn commit(self: *Transaction) !void {
        if (self.committed) return error.AlreadyCommitted;

        // Execute all XCB operations (batched)
        for (self.xcb_ops.items) |op| {
            switch (op) {
                .map => |win| _ = xcb.xcb_map_window(self.wm.conn, win),
                .unmap => |win| _ = xcb.xcb_unmap_window(self.wm.conn, win),
                .configure => |cfg| utils.configureWindow(self.wm.conn, cfg.win, cfg.rect),
                .set_border => |sb| {
                    _ = xcb.xcb_change_window_attributes(
                        self.wm.conn,
                        sb.win,
                        xcb.XCB_CW_BORDER_PIXEL,
                        &[_]u32{sb.color},
                    );
                },
                .set_focus => |win| {
                    _ = xcb.xcb_set_input_focus(
                        self.wm.conn,
                        xcb.XCB_INPUT_FOCUS_POINTER_ROOT,
                        win,
                        xcb.XCB_CURRENT_TIME,
                    );
                },
                .raise => |win| {
                    _ = xcb.xcb_configure_window(
                        self.wm.conn,
                        win,
                        xcb.XCB_CONFIG_WINDOW_STACK_MODE,
                        &[_]u32{xcb.XCB_STACK_MODE_ABOVE},
                    );
                },
            }
        }

        // Execute all state operations
        for (self.state_ops.items) |op| {
            switch (op) {
                .add_window => |aw| {
                    const workspaces = @import("workspaces");
                    if (workspaces.getState()) |ws_state| {
                        if (aw.ws < ws_state.workspaces.len) {
                            var ws = &ws_state.workspaces[aw.ws];
                            if (!ws.contains(aw.win)) {
                                ws.windows.append(ws.allocator, aw.win) catch continue;
                            }
                        }
                    }
                },
                .remove_window => |rw| {
                    const workspaces = @import("workspaces");
                    if (workspaces.getState()) |ws_state| {
                        if (rw.ws < ws_state.workspaces.len) {
                            _ = ws_state.workspaces[rw.ws].remove(rw.win);
                        }
                    }
                },
                .add_tiled => |win| {
                    const tiling = @import("tiling");
                    if (tiling.getState()) |t_state| {
                        for (t_state.tiled_windows.items) |w| {
                            if (w == win) break;
                        } else {
                            t_state.tiled_windows.insert(t_state.allocator, 0, win) catch continue;
                        }
                    }
                },
                .remove_tiled => |win| {
                    const tiling = @import("tiling");
                    if (tiling.getState()) |t_state| {
                        for (t_state.tiled_windows.items, 0..) |w, i| {
                            if (w == win) {
                                _ = t_state.tiled_windows.orderedRemove(i);
                                break;
                            }
                        }
                    }
                },
                .set_focused => |win| {
                    self.wm.focused_window = win;
                },
                .mark_retile => {
                    const tiling = @import("tiling");
                    if (tiling.getState()) |t_state| {
                        t_state.needs_retile = true;
                    }
                },
            }
        }

        // Single flush at the end
        utils.flush(self.wm.conn);
        self.committed = true;
    }

    pub fn rollback(self: *Transaction) void {
        self.xcb_ops.clearRetainingCapacity();
        self.state_ops.clearRetainingCapacity();
        self.committed = true;
    }
};

/// Helper: Execute window mapping atomically
pub fn atomicMapWindow(wm: *WM, win: u32, workspace: usize) !void {
    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    try tx.addWindowToWorkspace(workspace, win);
    try tx.mapWindow(win);

    if (wm.config.tiling.enabled) {
        try tx.addTiledWindow(win);
        try tx.markRetile();
    }

    try tx.commit();
}

/// Helper: Execute window destruction atomically
pub fn atomicDestroyWindow(wm: *WM, win: u32) !void {
    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    const was_focused = wm.focused_window == win;

    try tx.removeTiledWindow(win);

    // Remove from all workspaces
    const workspaces = @import("workspaces");
    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces, 0..) |*ws, i| {
            if (ws.contains(win)) {
                try tx.removeWindowFromWorkspace(i, win);
            }
        }
    }

    // Handle focus
    if (was_focused) {
        try tx.updateFocus(null);
        if (workspaces.getCurrentWindowsView()) |ws_windows| {
            if (ws_windows.len > 0) {
                try tx.setFocus(ws_windows[0]);
                try tx.updateFocus(ws_windows[0]);
            }
        }
    }

    try tx.markRetile();
    try tx.commit();
}

/// Helper: Move window between workspaces atomically
pub fn atomicMoveWindow(wm: *WM, win: u32, from_ws: usize, to_ws: usize) !void {
    if (from_ws == to_ws) return;

    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    const is_focused = wm.focused_window == win;

    try tx.removeWindowFromWorkspace(from_ws, win);
    try tx.addWindowToWorkspace(to_ws, win);

    const workspaces = @import("workspaces");
    if (workspaces.getCurrentWorkspace()) |current| {
        if (from_ws == current and to_ws != current) {
            try tx.unmapWindow(win);

            if (is_focused) {
                try tx.updateFocus(null);
                if (workspaces.getCurrentWindowsView()) |ws_windows| {
                    if (ws_windows.len > 0) {
                        try tx.setFocus(ws_windows[0]);
                        try tx.updateFocus(ws_windows[0]);
                    }
                }
            }
        }
    }

    try tx.markRetile();
    try tx.commit();
}

/// Helper: Switch workspaces atomically
pub fn atomicSwitchWorkspace(wm: *WM, from: usize, to: usize) !void {
    if (from == to) return;

    var tx = try Transaction.begin(wm);
    defer tx.deinit();

    const workspaces = @import("workspaces");
    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces[from].windows.items) |win| {
            try tx.unmapWindow(win);
        }

        for (ws_state.workspaces[to].windows.items) |win| {
            try tx.mapWindow(win);
        }

        if (ws_state.workspaces[to].windows.items.len > 0) {
            const win = ws_state.workspaces[to].windows.items[0];
            try tx.setFocus(win);
            try tx.updateFocus(win);
        } else {
            try tx.updateFocus(null);
        }
    }

    try tx.markRetile();
    try tx.commit();
}
