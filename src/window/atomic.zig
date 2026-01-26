//! Atomic operation wrapper for window manager state changes.
//!
//! This module provides a transaction-based system for grouping XCB and state
//! operations into atomic units. Transactions support:
//! - Validation before execution
//! - Snapshotting for rollback (optional)
//! - Batched XCB operations for efficiency
//!
//! Usage:
//!   var tx = try Transaction.begin(wm);
//!   defer tx.deinit();
//!   try tx.mapWindow(win);
//!   try tx.addWindowToWorkspace(ws, win);
//!   try tx.commit();

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

const WorkspaceWindow = struct {
    ws: usize,
    win: u32,
};

const StateSnapshot = struct {
    workspace_windows: std.ArrayList(WorkspaceWindow),
    tiled_windows: std.ArrayList(u32),
    focused_window: ?u32,

    fn deinit(self: *StateSnapshot, allocator: std.mem.Allocator) void {
        self.workspace_windows.deinit(allocator);
        self.tiled_windows.deinit(allocator);
    }
};

pub const Transaction = struct {
    wm: *WM,
    xcb_ops: std.ArrayListUnmanaged(XcbOp) = .{},
    state_ops: std.ArrayListUnmanaged(StateOp) = .{},
    configured_rects: std.AutoHashMap(u32, utils.Rect),
    committed: bool = false,
    rolled_back: bool = false,
    allocator: std.mem.Allocator,
    snapshot: ?StateSnapshot = null,
    enable_snapshot: bool = true,

    pub fn begin(wm: *WM) !Transaction {
        var tx = Transaction{
            .wm = wm,
            .xcb_ops = .{},
            .state_ops = .{},
            .configured_rects = std.AutoHashMap(u32, utils.Rect).init(wm.allocator),
            .committed = false,
            .rolled_back = false,
            .allocator = wm.allocator,
            .snapshot = null,
            .enable_snapshot = true,
        };

        try tx.xcb_ops.ensureTotalCapacity(wm.allocator, 32);
        try tx.state_ops.ensureTotalCapacity(wm.allocator, 16);
        try tx.configured_rects.ensureTotalCapacity(16);

        return tx;
    }

    pub fn beginFast(wm: *WM) !Transaction {
        var tx = try begin(wm);
        tx.enable_snapshot = false;
        return tx;
    }

    pub fn deinit(self: *Transaction) void {
        self.xcb_ops.deinit(self.allocator);
        self.state_ops.deinit(self.allocator);
        self.configured_rects.deinit();
        if (self.snapshot) |*snap| {
            snap.deinit(self.allocator);
        }
    }

    pub fn mapWindow(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .map = win });
    }

    pub fn unmapWindow(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .unmap = win });
    }

    pub fn configureWindow(self: *Transaction, win: u32, rect: utils.Rect) !void {
        try self.configured_rects.put(win, rect);
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .configure = .{ .win = win, .rect = rect } });
    }

    pub fn setBorder(self: *Transaction, win: u32, color: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .set_border = .{ .win = win, .color = color } });
    }

    pub fn setFocus(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .set_focus = win });
    }

    pub fn raiseWindow(self: *Transaction, win: u32) !void {
        if (self.xcb_ops.items.len >= self.xcb_ops.capacity) {
            try self.xcb_ops.ensureUnusedCapacity(self.allocator, 8);
        }
        self.xcb_ops.appendAssumeCapacity(.{ .raise = win });
    }

    pub fn addWindowToWorkspace(self: *Transaction, ws: usize, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .add_window = .{ .ws = ws, .win = win } });
    }

    pub fn removeWindowFromWorkspace(self: *Transaction, ws: usize, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .remove_window = .{ .ws = ws, .win = win } });
    }

    pub fn addTiledWindow(self: *Transaction, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .add_tiled = win });
    }

    pub fn removeTiledWindow(self: *Transaction, win: u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .remove_tiled = win });
    }

    pub fn updateFocus(self: *Transaction, win: ?u32) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .set_focused = win });
    }

    pub fn markRetile(self: *Transaction) !void {
        if (self.state_ops.items.len >= self.state_ops.capacity) {
            try self.state_ops.ensureUnusedCapacity(self.allocator, 4);
        }
        self.state_ops.appendAssumeCapacity(.{ .mark_retile = {} });
    }

    pub fn getConfiguredRect(self: *const Transaction, win: u32) ?utils.Rect {
        return self.configured_rects.get(win);
    }

    fn validate(self: *Transaction) !void {
        const workspaces = @import("workspaces");

        for (self.state_ops.items) |op| {
            switch (op) {
                .add_window => |aw| {
                    if (workspaces.getState()) |ws_state| {
                        if (aw.ws >= ws_state.workspaces.len) {
                            return error.InvalidWorkspace;
                        }
                    }
                },
                .remove_window => |rw| {
                    if (workspaces.getState()) |ws_state| {
                        if (rw.ws >= ws_state.workspaces.len) {
                            return error.InvalidWorkspace;
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn createSnapshot(self: *Transaction) !void {
        if (!self.enable_snapshot) return;

        const workspaces = @import("workspaces");
        const tiling = @import("tiling");

        var snap = StateSnapshot{
            .workspace_windows = std.ArrayList(WorkspaceWindow){},
            .tiled_windows = std.ArrayList(u32){},
            .focused_window = self.wm.focused_window,
        };
        errdefer snap.deinit(self.allocator);

        if (workspaces.getState()) |ws_state| {
            for (ws_state.workspaces, 0..) |ws, i| {
                for (ws.windows.items) |win| {
                    try snap.workspace_windows.append(self.allocator, .{ .ws = i, .win = win });
                }
            }
        }

        if (tiling.getState()) |t_state| {
            try snap.tiled_windows.appendSlice(self.allocator, t_state.tiled_windows.items);
        }

        self.snapshot = snap;
    }

    fn restoreFromSnapshot(self: *Transaction, snap: StateSnapshot) !void {
        const workspaces = @import("workspaces");
        const tiling = @import("tiling");

        if (workspaces.getState()) |ws_state| {
            for (ws_state.workspaces) |*ws| {
                ws.windows.clearRetainingCapacity();
                ws.window_set.clearRetainingCapacity();
            }

            for (snap.workspace_windows.items) |ww| {
                if (ww.ws < ws_state.workspaces.len) {
                    try ws_state.workspaces[ww.ws].add(ww.win);
                }
            }
        }

        if (tiling.getState()) |t_state| {
            t_state.tiled_windows.clearRetainingCapacity();
            try t_state.tiled_windows.appendSlice(t_state.allocator, snap.tiled_windows.items);
        }

        self.wm.focused_window = snap.focused_window;
    }

    pub fn commit(self: *Transaction) !void {
        if (self.committed) return error.AlreadyCommitted;
        if (self.rolled_back) return error.AlreadyRolledBack;

        try self.validate();

        if (self.enable_snapshot) {
            try self.createSnapshot();
            errdefer {
                if (self.snapshot) |*snap| snap.deinit(self.allocator);
                self.rollback() catch |err| {
                    std.log.err("[atomic] Rollback after commit failure also failed: {}", .{err});
                };
            }
        }

        var had_xcb_errors = false;

        for (self.xcb_ops.items) |op| {
            switch (op) {
                .map => |win| {
                    const cookie = xcb.xcb_map_window(self.wm.conn, win);
                    if (cookie.sequence == 0) {
                        std.log.err("[atomic] Failed to map window {}", .{win});
                        had_xcb_errors = true;
                    }
                },
                .unmap => |win| {
                    const cookie = xcb.xcb_unmap_window(self.wm.conn, win);
                    if (cookie.sequence == 0) {
                        std.log.err("[atomic] Failed to unmap window {}", .{win});
                        had_xcb_errors = true;
                    }
                },
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

        if (had_xcb_errors and self.enable_snapshot) {
            std.log.err("[atomic] XCB operations failed, rolling back transaction", .{});
            try self.rollback();
            return error.XcbOperationsFailed;
        }

        for (self.state_ops.items) |op| {
            switch (op) {
                .add_window => |aw| {
                    const workspaces = @import("workspaces");
                    if (workspaces.getState()) |ws_state| {
                        if (aw.ws < ws_state.workspaces.len) {
                            ws_state.workspaces[aw.ws].add(aw.win) catch |err| {
                                std.log.err("[atomic] Failed to add window to workspace: {}", .{err});
                                if (self.enable_snapshot) return err;
                            };
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
                        if (!t_state.tiled_set.contains(win)) {
                            t_state.tiled_windows.insert(t_state.allocator, 0, win) catch |err| {
                                std.log.err("[atomic] Failed to add tiled window: {}", .{err});
                                if (self.enable_snapshot) return err;
                            };
                            t_state.tiled_set.put(win, {}) catch |err| {
                                std.log.err("[atomic] Failed to add to tiled set: {}", .{err});
                                _ = t_state.tiled_windows.orderedRemove(0);
                                if (self.enable_snapshot) return err;
                            };
                        }
                    }
                },
                .remove_tiled => |win| {
                    const tiling = @import("tiling");
                    if (tiling.getState()) |t_state| {
                        _ = t_state.tiled_set.remove(win);
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

        utils.flush(self.wm.conn);
        self.committed = true;

        if (self.snapshot) |*snap| {
            snap.deinit(self.allocator);
            self.snapshot = null;
        }
    }

    pub fn rollback(self: *Transaction) !void {
        if (self.committed) return error.AlreadyCommitted;
        if (self.rolled_back) return;

        defer self.rolled_back = true;

        if (self.snapshot) |snap| {
            try self.restoreFromSnapshot(snap);
            std.log.info("[atomic] Transaction rolled back successfully", .{});
        }

        self.xcb_ops.clearRetainingCapacity();
        self.state_ops.clearRetainingCapacity();

        if (self.snapshot) |*snap| {
            snap.deinit(self.allocator);
            self.snapshot = null;
        }
    }
};

pub fn atomicMapWindow(wm: *WM, win: u32, workspace: usize) !void {
    var tx = try Transaction.beginFast(wm);
    defer tx.deinit();

    try tx.addWindowToWorkspace(workspace, win);
    try tx.mapWindow(win);

    if (wm.config.tiling.enabled) {
        try tx.addTiledWindow(win);
        try tx.markRetile();
    }

    try tx.commit();
}

pub fn atomicDestroyWindow(wm: *WM, win: u32) !void {
    var tx = try Transaction.beginFast(wm);
    defer tx.deinit();

    const was_focused = wm.focused_window == win;

    try tx.removeTiledWindow(win);

    const workspaces = @import("workspaces");
    if (workspaces.getState()) |ws_state| {
        if (ws_state.window_to_workspace.get(win)) |ws_idx| {
            try tx.removeWindowFromWorkspace(ws_idx, win);
        }
    }

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

pub fn atomicMoveWindow(wm: *WM, win: u32, from_ws: usize, to_ws: usize) !void {
    if (from_ws == to_ws) return;

    var tx = try Transaction.beginFast(wm);
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
        } else if (from_ws != current and to_ws == current) {
            try tx.mapWindow(win);

            if (wm.config.tiling.enabled) {
                try tx.setFocus(win);
                try tx.updateFocus(win);
            }
        }
    }

    try tx.markRetile();
    try tx.commit();
}

pub fn atomicSwitchWorkspace(wm: *WM, from: usize, to: usize) !void {
    if (from == to) return;

    var tx = try Transaction.beginFast(wm);
    defer tx.deinit();

    const workspaces = @import("workspaces");

    if (workspaces.getState()) |ws_state| {
        for (ws_state.workspaces[to].windows.items) |win| {
            try tx.mapWindow(win);
        }

        for (ws_state.workspaces[from].windows.items) |win| {
            try tx.unmapWindow(win);
        }

        if (wm.fullscreen_window) |fs_win| {
            const fs_on_from = for (ws_state.workspaces[from].windows.items) |win| {
                if (win == fs_win) break true;
            } else false;

            const fs_on_to = for (ws_state.workspaces[to].windows.items) |win| {
                if (win == fs_win) break true;
            } else false;

            if (fs_on_from and !fs_on_to) {
                try tx.unmapWindow(fs_win);
            }

            if (fs_on_to and !fs_on_from) {
                try tx.mapWindow(fs_win);
                try tx.raiseWindow(fs_win);
            }
        }

        if (ws_state.workspaces[to].windows.items.len > 0) {
            const win = ws_state.workspaces[to].windows.items[0];
            try tx.setFocus(win);
            try tx.updateFocus(win);
        } else {
            try tx.updateFocus(null);
        }
    }

    try tx.commit();
}
