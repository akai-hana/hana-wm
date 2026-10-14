//! Raw X input -> configured actions: the single router the event loop hands
//! key, button, and motion events to. Owns the live XKB state and the
//! (modifiers, keysym) -> Action dispatch map (rebuilt on startup and on config
//! reload or keyboard-mapping change). Mouse intake -- the button/motion
//! handlers, press classification, and drag routing -- lives in mouse.zig and
//! is re-exported below; key dispatch stays here (the Super+click grab itself
//! is installed by `grabs.grabMouseButtons`, sequenced by main after `setup`).
//! The action dispatcher itself (executeAction) lives in dispatch.zig,
//! re-exported below: mouse.zig dispatches config mouse binds
//! through dispatch.zig directly, so neither mouse nor dispatch needs to import
//! this module.
//! Delegates to keybind.zig for resolution, surfaces for chrome routing,
//! dispatch/actions for tiling/floating work.

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const masks = @import("masks");
const log = @import("log");
const focus = @import("focus");
const xkbcommon = @import("xkbcommon");
const keybind = @import("keybind");
const build_options = @import("build_options");
const cursor = @import("cursor");
// Bar hook set; the core-owned `surfaces` composition root, absent-safe.
const surfaces = @import("surfaces").Surfaces;
// Grab installation lives in grabs.zig, which reads this module's resolved
// keybind list -- so this module must NOT import it back. The two places that
// used to (the mouse grab at setup, the regrab after a keyboard mapping
// change) are sequenced by their callers instead: main.zig and events.zig
// import both sides, which is where the order belongs anyway.

const time = @import("time");

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

// Action dispatch (the executeAction dispatcher) lives in dispatch.zig since
// review 05-input round 2: mouse.zig's config mouse binds dispatch through it,
// and keeping the dispatcher here forced input <-> mouse to import each other.
// Re-exported so handleKeyPress and the input tests keep their
// single unchanged surface.
const dispatch = @import("dispatch");
pub const executeAction = dispatch.executeAction;

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
    cursor.setupRoot(conn, screen);
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
