//! Action dispatch: `executeAction` + `grafted`, the single router every configured
//! action ends in -- the one module both the key path (keys.zig) and the mouse path
//! (mouse.zig) must reach, so a home of its own keeps those two from importing each
//! other. No wire traffic of its own: the close action delegates to the shared ICCCM
//! path in icccm.zig, everything else routes through model/hooks.
const std = @import("std");
const build_options = @import("build_options");

const core = @import("core");
const types = @import("types");
const log = std.log.scoped(.dispatch);
const focus = @import("focus");
/// Primary-column width step per primary-width adjustment press.
const master_width_step: f32 = 0.025;
/// Secondary-column balance step per grow_stack press.
const stack_balance_step: f32 = 0.5;
const action_mod = @import("action");
const pipeline = @import("pipeline");
const query = @import("query");
const window = @import("window");
const diagnostic = @import("diagnostic");
const surfaces = @import("surfaces").Surfaces;
const spawn = @import("spawn");
const process = @import("process");

/// The toggle-bar-position action: re-anchor the bar, then reconcile.
///
/// The reconcile lives here rather than in the bar's renderer because it takes the X
/// grab and re-derives every placement from the new usable area -- a layout decision
/// about the whole session. The ORDER matters: the bar publishes its new screen claim
/// while it moves, and core must see it before the reconcile recomputes placements.
fn toggleBarPosition() void {
    if (comptime !build_options.has_bar) return;
    surfaces.toggleBarSegmentAnchor();

    // One token owns grab+ungrab+flush, so the early return below releases it
    // without having to remember.
    const grab = pipeline.grabScoped();
    defer grab.deinit();
    const current_ws = query.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
        // The bar re-anchor already changed the usable-area claim; re-derive
        // placements even with no current workspace to report, else the claim
        // goes unread and placements stay stale until an unrelated event.
        grab.reconcileNow(.{});
        return;
    };
    const forced_hidden = if (surfaces.barForcedHiddenByFullscreen) |f|
        f(pipeline.state(), current_ws)
    else
        false;
    if (!forced_hidden) grab.reconcileNow(.{});
    window.updateFloatingWindowBorders();
    log.info("Bar position toggled to: {s}", .{@tagName(core.getState().config.bar.bar_position)});
}

/// Closes a window via the shared ICCCM close path (icccm.closeViaProtocol:
/// WM_DELETE_WINDOW, destroy fallback). Kept as the action's named handler so the
/// close_window arm reads as its own intent.
fn closeWindow(win: u32) void {
    window.closeViaProtocol(win);
}

/// Directional actions carry a `Dir`; map it to the signed step used by the tiling ops
/// (`.forward` = +1, `.reverse` = -1). One generic serves both the integer step and the
/// scaled f32 rate, so the two can never disagree about which direction is positive.
inline fn dirSign(comptime T: type, dir: types.Dir) T {
    return if (dir == .forward) 1 else -1;
}

/// Top-level action dispatcher: each action tag routes to its handler inline (single
/// switch, no per-class delegates); errors are handled internally. `pub` for
/// mouse.zig, whose config mouse binds dispatch through it, and for keys.zig.
pub fn executeAction(action: *const types.Action) void {
    switch (action.*) {
        // A `,`-sequence runs steps in strict order: each step fully finishes
        // (for a raw exec step that means waiting for the command to exit, see
        // spawn.execSynchronous) before the next begins.
        .sequence => |acts| for (acts) |*a|
            if (a.* == .exec) spawn.execSynchronous(core.getState().alloc, a.exec) else executeAction(a),
        // Core
        .close_window => if (focus.getFocused()) |win| closeWindow(win),
        .reload_config => process.reload(),
        .reload_hana => process.requestReexec(),
        .dump_state => diagnostic.dumpState(),
        .exec => |cmd| spawn.executeShellCommand(cmd) catch |err|
            log.err("exec failed: {}", .{err}),
        // A `+` batch is fire-and-forget: members launch together, no member waits on
        // another, and execs spawn detached. Exception: a member that is itself a `,`
        // -sequence goes through executeAction's sequence arm, which blocks on its exec
        // children, so a `,`-sequence inside a `+` batch IS awaited, not detached.
        .parallel => |acts| for (acts) |*a| executeAction(a),

        // Fullscreen: keybind path resolves the focused window, then shares the
        // chrome-click transition.
        .toggle_fullscreen => {
            if (pipeline.state().focused) |win| window.command.callHook(.toggleFullscreenWindow, .{win});
        },

        .toggle_floating_window => if (focus.getFocused()) |win|
            grafted(.toggle_floating_window, toggleFloatingWindow, win),
        .cycle_layout => |dir| grafted(.cycle_layout, window.cycleLayoutKind, dirSign(i32, dir)),
        .cycle_variants => |dir| grafted(.cycle_variants, window.stepVariantDir, dirSign(i32, dir)),
        .set_master_width => |dir| window.adjustPrimaryWidthAction(dirSign(f32, dir) * master_width_step),
        .set_master_count => |dir| window.adjustPrimaryCount(dirSign(i32, dir)),
        .grow_stack => |dir| window.adjustSecondaryBalance(dirSign(f32, dir) * stack_balance_step),
        .swap_master => |mode| window.swapPrimaryAction(mode == .focus_swap),
        .move_window_next => window.moveFocused(1),
        .move_window_prev => window.moveFocused(-1),
        .scroll_view => |dir| window.viewportStep(dirSign(i32, dir)),

        // Cycle focus forward/backward. The viewport snap runs as a duty inside the
        // focus transition's single grab (window.snapViewportFocusedDuty), so a cycle
        // that scrolls the viewport is still one grab+reconcile, not focus-then-snap's
        // two; focus.cycleFocus pairs the target with that duty.
        .cycle_focus => |dir| focus.cycleFocus(dir, &window.snapViewportFocusedDuty),

        // Workspaces. A tree without the workspaces module collapses to a single
        // implicit workspace (query.getWorkspaceCount), so these calls are always
        // valid. Dispatch goes through the registry because the module is optional:
        // without it there is no binder and the command no-ops instead of failing to
        // compile.
        .switch_workspace => |ws| window.command.callHook(.switchWorkspace, .{ws}),
        .move_to_workspace => |ws| if (focus.getFocused()) |wid| window.command.callHook(.moveToWorkspace, .{ wid, ws }),
        .toggle_tag => |ws| if (focus.getFocused()) |wid| window.command.callHook(.toggleTag, .{ wid, ws, true }),
        .all_workspaces => window.command.callHook(.allWorkspaces, .{}),
        .pin_window => if (focus.getFocused()) |wid| window.command.callHook(.pinWindow, .{wid}),

        // Bar: visibility, position and chrome-overlay toggles. All three call
        // their hooks directly -- each is a no-op without a surface module, so
        // a `has_bar` guard would repeat a decision `surfaces` already encodes.
        .toggle_bar_visibility => surfaces.setBarState(.toggle_bar_visibility),
        .toggle_bar_position => toggleBarPosition(),
        .toggle_prompt => surfaces.chromeToggleOverlay(),

        // Minimize: minimize, unminimize (LIFO/FIFO), and restore all.
        .minimize_window => window.command.callHook(.minimizeWindow, .{focus.getFocused()}),
        .unminimize => |order| window.command.callHook(.unminimizeOrdered, .{order}),
        .unminimize_all => window.command.callHook(.unminimizeAll, .{}),
    }
}

/// `toggle_floating_window` as a VALUE: `grafted` takes a function pointer, so registry
/// dispatch needs a named entry point rather than an inline `callHook`. `pub` for
/// mouse.zig, whose mouse bind grafts through this too.
pub fn toggleFloatingWindow(win: u32) void {
    window.command.callHook(.toggleFloatingWindow, .{win});
}

/// The one way to run a scaffolded tiling op. `tag` is the action it runs, and the
/// `comptime` check makes `action_mod.needsTilingFocusScaffold` a GATE rather than
/// documentation: grafting a tag the type says does not need it (or renaming an arm so
/// the graft covers a different tag) is a build error, not a runtime surprise. The error
/// sits in the `else` branch because Zig prunes the untaken branch of a comptime-known
/// `if` without analyzing it. `pub` for mouse.zig.
pub inline fn grafted(comptime tag: std.meta.Tag(types.Action), comptime op: anytype, arg: anytype) void {
    comptime if (action_mod.needsTilingFocusScaffold(tag)) {} else @compileError(
        "dispatch.grafted used for an action action_mod.needsTilingFocusScaffold does not declare",
    );
    focus.setSuppressReason(.tiling_operation);
    op(arg);
    focus.beginTilingOpSettle();
}
