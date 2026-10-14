//! Model-pipeline glue: owns the global Model, builds reconcile.Ctx per tick,
//! exposes slot entry points and reconcile hooks; X-free.

const std = @import("std");
const model_mod = @import("model");
const core = @import("core");
const focus = @import("focus");
const xcb_sink = @import("sink");
const usable_area = @import("usable_area");
const build_options = @import("build_options");
const log = @import("log");
const time = @import("time");

/// Layout registry (build-generated); the active layout is a `u8` index into
/// it (see model.LayoutParams.kind). Empty when the tiling subsystem is
/// absent. Gated on has_tiling so tree variants without tiling compile.
const contract = @import("contract");
const tiling = @import("tiling_seam").tiling;
const scaling = @import("scaling");

const ledger = @import("ledger");
const reconcile = @import("reconcile");
const sink = @import("sink");

var instance: model_mod.Model = undefined;
pub fn init() void {
    instance = .{}; // bounded lists: no allocator inside the model
    g_sink = .{ .conn = core.getState().conn };
    core.markModelReady();
    ledger.init();
}
/// READ-ONLY access to the WM model (single source of truth). The return type
/// is `*const`, so any attempt to write through this handle is a compile
/// error: the compiler is the mutation tripwire, and it is the ONLY real one
/// this layer ever had (see `mut`).
pub inline fn model() *const model_mod.Model {
    if (!core.isModelReady()) @panic("pipeline.model() called before init()");
    return &instance;
}

/// MUTABLE access to the WM model. The enforcement is the type split itself:
/// readers take `*const` from `model()`, writers explicitly opt into `mut()`.
/// Zero-cost.
///
/// Deliberately bumps NO fact revision ("rev bumps into mut()" was considered
/// by the KISS audit and rejected): mut() cannot know WHICH fact a mutation
/// changed -- `focus.setFocus(pipeline.mut(), ...)` is a focus_rev change, a
/// params write is layout_rev, and an unconditional window_rev here would
/// repaint every bar segment on every focus change (a real regression: window
/// dirties drive the all-segments sweep, focus only the title). Fact bumps
/// stay adjacent to the change that owns them; the ONE structural bump (10.5)
/// lives in reconcileGrab, which is the pattern for making a bump
/// impossible-to-forget -- when a path has a single meaning, not generally.
pub inline fn mut() *model_mod.Model {
    if (!core.isModelReady()) @panic("pipeline.mut() called before init()");
    return &instance;
}

/// Returns the current tiling layout (a registry index, see
/// model.LayoutParams.kind) from the live model state. Falls back to config
/// name resolution pre-init. An unresolvable config name (removed module,
/// unknown spelling) is loud, never silent.
pub inline fn getCurrentLayout() u8 {
    if (core.isModelReady()) return model().ws[model().current.index].params.kind;
    return defaultIndexForLayoutName(core.getState().config.tiling.defaultLayout());
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
/// and handoff's restored-layout degradation, so both site types resolve
/// config names identically.
pub fn defaultIndexForLayoutName(name: []const u8) u8 {
    if (!build_options.has_tiling) return contract.default_kind;
    return tiling.layoutKindFallingBack(name, contract.default_kind);
}

var g_sink: xcb_sink.XcbSink = undefined;

/// The shared XCB sink: inited once in init(), then free across every use.
/// Public for the grab-free wire-write seams this pipeline no longer wraps
/// (geometry's targeted drag tick, floating's drag raise): a raw request
/// sequence with no model or grab involvement belongs at the call site.
pub inline fn syncSink() sink.Sink {
    return (&g_sink).sink();
}

var g_ctx: reconcile.Ctx = undefined;

/// The tiling engine environment for a workspace, resolved from live config
/// (scaled margins, min_dim, master side).
///
/// It takes no layout params: everything left in `Env` is a config-derived
/// constant, while the workspace's VARIANT index is model state that reaches a
/// layout module as `View.params.variant_idx`.
fn tilingEnv() contract.Env {
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
        // 13.6: resolved ONCE here, through the same call the bar uses, so
        // geometry and the bar's "no layout" report can never disagree.
        .layout_active = contract.activeLayoutKind(
            model().ws[model().current.index].params.kind,
            core.tilingEnabled(),
        ) != null,
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
    /// `o` is passed through to `reconcile.run` (`.{}` for a plain retile;
    /// the fullscreen grab in manage passes `.force_restack`). Asserts the
    /// token was taken with a ctx (grabScoped always is). This is the bar's
    /// replacement for the old pub pipeline.reconcileNow(), which
    /// let a grabbed caller reconcile against a ctx its geometry writes were
    /// not bracketed by.
    pub fn reconcileNow(self: ScopedGrab, o: reconcile.Opts) void {
        std.debug.assert(self.c != null);
        // Refresh the screen-derived fields from LIVE state immediately before
        // geometry is emitted, rather than trusting the snapshot taken when
        // the grab was acquired. A surface can change what it claims of the
        // screen while the grab is held -- the fullscreen bar does exactly
        // that, unmapping itself and releasing its claim inside the same grab
        // that is about to re-tile the windows -- and a ctx snapshotted before
        // that change would tile into a work area the model had already
        // invalidated. The visible symptom was leaving fullscreen and finding
        // the bar back but the layout still sized as though no bar existed,
        // until an unrelated event (a workspace switch) rebuilt the ctx.
        //
        // Only these two fields are refreshed, and deliberately NOT the whole
        // ctx: rebuilding under a grab would re-run the pre-reconcile duties
        // after geometry had already been applied (see `ctx`), leaving the
        // model and the server disagreeing. `.workarea` and `.bar_win` are
        // pure reads of live screen state, so re-reading them cannot
        // double-apply anything.
        self.c.?.workarea = usable_area.workArea(core.getState().screen);
        self.c.?.bar_win = usable_area.mappedSurfaceWindow();
        reconcile.run(&instance, self.c.?, o);
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

/// Opt-in retile latency instrumentation (RETILE_PROF). Measures the wall
/// clock held by each server-grab retile -- the exact latency a user feels
/// across a tiling op. Gated by `build_options.profile_key` (the same flag as
/// the key-dispatch path) so release WMs compile it out.
///
/// This lived in `reconcile` next to the grab bracket it instrumented
/// (5.4). The bracket belongs to the pipeline, so the measurement of the
/// bracket belongs here with it.
const retile_prof = log.WindowedProfiler(
    build_options.profile_key,
    "[RETILE_PROF] last {} grab-retiles: avg={d:.0}ns min={d}ns max={d}ns",
    std.log.info,
);

/// The default reconcile entry: bump the WINDOW fact first (10.5), then
/// reconcile under a fresh server grab with the given opts -- `.{}` for a
/// plain retile, `.{ .force_restack = true }` to re-emit stacking even when
/// the ledger says nothing moved. The retile profiler measures the whole
/// bracket (ctx build through ungrabAndFlush).
///
/// The bump lives HERE, not in each caller. Eight actions used to reconcile
/// with no bump at all, so the bar could read a stale window fact after
/// geometry moved -- the invariant was "remember to bump", held only by the
/// actions that happened to route through a bumping wrapper. Making this the
/// one path that bumps is what makes it impossible to forget. A bump is a
/// monotonic `rev +%= 1` compared once per tick, so a site that wants a bump
/// for its own reasons may take a double bump here without a second work pass.
///
/// Grab ownership lives at grabScoped and nowhere else: the reconcile-under-
/// grab family this entry absorbed used to route through a second grab
/// bracket inside `reconcile` whose nested ungrab would have released the
/// outer grab. There is exactly one bracket now, and the profiler wraps it.
pub inline fn reconcileGrab(o: reconcile.Opts) void {
    core.window.bump();
    const t0: i128 = if (retile_prof.enabled) time.monotonicNs() else 0;
    defer if (retile_prof.enabled) retile_prof.note(time.monotonicNs() - t0);
    const g = grabScoped();
    defer g.deinit();
    reconcile.run(&instance, g.c.?, o);
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
    // The duty is only ever invoked on the `.before` leg (see below).
    std.debug.assert(!(order == .after and duty != null));
    const g = grabScoped();
    defer g.deinit();
    if (order == .before) {
        focus.applyPendingFocus(t);
        if (duty) |d| d();
    }
    reconcile.run(&instance, g.c.?, o);
    if (order == .after) focus.applyPendingFocus(t);
}
