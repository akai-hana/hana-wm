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

inline fn getMinStateConst(wm: *const WM) ?*const defs.MinimizeState {
    return if (wm.minimize) |*s| s else null;
}

/// Ordered removal of `win` from `list`. No-op if absent.
fn removeFromList(list: *std.ArrayListUnmanaged(u32), win: u32) void {
    for (list.items, 0..) |w, i| {
        if (w != win) continue;
        _ = list.orderedRemove(i);
        return;
    }
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

pub fn isMinimized(wm: *const WM, win: u32) bool {
    const s = getMinStateConst(wm) orelse return false;
    return s.minimized_info.contains(win);
}

fn trackMinimized(s: *defs.MinimizeState, ws_idx: u8, win: u32, saved_fs: ?defs.WindowGeometry) bool {
    s.per_workspace[ws_idx].append(s.allocator, win) catch return false;
    s.minimized_info.put(win, .{ .saved_fs = saved_fs, .workspace = ws_idx }) catch {
        _ = s.per_workspace[ws_idx].pop();
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
    const ws = workspaces.getCurrentWorkspaceObject() orelse {
        focus.clearFocus(wm);
        return;
    };
    if (workspaces.firstNonMinimized(wm, ws.windows.items())) |win| {
        focus.setFocus(wm, win, .window_destroyed);
    } else {
        focus.clearFocus(wm);
    }
}

pub fn minimizeWindow(wm: *WM) void {
    const win    = wm.focused_window                orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const s      = getMinState(wm)                  orelse return;

    if (isMinimized(wm, win)) return;

    var saved_fs: ?defs.WindowGeometry = null;
    if (wm.fullscreen.window_to_workspace.get(win)) |fs_ws| {
        if (wm.fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = info.saved_geometry;
            wm.fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    if (!trackMinimized(s, ws_idx, win, saved_fs)) {
        debug.err("minimize: allocation failure tracking window 0x{x} -- rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
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

fn restoreWindow(wm: *WM, win: u32) void {
    const s = getMinState(wm) orelse return;

    const entry = s.minimized_info.fetchRemove(win) orelse return;

    if (entry.value.saved_fs) |geom| {
        wm.focused_window = win;
        fullscreen.enterFullscreenWithSavedGeom(wm, win, geom);
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

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(wm: *WM, order: RestoreOrder) void {
    const s      = getMinState(wm)                  orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const list   = &s.per_workspace[ws_idx];
    const win = switch (order) {
        .lifo => list.pop() orelse return,
        .fifo => blk: {
            if (list.items.len == 0) return;
            break :blk list.orderedRemove(0);
        },
    };
    restoreWindow(wm, win);
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

    // Partition the snapshot into windows that need special fullscreen restore
    // and those that can be batched in a single grab. Previously, finding any
    // fullscreen-minimized window caused ALL windows to go through per-window
    // restoreWindow calls (N separate grabs). Now only the fullscreen windows
    // pay that cost; the rest are batched together.
    var fs_buf:    [64]u32 = undefined; // fullscreen-when-minimized
    var plain_buf: [128]u32 = undefined; // normal minimize
    var fs_count: usize = 0;
    var plain_count: usize = 0;

    for (snapshot.items) |win| {
        const entry = s.minimized_info.get(win) orelse continue;
        if (entry.saved_fs != null) {
            if (fs_count < fs_buf.len) { fs_buf[fs_count] = win; fs_count += 1; }
        } else {
            if (plain_count < plain_buf.len) { plain_buf[plain_count] = win; plain_count += 1; }
        }
    }

    // Batch path: restore all non-fullscreen windows in a single server grab.
    if (plain_count > 0) {
        _ = xcb.xcb_grab_server(wm.conn);

        if (wm.config.tiling.enabled) {
            for (plain_buf[0..plain_count]) |win| {
                _ = s.minimized_info.fetchRemove(win);
                tiling.addWindow(wm, win);
            }
            tiling.retileCurrentWorkspace(wm);
        } else {
            const pos = utils.floatDefaultPos(wm);
            for (plain_buf[0..plain_count]) |win| {
                _ = s.minimized_info.fetchRemove(win);
                _ = xcb.xcb_configure_window(wm.conn, win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }

        // Focus the most-recently-minimized plain window (last in snapshot order
        // that ended up in plain_buf).
        focus.setFocus(wm, plain_buf[plain_count - 1], .window_spawn);

        bar.redrawImmediate(wm);
        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);
    }

    // Per-window path: fullscreen windows each need their own grab because
    // re-entering fullscreen involves bar hide + sibling offscreen + raise.
    // This case is rare enough that N separate grabs is acceptable.
    for (fs_buf[0..fs_count]) |win| restoreWindow(wm, win);
}

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn forceUntrack(wm: *WM, win: u32) void {
    const s     = getMinState(wm) orelse return;
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    removeFromList(&s.per_workspace[entry.value.workspace], win);
}

// Called by workspaces.zig when a minimized window is moved to another workspace.
// The old workspace is read from minimized_info directly — the caller no longer
// needs to supply it, eliminating the class of bugs where the passed ws diverges
// from the stored canonical value.
pub fn moveToWorkspace(wm: *WM, win: u32, new_ws: u8) void {
    const s = getMinState(wm) orelse return;
    // Read the canonical old workspace from the info map rather than trusting
    // the caller-supplied value, which could be stale if the window was moved
    // between workspaces before this call.
    const entry = s.minimized_info.getPtr(win) orelse return;
    const old_ws = entry.workspace;

    if (old_ws == new_ws) return;
    if (old_ws >= s.per_workspace.len or new_ws >= s.per_workspace.len) return;

    removeFromList(&s.per_workspace[old_ws], win);

    s.per_workspace[new_ws].append(s.allocator, win) catch |err| {
        // INVARIANT BREAK: win has been removed from per_workspace[old_ws] but
        // cannot be added to per_workspace[new_ws]. minimized_info still maps
        // win -> old_ws; forceUntrack will find a mismatched entry (no-op remove
        // then info eviction). The window silently disappears from the minimized
        // list — acceptable under OOM.
        debug.warnOnErr(err, "minimize.moveToWorkspace: failed to append, window lost from minimize list");
        return;
    };

    entry.workspace = new_ws;
}
