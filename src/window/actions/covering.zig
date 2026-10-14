//! Fullscreen/covering orchestration: the enter/exit/switch transition for an
//! arbitrary window in ONE model transition + ONE reconcile.
//!
//! Each action is one model transition + one sync entry; the covering winner
//! renders edge-to-edge while everyone else parks off-screen in the same
//! transition. Bar hide/show deferral and the EWMH state writes stay
//! protocol-side, driven through the window_modules registry's pending
//! machinery so events.zig's ConfigureNotify handler works unchanged.
//!
//! The shared transition tails (retile, focusFallback,
//! prepareAndSetFocus, the covering-occupant queries) live in `actions.zig`,
//! the hub this file imports: the two files form the window layer's
//! intentional runtime-only import cycle (the same hub-and-spoke shape
//! check-layers.sh documents for core<->window).

const core = @import("core");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const build_options = @import("build_options");
const time = @import("time");
const log = @import("log");

const actions = @import("actions");
const registry = @import("registry");
const surfaces = @import("surfaces").Surfaces;
const window_mods = @import("window_modules").modules;

/// Fullscreen transition classification for the atomic grab path: a named
/// kind instead of a bool-pair so enter/exit/switch_ can't be passed
/// inconsistently. Drives the EWMH state writes and the bar hide/show
/// arming inside the grab (this file owns the fullscreen orchestration,
/// so the classification lives with it).
const FullscreenKind = enum { enter, exit, switch_ };

const providerOf = registry.providerOf;

/// Covering enter/exit/switch for an arbitrary window in ONE model
/// transition + ONE reconcile.
///
/// The covering winner renders on the full screen edge-to-edge (screen rect,
/// bw=0, pixel=0, ABOVE merged); everyone else parks off-screen in the same
/// transition. Floating exit geometry replays from the base rect via the LastSent
/// diff; tiled exit re-derives placements from the tiling engine, so the pre-exit
/// "restore then re-park" request round collapses away.
///
/// Bar hide/show deferral and EWMH stay protocol-side, driven through the
/// window_modules registry's pending machinery so events.zig's ConfigureNotify
/// handler works unchanged. The keybind path resolves the focused window at
/// the dispatch site and lands here too.
pub fn fullscreenToggleWindow(win: model_mod.WindowId) void {
    fullscreenSetWindow(win, null);
}

/// The same transition with an explicit target state, for EWMH requests that
/// are a SET rather than a toggle.
///
/// `_NET_WM_FULLSCREEN_REQUEST` carries the intended end state in data32[0]
/// (1 = enter, 0 = leave). Browsers use it for native video fullscreen, and
/// feeding it to a toggle inverts the request: pressing F twice in the same
/// player, or Firefox re-asserting fullscreen on a window that is already
/// covered, would drop the window OUT of fullscreen. `want` is null for the
/// keybind and `_NET_WM_STATE` toggle paths, which genuinely mean "flip".
pub fn fullscreenSetWindow(win: model_mod.WindowId, want: ?bool) void {
    // Timing: wall-clock from action entry (keybind/EWMH resolve) to the
    // synchronous completion of the fullscreen transition INCLUDING the bar
    // hide and the ungrabAndFlush of the enclosing grab — i.e. the point at
    // which the bar is gone and the window is sized, all visible on the next
    // compositor frame. Gated on `-Dprofile-key` like the other profiler
    // sites, so non-profiled builds skip the clock samples.
    const fs_t0: u64 = if (build_options.profile_key) time.monotonicNs() else 0;
    const wm = providerOf(.toggleCovering) orelse return;
    if (!core.getState().config.fullscreen_enabled) return;
    const m = pipeline.mut();
    // Never cover a window off the viewed workspace: the covering
    // record binds the current workspace and would claim it while hidden.
    if (!model_mod.visibleOn(m, win, m.current)) return;

    // Classify BEFORE toggling so bar deferrals keep the occupant
    // scan in one place; both the classification and prev_fs_win need
    // the same result, saving one full store scan.
    const prev_fs_win = actions.currentCoveringOccupant(m);
    const is_fs = model_mod.isCoveringOn(m, win, m.current);
    // An explicit request that matches the current state is a no-op, not a
    // toggle: without this guard a redundant `_NET_WM_FULLSCREEN_REQUEST`
    // would flip the window the wrong way.
    if (want) |target| if (target == is_fs) return;
    const kind: FullscreenKind =
        if (is_fs) .exit else if (prev_fs_win != null) .switch_ else .enter;
    const was_focused = m.focused == win;

    if (!wm.toggleCovering.?(m, win)) return;

    // Focus the covering winner unless it already owns focus or the toggle
    // turned fullscreen OFF. A covering window owns the whole screen, so it
    // must own keyboard focus too: requests can arrive for an unfocused
    // window (EWMH) and a covering switch can raise a window the pointer is
    // not over, leaving keystrokes stranded on the displaced occupant. The
    // model write happens before the reconcile (borders and the winner seed
    // derive from it); the X focus lands inside the same grab, after the
    // reconcile maps/raises the entrant. Returns .none for a no_input
    // entrant (which can never hold X focus) without touching the model.
    var ft: focus.FocusTransition = .none;
    if (kind != .exit and !was_focused) ft = actions.prepareAndSetFocus(m, win, .user_command);

    // Atomic fullscreen transition: reconcile, focus handoff, EWMH writes and
    // bar hide/show all land inside the same server grab (grouped atomicity),
    // so geometry, stacking, input focus and the bar's claim can never be
    // observed half-applied. The enter path unmaps the bar immediately rather
    // than deferring to ConfigureNotify. `t` (ft) is the optional focus
    // transition to the covering entrant (`.none` for an exit or an
    // already-focused entrant): applied AFTER the reconcile so the entrant is
    // mapped+raised before xcb_set_input_focus targets it (the mapRequest
    // ordering rule); a parked/unparked entrant is re-mapped inside this grab.
    {
        const g = pipeline.grabScoped();
        defer g.deinit();
        g.reconcileNow(.{ .force_restack = true });
        focus.applyPendingFocus(ft);
        // EWMH advertisement inside the grab: clear for whoever left
        // fullscreen, set for entrant. All fire-and-forget
        // (xcb_change_property). Uniform loop over the sub-system set:
        // each module that provides the hook runs it. In practice only
        // fullscreen does, preserving the old gated single hook call
        // exactly; the loop just makes the dispatch mechanism uniform
        // rather than a merged struct. Ordering and the
        // kind/prev_fs_win/m.focused logic is unchanged.
        // Not registry.dispatchAll, despite being a fan-out over window_mods:
        // callAll passes ONE argument set to every binder, and this needs
        // two calls with different arguments (clear the previous
        // fullscreen window, then set this one), plus a per-call-site
        // condition on kind. Routing it through callAll would mean
        // flattening that into a single uniform call, which is the bug the
        // uniformity is meant to prevent.
        for (window_mods) |wm_mod| {
            if (wm_mod.setEwmhFullscreenState) |hook| {
                if (kind == .switch_) {
                    if (prev_fs_win) |old| hook(old, false);
                }
                hook(win, kind != .exit);
            }
        }
        // Bar hide/show inside the grab: no separate grab/reconcile cycle.
        //
        // ENTER: immediately unmap the bar via the Surfaces hooks. The
        // fullscreen client is already mapped+raised+screen-sized by the
        // reconcile, so it covers the bar before the unmap reaches the
        // server. Cancel any stale pending bar show from a previous exit
        // (a new enter supersedes it).
        //
        // EXIT: arm the deferred show. The bar reappears after the
        // client's ConfigureNotify confirms non-fullscreen dimensions.
        if (kind != .exit) {
            // Immediate bar unmap when fullscreen claims the usable area.
            surfaces.hideBarForFullscreen();
        } else {
            // Exit: deferred bar show (unchanged path).
            if (m.focused) |w| {
                registry.dispatchAll(.armPendingBarShow, .{w});
            }
        }
    }

    // Deterministic fullscreen-exit reaction: the model no longer has a
    // covering occupant the moment the toggle lands, so bump the fact now.
    // The deferred bar-show arm alone is not enough: it waits for a
    // non-fullscreen ConfigureNotify, which never arrives when a window's
    // restored anchor IS the screen size (the model just restores it in
    // place) -- the bar would stay hidden until some unrelated event happened
    // to bubble the fact.
    //
    // Resolving the arm here is what keeps this bump the ONLY one. Because
    // the toggle answers the question itself, the intent it armed inside the
    // grab is retired instead of left for a later ConfigureNotify to answer
    // the same question again and republish an identical bar state.
    if (kind == .exit) {
        registry.dispatchAll(.resolvePendingBarNow, .{win});
        core.fullscreen.bump();
    }

    // Completion of the transition is synchronous: run time elapsed
    // already covers the reconcile + immediate bar hide (enter) and the
    // ungrabAndFlush, i.e. the visual-completion point.
    if (build_options.profile_key) {
        const dt = time.monotonicNs() - fs_t0;
        log.info("[FSPROF] win={d} kind={s} done {d}ns", .{
            win, @tagName(kind), dt,
        });
    }
}
