//! The window-manager lifecycle actions: fullscreen
//! (covering enter/exit/switch), the map-request tail,
//! the post-geometry focus handoff, and the unmanage
//! tail. Each action is one model transition + one
//! sync entry. The shared transition tails (retile,
//! focusFallback, prepareAndSetFocus, the
//! covering-occupant queries) live in `actions.zig`,
//! the hub this file imports: the two files form the
//! window layer's intentional runtime-only import
//! cycle (the same hub-and-spoke shape check-layers.sh
//! documents for core<->window).

const core = @import("core");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const focus = @import("focus");
const window = @import("window");
const tracking = @import("tracking");
const wincache = @import("wincache");
const contract = @import("contract");
const ledger = @import("ledger");
const build_options = @import("build_options");
const time = @import("time");
const log = @import("log");

const actions = @import("actions");
const gate = actions.gate;

/// Registry lookup for the hook `field` (see `contract.providerOf`), null when
/// no module binds it; canonical scan lives in window.providerOf.
const providerOf = actions.providerOf;

const Ctx = actions.Ctx;

// covering (screen claim)

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
    // seams, so non-profiled builds skip the clock samples.
    const fs_t0: u64 = if (build_options.profile_key) time.monotonicNs() else 0;
    const wm = providerOf(.toggleCovering) orelse return;
    if (!core.getState().config.fullscreen_enabled) return;
    const m = pipeline.mut(&gate);
    // Never cover a window off the viewed workspace: the covering
    // record binds the current ws and would claim it while hidden.
    if (!model_mod.visibleOn(m, win, m.current)) return;

    // Classify BEFORE toggling so bar deferrals keep the occupant
    // scan in one place; both the classification and prev_fs_win need
    // the same result, saving one full store scan.
    const prev_fs_win = actions.currentCoveringOccupant(m);
    const is_fs = actions.isCoveringOnWs(m, win);
    // An explicit request that matches the current state is a no-op, not a
    // toggle: without this guard a redundant `_NET_WM_FULLSCREEN_REQUEST`
    // would flip the window the wrong way.
    if (want) |target| if (target == is_fs) return;
    const kind: pipeline.FullscreenKind =
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

    // EWMH writes + bar arming land inside the same grab as geometry -- all
    // fire-and-forget or pure state.
    pipeline.reconcileUnderGrabNowFullscreen(
        .{ .force_restack = true },
        ft,
        win,
        prev_fs_win,
        kind,
    );

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
        window.dispatchAll(.resolvePendingBarNow, .{win});
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

// spawn/map lifecycle

/// MapRequest tail. The caller's front-end (event masks, property
/// queries, size-hints cache) has already run; this registers the window in
/// the model and lets ONE reconcile do map+pixel+bw+geom(+ABOVE winner) for
/// on-current spawns. Off-current spawns park by construction; sync sends
/// their border width at first show instead of immediately (invisible either
/// way; one less request).
///
/// `float_rect` admits the window already floating: the entry is registered
/// tiled (core membership is tiled-only) and then immediately detached to the
/// given rect with no home-list membership, mirroring detachTiledToFloating's
/// anchor/home_ws state. The reconcile tail then sizes it floating in one
/// reconcile, so a float-rule spawn never flashes a tiled slot.
pub fn mapRequest(win: model_mod.WindowId, target_ws: u8, on_current: bool, float_rect: ?model_mod.Rect) void {
    const m = pipeline.mut(&gate);
    if (tracking.isManaged(win)) return; // double-manage guard, see tracking.isManaged

    // A defined refusal (store or home-list full) leaves the window
    // unmanaged.
    model_mod.register(m, win, if (on_current) null else model_mod.WSId.fromIndex(target_ws)) catch {
        log.warn("mapRequest: capacity full; window 0x{x} left unmanaged", .{win});
        // Evict, or a refused window's XID lingers in the cache forever: XIDs
        // are recycled, so the next client to be handed this id would inherit
        // a stale title/child entry and read the wrong window.
        wincache.removeWindow(win);
        return;
    };
    // Bridge the cached WM_NORMAL_HINTS into the model entry at registration.
    const e = m.store.getPtr(win);
    if (e) |ep| ep.size_hints = wincache.peekHints(win);

    // Float-rule admission: detach the entry from its tiled slot before the
    // fifo placement runs (which assumes a home slot, nonsensical for a
    // floating window). The anchor/home_ws state mirrors toggleFloating's
    // detach, and the reconcile tail applies the rect in the same reconcile.
    if (float_rect) |rect| {
        if (e) |ep| {
            if (ep.home_ws) |home| model_mod.removeValue(&m.ws[home.index].tiled_order, win);
            ep.anchor = .{ .floating = rect };
            ep.home_ws = null;
        }
    } else {
        // Primary-fifo variant spawn placement (moved out of model.register;
        // it is SPAWN policy, not membership policy): a new window takes the
        // primary-column head slot, and the previous head window drops one
        // slot.
        {
            // Clamp the requested home workspace so a misconfigured target
            // can't index past the ws array in ReleaseFast (defense in depth;
            // the MapRequest front-end already resolves/clamps the target).
            const home: model_mod.WSId = if (on_current)
                m.current
            else
                window.clampToValidWorkspace(target_ws, model_mod.WSId.fromIndex(m.current.index));
            const p = &m.ws[home.index].params;
            // Same policy restated at the spawn site: driven by the active
            // module's fifo_variant metadata (the head slot binds variant
            // index 1).
            if (contract.moduleOf(p.kind)) |mv| {
                if (mv.fifo_variant) |v| {
                    if (p.variant_idx == v and m.ws[home.index].tiled_order.len > 1)
                        model_mod.reorderTiled(m, win, 0);
                }
            }
        }
    }
    focus.initWindowGrabs(win); // protocol-side keygrabs, both paths did this
    core.window.bump(); // a window was admitted

    if (!on_current) return;

    // Focus prep before the model write (same rule as focusFallback): a
    // spawned no_input window must never take model focus -- its focus
    // protocol can't land, so marking it focused would leave borders and
    // stacking claiming a focus X will never deliver. X input focus lands
    // AFTER the reconcile, inside the same grab: the window must be mapped
    // before xcb_set_input_focus, so both map+focus land under one grab.
    const ft = actions.prepareAndSetFocus(m, win, .window_spawn);
    pipeline.reconcileGrabFocus(.{}, ft, .after, null);
}

/// The tail shared with session adoption: put X input focus on whatever the
/// model says is focused, inside one grab AFTER geometry, or -- when nothing is
/// focused -- reconcile under the grab with no focus handoff.
///
/// Adopted windows are already mapped, so the mapRequest path's ordering
/// ("map, then focus, in the same grab") is satisfied here for the same
/// reason. Both callers need this to be identical: a session that adopts 40
/// windows and then focuses differently from a session that spawned them is a
/// bug that only shows up after a re-exec.
pub fn focusAfterGeometry() void {
    if (pipeline.model().focused) |focused| {
        const ft = actions.prepareAndSetFocus(pipeline.mut(&gate), focused, .window_spawn);
        pipeline.reconcileGrabFocus(.{}, ft, .after, null);
    } else {
        pipeline.reconcileGrab();
    }
}

/// Unmanage tail: close/destroy/unmap of a managed window. Local
/// bookkeeping (covering record, caches, sub-system removes) has already
/// run; this drops the model entry and re-focuses. Inactive-workspace
/// geometry repairs ride the same global LastSent diff.
pub fn unmanage(ctx: *Ctx, win: model_mod.WindowId) void {
    const m = pipeline.mut(&gate);
    // Covering and focus truth arrive via ctx: the sole caller (window.
    // unmanageWindow) removes the model entry (the workspace layer's
    // removeWindow -> unregister) BEFORE this action runs, so reading the
    // store here could never see either; closing the covering occupant never
    // restored the bar, and the withdrawn window's focus ownership was
    // unknowable.
    const was_fs_current = if (ctx.withdrawn_fullscreen_ws) |ws_id| ws_id.eql(m.current) else false;
    const was_focused = ctx.withdrawn_was_focused;

    model_mod.unregister(m, win);
    ledger.forget(win); // X ids recycle; stale LastSent must not survive

    // Closing the current workspace's covering occupant releases the area;
    // retileWithFallback bumps the core fact so the bar reacts.
    actions.retileWithFallback(m, was_fs_current, was_focused);
}
