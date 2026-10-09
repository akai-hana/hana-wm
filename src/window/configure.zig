//! ConfigureRequest compliance: client-requested geometry/border-width
//! handling that answers the CLIENT (protocol duty), not layout.
//!
//! Honored requests route through the window-module hook
//! (`honorConfigureRequest`); denied/tiled requests echo the applied
//! geometry with a synthetic ConfigureNotify (ICCCM 4.1.5). Split out of
//! window.zig, which re-exports `handleConfigureRequest` as the event
//! dispatch surface events.zig's table binds.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const ledger = @import("ledger");
const reconcile = @import("reconcile");
const actions = @import("actions");
const model_mod = @import("model");

const window = @import("window");
const registry = @import("registry");
const query = @import("query");

const geometry_mask: u16 =
    xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH;

fn sendConfigureNotify(win: u32, rect: model_mod.Rect) void {
    var ev = std.mem.zeroes(xcb.xcb_configure_notify_event_t);
    ev.response_type = xcb.XCB_CONFIGURE_NOTIFY;
    ev.event = win;
    ev.window = win;
    ev.x = rect.x;
    ev.y = rect.y;
    ev.width = rect.width;
    ev.height = rect.height;
    ev.border_width = rect.border_width;
    _ = xcb.xcb_send_event(
        core.getState().conn,
        0,
        win,
        xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
        @ptrCast(&ev),
    );
}

/// Resolve the window's current geometry, cheapest source first:
///
///   1. Model/sync truth: floating base or last-sent ledger rect. Covers
///      covering winners too -- sync seeds the covering winner's ledger rect
///      with the screen rect (bw 0), so the screen pin needs no special case
///      here (a redundant covering branch would duplicate that).
///   2. True cache miss: one blocking xcb_get_geometry. Floating windows
///      never retiled; a fallback, not a hot path.
///
/// Returns null when even the fallback fails (window gone).
fn resolveConfigureGeometry(win: u32) ?model_mod.Rect {
    // Model/sync truth: floating base or last-sent ledger rect.
    if (reconcile.truthRect(pipeline.model(), win)) |rect| {
        // Report the border width we actually last sent for this window
        // (the ledger), not the global config default. The two differ before
        // the first reconcile and for per-window overrides; a wrong value here
        // makes clients mis-size themselves.
        const border: u16 = if (!build_options.has_tiling)
            0
        else
            ledger.lastBorderWidthFor(win) orelse core.borderWidth();
        return .{
            .x = rect.x,
            .y = rect.y,
            .width = rect.width,
            .height = rect.height,
            .border_width = border,
        };
    }

    const conn = core.getState().conn;
    return window.getGeometry(conn, win);
}

fn sendSyntheticConfigureNotify(win: u32) void {
    const rect = resolveConfigureGeometry(win) orelse return;
    sendConfigureNotify(win, rect);
}

fn handleManagedConfigureRequest(
    win: u32,
    event: *const xcb.xcb_configure_request_event_t,
    mask: u16,
) void {
    const req: model_mod.ConfigureReq = .{
        .x = if (mask & xcb.XCB_CONFIG_WINDOW_X != 0) event.x else null,
        .y = if (mask & xcb.XCB_CONFIG_WINDOW_Y != 0) event.y else null,
        .width = if (mask & xcb.XCB_CONFIG_WINDOW_WIDTH != 0) event.width else null,
        .height = if (mask & xcb.XCB_CONFIG_WINDOW_HEIGHT != 0) event.height else null,
        .border_width = if (mask & xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH != 0)
            event.border_width
        else
            null,
    };
    const wm = registry.providerOf(.honorConfigureRequest) orelse return;
    switch (wm.honorConfigureRequest.?(pipeline.mut(), win, req)) {
        .geometry_applied => {
            // ICCCM 4.1.5: a border-width-only request applied by the module
            // needs the synthetic ConfigureNotify (the width isn't otherwise
            // observable) AND the reconcile ledger updated so the next reconcile
            // doesn't re-assert the WM width (reverting the honored value).
            if (mask == xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH) {
                noteHonoredBorderWidth(win, event.border_width);
                sendSyntheticConfigureNotify(win);
                return;
            }
            // Don't teleport an off-screen window onto the visible usable area.
            // A parked (off-workspace) or non-current-workspace floating
            // window's ConfigureRequest must update its model rect (done in the
            // module above) but not move the X window, which would flash it
            // onto the current workspace; it is configured when next shown.
            const m = pipeline.model();
            if (model_mod.visibleOn(m, win, m.current))
                sendRequestedConfigure(win, event, mask);
            return;
        },
        .border_only => {
            if (mask != xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH)
                _ = xcb.xcb_configure_window(
                    core.getState().conn,
                    win,
                    xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
                    &[_]u32{event.border_width},
                );
            noteHonoredBorderWidth(win, event.border_width);
        },
        .ignored => {},
    }
    // ICCCM 4.1.5: echo a synthetic ConfigureNotify so the client observes
    // its denied geometry / new border width.
    sendSyntheticConfigureNotify(win);
}

/// Record an honored border width in the reconcile ledger so the next reconcile
/// doesn't re-assert the WM default (reverting the honored value). No-op on
/// non-tiling builds.
fn noteHonoredBorderWidth(win: u32, bw: u16) void {
    if (build_options.has_tiling) ledger.markSentBorderWidth(win, bw);
}

pub fn handleConfigureRequest(event: *const xcb.xcb_configure_request_event_t) void {
    const win = event.window;

    // Fast exit: no geometry fields requested, so skip the managed predicates
    // (stacking-order-only requests from compositors/override-redirect).
    const mask = event.value_mask & geometry_mask;
    if (mask == 0) return;

    // Deny min-size ConfigureRequests from the window being drag-resized.
    if (actions.isResizingWindow(win)) {
        const last = actions.getDragLastRect();
        if (last.width != 0) {
            sendConfigureNotify(win, .{
                .x = last.x,
                .y = last.y,
                .width = last.width,
                .height = last.height,
                .border_width = core.borderWidth(),
            });
        } else {
            sendSyntheticConfigureNotify(win);
        }
        return;
    }

    // isValidManagedWindow, not a bare isManaged: every other consumer of this
    // predicate already filters the invalid-window sentinel first, and one
    // spelling means a chrome XID cannot slip through this path.
    if (core.isModelReady() and query.isValidManagedWindow(win)) {
        handleManagedConfigureRequest(win, event, mask);
        return;
    }

    sendRequestedConfigure(win, event, mask);
}

/// Builds the value list from `event` in XCB_CONFIG_WINDOW_* bit order and
/// issues the ConfigureWindow request.
fn sendRequestedConfigure(
    win: u32,
    event: *const xcb.xcb_configure_request_event_t,
    mask: u16,
) void {
    const fields = .{
        .{ xcb.XCB_CONFIG_WINDOW_X, model_mod.toXcbCoord(event.x) },
        .{ xcb.XCB_CONFIG_WINDOW_Y, model_mod.toXcbCoord(event.y) },
        .{ xcb.XCB_CONFIG_WINDOW_WIDTH, event.width },
        .{ xcb.XCB_CONFIG_WINDOW_HEIGHT, event.height },
        .{ xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, event.border_width },
    };
    var values: [5]u32 = undefined;
    var n: usize = 0;
    inline for (fields) |f| {
        if (mask & f[0] != 0) {
            values[n] = @intCast(f[1]);
            n += 1;
        }
    }
    _ = xcb.xcb_configure_window(core.getState().conn, win, mask, &values);
}
