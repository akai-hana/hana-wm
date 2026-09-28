//! Model-pipeline entry glue. This module owns the global Model instance,
//! builds the per-reconcile reconcile.Ctx from live state, and exposes the
//! reconcile slots entry points call.
//!
//! Entry points: init() (startup), dragTick() (floating drag motion),
//! reconcileNow() (retile/EWMH/manage/unmanage), and the
//! fullscreenToggleWindow/workspace hooks routed from the window layer.

const std = @import("std");
const model_mod = @import("model");
const core = @import("core");
const focus = @import("focus");
const xcb_sink = @import("sink");
const usable_area = @import("usable_area");
const build_options = @import("build_options");
const log = @import("log");
const time = @import("time");
const surfaces = @import("surfaces").Surfaces;
// Fullscreen EWMH/bar-arming hooks via the build-generated `window_modules`
// registry (the loop below no-ops without fullscreen).
const window_mods = @import("window_modules").modules;

/// Layout registry (build-generated); the active layout is a `u8` index into
/// it (see model.LayoutParams.kind). Empty when the tiling subsystem is
/// absent. Gated on has_tiling so tree variants without tiling compile.
const contract = @import("contract");
const tiling = @import("tiling_seam").tiling;
const scaling = @import("scaling");

const ledger = @import("ledger");
const reconcile = @import("reconcile");
const sink = @import("sink");
/// True after init(); kept as a named predicate so callers read as
/// "is the model live" rather than reaching for a bare global. The VALUE now
/// comes from core's single boot phase, so it cannot disagree with core.isReady()
/// the way two independently-set latches could.
pub inline fn initialized() bool {
    return core.isModelReady();
}

var instance: model_mod.Model = undefined;
pub fn init() void {
    instance = .{}; // bounded lists: no allocator inside the model
    g_sink = .{ .conn = core.getState().conn };
    core.markModelReady();
    ledger.init();
}
/// READ-ONLY access to the WM model (single source of truth). The return type
/// is `*const`, so any attempt to write through this handle is a compile
/// error: the compiler is the mutation tripwire. A MUTABLE handle requires
/// the transition-layer gate (`pipeline.mut`); only modules that own model
/// transitions declare a private `Gate` (actions/window/focus/tracking).
pub inline fn model() *const model_mod.Model {
    if (!initialized()) @panic("pipeline.model() called before init()");
    return &instance;
}

/// Capability gate for mutable model access (see `mut`). Accident-resistant,
/// not adversarial: declaring a fresh Gate compiles, but no module does so by
/// accident -- the read-only `model()` handle is the default.
pub const Gate = struct {};

/// MUTABLE access to the WM model. Requires a `Gate` value, which only the
/// transition layer declares privately; every other module sees only the
/// read-only `model()` handle. Zero-cost: the empty gate is compile-time
/// discarded.
pub inline fn mut(g: *const Gate) *model_mod.Model {
    _ = g;
    if (!initialized()) @panic("pipeline.mut() called before init()");
    return &instance;
}

/// Returns the current tiling layout (a registry index, see
/// model.LayoutParams.kind) from the live model state. Falls back to config
/// name resolution pre-init. An unresolvable config name (removed module,
/// unknown spelling) is loud, never silent.
pub inline fn getCurrentLayout() u8 {
    if (initialized()) return model().ws[model().current.index].params.kind;
    return defaultIndexForLayoutName(core.getState().config.tiling.layout);
}

/// Returns the current workspace's active tiling variant index (see
/// model.WSParams.variant_idx) from the live model state, checked at the one
/// place that already owns the workspace-index rule. A bar module used to
/// hand-walk `model().ws[model().current.index].params.variant_idx` itself,
/// duplicating this lookup AND its unchecked @intCast; now it asks.
pub inline fn getCurrentVariantIdx() usize {
    return @intCast(model().ws[model().current.index].params.variant_idx);
}

/// Resolves a config layout name to a registry index (see
/// model.LayoutParams.kind), collapsing to `contract.default_kind` when the
/// name does not resolve. Loud, never silent: an unresolvable/removed
/// layout name is a config bug. Shared by getCurrentLayout (pre-init fallback)
/// and persist's restored-layout degradation, so both site types resolve
/// config names identically.
pub fn defaultIndexForLayoutName(name: []const u8) u8 {
    if (!build_options.has_tiling) return contract.default_kind;
    return tiling.layoutKindFallingBack(name, contract.default_kind);
}

var g_sink: xcb_sink.XcbSink = undefined;

/// The shared XCB sink: inited once in init(), then free across every use.
inline fn syncSink() sink.Sink {
    return (&g_sink).sink();
}

var g_ctx: reconcile.Ctx = undefined;

/// The tiling engine environment for a workspace, resolved from live config
/// (scaled margins, min_dim, master side). Shared by `ctx()` and the test
/// fixture's placement expectations, so the fixture mirrors production env
/// resolution instead of hand-building it.
///
/// It takes no layout params: everything left in `Env` is a config-derived
/// constant, while the workspace's VARIANT index is model state that reaches a
/// layout module as `View.params.variant_idx`. It used to be copied in here as
/// well, which gave one fact two homes and had the layouts reading the copy.
pub fn tilingEnv() contract.Env {
    const cs = core.getState();
    const screen_h = cs.screen.height_in_pixels;
    return .{
        .margins = .{
            .gap = scaling.scaleBorderWidth(cs.config.tiling.gap_width, screen_h),
            .border = core.borderWidth(),
        },
        .min_dim = cs.config.tiling.min_window_dim,
        .primary_on_right = cs.config.tiling.master_side == .right,
    };
}

/// Builds the per-retile Ctx from live state: workarea via bar's helper,
/// margins/min_dim/master side from config (see tilingEnv), colors from
/// config.tiling.
/// Only valid after init().
fn ctx() *reconcile.Ctx {
    // Inside a server grab the ctx belongs to the operation that TOOK the
    // grab: rebuilding it there would recompute `.workarea`/`.bar_win` from
    // live state under a body that has already committed to them (the
    // fullscreen path unmaps the bar inside the same grab), and would re-run
    // the pre-reconcile duties after geometry was already applied, leaving
    // the model and the server disagreeing. Inside a grab, read the in-flight
    // ctx via currentCtx(); to start a new operation, call prepare().
    std.debug.assert(grab_depth == 0);
    const cs = core.getState();
    const screen_h = cs.screen.height_in_pixels;
    const env = tilingEnv();
    g_ctx = .{
        .sink = syncSink(),
        .screen = .{
            .x = 0,
            .y = 0,
            .width = cs.screen.width_in_pixels,
            .height = screen_h,
        },
        .workarea = usable_area.workArea(cs.screen),
        .env = env,
        .color_of = colorOf,
        .bar_win = usable_area.mappedSurfaceWindow(),
    };
    return &g_ctx;
}

/// Focused/unfocused border-pixel pick for the reconcile Ctx. Fullscreen
/// windows get bw=0/pixel=0 through the fullscreen branch policy in sync
/// instead. Reads MODEL focus; focus.zig mirrors every transition into
/// m.focused, so this is the same single source of truth.
fn colorOf(win: model_mod.WindowId, m: *const model_mod.Model) u32 {
    const cfg = &core.getState().config.tiling;
    return model_mod.focusedBorderColor(m, win, cfg.border_focused, cfg.border_unfocused);
}

pub inline fn dragTick(win: model_mod.WindowId) void {
    reconcile.reconcileDragTick(&instance, syncSink(), win);
}

/// Scroll viewport caller duties applied at the single reconcile choke
/// point, dispatched through the active layout module's preReconcile hook
/// (the scroll addon registers snap-right-on-growth + clamp; a layout that
/// provides no hook has no pre-reconcile duty).
fn preReconcileDuties() void {
    if (!build_options.has_tiling) return;
    // Internal choke point: touches the private `instance` directly (not via
    // model()/mut()) because this is the model owner applying the active
    // layout's pure pre-reconcile delta (value-in, value-out -- no layout
    // module receives a mutable pointer into the model anymore).
    //
    // 8.8: the WRITE goes through model.applyParamsDelta rather than a raw
    // `*LayoutParams` taken from the model. The value-in/value-out shape
    // already stopped layout modules from mutating; this closes the last
    // un-gated channel, which was this pipeline function itself holding a
    // mutable pointer into model state across a call into a layout module.
    const ws = instance.current;
    const p = instance.ws[ws.index].params;
    const md = contract.moduleOf(p.kind) orelse return;
    if (md.preReconcile == null) return;
    const n = model_mod.tiledCountOnWs(&instance, ws);
    const wa = usable_area.workArea(core.getState().screen);
    model_mod.applyParamsDelta(&instance, ws, md.preReconcile.?(p, n, wa.width));
}

/// The ONE place a reconcile ctx is built and the one place pre-reconcile
/// duties run. Every reconcile-family entry point calls this exactly once,
/// always before reading the ctx: the scroll layout's duty mutates the model
/// (viewport clamp), so it has to be folded into the geometry that follows it
/// rather than applied as a separate pass. Previously four entry points each
/// paired `preReconcileDuties()` with their own `ctx()` call, which is what
/// let a hook deep inside a grab ask for a second, divergent ctx.
fn prepare() *reconcile.Ctx {
    preReconcileDuties();
    return ctx();
}

/// The ctx of the grab currently in flight, for a hook that must queue its
/// writes into somebody else's atomic bracket (the EWMH fullscreen write).
/// Asserts a grab IS held: outside one there is no in-flight ctx to borrow,
/// and the right answer is to start an operation with prepare() or to use a
/// named entry point. Deliberately does NOT run the pre-reconcile duties --
/// the enclosing operation already ran them.
pub fn currentCtx() *reconcile.Ctx {
    std.debug.assert(grab_depth > 0);
    return &g_ctx;
}

/// Raise `win` to the top of the stack immediately, outside any server grab,
/// then flush. The drag-tick path needs only these two ungrabbed requests;
/// it used to borrow `grabCtx`, which ran a full pre-reconcile duty pass and
/// built an entire retile ctx for them.
pub fn raiseWindowNow(win: model_mod.WindowId) void {
    const s = syncSink();
    s.stackOnly(win, .above);
    s.flush();
}

/// Runs a reconcile-family body under one X server grab, always
/// releasing+flushing on exit (defer), so no grab site can forget the
/// atomicity bracket. `body` is a value-capturing struct with a
/// `fn call(self, c: *Ctx) void` method (the codebase's closure idiom); each
/// entry point captures the args its compose needs.
/// Nesting depth of the server grab. `XGrabServer` is NOT reentrant and has no
/// matching "already held" state: a nested grab followed by an ungrab would
/// release the OUTER grab too, so the rest of the session would run ungrabbed
/// while believing it holds the lock -- the exact class of bug that produces
/// "a request failed for no visible reason" reports hours later. One counter
/// at the single seam every grab goes through turns that into an assert at the
/// point of the mistake.
var grab_depth: u32 = 0;

/// Server-grab ownership as a token: taking it grabs, dropping it ungrabs AND
/// flushes. Every exit path releases it, including an early return or a failed
/// reconcile inside the body -- which is precisely the failure mode the bar's
/// hand-written `requests.grabServer` / `ungrabAndFlush` pairs had to repeat
/// by hand at every early return (its re-anchor path had one).
///
/// The ctx is built when the grab is TAKEN, not on demand, so every wire write
/// and every reconcile inside the bracket is computed against one ctx. It
/// carries its own `reconcileNow` for exactly that reason: a caller cannot
/// reconcile against a different ctx than the one its geometry is bracketed
/// by, and it cannot reach pipeline's flushless reconcile at all.
pub const ScopedGrab = struct {
    /// The ctx this bracket reconciles against, or null for a grab that was
    /// only ever for wire writes.
    c: ?*reconcile.Ctx,
    s: sink.Sink,

    /// Releases the grab and flushes. Asserts rather than tolerating a double
    /// release: an extra release would ungrab a grab this token does not own.
    pub fn deinit(self: ScopedGrab) void {
        std.debug.assert(grab_depth > 0);
        grab_depth -= 1;
        self.s.ungrabAndFlush();
    }

    /// Flushless reconcile inside this bracket, against this token's ctx.
    /// Asserts the token was taken with a ctx (grabScoped always is). This is
    /// the bar's replacement for the old pub pipeline.reconcileNow(), which
    /// let a grabbed caller reconcile against a ctx its geometry writes were
    /// not bracketed by.
    pub fn reconcileNow(self: ScopedGrab) void {
        std.debug.assert(self.c != null);
        reconcile.run(&instance, self.c.?, .{});
    }
};

/// Takes the server grab, building the reconcile ctx first (ctx() refuses to
/// build under a grab) and returning the token that owns it.
pub fn grabScoped() ScopedGrab {
    std.debug.assert(grab_depth == 0);
    const c = prepare();
    const s = syncSink();
    s.grabServer();
    grab_depth += 1;
    return .{ .c = c, .s = s };
}

/// Takes the server grab WITHOUT building a reconcile ctx, for a client that
/// only needs atomic wire writes and runs no geometry pass (the bar config
/// reload: destroy old + create new + map). Deliberately does NOT run the
/// pre-reconcile duties: those mutate the model for a reconcile that is meant
/// to follow, and with no reconcile following they would leave the model and
/// the server disagreeing -- the exact hazard ScopedGrab.reconcileNow exists
/// to prevent. Use grabScoped() when a reconcile is coming.
pub fn grabOnly() ScopedGrab {
    std.debug.assert(grab_depth == 0);
    const s = syncSink();
    s.grabServer();
    grab_depth += 1;
    return .{ .c = null, .s = s };
}

fn withServerGrab(body: anytype) void {
    const g = grabScoped();
    defer g.deinit();
    body.call(g.c.?);
}

/// Opt-in retile latency instrumentation (RETILE_PROF). Measures the wall
/// clock held by each server-grab retile -- the exact latency a user feels
/// across a tiling op. Gated by `build_options.profile_key` (the same flag as
/// the key-dispatch path) so release WMs compile it out.
///
/// This lived in `reconcile` next to the `reconcileUnderGrab` it instrumented
/// (5.4). The bracket belongs to the pipeline, so the measurement of the
/// bracket belongs here with it.
const retile_prof = log.WindowedProfiler(
    build_options.profile_key,
    "[RETILE_PROF] last {} grab-retiles: avg={d:.0}ns min={d}ns max={d}ns",
    std.log.info,
);

/// Grab server, reconcile, then ungrabAndFlush, atomically.
pub inline fn reconcileUnderGrabNow(o: reconcile.Opts) void {
    // 5.4: this used to be exempt from withServerGrab because
    // `reconcile.reconcileUnderGrab` ran its OWN grab/ungrab bracket, and a
    // nested grab's ungrab would release the outer one. That second bracket is
    // gone: grab ownership now lives here and only here, so this is just
    // withServerGrab with the profiler around it.
    const t0: i128 = if (retile_prof.enabled) time.monotonicNs() else 0;
    defer if (retile_prof.enabled) retile_prof.note(time.monotonicNs() - t0);
    withServerGrab(struct {
        o: reconcile.Opts,
        fn call(self: @This(), c: *reconcile.Ctx) void {
            reconcile.run(&instance, c, self.o);
        }
    }{ .o = o });
}

/// The common case: reconcile under a fresh server grab with DEFAULT opts,
/// bumping the WINDOW fact first (10.5).
///
/// The bare `reconcileUnderGrabNow(.{})` call site reads as "pass the empty
/// options struct", which invites the reader to hunt for what the defaults
/// are; this alias states the intent. `reconcileUnderGrabNow` stays for the
/// sites that really do set `force_restack`.
///
/// The bump lives HERE, not in each caller. Eight actions reconciled through
/// this alias with no bump at all, so the bar could read a stale window fact
/// after geometry moved -- the invariant was "remember to bump", held only by
/// the actions that happened to route through `retile`. Making the default
/// path bump is what makes it impossible to forget. A bump is a monotonic
/// `rev +%= 1` compared once per tick, so a site that wants a bump for its
/// own reasons may take a double bump here without a second work pass.
pub inline fn reconcileGrab() void {
    core.window.bump();
    reconcileUnderGrabNow(.{});
}

/// Grab server, run the focus transition, reconcile, then ungrabAndFlush
/// (or the reverse order) atomically.
/// Order of `reconcileGrabFocus`' two phases inside the grab: focus lands
/// before geometry (most actions), or after (mapRequest, where the window
/// must be mapped before xcb_set_input_focus targets it).
///
/// `duty` (usually null) runs inside the grab after the focus protocol and
/// before the reconcile WHEN FOCUS LANDS FIRST. Lets a caller fold a
/// model-derived adjustment that depends on the new focus (the viewport snap)
/// into the same reconcile instead of opening a second grab.
///
/// 10.8: it runs ONLY on the `.before` leg, so a `.after` caller passing a
/// duty had it dropped with no diagnostic -- the function returned normally
/// and the caller reasonably believed its adjustment had been folded in.
/// `assert`ed here rather than left to the doc, because the drop is silent and
/// the symptom (a viewport that does not move, or geometry computed against a
/// stale focus) points nowhere near this argument.
pub const FocusOrder = enum {
    before,
    after,
};

pub inline fn reconcileGrabFocus(
    o: reconcile.Opts,
    t: focus.FocusTransition,
    order: FocusOrder,
    duty: ?*const fn () void,
) void {
    // The duty is only ever invoked on the `.before` leg (see `call` below).
    std.debug.assert(!(order == .after and duty != null));
    preReconcileDuties();
    withServerGrab(struct {
        o: reconcile.Opts,
        t: focus.FocusTransition,
        order: FocusOrder,
        duty: ?*const fn () void,
        fn call(self: @This(), c: *reconcile.Ctx) void {
            if (self.order == .before) {
                focus.applyPendingFocus(self.t);
                if (self.duty) |d| d();
            }
            reconcile.run(&instance, c, self.o);
            if (self.order == .after) focus.applyPendingFocus(self.t);
        }
    }{ .o = o, .t = t, .order = order, .duty = duty });
}

/// Commit a focus transition inside one server grab with no reconcile: for
/// focus-only changes where geometry/stacking cannot differ (hover focus).
/// Borders repaint via the per-batch sweep on the commit's focus bump.
pub inline fn focusOnlyCommit(t: focus.FocusTransition) void {
    withServerGrab(struct {
        t: focus.FocusTransition,
        fn call(self: @This(), _: *reconcile.Ctx) void {
            focus.applyPendingFocus(self.t);
        }
    }{ .t = t });
}

/// Fullscreen transition classification for the atomic grab path (the fn
/// below): a named kind instead of a bool-pair so enter/exit/switch_ can't be
/// passed inconsistently. Drives the EWMH state writes and the bar
/// hide/show arming inside the grab.
pub const FullscreenKind = enum { enter, exit, switch_ };

/// Grab server, reconcile, do focus + EWMH + bar hide, then ungrabAndFlush,
/// atomically. Specialised for the fullscreen toggle path so the focus
/// handoff, EWMH writes and the bar unmap/hide land inside the same grab as
/// geometry (grouped atomicity); the enter path unmaps the bar immediately
/// rather than deferring to ConfigureNotify.
///
/// `t` is the optional focus transition to the covering entrant (`.none` for
/// an exit or an already-focused entrant): a covering switch/enter hands
/// input focus to the window that owns the usable area. Applied AFTER the
/// reconcile so the entrant is mapped+raised before xcb_set_input_focus
/// targets it (the mapRequest ordering rule); a parked/unparked entrant is
/// re-mapped inside this grab.
pub inline fn reconcileUnderGrabNowFullscreen(
    o: reconcile.Opts,
    t: focus.FocusTransition,
    win: model_mod.WindowId,
    prev_fs_win: ?model_mod.WindowId,
    kind: FullscreenKind,
) void {
    preReconcileDuties();
    withServerGrab(struct {
        o: reconcile.Opts,
        t: focus.FocusTransition,
        win: model_mod.WindowId,
        prev_fs_win: ?model_mod.WindowId,
        kind: FullscreenKind,
        fn call(self: @This(), c: *reconcile.Ctx) void {
            reconcile.run(&instance, c, self.o);
            focus.applyPendingFocus(self.t);
            // EWMH advertisement inside the grab: clear for whoever left
            // fullscreen, set for entrant. All fire-and-forget
            // (xcb_change_property). Uniform loop over the sub-system set:
            // each module that provides the hook runs it. In practice only
            // fullscreen does, preserving the old gated single hook call
            // exactly; the loop just makes the dispatch mechanism uniform
            // rather than a merged struct. Ordering and the
            // kind/prev_fs_win/instance.focused logic is unchanged.
            for (window_mods) |m| {
                if (m.setEwmhFullscreenState) |hook| {
                    if (self.kind == .switch_) {
                        if (self.prev_fs_win) |old| hook(old, false);
                    }
                    hook(self.win, self.kind != .exit);
                }
            }
            // Bar hide/show inside the grab: no separate grab/reconcile cycle.
            //
            // ENTER: immediately unmap the bar via the surfaces seam. The
            // fullscreen client is already mapped+raised+screen-sized by
            // reconcile.run, so it covers the bar before the unmap reaches
            // the server. Cancel any stale pending bar show from a previous
            // exit (a new enter supersedes it).
            //
            // EXIT: arm the deferred show. The bar reappears after the
            // client's ConfigureNotify confirms non-fullscreen dimensions.
            if (self.kind != .exit) {
                // Immediate bar unmap when fullscreen claims the usable area.
                surfaces.hideBarForFullscreen();
            } else {
                // Exit: deferred bar show (unchanged path).
                if (instance.focused) |w| {
                    contract.callAll(contract.WindowModule, window_mods[0..], .armPendingBarShow, .{w});
                }
            }
        }
    }{ .o = o, .t = t, .win = win, .prev_fs_win = prev_fs_win, .kind = kind });
}

/// Flushless reconcile against a FRESH ctx and no grab (drag tick path). Kept
/// public for the drag tick, which needs no atomicity; the grabbed case moved
/// onto ScopedGrab.reconcileNow so a grabbed caller cannot reach a reconcile
/// that would build a second ctx.
pub inline fn reconcileNow() void {
    reconcile.run(&instance, prepare(), .{});
}

// The old `grabCtx` manual-grab seam is gone. It could be called from inside
// a grab -- the fullscreen EWMH hook did exactly that -- and it rebuilt the
// ctx, re-ran the pre-reconcile duties, and documented a
// `caller MUST ungrabAndFlush` contract its one in-grab caller could not
// honour without releasing the enclosing grab. Its callers now use
// currentCtx() to join a grab in flight, or a named entry point.
