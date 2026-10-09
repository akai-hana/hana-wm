//! Window-layer event handlers, split out of `window.zig`.
//!
//! Three event classes in one file, each self-contained:
//!
//!   1. CONFIGURE_REQUEST — client-requested geometry/border-width
//!      handling that answers the CLIENT (protocol duty), not layout.
//!      Honored requests route through the window-module hook
//!      (`honorConfigureRequest`); denied/tiled requests echo the applied
//!      geometry with a synthetic ConfigureNotify (ICCCM 4.1.5).
//!   2. CLIENT_MESSAGE — EWMH fullscreen requests from applications (the
//!      pager / native-fullscreen side of the fullscreen protocol; the
//!      model transition itself is actions/covering.zig). Owns the
//!      warn-once latches: a looping pager would otherwise flood the log,
//!      and the latches reset with the rest of the window layer's init
//!      discipline (window.init calls `reset`).
//!   3. CROSSING — Enter/LeaveNotify handling: hover focus and crossing
//!      suppression. The focus protocol itself (prepare/apply,
//!      suppression state) stays in protocol/focus.zig.
//!
//! `window.zig` re-exports the four public handlers as the event dispatch
//! surface events.zig's table binds. (Formerly three separate files
//! merged back 2026-10-09: all three were window-internal, consumed only
//! by window.zig, and split for event-class organization rather than any
//! cycle or layer boundary.)

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const log = @import("log");
const pipeline = @import("pipeline");
const build_options = @import("build_options");
const ledger = @import("ledger");
const reconcile = @import("reconcile");
const actions = @import("actions");
const model_mod = @import("model");
const atoms = @import("atoms");
const focus = @import("focus");
const query = @import("query");
const window = @import("window");
const registry = @import("registry");

// ---------------------------------------------------------------------------
// 1. ConfigureRequest compliance.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// 2. EWMH ClientMessage.
// ---------------------------------------------------------------------------

const State = struct {
    // Warn-once latches for client-message diagnostics (see
    // handleClientMessage): a looping pager would otherwise flood the log.
    // One latch per message class -- two unrelated warnings sharing a latch
    // meant whichever fired first silenced the other for the process's life.
    // Reset together via reset() so an init() re-arms every diagnostic.
    warned_unmanaged_fs_request: bool = false,
    warned_active_ignore: bool = false,
    warned_unmanaged_state: bool = false,
};

var state: State = .{};

/// Re-arm every warn latch (called from window.init's reset discipline).
pub fn reset() void {
    state = .{};
}

/// Logs `fmt` at warn level at most once per process, arming `latch` (a field
/// of `State`, so a reset() re-arms every diagnostic together). The
/// client-message handlers are fed by EWMH pagers that can loop forever, and
/// one shared latch between two message classes meant the second warning could
/// never fire after the first.
fn warnOnce(latch: *bool, comptime fmt: []const u8, args: anytype) void {
    if (latch.*) return;
    latch.* = true;
    log.warn(fmt, args);
}

pub fn handleClientMessage(event: *const xcb.xcb_client_message_event_t) void {
    if (event.format != 32) return;

    // Unhonorable pager requests are dropped silently otherwise; each warn
    // fires once per process so a looping pager cannot flood the log.
    // `_NET_WM_FULLSCREEN_REQUEST` is a SEPARATE EWMH message from
    // `_NET_WM_STATE`, and it is the one browsers use for native video
    // fullscreen. Its layout is: window field = the window, data32[0] = the
    // intended end state (1 enter, 0 leave). Dropping it -- as the pre-fix
    // handler did, since the atom appeared nowhere in the tree -- is why F
    // did nothing in a YouTube player while hana's own Mod+F worked.
    const net_fs_request = atoms.getAtomOrZero("_NET_WM_FULLSCREEN_REQUEST");
    if (net_fs_request != 0 and event.type == net_fs_request) {
        const win = event.window;
        if (!query.isValidManagedWindow(win)) {
            warnOnce(
                &state.warned_unmanaged_fs_request,
                "Ignoring _NET_WM_FULLSCREEN_REQUEST for unmanaged window 0x{x}",
                .{win},
            );
            return;
        }
        // Only 0 and 1 are defined; anything else is dropped rather than
        // guessed at, since guessing means entering or leaving fullscreen on
        // a client that asked for neither.
        const target = switch (event.data.data32[0]) {
            0 => false,
            1 => true,
            else => return,
        };
        // PIPELINE: model-path transition; the transition stays on the single
        // source of truth.
        actions.fullscreenSetWindow(win, target);
        return;
    }

    const net_active = atoms.getAtomOrZero("_NET_ACTIVE_WINDOW");
    if (net_active != 0 and event.type == net_active) {
        warnOnce(
            &state.warned_active_ignore,
            "Ignoring _NET_ACTIVE_WINDOW request for 0x{x}: EWMH activation is not implemented",
            .{event.window},
        );
        return;
    }

    const net_wm_state = atoms.getAtomOrZero("_NET_WM_STATE");
    if (net_wm_state == 0 or event.type != net_wm_state) return;

    const fs_atom = atoms.getAtomOrZero("_NET_WM_STATE_FULLSCREEN");
    if (fs_atom == 0) return;
    const prop1 = event.data.data32[1];
    const prop2 = event.data.data32[2];
    if (prop1 != fs_atom and prop2 != fs_atom) return;

    const win = event.window;
    if (!query.isValidManagedWindow(win)) {
        warnOnce(
            &state.warned_unmanaged_state,
            "Ignoring _NET_WM_STATE request for unmanaged window 0x{x}",
            .{win},
        );
        return;
    }

    const action = event.data.data32[0];
    // EWMH _NET_WM_STATE action codes, carried in data32[0]. `want` is
    // the target state for the SET paths (add/remove); `toggle` is null
    // -- a genuine flip, the keybind path's meaning.
    const ewmh_state_add: u32 = 1;
    const ewmh_state_remove: u32 = 0;
    const ewmh_state_toggle: u32 = 2;
    const want: ?bool = switch (action) {
        ewmh_state_add => true,
        ewmh_state_remove => false,
        ewmh_state_toggle => null,
        else => return,
    };
    // PIPELINE: model-path transition; the transition stays on the single
    // source of truth. `fullscreenSetWindow` re-checks want-vs-current
    // itself and computes the covering state inside the same grab, so no
    // covering pre-scan or explicit guard is needed here -- one covering
    // scan per request instead of two.
    actions.fullscreenSetWindow(win, want);
}

// ---------------------------------------------------------------------------
// 3. Enter/Leave crossing.
// ---------------------------------------------------------------------------

inline fn suppressSpawnCrossing(root_x: i16, root_y: i16) bool {
    if (focus.getSuppressReason() != .window_spawn) return false;
    // The spawn snapshot (focus.spawnCursor()) is taken by
    // handleMapRequest
    // when the spawn's MapRequest arrives. Mapping a new window under the
    // stationary cursor produces a PAIR of synthetic crossings, both carrying
    // the spawn's root coordinates: the enter into the spawned window, and the
    // return crossing into the window it displaced (which, when the spawned
    // window immediately parks offscreen, is the previous focus). A one-shot
    // guard only drops the first, letting the return crossing re-steal focus
    // from the just-spawned window via mouse_enter.
    //
    // Keep the guard armed while crossings stay at the spawn pixel: only a
    // genuine pointer move (different coordinates) is a real hover and may
    // clear it. A cursor parked where it was when the app launched can't hover
    // a different window at that same pixel until it moves, which is the
    // acceptable price for not stealing focus during the spawn's layout.
    const cursor = focus.spawnCursor();
    if (root_x == cursor.x and root_y == cursor.y) return true;
    focus.setSuppressReason(.none);
    return false;
}

/// Shared guard tail for the EnterNotify/LeaveNotify handlers, run after each
/// handler's event-shape filter (mode/detail/root): a floating drag owns the
/// pointer, and a spawn's synthetic crossing (the window mapping under the
/// parked cursor) must be suppressed. Returns true when the crossing should
/// be dropped.
inline fn crossingShouldDrop(root_x: i16, root_y: i16) bool {
    if (actions.isDragging()) return true;
    return suppressSpawnCrossing(root_x, root_y);
}

/// Attempt to focus `win` via the hover (EnterNotify) path.
///
/// Guards against workspace membership and hidden state before calling
/// focus.grabFocus(.mouse_enter). The .mouse_enter reason is the direct
/// EnterNotify path: lightweight, no raise, no confirm.
inline fn maybeFocusWindow(win: u32) void {
    // In all-view mode every window is visible on the current workspace
    // regardless of its tag mask, so hover must be able to focus it too; a
    // bare membership check made all-view windows un-focusable by ENTER.
    if (!query.isOnCurrentWorkspace(win) and !pipeline.model().all_view_active) return;
    if (registry.callHookBool(.isWindowHidden, .{ pipeline.model(), win })) return;
    focus.grabFocus(win, .mouse_enter);
}

pub fn handleEnterNotify(event: *const xcb.xcb_enter_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL or
        event.detail == xcb.XCB_NOTIFY_DETAIL_INFERIOR)
        return;
    if (crossingShouldDrop(event.root_x, event.root_y)) return;
    if (focus.shouldSuppressEnterNotify()) return;
    maybeFocusWindow(window.findManagedWindow(core.getState().conn, event.event, query.isManaged));
}

pub fn handleLeaveNotify(event: *const xcb.xcb_leave_notify_event_t) void {
    focus.setLastEventTime(event.time);
    if (event.event != core.getState().root) return;
    if (event.mode != xcb.XCB_NOTIFY_MODE_NORMAL) return;
    if (crossingShouldDrop(event.root_x, event.root_y)) return;
    // When child is zero the pointer left to an area not covered by any window.
    if (event.child == 0) return;
    // Guard against unmanaged subwindows (e.g. embedded GTK widgets): a root
    // LeaveNotify with non-zero child doesn't guarantee a managed toplevel.
    // Walk up to the managed toplevel, consistent with handleEnterNotify's
    // findManagedWindow.
    maybeFocusWindow(window.findManagedWindow(core.getState().conn, event.child, query.isManaged));
}
