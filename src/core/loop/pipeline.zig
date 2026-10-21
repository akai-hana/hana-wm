//! Model-pipeline glue: owns the global Model, builds reconcile.Ctx per tick,
//! exposes slot entry points and reconcile hooks. X-aware (dispatches through
//! the sink, consults display facts); the X-free half of the model pipeline
//! lives in core/model.zig and tiling/.

const std = @import("std");
const model_mod = @import("model");
const core = @import("core");
const focus = @import("focus");
const types = @import("types");
const window_state_ops = @import("window_state_ops");
const xcb_sink = @import("sink");
const usable_area = @import("usable_area");
const build_options = @import("build_options");
const log = std.log.scoped(.pipeline);
const profile = @import("profile");

/// Layout registry (build-generated); the active layout is a `u8` index into it (see
/// model.LayoutParams.kind). Empty when the tiling subsystem is absent. Gated on
/// has_tiling so tree variants without tiling compile.
const contract = @import("tiling_contract");
const tiling = @import("tiling_seam").tiling;
const scaling = @import("scaling");

const reconcile = @import("reconcile");
const sink = @import("sink");
// Cycle-accepted: pipeline -> window -> registry -> window_modules -> any module ->
// pipeline. Top-level const decls are lazy, so the import cycle compiles; if it ever
// stops, the fallback is runtime slot registration (a module's init registering its
// color provider into a core-side slot). Needed only for the borders color hook (P2-47).
const window = @import("window");

var instance: model_mod.Model = undefined;
pub fn init() void {
    instance = .{}; // bounded lists: no allocator inside the model
    g_sink = .{ .conn = core.getState().conn };
    core.markModelReady();
    reconcile.init();
}

/// Clear every workspace's focus MRU (index 0 = most recent; see focus.setFocus's
/// front-insert). Boot zeroing (init's `instance = .{}`) already clears it; this
/// exists for the window layer's deinit/init reset discipline, which cycles WITHOUT a
/// pipeline re-init — a harness restart must not inherit the previous cycle's MRU
/// order. Gated so pre-model callers no-op.
pub fn clearFocusMru() void {
    if (!core.isModelReady()) return;
    for (&instance.ws) |*s| s.focus_mru.clear();
}
/// READ-ONLY access to the WM model (single source of truth). The return type is
/// `*const`, so any attempt to write through this handle is a compile error: the
/// compiler is the mutation tripwire, and it is the ONLY real one this layer ever had
/// (see `mut`).
pub inline fn state() *const model_mod.Model {
    if (!core.isModelReady()) @panic("pipeline.state() called before init()");
    return &instance;
}

/// MUTABLE access to the WM model. The enforcement is the type split itself: readers
/// take `*const` from `state()`, writers explicitly opt into `mut()`.
///
/// Deliberately bumps NO fact revision: the bump policy (why fact revs stay adjacent
/// to their owning change, and why reconcileGrab's window bump is the one structural
/// exception) is model-owner role documentation and lives with the role in
/// ARCHITECTURE.md section 5.3.
pub inline fn mut() *model_mod.Model {
    if (!core.isModelReady()) @panic("pipeline.mut() called before init()");
    return &instance;
}

/// Returns the current tiling layout (a registry index, see model.LayoutParams.kind)
/// from the live model state. Falls back to config name resolution pre-init. An
/// unresolvable config name is loud, never silent.
pub inline fn getCurrentLayout() u8 {
    if (core.isModelReady()) return state().ws[state().current.index].params.kind;
    if (comptime !build_options.has_tiling) return contract.default_kind;
    return defaultIndexForLayoutName(core.getState().config.tiling.defaultLayout());
}

/// Returns the current workspace's active tiling variant index (see
/// model.WSParams.variant_idx) from the live model state, checked at the one place
/// that already owns the workspace-index rule.
pub inline fn getCurrentVariantIdx() usize {
    return @intCast(state().ws[state().current.index].params.variant_idx);
}

/// Resolves a config layout name to a registry index (see model.LayoutParams.kind),
/// collapsing to `contract.default_kind` when the name does not resolve. Loud, never
/// silent -- an unresolvable layout name is a config bug. Shared by getCurrentLayout
/// (pre-init fallback) and handoff's restored-layout degradation so both resolve
/// config names identically.
pub fn defaultIndexForLayoutName(name: []const u8) u8 {
    if (!build_options.has_tiling) return contract.default_kind;
    return tiling.layoutKindFallingBack(name, contract.default_kind);
}

var g_sink: xcb_sink.XcbSink = undefined;

/// The shared XCB sink: inited once in init(), then free across every use. Public for
/// the grab-free wire-write paths (geometry's drag tick, floating's drag raise): a raw
/// request sequence with no model or grab involvement belongs at the call site.
pub inline fn syncSink() sink.Sink {
    return (&g_sink).sink();
}

var g_ctx: reconcile.Ctx = undefined;

/// The tiling engine environment for a workspace, resolved from live config (scaled
/// margins, min_dim, master side).
///
/// It takes no layout params: everything left in `Env` is a config-derived constant,
/// while the workspace's VARIANT index is model state reaching a layout module as
/// `View.params.variant_idx`.
fn tilingEnv() contract.Env {
    if (comptime !build_options.has_tiling) return .{
        .margins = .{ .gap = 0, .border = 0 },
        .min_dim = types.default_min_window_dim,
        .primary_on_right = false,
    };
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
/// margins/min_dim/master side from config (see tilingEnv), border color via the
/// window layer's borders module (constant 0 when absent, P2-47). Only valid after
/// init().
fn ctx() *reconcile.Ctx {
    // Inside a server grab the ctx belongs to the operation that TOOK the grab:
    // rebuilding it there would recompute `.workarea`/`.bar_win` from live state under
    // a body that has already committed to them (the fullscreen path unmaps the bar
    // inside the same grab) and would re-run the pre-reconcile duties after geometry
    // was already applied. Inside a grab, read the in-flight ctx via currentCtx(); to
    // start a new operation, call prepare().
    assertGrab(grab_depth == 0);
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
        .color_of = window.borderColorOf,
        .bar_win = usable_area.mappedSurfaceWindow(),
        // Resolved ONCE here, through the same call the bar uses, so geometry and the
        // bar's "no layout" report can never disagree.
        .layout_active = contract.activeLayoutKind(
            state().ws[state().current.index].params.kind,
            core.tilingEnabled(),
        ) != null,
    };
    return &g_ctx;
}

/// Scroll viewport caller duties applied at the single reconcile choke point,
/// dispatched through the active layout module's preReconcile hook (the scroll addon
/// registers snap-right-on-growth + clamp; no hook = no duty).
fn preReconcileDuties() void {
    if (!build_options.has_tiling) return;
    // Internal choke point: touches the private `instance` directly (not via
    // state()/mut()) because this is the model owner applying the active layout's pure
    // pre-reconcile delta (value-in, value-out). The WRITE goes through
    // window_state_ops.applyParamsDelta, closing the last un-gated channel.
    const ws = instance.current;
    const p = instance.ws[ws.index].params;
    const md = contract.moduleOf(p.kind) orelse return;
    if (md.preReconcile == null) return;
    const n = model_mod.tiledCountOnWs(&instance, ws);
    const wa = usable_area.workArea(core.getState().screen);
    window_state_ops.applyParamsDelta(&instance, ws, md.preReconcile.?(p, n, wa.width));
}

/// The ONE place a reconcile ctx is built and the one place pre-reconcile duties run.
/// Every reconcile-family entry point calls this exactly once: the scroll layout's
/// duty mutates the model, so it must be folded into the geometry that follows rather
/// than run as a separate pass.
fn prepare() *reconcile.Ctx {
    preReconcileDuties();
    return ctx();
}

/// The ctx of the grab currently in flight, for a hook that must queue its writes into
/// somebody else's atomic bracket (the EWMH fullscreen write). Asserts a grab IS held.
/// Deliberately does NOT run the pre-reconcile duties -- the enclosing operation did.
pub fn currentCtx() *reconcile.Ctx {
    assertGrab(grab_depth > 0);
    return &g_ctx;
}

/// Nesting depth of the server grab. `XGrabServer` is NOT reentrant: a nested grab
/// followed by an ungrab would release the OUTER grab too. One counter at the choke
/// point turns that into an assert at the mistake.
var grab_depth: u32 = 0;

/// The grab-depth invariant check, kept in EVERY build profile (default
/// `-Dstrict-grabs=true`): cheap integer compares that must not be lost to assert
/// elision in ReleaseFast. Opt out with `-Dstrict-grabs=false` (measured builds only).
inline fn assertGrab(cond: bool) void {
    if (comptime build_options.strict_grabs) {
        if (!cond) std.debug.panic("grab-depth invariant violated (pipeline)", .{});
    }
}

/// Server-grab ownership as a token: taking it grabs, dropping it ungrabs AND flushes.
/// Every exit path releases it, including an early return -- precisely the failure mode
/// a hand-written grab/ungrab pair invites. The ctx is built when the grab is TAKEN, so
/// every wire write and reconcile inside the bracket is computed against one ctx.
pub const ScopedGrab = struct {
    /// The ctx this bracket reconciles against, or null for a grab that was only ever
    /// for wire writes.
    c: ?*reconcile.Ctx,
    s: sink.Sink,

    /// Releases the grab and flushes. Asserts rather than tolerating a double release:
    /// an extra release would ungrab a grab this token does not own.
    pub fn deinit(self: ScopedGrab) void {
        assertGrab(grab_depth > 0);
        grab_depth -= 1;
        self.s.ungrabAndFlush();
    }

    /// Flushless reconcile inside this bracket, against this token's ctx. `o` passes
    /// through to `reconcile.run`. Asserts the token was taken with a ctx, so a grabbed
    /// caller cannot reconcile against a ctx its geometry writes are not bracketed by.
    pub fn reconcileNow(self: ScopedGrab, o: reconcile.Opts) void {
        assertGrab(self.c != null);
        // Refresh the screen-derived fields from LIVE state immediately before geometry is
        // emitted: a surface can change what it claims of the screen while the grab is held
        // (the fullscreen bar unmaps inside the same grab), and a pre-change ctx would tile
        // into an already-invalidated work area. Only these two fields are refreshed, NOT
        // the whole ctx (see `ctx` for why).
        self.c.?.workarea = usable_area.workArea(core.getState().screen);
        self.c.?.bar_win = usable_area.mappedSurfaceWindow();
        reconcile.run(&instance, self.c.?, o);
        model_mod.debugCheckInvariants(&instance);
    }
};

/// Takes the server grab, building the reconcile ctx first (ctx() refuses to build
/// under a grab) and returning the token that owns it.
pub fn grabScoped() ScopedGrab {
    assertGrab(grab_depth == 0);
    const c = prepare();
    const s = syncSink();
    s.grabServer();
    grab_depth += 1;
    return .{ .c = c, .s = s };
}

/// Takes the server grab WITHOUT building a reconcile ctx, for a client that only needs
/// atomic wire writes and runs no geometry pass (the bar config reload). Deliberately
/// does NOT run the pre-reconcile duties: with no reconcile following they would leave
/// model and server disagreeing. Use grabScoped() when a reconcile is coming.
pub fn grabOnly() ScopedGrab {
    assertGrab(grab_depth == 0);
    const s = syncSink();
    s.grabServer();
    grab_depth += 1;
    return .{ .c = null, .s = s };
}

/// Opt-in retile latency instrumentation (RETILE_PROF): wall clock held by each
/// server-grab retile. Gated by `build_options.profile_key` so release WMs compile it
/// out. The bracket belongs to the pipeline, so the measurement belongs here with it.
const retile_prof = profile.WindowedProfiler(
    build_options.profile_key,
    "[RETILE_PROF] last {} grab-retiles: avg={d:.0}ns min={d}ns max={d}ns",
    std.log.info,
);

/// The default reconcile entry: bump the WINDOW fact first, then reconcile under a
/// fresh server grab with the given opts -- `.{}` for a plain retile,
/// `.{ .force_restack = true }` to re-emit stacking even when the ledger says nothing
/// moved. The bump lives HERE, not in each caller: "remember to bump" as a per-caller
/// invariant is one an action can forget, leaving the bar to read a stale window fact
/// after geometry moved. Grab ownership lives at grabScoped and nowhere else.
pub inline fn reconcileGrab(o: reconcile.Opts) void {
    core.window.bump();
    const t0: i128 = if (retile_prof.enabled) core.monotonicNs() else 0;
    defer if (retile_prof.enabled) retile_prof.note(core.monotonicNs() - t0);
    const g = grabScoped();
    defer g.deinit();
    reconcile.run(&instance, g.c.?, o);
    model_mod.debugCheckInvariants(&instance);
}

/// Grab server, run the focus transition, reconcile, then ungrabAndFlush (or the reverse
/// order) atomically. Focus lands before geometry (most actions), or after (mapRequest).
/// `duty` (usually null) runs inside the grab after the focus protocol and before the
/// reconcile WHEN FOCUS LANDS FIRST. It runs ONLY on the `.before` leg -- asserted
/// below, because a `.after` caller's duty would otherwise drop silently.
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
    // Only ever invoked on the `.before` leg (see below).
    std.debug.assert(!(order == .after and duty != null));
    const g = grabScoped();
    defer g.deinit();
    if (order == .before) {
        focus.applyPendingFocus(t);
        if (duty) |d| d();
    }
    reconcile.run(&instance, g.c.?, o);
    if (order == .after) focus.applyPendingFocus(t);
    model_mod.debugCheckInvariants(&instance);
}
