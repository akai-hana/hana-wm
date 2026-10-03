//! User input handling
//! Handles keyboard, mouse buttons, pointer motion, and drag operations.

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const restart = @import("restart");
const constants = @import("constants");
const masks = @import("masks");
const log = @import("log");
const window = @import("window");
const tracking = @import("tracking");
const focus = @import("focus");
const xkbcommon = @import("xkbcommon");
const keybind = @import("keybind");
const build_options = @import("build_options");
const pipeline = @import("pipeline");
const actions = @import("actions");
const spawn = @import("spawn");
const diag = @import("diag");
const cursor = @import("cursor");
// Bar hook set; the core-owned `surfaces` composition root, absent-safe.
const surfaces = @import("surfaces").Surfaces;
// `grabKeybindings` lives in events.zig (mutual runtime-only dependency).
const events = @import("events");

const atoms = @import("atoms");
const lifecycle = @import("lifecycle");
const time = @import("time");
// Constants

var xkb_state: ?xkbcommon.XkbState = null;

// The (modifiers, keysym) -> Action dispatch map. Owned here, not by Config,
// to keep the pure config layer X-free (see the rationale in keybind.zig).
// Rebuilt on startup and every config reload (buildKeybinds); the entries
// borrow `*const Action` pointers from the live config's keybindings.
var keybind_resolver: keybind.KeybindResolver = .{};
var resolved_binds: []keybind.ResolvedBind = &.{};

/// Initialises the XKB context, keymap, and key state
/// from the server's current keyboard configuration.
pub fn initXkb(conn: core.Connection) !void {
    xkb_state = try xkbcommon.XkbState.init(conn);
}

/// Tears down XKB state. Must be called after all other deinit steps.
pub fn deinitXkb() void {
    if (xkb_state) |*s| s.deinit();
    xkb_state = null;
}

/// Returns a read-only view of the module-owned XkbState, or null only at boot
/// before initXkb has run and at shutdown after deinitXkb (there is no reload
/// window; see events.zig's reload path). The pointer is invalidated by
/// deinitXkb and must not be cached across it.
///
/// Const, deliberately. Zig has no private fields, so a struct's fields are
/// reachable by anyone holding a pointer to it -- which made the live
/// keycode->keysym table and the reverse index a mutation surface: any module
/// could overwrite a key's keysym or truncate the index, and the dispatch path
/// would read the damage with no way to tell it from a real mapping. Handing
/// out `*const` closes every field but one: `rebuild`, which this module calls
/// through `getXkbStateMut` and which rebuilds both tables as a unit.
pub fn getXkbState() ?*const xkbcommon.XkbState {
    return if (xkb_state) |*s| s else null;
}

/// The one mutable handle on the XKB state, kept inside this module: the
/// mapping-change path needs to replace the tables, and nothing else does.
fn getXkbStateMut() ?*xkbcommon.XkbState {
    return if (xkb_state) |*s| s else null;
}

/// Resolves `keybindings` against the live XKB state and rebuilds the dispatch
/// map. Call once at startup (after `initXkb` and config load) and again on
/// every config reload with the new config's keybindings. No-op without XKB.
pub fn buildKeybinds(keybindings: []types.Keybind) void {
    const state = getXkbState() orelse return;
    const alloc = core.getState().alloc;
    // The compiled list lives here, not in config: it is derived from the live
    // keyboard, and `grabKeybindings` needs it on every regrab (including
    // reloads that did not change the bindings). Rebuilt here so a keyboard
    // change and a binding change take the same path.
    resolved_binds = alloc.realloc(resolved_binds, keybindings.len) catch {
        resolved_binds = &.{};
        return;
    };
    resolved_binds = keybind.resolveKeycodes(keybindings, state, resolved_binds);
    keybind.reportUnresolved(resolved_binds);
    keybind_resolver.rebuildDispatchMap(keybindings, alloc, core.config_rev.rev());
}

/// The keybindings with keycodes resolved against the live XKB state, for
/// `events.grabKeybindings`. Empty when XKB is unavailable (no keyboard to
/// resolve against), which is also when nothing can be grabbed.
pub fn resolvedKeybinds() []const keybind.ResolvedBind {
    return resolved_binds;
}

/// Releases the dispatch map AND the compiled keybind list. Call before the
/// config whose keybindings the entries point into is freed (shutdown).
///
/// The list was allocated by `buildKeybinds` via `alloc.realloc` and this used
/// to free only the dispatch map, leaking the list on every shutdown. The
/// `len != 0` guard is not cosmetic: the initial value is a `&.{}` pointing at
/// a static empty slice, and freeing that would be handing the allocator a
/// pointer it never produced.
pub fn deinitKeybinds() void {
    const alloc = core.getState().alloc;
    keybind_resolver.deinit(alloc);
    if (resolved_binds.len != 0) {
        alloc.free(resolved_binds);
        resolved_binds = &.{};
    }
}

/// Rebuilds the keymap/keysym table after the server changes the keyboard
/// mapping (setxkbmap/xmodmap). `keyboard` is the event's `request` field
/// narrowed to MappingKeyboard; false for the modifier-map and pointer
/// mapping events that arrive through the same type, which are ignored. Keybinding resolution is keysym-indexed, so
/// rebuilding the flat keycode->keysym table keeps existing bindings working
/// under the new layout. However, the per-binding keycodes the key grabs were
/// made with were resolved against the old layout and go stale; re-resolve
/// them from the rebuilt table and re-grab (ungrab existing, then grab new)
/// so keybindings keep firing after the mapping change.
pub fn handleMappingNotify(keyboard: bool) void {
    // Only a KEYBOARD mapping change can invalidate the keycode->keysym table
    // and the key grabs resolved against it. The server also reports
    // modifier-map and pointer-button remaps through this same event, and
    // those are common (`xmodmap` touches both): rebuilding for them threw
    // away working state and made the user pay a full ungrab/regrab storm
    // over a change that cannot have affected any binding. The modifier map
    // is not part of this table, and button remapping is the client's own
    // business.
    if (!keyboard) return;
    const cs = core.getState();
    const state = getXkbStateMut() orelse return;
    state.rebuild(cs.conn);

    // Re-resolve the compiled list from the new table, then atomically re-grab
    // (ungrab all, grab the updated set). `buildKeybinds` is the single place
    // that produces the list, so a mapping change cannot leave the grab path
    // reading a list resolved against the old keyboard.
    buildKeybinds(cs.config.keybindings.items);
    events.grabKeybindings();
}

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
        return;
    };
    const forced_hidden = if (surfaces.barForcedHiddenByFullscreen) |f|
        f(pipeline.model(), current_ws)
    else
        false;
    const no_fullscreen = !forced_hidden;
    if (no_fullscreen) grab.reconcileNow();
    window.updateFloatingWindowBorders();
    window.markBordersFlushed();
    log.info("Bar position toggled to: {s}", .{@tagName(core.getState().config.bar.bar_position)});
}

// Grab setup

/// Grabs mouse buttons on the root window and applies the user's cursor theme.
pub fn setup(conn: core.Connection, screen: core.Screen) void {
    events.grabMouseButtons();
    cursor.Cursor.setupRoot(conn, screen);
    reportUndeliverableMouseBinds();
}

/// Warns about every `[binds]` mouse entry the root grab can never deliver.
///
/// This is the worst failure mode a config surface has: the bind parses, the
/// config loads, `configChanged` sees no change, the user presses the combo
/// and the click simply goes to the client. Nothing anywhere else reports it.
/// De-duplicated by the (modifiers, button) pair, so a dead combo bound three
/// times is reported once, and the message names the binding's index in config
/// order so it can be found.
pub fn reportUndeliverableMouseBinds() void {
    const binds = core.getState().config.mouse_bindings.items;
    // The grab as `setupGrabs` actually makes it, handed to the pure rule so
    // that rule needs no knowledge of the X layer and stays unit-testable.
    const grab: keybind.MouseGrabSpec = .{
        .buttons = &events.mouse_grab_buttons,
        .modifiers = masks.mod_super,
        .lock_bits = masks.lock_bits,
    };
    for (binds, 0..) |mb, i| {
        const reason = keybind.undeliverableMouseBindReason(mb, grab) orelse continue;
        var dup = false;
        for (binds[0..i]) |earlier| {
            if (earlier.button == mb.button and earlier.modifiers == mb.modifiers) dup = true;
        }
        if (dup) continue;
        log.warn(
            "Mouse binding #{} (mods=0x{x:0>4} button={}) can never fire: {s}",
            .{ i + 1, mb.modifiers, mb.button, reason },
        );
    }
}

// Key-dispatch latency instrumentation. Measures the wall-clock time from
// event receipt (entry to handleKeyPress) to the bound action's dispatch,
// accumulated over a window so a periodic summary can be logged. Gated by
// `build_options.profile_key` so release WMs compile it out entirely.
const key_profile = log.WindowedProfiler(
    build_options.profile_key,
    "[KPROF] receive->action last {} keys: avg={d:.0}ns min={d}ns max={d}ns",
    log.info,
);

// Event handlers

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void {
    // Timing: wall-clock from event receipt to the bound action's dispatch.
    // Compiled out when `build_options.profile_key` is false.
    const key_t0: i128 = if (key_profile.enabled) time.monotonicNs() else 0;

    focus.setLastEventTime(event.time);

    const state = getXkbState() orelse {
        log.warn("[KEY] keypress before XKB init; ignoring", .{});
        return;
    };

    const mods = masks.normalizeModifiers(event.state);
    const keysym = state.keycodeToKeysym(event.detail);

    // O(1) dispatch via the (modifiers << 32 | keysym) map built by
    // input.buildKeybinds.
    const matched = keybind_resolver.lookup(mods, keysym, core.config_rev.rev());

    // The chrome overlay owns all key input while active; routing is handled
    // inside it (input flows in, true = consumed, before keybinding dispatch).
    // No `has_bar` guard: `chromeHandleKeypress` is a no-op hook that returns
    // false when no surface module is compiled in, so the flag test was
    // duplicating a decision the `surfaces` type already made.
    if (surfaces.chromeHandleKeypress(event, matched)) return;

    if (matched) |action| {
        // Per-key dispatch logs are `.debug` so release WMs (default log
        // level `.info`) compile them out of the hot path; folding them into
        // a summary keeps tracing available without per-key formatting+write.
        log.debug("[KEY] mods=0x{x} keysym=0x{x} action={s}", .{
            masks.toMask(mods), keysym, @tagName(action.*),
        });
        if (key_profile.enabled) key_profile.note(time.monotonicNs() - key_t0);
        executeAction(action);
    } else if (!mods.isEmpty() or !masks.isModifierKeysym(keysym)) {
        // Bare modifier press (Shift/Ctrl/Alt/Super/Hyper L/R) can never
        // match a binding; staying silent keeps logs free of keystroke noise.
        log.debug("[KEY] mods=0x{x} keysym=0x{x} no binding", .{ masks.toMask(mods), keysym });
    }
}

/// Tracks the event timestamp for focus machinery on release.
/// (Held-key auto-repeat semantics live in xkbcommon's detectable
/// auto-repeat; see there.)
pub fn handleKeyRelease(event: *const xcb.xcb_key_release_event_t) void {
    focus.setLastEventTime(event.time);
}

/// Dispatches a priority-ordered button-press event, splitting the two named
/// paths: a plain click on the bar window routes to the bar; every other
/// press goes through the managed-window mouse machinery.
pub fn handleButtonPress(event: *const xcb.xcb_button_press_event_t) void {
    focus.setLastEventTime(event.time);
    const super_held = (event.state & masks.mod_super) != 0;
    const clicked_window = if (event.child != 0) event.child else event.event;
    // The bar path: a plain (non-Super) click whose target is the bar window.
    // The bar selects BUTTON_PRESS directly rather than through the
    // Super+Button grab, so a plain click arrives ungrabbed; route it to the bar
    // and skip the managed-window/replay-pointer machinery built for the
    // synchronous grab a client-window click goes through. Super-held clicks
    // fall through to the normal mouse-binding/drag path. Previously two
    // wrappers stood between this and the surfaces hook, for one call site.
    if (!super_held and surfaces.isBarWindow(clicked_window)) {
        surfaces.handleButtonPress(event);
        return;
    }
    handleWindowButtonPress(event, super_held, clicked_window);
}

/// The facts a button press is routed on, taken as FIELDS so the routing rule
/// is a pure function of them: the dispatch below cannot be exercised without
/// an X server and a live grab, but this can.
pub const MousePress = struct {
    /// Super was held, i.e. the press came through the root grab rather than
    /// being delivered to a client.
    super_held: bool,
    button: u8,
    /// The press landed on a managed, non-root window.
    target_managed: bool,
    /// A config mouse bind matched and has ALREADY been dispatched (which
    /// released the grab as part of dispatching). Set by the caller, in the
    /// order `classifyMousePress` documents, because the lookup needs the live
    /// config and the managed-window id.
    bind_fired: bool,
};

/// What a press should do, and -- the part that used to be implicit -- what
/// happens to the grab afterwards. Every arm of the dispatch below is one of
/// these, and the dispatch is exhaustive with no `else`, so a new arm that
/// forgets to settle the grab is a compile error rather than a frozen
/// keyboard and pointer.
pub const MouseIntent = union(enum) {
    /// Super+scroll: a viewport bind, or a plain release when unbound. Checked
    /// before the managed-window guard because scroll binds do not target a
    /// window, so they must still fire over the desktop and the bar.
    scroll_bind,
    /// The press landed on the root or an unmanaged window.
    unmanaged,
    /// Plain click on a managed window: focus it.
    focus_click,
    /// A config mouse bind already ran; the grab was released with it.
    bound_action,
    /// Super+left/right with no bind: start a drag and keep the grab.
    start_drag,
    /// Super+any other button, unbound: replay as a plain click, which is what
    /// thaws both devices. Omitting it is how a grab silently freezes input.
    replay,
};

/// The mouse routing rule, as a pure function.
///
/// The ORDER here is the whole contract, and it is why this is worth pinning:
/// scroll binds precede the managed-window guard; focus precedes the bind
/// lookup; the drag and the replay fallback are both "Super and unbound", and
/// only the button number tells them apart.
pub fn classifyMousePress(p: MousePress) MouseIntent {
    if (p.super_held and
        (p.button == constants.mouse_button_scroll_up or p.button == constants.mouse_button_scroll_down))
    {
        // A fired scroll bind reports the SAME intent as any other fired bind,
        // so every intent has exactly one grab outcome and a path cannot
        // release twice (or, once the discipline is trusted, not at all).
        return if (p.bind_fired) .bound_action else .scroll_bind;
    }
    if (!p.target_managed) return .unmanaged;
    if (!p.super_held) return .focus_click;
    if (p.bind_fired) return .bound_action;
    if (p.button == constants.mouse_button_left or p.button == constants.mouse_button_right)
        return .start_drag;
    return .replay;
}

/// The managed-window path: scroll-wheel binds, focus, config mouse-bind
/// lookup, drag, and the unbound-Super replay fallback.
fn handleWindowButtonPress(event: *const xcb.xcb_button_press_event_t, super_held: bool, clicked_window: u32) void {
    const cs = core.getState();
    const mods = masks.toMask(masks.normalizeModifiers(event.state));

    const managed_window = window.findManagedWindow(cs.conn, clicked_window, tracking.isManaged);
    const target_managed = clicked_window != cs.root and managed_window != 0;

    // A scroll bind is looked up FIRST, with window 0, because it does not
    // target a window and must fire over the desktop and the bar too; every
    // other bind targets the clicked window, which is not known to be managed
    // until the lookup above has run. `classifyMousePress` documents the order.
    const scroll_bind = super_held and (event.detail == constants.mouse_button_scroll_up or
        event.detail == constants.mouse_button_scroll_down);
    const bind_fired = if (scroll_bind)
        tryConfigMouseBind(mods, event.detail, 0, event.time)
    else if (target_managed and super_held)
        tryConfigMouseBind(mods, event.detail, managed_window, event.time)
    else
        false;

    const intent = classifyMousePress(.{
        .super_held = super_held,
        .button = event.detail,
        .target_managed = target_managed,
        .bind_fired = bind_fired,
    });

    // Exhaustive, no `else`: an arm that forgets to settle the grab, or a new
    // intent, stops the build.
    switch (intent) {
        .scroll_bind, .unmanaged, .replay => releaseGrab(event.time),
        .focus_click => {
            focus.grabFocus(managed_window, .mouse_click);
            releaseGrab(event.time);
        },
        // The bind dispatch already released the grab.
        .bound_action => {},
        .start_drag => {
            if (build_options.has_floating) actions.startDrag(managed_window, event.detail, event.root_x, event.root_y);
            keepDragGrab(event.time);
        },
    }
}

/// Stops any active drag and updates the last event timestamp.
pub fn handleButtonRelease(event: *const xcb.xcb_button_release_event_t) void {
    focus.setLastEventTime(event.time);
    // Releases on the bar window terminate a segment scrub (the bar clears
    // its drag anchor). Routed before the managed-window path, as clicks are.
    if (surfaces.isBarWindow(event.event)) {
        surfaces.handleButtonRelease(event);
        return;
    }
    if (build_options.has_floating and actions.isDragging()) actions.stopDrag();
}

/// Forwards motion to the drag engine and clears focus suppression.
/// Raw PointerMotion is coalesced upstream (events.handleXcbEvents collapses
/// runs to the last event), so this runs at most once per poll wakeup.
pub fn handleMotionNotify(event: *const xcb.xcb_motion_notify_event_t) void {
    focus.setLastEventTime(event.time);

    // Press-hold motion on the bar window feeds the scrub-drag path: it is
    // routed before the managed-window drag engine, which targets a client
    // window grab, never the bar.
    if (surfaces.isBarWindow(event.event)) {
        surfaces.handleButtonMotion(event);
        return;
    }

    if (build_options.has_floating and actions.isDragging()) {
        actions.updateDrag(event.root_x, event.root_y);
        return;
    }

    focus.setSuppressReason(.none);
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
fn executeAction(action: *const types.Action) void {
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
        // keep running after the batch moves on.
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
/// that direction.
inline fn grafted(comptime tag: std.meta.Tag(types.Action), comptime op: anytype, arg: anytype) void {
    comptime if (types.needsTilingFocusScaffold(tag)) {} else @compileError(
        "input.grafted used for an action types.needsTilingFocusScaffold does not declare",
    );
    focus.setSuppressReason(.tiling_operation);
    op(arg);
    focus.beginTilingOpSettle();
}

// Diagnostics

/// Logs a full WM state snapshot at info level. Used for diagnostics only.

// Helpers

/// Last entry in `binds` matching (mods, button), or null.
///
/// The scan deliberately does NOT stop at the first match: the last entry wins,
/// and every entry it shadows is reported through the same reporter the
/// keyboard table uses. Taking the first match instead made one config mistake
/// a warning on a key and silence on a button, and made the winner depend on
/// file order in one path but not the other.
///
/// Pure over the slice (the only side effect is the warning) so the policy is
/// testable without a live core state.
pub fn findMouseBind(
    binds: []const types.MouseBind,
    mods: u16,
    button: u8,
) ?*const types.MouseBind {
    var found: ?*const types.MouseBind = null;
    for (binds, 0..) |*mb, i| {
        if (mb.modifiers != mods or mb.button != button) continue;
        if (found != null) keybind.logShadowConflict("Mouse binding", i, mods, "button", button);
        found = mb;
    }
    return found;
}

/// Searches config mouse bindings for a modifier+button match and executes it.
/// Returns true and releases the grab if a binding is found, false otherwise.
fn tryConfigMouseBind(mods: u16, button: u8, win: u32, ts: u32) bool {
    // Linear scan is intentional: mouse bindings are few (~5-10), hash overhead not worth it.
    const mb = findMouseBind(core.getState().config.mouse_bindings.items, mods, button) orelse
        return false;

    // Most mouse binds execute against the keyboard-focused window
    // (executeAction); toggle_floating_window is inherently per-window
    // and so targets the CLICKED window instead.
    switch (mb.action) {
        .toggle_floating_window => grafted(.toggle_floating_window, actions.toggleFloating, win),
        else => executeAction(&mb.action),
    }
    releaseGrab(ts);
    return true;
}

/// Shared tail for releasing grab sequences. The two callers differ only in
/// the pointer mode: REPLAY_POINTER (release the grab, let the click through)
/// vs ASYNC_POINTER (keep the grab for drag tracking).
inline fn finishGrab(ts: u32, pointer_mode: c_uint) void {
    const conn = core.getState().conn;
    _ = xcb.xcb_allow_events(conn, pointer_mode, ts);
    _ = xcb.xcb_allow_events(conn, xcb.XCB_ALLOW_ASYNC_KEYBOARD, ts);
    _ = xcb.xcb_flush(conn);
}

/// Releases both SYNC grabs acquired on Super+click, replaying the pointer so
/// the click reaches the app underneath. Only safe for click paths that don't
/// need to keep tracking the pointer afterward; NOT for drag start; use
/// keepDragGrab. Always pass event.time, never XCB_CURRENT_TIME.
inline fn releaseGrab(ts: u32) void {
    finishGrab(ts, xcb.XCB_ALLOW_REPLAY_POINTER);
}

/// Un-freezes the pointer for a drag while keeping the Super+Button grab
/// engaged: AsyncPointer resumes delivery without replaying or ending the
/// grab, so MotionNotify/ButtonRelease keep reaching us. The grab ends on
/// release; the keyboard grab drops immediately. Always pass event.time.
inline fn keepDragGrab(ts: u32) void {
    finishGrab(ts, xcb.XCB_ALLOW_ASYNC_POINTER);
}
