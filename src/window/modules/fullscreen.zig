///! Fullscreen management

const std        = @import("std");
const defs       = @import("defs");
const xcb        = defs.xcb;
const WM         = defs.WM;
const utils      = @import("utils");
const tiling     = @import("tiling");
const workspaces = @import("workspaces");
const bar        = @import("bar");
const constants  = @import("constants");
const debug      = @import("debug");
const minimize   = @import("minimize");

inline fn borderColor(wm: *WM, win: u32) u32 {
    return if (wm.focused_window == win) wm.config.tiling.border_focused
           else                          wm.config.tiling.border_unfocused;
}

// Geometry pre-fetch ───────────────────────────────────────────────────────

/// Saved geometry captured before the server grab.
/// xcb_get_geometry_reply is a blocking round-trip that must never happen
/// inside a grab — another client holding a concurrent grab would deadlock.
const SavedGeom = struct {
    x: i16, y: i16,
    width: u16, height: u16,
    border_width: u16,
};

/// Fetch the current geometry of `win` with a round-trip.
/// If the window is offscreen (e.g. a sibling of the current fullscreen window
/// that was parked during a previous enter), falls back to a sensible default
/// centred quarter of the screen.
fn fetchWindowGeom(wm: *WM, win: u32) SavedGeom {
    const reply = xcb.xcb_get_geometry_reply(
        wm.conn, xcb.xcb_get_geometry(wm.conn, win), null,
    ) orelse return .{
        .x            = @divTrunc(@as(i16, @intCast(wm.screen.width_in_pixels)),  4),
        .y            = @divTrunc(@as(i16, @intCast(wm.screen.height_in_pixels)), 4),
        .width        = @divTrunc(wm.screen.width_in_pixels,  2),
        .height       = @divTrunc(wm.screen.height_in_pixels, 2),
        .border_width = 0,
    };
    defer std.c.free(reply);

    const is_offscreen =
        reply.*.x < constants.OFFSCREEN_THRESHOLD_MIN or
        reply.*.x > constants.OFFSCREEN_THRESHOLD_MAX or
        reply.*.y < constants.OFFSCREEN_THRESHOLD_MIN or
        reply.*.y > constants.OFFSCREEN_THRESHOLD_MAX;

    return .{
        .x            = if (is_offscreen) @divTrunc(@as(i16, @intCast(wm.screen.width_in_pixels)),  4) else reply.*.x,
        .y            = if (is_offscreen) @divTrunc(@as(i16, @intCast(wm.screen.height_in_pixels)), 4) else reply.*.y,
        .width        = if (is_offscreen) @divTrunc(wm.screen.width_in_pixels,  2) else reply.*.width,
        .height       = if (is_offscreen) @divTrunc(wm.screen.height_in_pixels, 2) else reply.*.height,
        .border_width = reply.*.border_width,
    };
}

// Atomic inner helpers (no grab, no flush) ─────────────────────────────────
//
// These functions only queue XCB requests — they never grab the server or
// flush.  The caller owns the grab/ungrab/flush envelope.
//
// Separating "what to queue" from "when to send" is what allows toggleFullscreen
// to wrap an exit+enter pair in a SINGLE grab, eliminating the intermediate
// composited frame that two independent grabs would otherwise produce.

/// Queue all XCB commands needed to enter fullscreen for `win` on `ws`.
/// `geom` must be pre-fetched outside the grab via fetchWindowGeom.
fn enterFullscreenCommit(wm: *WM, win: u32, ws: u8, geom: SavedGeom) void {
    wm.fullscreen.setForWorkspace(ws, .{
        .window    = win,
        .workspace = ws,
        .saved_geometry = .{
            .x            = geom.x,
            .y            = geom.y,
            .width        = geom.width,
            .height       = geom.height,
            .border_width = geom.border_width,
        },
    }) catch {
        debug.err("Failed to save fullscreen state for workspace {}", .{ws});
        return;
    };

    // Push all sibling windows off-screen.  Evict each from the geometry cache
    // so the next retile unconditionally restores their positions.  Without the
    // eviction, configureSafe would find a hit (the stored tiled rect matches
    // the freshly-computed one) and silently skip the configure_window, leaving
    // the siblings stuck offscreen after the user exits fullscreen.
    if (workspaces.getCurrentWorkspaceObject()) |ws_obj| {
        for (ws_obj.windows.items()) |other_win| {
            if (other_win == win) continue;
            _ = xcb.xcb_configure_window(wm.conn, other_win,
                xcb.XCB_CONFIG_WINDOW_X,
                &[_]u32{@bitCast(@as(i32, constants.OFFSCREEN_X_POSITION))});
            tiling.invalidateGeomCache(other_win);
        }
    }

    // Hide bar.  Fullscreen state is already recorded above, so any retile
    // triggered inside setBarState returns early and does not fight us.
    bar.setBarState(wm, .hide_fullscreen);

    // Expand the window to cover the entire screen with no border, then raise
    // it above any floating window not in the workspace list.
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
        xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
        xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
        &[_]u32{
            0, 0,
            @intCast(wm.screen.width_in_pixels),
            @intCast(wm.screen.height_in_pixels),
            0,
        });
    _ = xcb.xcb_configure_window(wm.conn, win,
        xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});

    // Evict the fullscreen window itself from the geometry cache.  Its entry
    // still holds the pre-fullscreen tiled rect.  On exit, retile would compute
    // that same rect, get a spurious hit, and skip the configure_window —
    // leaving the window stuck at fullscreen dimensions.
    tiling.invalidateGeomCache(win);
}

/// Queue all XCB commands needed to exit fullscreen for `win` on `ws`.
/// Clears the fullscreen state before triggering any retile so that retile's
/// early-return guard (getForWorkspace) does not abort the run.
fn exitFullscreenCommit(wm: *WM, win: u32, ws: u8) void {
    const fs_info = wm.fullscreen.getForWorkspace(ws) orelse return;
    if (fs_info.window != win) return;

    const saved = fs_info.saved_geometry;

    // Clear fullscreen state BEFORE calling setBarState so that the retile it
    // triggers internally does not see an active fullscreen and bail.
    wm.fullscreen.removeForWorkspace(ws);

    // Show bar; for tiled workspaces this also retiles, repositioning all
    // windows (including `win`) back to their correct tiled geometry and
    // bringing offscreen siblings back on-screen.
    bar.setBarState(wm, .show_fullscreen);

    if (tiling.isWindowTiled(win)) {
        // retile (above) already sent the correct x/y/w/h for `win`.
        // Restore border width and colour separately — the Rect that retile
        // sends does not include BORDER_WIDTH, so it remains 0 (as set during
        // enter) until we explicitly restore it here.
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{saved.border_width});
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(wm, win)});
    } else {
        // Floating: restore saved geometry and border explicitly.
        _ = xcb.xcb_configure_window(wm.conn, win,
            xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
            xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{
                @bitCast(@as(i32, saved.x)),
                @bitCast(@as(i32, saved.y)),
                saved.width,
                saved.height,
                saved.border_width,
            });
        _ = xcb.xcb_change_window_attributes(wm.conn, win,
            xcb.XCB_CW_BORDER_PIXEL, &[_]u32{borderColor(wm, win)});

        // Bring non-minimized siblings back to a visible on-screen position.
        if (workspaces.getCurrentWorkspaceObject()) |ws_obj| {
            const x: u32 = @intCast(wm.screen.width_in_pixels  / 4);
            const y: u32 = @intCast(wm.screen.height_in_pixels / 4);
            for (ws_obj.windows.items()) |other_win| {
                if (other_win == win) continue;
                if (minimize.isMinimized(other_win)) continue;
                _ = xcb.xcb_configure_window(wm.conn, other_win,
                    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                    &[_]u32{ x, y });
            }
        }
    }
}

// Grab-owning wrappers ─────────────────────────────────────────────────────
//
// Pattern for each wrapper:
//   1. Any blocking round-trips (geometry fetch) happen BEFORE the grab.
//   2. xcb_grab_server is queued.
//   3. The commit function queues all visual changes.
//   4. xcb_ungrab_server is queued immediately after the commit — BEFORE flush.
//   5. A single flush delivers grab + all changes + ungrab in one write.
//
// Queuing the ungrab before the flush is the key difference from the old code,
// which flushed between the commands and the ungrab.  With this pattern the X
// server receives and processes the entire batch atomically: picom is frozen for
// the duration of the grab and composites only the fully-transitioned state.

fn enterFullscreen(wm: *WM, win: u32, ws: u8) void {
    const geom = fetchWindowGeom(wm, win);
    _ = xcb.xcb_grab_server(wm.conn);
    enterFullscreenCommit(wm, win, ws, geom);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

fn exitFullscreen(wm: *WM, win: u32, ws: u8) void {
    _ = xcb.xcb_grab_server(wm.conn);
    exitFullscreenCommit(wm, win, ws);
    _ = xcb.xcb_ungrab_server(wm.conn);
    utils.flush(wm.conn);
}

// Public API──

/// Enter fullscreen for a specific window on the current workspace.
/// Used by the minimize module to restore windows that were fullscreen when
/// minimized.  The caller is responsible for setting wm.focused_window before
/// calling this function.
pub fn enterFullscreenForWindow(wm: *WM, win: u32) void {
    const ws = workspaces.getCurrentWorkspace() orelse return;
    enterFullscreen(wm, win, ws);
}

pub fn toggleFullscreen(wm: *WM) void {
    const win        = wm.focused_window orelse return;
    const current_ws = workspaces.getCurrentWorkspace() orelse return;

    if (wm.fullscreen.getForWorkspace(current_ws)) |fs_info| {
        if (fs_info.window == win) {
            // Simple exit — single atomic grab.
            exitFullscreen(wm, win, current_ws);
        } else {
            // Switching fullscreen from one window to another.
            //
            // Pre-fetch geometry for the incoming window BEFORE the grab.
            // xcb_get_geometry_reply blocks; doing it inside a grab risks
            // deadlock if another client holds a concurrent grab.
            const geom = fetchWindowGeom(wm, win);

            // Wrap BOTH the exit and the enter in a single server grab.
            // This eliminates the intermediate composited frame that two
            // independent grabs would produce between the transitions.
            _ = xcb.xcb_grab_server(wm.conn);
            exitFullscreenCommit(wm, fs_info.window, current_ws);
            enterFullscreenCommit(wm, win, current_ws, geom);
            _ = xcb.xcb_ungrab_server(wm.conn);
            utils.flush(wm.conn);
        }
    } else {
        // Simple enter — single atomic grab.
        enterFullscreen(wm, win, current_ws);
    }
}
