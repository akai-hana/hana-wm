//! Window minimization: hide/restore with LIFO, FIFO, or bulk restore.
//!
//! Minimized windows remain in their workspace's window list so the bar
//! keeps rendering them, but they are moved offscreen and removed from
//! tiling so remaining windows fill the freed space.
//!
//! Three restore operations are provided, all scoped to the current workspace:
//!   unminimize(.lifo): restore the most recently minimized window (stack pop)
//!   unminimize(.fifo): restore the least recently minimized window (queue dequeue)
//!   unminimizeAll:     restore every minimized window on the current workspace
//!
//! Ordering is tracked via a monotonic per-entry timestamp — no separate
//! per-workspace ordered lists are maintained. The single `minimized_info` map is
//! the only source of truth; scanning it for the LIFO/FIFO candidate is O(n)
//! but n is always tiny in practice (typically < 10 minimized windows).
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

// Types 

/// Per-window minimize record.
const MinimizedEntry = struct {
    saved_fs:       ?defs.WindowGeometry, // non-null iff the window was fullscreen when minimized
    workspace_mask: u64,                  // bitmask of all workspaces this window belongs to
    /// Monotonic counter assigned at minimize time. Higher = more recently minimized.
    /// Used to implement LIFO (pop highest) and FIFO (pop lowest) without
    /// maintaining a separate ordered list per workspace.
    timestamp:      u64,
};

const State = struct {
    minimized_info: std.AutoHashMap(u32, MinimizedEntry),
    allocator:      std.mem.Allocator,
    /// Incremented each time a window is minimized. Never reused.
    next_timestamp: u64,

    pub fn deinit(self: *State) void {
        self.minimized_info.deinit();
    }
};

// Module state 

// Module singleton — guaranteed live after init().
var g_state:       State = undefined;
var g_initialized: bool  = false;

pub inline fn getState() *State {
    std.debug.assert(g_initialized);
    return &g_state;
}

pub inline fn getStateOpt() ?*State {
    return if (g_initialized) &g_state else null;
}

// Lifecycle 

pub fn init(wm: *WM) !void {
    var info_map = std.AutoHashMap(u32, MinimizedEntry).init(wm.allocator);
    try info_map.ensureTotalCapacity(8);
    g_state = .{
        .minimized_info = info_map,
        .allocator      = wm.allocator,
        .next_timestamp = 0,
    };
    g_initialized = true;
}

pub fn deinit() void {
    if (!g_initialized) return;
    g_state.deinit();
    g_initialized = false;
}

// Public queries 

pub inline fn isMinimized(_: *const WM, win: u32) bool {
    if (!g_initialized) return false;
    return g_state.minimized_info.contains(win);
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
        if (workspaces.firstNonMinimized(wm, ws.windows.items())) |win| {
            focus.setFocus(wm, win, .tiling_operation);
            return;
        }
    }
    focus.clearFocus(wm);
}

// Minimize 

pub fn minimizeWindow(wm: *WM) void {
    const win    = focus.getFocused()               orelse return;
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const s      = getState();

    if (isMinimized(wm, win)) return;

    const ws_mask = workspaces.getWindowWorkspaceMask(win) orelse
        (@as(u64, 1) << @intCast(ws_idx));

    // Tear down fullscreen state if needed, saving geometry for later restore.
    var saved_fs: ?defs.WindowGeometry = null;
    var fs_ws_for_rollback: ?u8 = null;
    if (fullscreen.workspaceFor(win)) |fs_ws| {
        if (fullscreen.getForWorkspace(fs_ws)) |info| {
            saved_fs = info.saved_geometry;
            fs_ws_for_rollback = fs_ws;
            fullscreen.removeForWorkspace(fs_ws);
        }
    }
    const was_fullscreen = saved_fs != null;

    if (wm.config.tiling.enabled) tiling.removeWindow(win);

    const ts = s.next_timestamp;
    s.minimized_info.put(win, .{
        .saved_fs       = saved_fs,
        .workspace_mask = ws_mask,
        .timestamp      = ts,
    }) catch {
        debug.err("minimize: allocation failure tracking window 0x{x} -- rolling back", .{win});
        if (wm.config.tiling.enabled) {
            tiling.addWindow(wm, win);
            tiling.retileCurrentWorkspace(wm);
        }
        if (was_fullscreen) {
            fullscreen.setForWorkspace(fs_ws_for_rollback.?, .{
                .window         = win,
                .saved_geometry = saved_fs.?,
            }) catch {
                debug.err("minimize rollback: failed to re-insert fullscreen state for 0x{x}", .{win});
            };
        }
        return;
    };
    s.next_timestamp = ts + 1;

    _ = xcb.xcb_grab_server(wm.conn);
    hideWindow(wm, win);
    focusBestAvailable(wm);
    if (was_fullscreen) {
        bar.setBarState(wm, .show_fullscreen);
    } else if (wm.config.tiling.enabled) {
        tiling.retileCurrentWorkspace(wm);
    }
    bar.redrawInsideGrab(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    _ = xcb.xcb_flush(wm.conn);
}

// Restore helpers 

fn restoreWindowImpl(wm: *WM, win: u32, saved_fs: ?defs.WindowGeometry) void {
    if (saved_fs) |geom| {
        // setFocus first so grabButtons, xcb_set_input_focus, and tiling border
        // state are all applied correctly before the window is raised to fullscreen.
        // .window_spawn skips the isWindowMapped round-trip (window is mapped,
        // just offscreen).
        focus.setFocus(wm, win, .window_spawn);
        fullscreen.enterFullscreen(wm, win, geom);
        bar.scheduleRedraw();
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
    bar.redrawInsideGrab(wm);
    _ = xcb.xcb_ungrab_server(wm.conn);
    _ = xcb.xcb_flush(wm.conn);
}

/// Remove `win` from minimized_info and restore it.
inline fn restoreWindow(wm: *WM, win: u32) void {
    const s = getState();
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    restoreWindowImpl(wm, win, entry.value.saved_fs);
}

// Unminimize 

pub const RestoreOrder = enum { lifo, fifo };

pub fn unminimize(wm: *WM, order: RestoreOrder) void {
    const s      = getState();
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const ws_bit: u64 = @as(u64, 1) << @intCast(ws_idx);

    // Single pass over minimized_info: find the window on the current workspace
    // with the highest (LIFO) or lowest (FIFO) timestamp.
    var best_win: ?u32 = null;
    var best_ts:  u64  = 0;
    var it = s.minimized_info.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.workspace_mask & ws_bit == 0) continue;
        const ts = kv.value_ptr.timestamp;
        const better = switch (order) {
            .lifo => best_win == null or ts > best_ts,
            .fifo => best_win == null or ts < best_ts,
        };
        if (better) { best_win = kv.key_ptr.*; best_ts = ts; }
    }

    const win = best_win orelse return;
    const entry = s.minimized_info.fetchRemove(win) orelse return;
    restoreWindowImpl(wm, win, entry.value.saved_fs);
}

pub fn unminimizeAll(wm: *WM) void {
    const s      = getState();
    const ws_idx = workspaces.getCurrentWorkspace() orelse return;
    const ws_bit: u64 = @as(u64, 1) << @intCast(ws_idx);

    // Collect all windows minimized on the current workspace.
    const Entry = struct { win: u32, ts: u64, is_fs: bool };
    const MAX = 128;
    var entries: [MAX]Entry = undefined;
    var count: usize = 0;

    var it = s.minimized_info.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.workspace_mask & ws_bit == 0) continue;
        if (count < MAX) {
            entries[count] = .{
                .win   = kv.key_ptr.*,
                .ts    = kv.value_ptr.timestamp,
                .is_fs = kv.value_ptr.saved_fs != null,
            };
            count += 1;
        }
    }
    if (count == 0) return;

    // Sort by timestamp ascending; fullscreen windows sort after plain ones
    // because each fullscreen restore needs its own server grab.
    std.sort.pdq(Entry, entries[0..count], {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.is_fs != b.is_fs) return !a.is_fs; // plain before fullscreen
            return a.ts < b.ts;
        }
    }.lt);

    var plain_end: usize = count;
    for (entries[0..count], 0..) |e, i| {
        if (e.is_fs) { plain_end = i; break; }
    }
    const plain_wins = entries[0..plain_end];
    const fs_wins    = entries[plain_end..count];

    // Batch restore all plain windows in a single server grab.
    if (plain_wins.len > 0) {
        _ = xcb.xcb_grab_server(wm.conn);

        if (wm.config.tiling.enabled) {
            for (plain_wins) |e| {
                _ = s.minimized_info.remove(e.win);
                tiling.addWindow(wm, e.win);
            }
            tiling.retileCurrentWorkspace(wm);
        } else {
            const pos = utils.floatDefaultPos(wm);
            for (plain_wins) |e| {
                _ = s.minimized_info.remove(e.win);
                _ = xcb.xcb_configure_window(wm.conn, e.win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ pos.x, pos.y });
            }
        }

        focus.setFocus(wm, plain_wins[plain_wins.len - 1].win, .window_spawn);

        bar.redrawInsideGrab(wm);
        _ = xcb.xcb_ungrab_server(wm.conn);
        _ = xcb.xcb_flush(wm.conn);
    }

    // Each fullscreen window needs its own grab.
    for (fs_wins) |e| restoreWindow(wm, e.win);
}

// State maintenance 

/// Called by window.zig on unmap/destroy to keep state coherent.
pub fn forceUntrack(_: *WM, win: u32) void {
    const s = getState();
    _ = s.minimized_info.remove(win);
}

/// Called by workspaces.zig when a minimized window is moved to another workspace.
pub fn moveToWorkspace(_: *WM, win: u32, new_ws: u8) void {
    const s = getState();
    const entry = s.minimized_info.getPtr(win) orelse return;
    entry.workspace_mask = @as(u64, 1) << @intCast(new_ws);
}

