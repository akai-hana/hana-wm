//! Key event handlers: the press/release half of the dispatch table.
//! The one concern in input.zig that is genuinely per-EVENT (everything else
//! was lifecycle: XKB state, bind compilation, grabs, theming).
//!
//! No wire traffic: a key press either resolves to an action through
//! keybinds' dispatch map or is dropped, and the action itself runs in
//! dispatch.zig.
const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const masks = @import("masks");
const log = std.log.scoped(.keys);
const profile = @import("profile");
const focus = @import("focus");
const build_options = @import("build_options");
const surfaces = @import("surfaces").Surfaces;
const xkb = @import("xkb");
const keybinds = @import("keybinds");
const dispatch = @import("dispatch");

// Key-dispatch latency instrumentation. Measures the wall-clock time from
// event receipt (entry to handleKeyPress) to the bound action's dispatch,
// accumulated over a window so a periodic summary can be logged. Gated by
// `build_options.profile_key` so release WMs compile it out entirely.
const key_profile = profile.WindowedProfiler(
    build_options.profile_key,
    "[KPROF] receive->action last {} keys: avg={d:.0}ns min={d}ns max={d}ns",
    log.info,
);

/// The pressed-key set, keyed by keycode: an action fires only on the
/// false→true transition, so a held combo cannot re-trigger side-effecting
/// actions (exec / reload / close_window) at the X auto-repeat rate. The
/// `[core] key_repeat` knob (default false) restores universal repeat by
/// making every press fire; this also lays the foundation for future
/// chord/hold features. Pure on purpose: the X-facing handlers only feed it
/// keycodes, so the transition rule is unit-testable headless.
pub const PressedKeys = struct {
    down: [256]bool = .{false} ** 256,

    /// Records a press of `keycode`; returns true when the action should
    /// fire (a fresh press, or any press when repeat is allowed).
    pub fn press(self: *PressedKeys, keycode: u8, repeat_allowed: bool) bool {
        const was_down = self.down[keycode];
        self.down[keycode] = true;
        return repeat_allowed or !was_down;
    }

    /// Records a release, re-arming the keycode's next press.
    pub fn release(self: *PressedKeys, keycode: u8) void {
        self.down[keycode] = false;
    }

    /// Clears every held keycode (a full reset; the set has no other writer).
    pub fn reset(self: *PressedKeys) void {
        self.down = .{false} ** 256;
    }
};

/// Singleton pressed set for the live keyboard. With detectable auto-repeat
/// enabled (xkb.zig), a held key re-delivers KeyPress with no interleaved
/// release, so the false→true transition is exactly "physically pressed again".
pub var pressed: PressedKeys = .{};

pub fn handleKeyPress(event: *const xcb.xcb_key_press_event_t) void {
    // Timing: wall-clock from event receipt to the bound action's dispatch.
    // Compiled out when `build_options.profile_key` is false.
    const key_t0: i128 = if (key_profile.enabled) core.monotonicNs() else 0;

    focus.setLastEventTime(event.time);

    const state = xkb.getXkbState() orelse {
        log.warn("[KEY] keypress before XKB init; ignoring", .{});
        return;
    };

    const mods = masks.normalizeModifiers(event.state);
    const keysym = state.keycodeToKeysym(event.detail);

    // O(1) dispatch via the (modifiers << 32 | keysym) map built by
    // keybinds.buildKeybinds.
    const matched = keybinds.lookupAction(mods, keysym, core.config_rev.rev());

    // The chrome overlay owns all key input while active; routing is handled
    // inside it (input flows in, true = consumed, before keybind dispatch).
    // No `has_bar` guard: `chromeHandleKeypress` is a no-op hook that returns
    // false when no surface module is compiled in, so the flag test was
    // duplicating a decision the `surfaces` type already made.
    if (surfaces.chromeHandleKeypress(event, matched)) return;

    if (matched) |action| {
        // Transition gate (D3): with `[core] key_repeat = false` (the
        // default) an action fires only on the false→true keycode
        // transition, so a held combo cannot re-trigger side-effecting
        // actions at auto-repeat rate. `key_repeat = true` restores the
        // universal-repeat behavior by firing on every press.
        if (!pressed.press(event.detail, core.getState().config.core.key_repeat)) {
            log.debug("[KEY] mods=0x{x} keysym=0x{x} repeat of held combo suppressed", .{ masks.toMask(mods), keysym });
            return;
        }
        // Per-key dispatch logs are `.debug` so release WMs (default log
        // level `.info`) compile them out of the hot path; folding them into
        // a summary keeps tracing available without per-key formatting+write.
        log.debug("[KEY] mods=0x{x} keysym=0x{x} action={s}", .{
            masks.toMask(mods), keysym, @tagName(action.*),
        });
        if (key_profile.enabled) key_profile.note(core.monotonicNs() - key_t0);
        dispatch.executeAction(action);
    } else if (!mods.isEmpty() or !masks.isModifierKeysym(keysym)) {
        // Bare modifier press (Shift/Ctrl/Alt/Super/Hyper L/R) can never
        // match a binding; staying silent keeps logs free of keystroke noise.
        log.debug("[KEY] mods=0x{x} keysym=0x{x} no binding", .{ masks.toMask(mods), keysym });
    }
}

/// Tracks the event timestamp for focus machinery on release, and re-arms
/// the keycode in the pressed set so the next press is a fresh transition.
/// (With detectable auto-repeat a held key delivers repeat presses with no
/// interleaved release, so the release here is only ever a real one.)
pub fn handleKeyRelease(event: *const xcb.xcb_key_release_event_t) void {
    pressed.release(event.detail);
    focus.setLastEventTime(event.time);
}
