//! Window minimization: per-workspace ordered hide/restore.
//!
//! Minimized windows remain in their workspace's window list so the bar
//! keeps rendering them, but they are moved offscreen and removed from
//! tiling so remaining windows fill the freed space.
//!
//! Three restore operations are provided, all scoped to the current workspace:
//!   unminimize(.lifo): restore the most recently minimized window (stack pop)
//!   unminimize(.fifo): restore the least recently minimized window (queue dequeue)
//!   unminimizeAll:     restore every minimized window
//!
//! Fullscreen interaction: minimizing a fullscreen window tears down the
//! fullscreen state but saves the pre-fullscreen geometry. Restoring such
//! a window puts it back into fullscreen exactly as it was.

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const focus      = @import("focus");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const fullscreen = @import("fullscreen");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");

// MinimizeState and MinimizedEntry are defined in defs.zig so WM can own them
// without circular imports. deinit is handled by WM.deinit.

inline fn getMinState(wm: *WM) ?*defs.MinimizeState {
    return if (wm.minimize) |*s| s else null;
}

/// Ordered removal of `win` from `list`. No-op if absent.
inline fn removeFromList(list: *std.ArrayListUnmanaged(u32), win: u32) void {
    const i = std.mem.indexOfScalar(u32, list.items, win) orelse return;
    _ = list.orderedRemove(i);
}

pub fn init(wm: *WM) void {
    const lists = wm.allocator.alloc(std.ArrayListUnmanaged(u32), wm.config.workspaces.count) catch {
        debug.err("minimize: failed to allocate per-workspace lists", .{});
        return;
    };
    for (lists) |*l| l.* = .{};

    var info_map = std.AutoHashMap(u32, defs.MinimizedEntry).init(wm.allocator);
    info_map.ensureTotalCapacity(8) catch {};

    wm.minimize = defs.MinimizeState{
        .per_workspace  = lists,
        .minimized_info = info_map,
        .allocator      = wm.allocator,
    };
}

pub inline fn isMinimized(wm: *const WM, win: u32) bool {
    const s = if (wm.minimize) |*m| m else return false;
    return s.minimized_info.contains(win);
}

fn trackMinimized(s: *defs.MinimizeState, ws_mask: u64, win: u32, saved_fs: ?defs.WindowGeometry) bool {
    // Pre-allocate capacity for every affected per-workspace list before
    // mutating any of them. If any allocation fails, no lists have been
    // touched yet so the rollback is a no-op and returning false is clean.
    var rem = ws_mask;
    while (rem != 0) {
        const idx: u8 = @intCast(@ctz(rem));
        rem &= rem - 1;
        if (idx < s.per_workspace.len)
            s.per_workspace[idx].ensureUnusedCapacity(s.allocator, 1) catch return false;
    }

    // Capacity is guaranteed; these appends cannot fail.
    rem = ws_mask;
    while (rem != 0) {
        const idx: u8 = @intCast(@ctz(rem));
        rem &= rem - 1;
        if (idx < s.per_workspace.len)
            s.per_workspace[idx].appendAssumeCapacity(win);
    }

    s.minimized_info.put(win, .{ .saved_fs = saved_fs, .workspace_mask = ws_mask }) catch {
        // Rollback: remove from all per-workspace lists.
        var rem2 = ws_mask;
        while (rem2 != 0) {
            const idx: u8 = @intCast(@ctz(rem2));
            rem2 &= rem2 - 1;
            if (idx < s.per_workspace.len) removeFromList(&s.per_workspace[idx], win);
        }
        return false;
    };
    return true;
}

inline fn hideWindow(wm: *WM, win: u32) void {
    _ = xcb.xcb_configure_window(
        wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X,
        &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))},
    );
}

pub fn focusBestAvailable(wm: *WM) void {
    if (workspaces.getCurrentWorkspaceObject()) |ws| {
        // Use .tiling_operation: skips the blocking mapped-check since windows
        // in the tiling set are guaranteed mapped, and avoids setting the wrong
        // suppress_focus_reason for crossing-event suppression.
        if (workspaces.firstNonMinimized(wm, ws.windows.items())) |win| {
            focus.setFocus(wm, win, .tiling_operation);
            return;
        }
    }
    focus.clearFocus(wm);
}

pub fn minimizeWindow(wm: *WM) void {
    const win    = wm.focused_window                orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const s      = getMinState(wm)                  orelse return;

    if (isMinimized(wm, win)) return;

    // Build a mask of all workspaces this window belongs to.
    const ws_mask = workspaces.getWindowWorkspaceMask(win) orelse
        (@as(u64, 1) << @intCast(ws_idx));

    var saved_fs: ?defs.WindowGeometry = null;
    var fs_ws_for_rollback: ?u8 = null;
    if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
        if (wm.fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = info.saved_geometry;
            fs_ws_for_rollback = fs_ws;
            wm.fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    if (!trackMinimized(s, ws_mask, win, saved_fs)) {
        debug.err("minimize: allocation failure tracking window 0x{x} -- rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        if (was_fullscreen) {
            wm.fullscreen.setForWorkspace(fs_ws_for_rollback.?, .{
                .window         = win,
                .saved_geometry = saved_fs.?,
            }) catch {
                debug.err("minimize rollback: failed to re-insert fullscreen state for 0x{x}", .{win});
            };
        }
        return;
    }

    _ = xcb.xcb_grab_server(wm.conn);
    hideWindow(wm, win);
    focusBestAvailable(wm);
    if (was_fullscreen) {
        bar.setBarState(wm, .show_fullscreen);
    } else if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// Inner restore: called with an already-fetched entry to avoid a second
// hash probe when the caller (unminimize) already holds the entry value.
fn restoreWindowImpl(wm: *WM, win: u32, saved_fs: ?defs.WindowGeometry) void {
    if (saved_fs) |geom| {
        // setFocus first so grabButtons, xcb_set_input_focus, and tiling border
        // state are all applied correctly before the window is raised to fullscreen.
        // .window_spawn skips the isWindowMapped round-trip (window is mapped,
        // just offscreen).
        focus.setFocus(wm, win, .window_spawn);
        fullscreen.enterFullscreen(wm, win, geom);
        bar.markDirty();
        return;
    }

    _ = xcb.xcb_grab_server(wm.conn);

    if (wm.config.tiling.enabled) {
        tiling.addWindow(wm, win);
        tiling.retileCurrentWorkspace(wm);
    } else {
        const pos = utils.floatDefaultPos(wm);
        _ = xcb.xcb_configure_window(
            wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
            &[_]u32{ pos.x, pos.y },
        );
    }

    focus.setFocus(wm, win, .window_spawn);
    bar.redrawImmediate(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

inline fn restoreWindow(wm: *WM, win: u32) void {
    const s = getMinState(wm) orelse return;
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    restoreWindowImpl(wm, win, entry.value.saved_fs);
}

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(wm: *WM, order: RestoreOrder) void {
    const s      = getMinState(wm)                  orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    if (list.items.len == 0) return;
    const win: u32 = switch (order) {
        .lifo => list.pop().?,
        .fifo => list.orderedRemove(0),
    };
    // fetchRemove here covers both the per-workspace cleanup below and the
    // restoration — one hash probe instead of get + fetchRemove.
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    var mask = entry.value.workspace_mask & ~(@as(u64, 1) << @intCast(ws_idx));
    while (mask != 0) {
        const idx: u8 = @intCast(@ctz(mask));
        mask &= mask - 1;
        if (idx < s.per_workspace.len) removeFromList(&s.per_workspace[idx], win);
    }
    restoreWindowImpl(wm, win, entry.value.saved_fs);
}

pub fn unminimizeAll(wm: *WM) void {
    const s      = getMinState(wm)                  orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    if (list.items.len == 0) return;

    // Snapshot and clear the ordered list before iterating.
    // Pre-size before clearing so OOM leaves `list` intact and the user can retry.
    var snapshot: std.ArrayListUnmanaged(u32) = .{};
    defer snapshot.deinit(s.allocator);
    snapshot.ensureTotalCapacity(s.allocator, list.items.len) catch |err| {
        debug.warnOnErr(err, "unminimize_all: snapshot allocation failed, no windows restored");
        return;
    };
    snapshot.appendSliceAssumeCapacity(list.items);
    list.clearRetainingCapacity();

    // In-place partition: plain (non-fullscreen) windows to the front, fullscreen
    // windows to the back. Single pass over the already-allocated snapshot slice.
    var plain_count: usize = 0;
    for (snapshot.items, 0..) |win, i| {
        const is_fs = if (s.minimized_info.get(win)) |e| e.saved_fs != null else false;
        if (!is_fs) {
            std.mem.swap(u32, &snapshot.items[plain_count], &snapshot.items[i]);
            plain_count += 1;
        }
    }
    const plain_wins = snapshot.items[0..plain_count];
    const fs_wins    = snapshot.items[plain_count..];

    // Batch path: restore all non-fullscreen windows in a single server grab.
    if (plain_wins.len > 0) {
        _ = xcb.xcb_grab_server(wm.conn);

        if (wm.config.tiling.enabled) {
            for (plain_wins) |win| {
                _ = s.minimized_info.fetchRemove(win);
                tiling.addWindow(wm, win);
            }
            tiling.retileCurrentWorkspace(wm);
        } else {
            const pos = utils.floatDefaultPos(wm);
            for (plain_wins) |win| {
                _ = s.minimized_info.fetchRemove(win);
                _ = xcb.xcb_configure_window(wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }

        focus.setFocus(wm, plain_wins[plain_wins.len - 1], .window_spawn);

        bar.redrawImmediate(wm);
        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);
    }

    // Per-window path: fullscreen windows each need their own grab because
    // re-entering fullscreen involves bar hide + sibling offscreen + raise.
    for (fs_wins) |win| restoreWindow(wm, win);
}

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn forceUntrack(wm: *WM, win: u32) void {
    const s     = getMinState(wm) orelse return;
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    var mask = entry.value.workspace_mask;
    while (mask != 0) {
        const idx: u8 = @intCast(@ctz(mask));
        mask &= mask - 1;
        if (idx < s.per_workspace.len) removeFromList(&s.per_workspace[idx], win);
    }
}

/// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(wm: *WM, win: u32, new_ws: u8) void {
    const s = getMinState(wm) orelse return;
    const entry = s.minimized_info.getPtr(win) orelse return;
    if (new_ws >= s.per_workspace.len) return;

    const old_mask = entry.workspace_mask;
    const new_bit: u64 = @as(u64, 1) << @intCast(new_ws);

    var rem = old_mask;
    while (rem != 0) {
        const idx: u8 = @intCast(@ctz(rem));
        rem &= rem - 1;
        if (idx < s.per_workspace.len) removeFromList(&s.per_workspace[idx], win);
    }
    s.per_workspace[new_ws].append(s.allocator, win) catch |err| {
        debug.warnOnErr(err, "minimize.moveToWorkspace: failed to append");
        return;
    };
    entry.workspace_mask = new_bit;
}
