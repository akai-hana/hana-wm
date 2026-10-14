//! Raw X input -> configured actions: the single router the event loop hands
//! key, button, and motion events to. Owns the live XKB state and the
//! (modifiers, keysym) -> Action dispatch map (rebuilt on startup and on config
//! reload or keyboard-mapping change), and the action dispatcher every
//! configured action (keybind, mouse bind, sequence, batch) ends in
//! (executeAction/grafted, re-merged from dispatch.zig 2026-10-10). Mouse
//! intake -- the button/motion handlers, press classification, and drag
//! routing -- lives in mouse.zig and is re-exported below (mouse's config
//! binds dispatch through this module, a lazy input<->mouse import cycle in
//! (the focus/focus_commit cycle dissolved 2026-10-10); key dispatch stays here (the
//! Super+click grab itself is installed by `grabs.grabMouseButtons`,
//! sequenced by main after `setup`).
//! Delegates to keybind.zig for resolution, surfaces for chrome routing,
//! actions for tiling/floating work.
const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const masks = @import("masks");
const log = @import("log");
const focus = @import("focus");
const xkbcommon = @import("xkbcommon");
const keybind = @import("keybind");
const build_options = @import("build_options");
// Bar hook set; the core-owned `surfaces` composition root, absent-safe.
const surfaces = @import("surfaces").Surfaces;
// Grab installation lives in grabs.zig, which reads this module's resolved
// keybind list -- so this module must NOT import it back. The two places that
// used to (the mouse grab at setup, the regrab after a keyboard mapping
// change) are sequenced by their callers instead: main.zig and events.zig
// import both sides, which is where the order belongs anyway.

const time = @import("time");
const constants = @import("constants");
const action_mod = @import("action");
const window = @import("window");
const pipeline = @import("pipeline");
const actions = @import("actions");
const spawn = @import("spawn");
const diag = @import("diag");
const atoms = @import("atoms");
const query = @import("query");
const lifecycle = @import("lifecycle");

// Mouse intake (button/motion handlers, press classification, config
// mouse-bind execution, and the Super+click grab-settle helpers) lives in
// mouse.zig since review 05-input Phase 6. Re-exported here so the
// events.zig dispatch table, main.setup, and the input tests keep their
// single unchanged surface. A named module import (not a relative
// `@import("mouse.zig")`): mouse.zig then wires its own dependency
// edges from its own root instead of borrowing this file's import
// table, so the two modules stay decoupled.
const mouse = @import("mouse");
pub const MousePress = mouse.MousePress;
pub const MouseIntent = mouse.MouseIntent;
pub const classifyMousePress = mouse.classifyMousePress;
pub const handleButtonPress = mouse.handleButtonPress;
pub const handleButtonRelease = mouse.handleButtonRelease;
pub const handleMotionNotify = mouse.handleMotionNotify;
pub const findMouseBind = mouse.findMouseBind;

// Constants

var xkb_state: ?xkbcommon.XkbState = null;

// The (modifiers, keysym) -> Action dispatch map. Owned here, not by Config,
// to keep the pure config layer X-free (see the rationale in keybind.zig).
// Rebuilt on startup and every config reload (buildKeybinds); the entries
// borrow `*const Action` pointers from the live config's keybindings.
var keybind_resolver: keybind.KeybindResolver = .{};
var resolved_binds: []keybind.ResolvedBind = &.{};
// Two derived views of the same config bindings, deliberately not merged into
// one array: `resolved_binds` is the KEYCODE view (config order, derived from
// the live XKB state, read by the grab path and the unresolved-keysym report)
// and the resolver's entries are the DISPATCH view (sorted by packed key,
// no keycode, read on every keypress). Merging them would make keycode
// resolution and dispatch building share one buffer and one failure path --
// today a failed realloc keeps the previous grabs working while a failed
// dispatch build fails closed -- to save one allocation. Each list's own
// rebuild failure mode is stated where it happens. Two lists, one source
// (the config's keybindings), no fact stored twice.

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
fn getXkbState() ?*const xkbcommon.XkbState {
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
    resolved_binds = alloc.realloc(resolved_binds, keybindings.len) catch |err| {
        // Do NOT clobber resolved_binds on failure: the old allocation is now
        // the only copy, and overwriting it here leaked it and silently
        // emptied the compiled list -> the next keypress grabbed nothing until
        // a keymap event. Keep the old set and tell the user.
        log.warn("buildKeybinds: realloc for {} bindings failed ({}); keeping the old set", .{ keybindings.len, err });
        return;
    };
    keybind.resolveKeycodes(keybindings, state, resolved_binds);
    keybind.reportUnresolved(resolved_binds);
    keybind_resolver.rebuildDispatchMap(keybindings, alloc, core.config_rev.rev());
}

/// The keybindings with keycodes resolved against the live XKB state, for
/// `grabs.grabKeybindings`. Empty when XKB is unavailable (no keyboard to
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
/// mapping events that arrive through the same type, which are ignored.
/// Keybind resolution is keysym-indexed, so rebuilding the flat keycode->keysym
/// table keeps existing bindings working under the new layout. However, the
/// per-binding keycodes the key grabs were made with were resolved against the
/// old layout and go stale; re-resolve them from the rebuilt table and re-grab
/// (ungrab existing, then grab new) so keybindings keep firing after the
/// mapping change.
/// Returns true when the keycodes changed under it, i.e. when the root key
/// grabs (taken with the OLD keycodes) are now stale and the caller must
/// re-grab. Returns false for the modifier-map and pointer-button remaps that
/// arrive through the same event: those are common (`xmodmap` touches both),
/// and rebuilding for them threw away working state and made the user pay a
/// full ungrab/regrab storm over a change that cannot have affected any
/// binding. The modifier map is not part of the keycode->keysym table, and
/// button remapping is the client's own business.
pub fn handleMappingNotify(keyboard: bool) bool {
    if (!keyboard) return false;
    const cs = core.getState();
    const state = getXkbStateMut() orelse return false;
    state.rebuild(cs.conn);

    // `buildKeybinds` is the single place that produces the list, so a mapping
    // change cannot leave the grab path reading a list resolved against the
    // old keyboard. The regrab itself is the CALLER's step: grabs reads this
    // module's list, and calling back into it here was the import cycle.
    buildKeybinds(cs.config.keybindings.items);
    return true;
}

// Grab setup

/// Applies the user's cursor theme and reports mouse binds that can never
/// fire. The root mouse grab itself is installed by the caller (main.zig
/// calls `grabs.grabMouseButtons` next). The report is pure analysis of the
/// config against `grabs.mouse_grab_buttons`, so it needs no grab to exist
/// yet.
pub fn setup(conn: core.Connection, screen: core.Screen) void {
    setupRoot(conn, screen);
    mouse.reportUndeliverableMouseBinds();
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
    // inside it (input flows in, true = consumed, before keybind dispatch).
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

// ---------------------------------------------------------------------------
// Root-window cursor theming (former cursor.zig, merged 2026-10-10) via
// libxcb-cursor: one startup call that touches the X connection and the
// screen and nothing else. The declarations are hand-written because
// `xcb_cursor_load_cursor` is a static inline function in the C header,
// which cImport cannot bind.
// ---------------------------------------------------------------------------

const Context = opaque {};

extern fn xcb_cursor_context_new(
    conn: core.Connection,
    screen: *xcb.xcb_screen_t,
    ctx: *?*Context,
) c_int;
extern fn xcb_cursor_load_cursor(ctx: *Context, name: [*:0]const u8) u32;
extern fn xcb_cursor_context_free(ctx: ?*Context) void;

/// Applies the user's cursor theme to the root window. Falls back silently
/// if xcb-cursor is unavailable or the cursor cannot be loaded.
fn setupRoot(conn: core.Connection, screen: core.Screen) void {
    var cursor_ctx: ?*Context = null;
    if (xcb_cursor_context_new(conn, screen, &cursor_ctx) < 0) return;
    defer xcb_cursor_context_free(cursor_ctx);

    const cursor = xcb_cursor_load_cursor(cursor_ctx.?, "left_ptr");
    if (cursor == xcb.XCB_NONE) return;

    const cookie = xcb.xcb_change_window_attributes_checked(
        conn,
        screen.root,
        xcb.XCB_CW_CURSOR,
        &[_]u32{cursor},
    );
    if (xcb.xcb_request_check(conn, cookie)) |err| {
        log.err("Failed to set root cursor: error_code={}", .{err.*.error_code});
        std.c.free(err);
    }

    // The server reference-counts cursors; freeing our handle is safe;
    // it stays alive as long as the root window holds a reference.
    _ = xcb.xcb_free_cursor(conn, cursor);
}

// ---------------------------------------------------------------------------
// Action dispatch (former dispatch.zig, merged 2026-10-10): the single
// router every configured action ends in. `executeAction` is pub for
// mouse.zig's config mouse binds; `grafted` likewise.
// ---------------------------------------------------------------------------

/// The toggle-bar-position action: re-anchor the bar, then reconcile.
///
/// The reconcile lives here rather than in the bar's renderer. It takes
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
    const current_ws = query.getCurrentWorkspace() orelse {
        window.updateWorkspaceBorders();
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
    if (!forced_hidden) grab.reconcileNow(.{});
    window.updateFloatingWindowBorders();
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
        .reload_hana => lifecycle.requestReexec(),
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
        // and focus.cycleFocus pairs the target with that duty, so the
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
/// the `comptime` check makes `action_mod.needsTilingFocusScaffold` a GATE rather
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
    comptime if (action_mod.needsTilingFocusScaffold(tag)) {} else @compileError(
        "dispatch.grafted used for an action action_mod.needsTilingFocusScaffold does not declare",
    );
    focus.setSuppressReason(.tiling_operation);
    op(arg);
    focus.beginTilingOpSettle();
}
