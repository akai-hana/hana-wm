//! The action dispatcher: the single router every configured action
//! (keybind, mouse bind, sequence, batch) ends in. Split out of
//! input.zig (review 05-input round 2) so mouse.zig can dispatch
//! config mouse binds without importing input.zig -- which re-exports
//! mouse's own handlers, an import cycle. Key intake (the XKB state
//! and the (modifiers, keysym) -> Action dispatch map) stays in
//! input.zig, which re-exports executeAction from here so its
//! key dispatch and the input tests keep one unchanged surface.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const restart = @import("restart");
const constants = @import("constants");
const log = @import("log");
const window = @import("window");
const focus = @import("focus");
const pipeline = @import("pipeline");
const actions = @import("actions");
const spawn = @import("spawn");
const diag = @import("diag");
const lifecycle = @import("lifecycle");
const atoms = @import("atoms");
const tracking = @import("tracking");
// Bar hook set; the core-owned `surfaces` composition root, absent-safe.
const surfaces = @import("surfaces").Surfaces;

/// The toggle-bar-position action: re-anchor the bar, then reconcile.
///
/// The reconcile lives here rather than in the bar's renderer (20.2). It takes
/// the X grab and re-derives every window placement from the new usable area,
/// which is a layout decision about the whole session, not something a
/// rendering module should be reaching for on its own account. The order
/// matters and is the reason this is one function: the bar publishes its new
/// screen claim while it moves, and that claim has to be visible to core
/// before the reconcile recomputes placements from it.
fn toggleBarPosition() void {
    surfaces.toggleBarSegmentAnchor();

    // One token owns grab+ungrab+flush, so the early return below (and any
    // future one) releases it without having to remember.
    const grab = pipeline.grabScoped();
    defer grab.deinit();
    const current_ws = tracking.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        window.markBordersFlushed();
        // The bar re-anchor already changed the usable-area claim; re-derive
        // placements from it even when there is no current workspace to
        // report: a bare early return left the bar-anchored claim unread and
        // placements stale until an unrelated event reconciled.
        grab.reconcileNow(.{});
        return;
    };
    const forced_hidden = if (surfaces.barForcedHiddenByFullscreen) |f|
        f(pipeline.model(), current_ws)
    else
        false;
    const no_fullscreen = !forced_hidden;
    if (no_fullscreen) grab.reconcileNow(.{});
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    log.info("Bar position toggled to: {s}", .{@tagName(core.getState().config.bar.bar_position)});
}

// Window operations

/// Closes a window gracefully via WM_DELETE_WINDOW (ICCCM §4.1.2.7), falling
/// back to xcb_destroy_window for clients that don't advertise the protocol.
/// The timestamp in data32[1] is the time passed to the client per §4.1.2.7.
fn closeWindow(win: u32) void {
    const conn = core.getState().conn;
    if (window.supportsWMDeleteCached(conn, win)) blk: {
        const protocols_atom = atoms.getAtomCached("WM_PROTOCOLS") orelse break :blk;
        const delete_atom = atoms.getAtomCached("WM_DELETE_WINDOW") orelse break :blk;

        var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
        event.response_type = xcb.XCB_CLIENT_MESSAGE;
        event.format = 32;
        event.window = win;
        event.type = protocols_atom;
        event.data.data32[0] = delete_atom;
        event.data.data32[1] = focus.getLastEventTime();

        _ = xcb.xcb_send_event(conn, 0, win, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&event));
        return;
    }
    _ = xcb.xcb_destroy_window(conn, win);
}

// Action dispatch

/// Directional actions carry a `Dir`; map it to the signed step used by the
/// tiling ops (`.forward` = +1, `.reverse` = -1). One generic serves both the
/// integer step and the scaled f32 rate, so the two can never disagree about
/// which direction is positive.
inline fn dirSign(comptime T: type, dir: types.Dir) T {
    return if (dir == .forward) 1 else -1;
}

/// Top-level action dispatcher. Routes each action tag to its handler inline
/// (single switch, no per-class delegates). Errors are handled internally.
/// `pub` for mouse.zig, whose config mouse binds dispatch through it
/// (input.zig re-exports it for its own key dispatch and tests).
pub fn executeAction(action: *const types.Action) void {
    switch (action.*) {
        // A `,`-sequence runs steps in strict order: each step fully finishes
        // (for a raw exec step, that means waiting until the command exits,
        // see spawn.execSynchronous) before the next one begins.
        .sequence => |acts| for (acts) |*a|
            if (a.* == .exec) spawn.execSynchronous(a.exec) else executeAction(a),
        // Core
        .close_window => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => lifecycle.reload(),
        .reload_hana => restart.requestReexec(),
        .dump_state => diag.dumpState(),
        .exec => |cmd| spawn.executeShellCommand(cmd) catch |err|
            log.err("exec failed: {}", .{err}),
        // A `+` batch is fire-and-forget: members are launched together, no
        // member waits on another, and execs spawn as detached children that
        // keep running after the batch moves on. Nesting exception: a member
        // that is itself a `,`-sequence is dispatched through executeAction's
        // sequence arm, which blocks on that sequence's exec children via
        // spawn.execSynchronous -- so a `,`-sequence inside a `+` batch is
        // awaited, not detached.
        .parallel => |acts| for (acts) |*a| executeAction(a),

        // Fullscreen: keybind path resolves the focused window, then shares
        // the chrome-click transition.
        .toggle_fullscreen => {
            if (pipeline.model().focused) |win| actions.fullscreenToggleWindow(win);
        },

        .toggle_floating_window => if (focus.getFocused()) |win|
            grafted(.toggle_floating_window, actions.toggleFloating, win),
        .cycle_layout => |dir| grafted(.cycle_layout, actions.cycleLayoutKind, dirSign(i32, dir)),
        .cycle_variants => |dir| grafted(.cycle_variants, actions.stepVariantDir, dirSign(i32, dir)),
        .set_master_width => |dir| actions.adjustPrimaryWidthAction(dirSign(f32, dir) * constants.master_width_step),
        .set_master_count => |dir| actions.adjustPrimaryCount(dirSign(i32, dir)),
        .grow_stack => |dir| actions.adjustSecondaryBalance(dirSign(f32, dir) * constants.stack_balance_step),
        .swap_master => |mode| actions.swapPrimaryAction(mode == .focus_swap),
        .move_window_next => actions.moveFocused(1),
        .move_window_prev => actions.moveFocused(-1),
        .scroll_view => |dir| actions.viewportStep(dirSign(i32, dir)),

        // Cycle focus forward/backward. The viewport snap runs as a duty
        // inside the focus transition's single grab (see
        // actions.snapViewportFocusedDuty), so a cycle that scrolls the
        // viewport is still one grab+reconcile, not focus-then-snap's two --
        // and 10.10's cycleFocus pairs the target with that duty, so the
        // pairing is no longer this call site's responsibility.
        .cycle_focus => |dir| focus.cycleFocus(dir, &actions.snapViewportFocusedDuty),

        // Workspaces. workspaces.zig self-gates to a single implicit
        // workspace when core.getState().config.workspaces.enabled is false,
        // so these calls are always valid regardless of that setting.
        .switch_workspace => |ws| actions.switchTo(ws),
        .move_to_workspace => |ws| if (focus.getFocused()) |wid| actions.moveWindowTo(wid, ws),
        .toggle_tag => |ws| if (focus.getFocused()) |wid| actions.tagToggle(wid, ws, true),
        .all_workspaces => actions.allViewToggle(),
        .pin_window => if (focus.getFocused()) |wid| actions.pinToggle(wid),

        // Bar: visibility toggle, position toggle, and chrome-overlay toggle.
        // The three bar-chrome actions call their hooks directly: each is a
        // no-op without a surface module, so guarding them with `has_bar`
        // repeated a decision the `surfaces` type already encodes.
        .toggle_bar_visibility => surfaces.setBarState(.toggle_bar_visibility),
        .toggle_bar_position => toggleBarPosition(),
        .toggle_prompt => surfaces.chromeToggleOverlay(),

        // Minimize: minimize, unminimize (LIFO/FIFO), and restore all.
        .minimize_window => actions.minimize(focus.getFocused()),
        .unminimize => |order| actions.restoreOrdered(order),
        .unminimize_all => actions.restoreAll(),
    }
}

/// The one way to run a scaffolded tiling op. `tag` is the action it runs, and
/// the `comptime` check makes `types.needsTilingFocusScaffold` a GATE rather
/// than documentation: grafting a tag the type says does not need it (or
/// renaming an arm so the graft silently covers a different tag) is a build
/// error, not a runtime surprise.
///
/// The error sits in the `else` branch because Zig prunes the untaken branch
/// of a comptime-known `if` without analyzing it: `if (!cond) @compileError(..)`
/// is dead code in exactly the case it exists to catch, and was verified to
/// compile clean. The converse -- a tag declared as needing the scaffold but
/// dispatched through a plain arm -- is invisible from here, so the
/// `tiling scaffold table matches the dispatcher's grafted set` test closes
/// that direction. `pub` for mouse.zig, whose toggle_floating_window
/// mouse binds graft through it.
pub inline fn grafted(comptime tag: std.meta.Tag(types.Action), comptime op: anytype, arg: anytype) void {
    comptime if (types.needsTilingFocusScaffold(tag)) {} else @compileError(
        "dispatch.grafted used for an action types.needsTilingFocusScaffold does not declare",
    );
    focus.setSuppressReason(.tiling_operation);
    op(arg);
    focus.beginTilingOpSettle();
}
