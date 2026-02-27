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
    const s = if (wm.minimize) |*m| m else return false;
    return s.minimized_info.contains(win);
}

fn trackMinimized(s: *defs.MinimizeState, ws_idx: u8, win: u32, saved_fs: ?defs.WindowGeometry) bool {
    s.per_workspace[ws_idx].append(s.allocator, win) catch return false;
    s.minimized_info.put(win, .{ .saved_fs = saved_fs, .workspace = ws_idx }) catch {
        // The rollback assumes `win` is the last element.  Assert here so a
        // future refactor that inserts multiple entries before the put does
        // not silently corrupt the list instead of triggering a visible failure.
        std.debug.assert(s.per_workspace[ws_idx].items[s.per_workspace[ws_idx].items.len - 1] == win);
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
        // Use .tiling_operation rather than .window_destroyed:
        //  - tiling_operation skips the blocking xcb_get_window_attributes
        //    mapped-check (windows in the tiling set are guaranteed mapped).
        //  - window_destroyed would trigger the check unnecessarily and also
        //    set the wrong suppress_focus_reason, potentially interfering with
        //    crossing-event suppression logic.
        focus.setFocus(wm, win, .tiling_operation);
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

    if (!trackMinimized(s, ws_idx, win, saved_fs)) {
        debug.err("minimize: allocation failure tracking window 0x{x} -- rolling back", .{win});
        // Roll back tiling removal so the window remains in the layout.
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        // Roll back fullscreen removal: the window is still visually fullscreen
        // (it was never hidden), but without this the WM has no record of it.
        // Re-inserting restores coherent state so toggleFullscreen still works.
        if (was_fullscreen) {
            wm.fullscreen.setForWorkspace(fs_ws_for_rollback.?, .{
                .window         = win,
                .saved_geometry = saved_fs.?,
            }) catch {
                // setForWorkspace itself failed under OOM — log and accept the
                // incoherent state rather than panicking.
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

fn restoreWindow(wm: *WM, win: u32) void {
    const s = getMinState(wm) orelse return;

    const entry = s.minimized_info.fetchRemove(win) orelse return;

    if (entry.value.saved_fs) |geom| {
        // enterFullscreen does not set keyboard focus on its own; call setFocus
        // first so grabButtons, xcb_set_input_focus, and tiling border state are
        // all applied correctly before the window is raised to fullscreen size.
        // .window_spawn skips the unnecessary isWindowMapped round-trip (the
        // window is known-mapped: it was just offscreen, not unmapped).
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

    // In-place partition: plain (non-fullscreen) windows to the front, fullscreen
    // windows to the back.  Single pass over the already-allocated snapshot slice —
    // no extra allocation and no truncation (the previous fixed [64]/[128] buffers
    // silently dropped any windows beyond those capacities).
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

        // Focus the most-recently-minimized plain window (last in snapshot order
        // that ended up in the plain partition).
        focus.setFocus(wm, plain_wins[plain_wins.len - 1], .window_spawn);

        bar.redrawImmediate(wm);
        _ = xcb.xcb_ungrab_server(wm.conn);
        utils.flush(wm.conn);
    }

    // Per-window path: fullscreen windows each need their own grab because
    // re-entering fullscreen involves bar hide + sibling offscreen + raise.
    // This case is rare enough that N separate grabs is acceptable.
    for (fs_wins) |win| restoreWindow(wm, win);
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
