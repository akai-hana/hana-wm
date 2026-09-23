//! Model-pipeline entry glue. This module owns the global Model instance,
//! builds the per-reconcile sync.Ctx from live state, and exposes the
//! reconcile slots entry points call.
//!
//! Entry points: init() (startup), dragTick() (floating drag motion),
//! reconcileNow() (retile/EWMH/manage/unmanage), and the
//! fullscreenToggleWindow/workspace hooks routed from the window layer.

const model_mod = @import("model");
const sync = @import("sync");
const core = @import("core");
const utils = @import("utils");
const focus = @import("focus");
const xcb_sink = @import("sink");
const screen = @import("screen");
const build_options = @import("build_options");
const surfaces = @import("plugins").Surfaces;
// Fullscreen EWMH/bar-arming hooks via the build-generated `window_modules`
// registry (the loop below no-ops without fullscreen).
const window_mods = @import("window_modules").modules;

/// Layout registry (build-generated); the active layout is a `u8` index into
/// it (see model.LayoutParams.kind). Empty when the tiling subsystem is
/// absent. Gated on has_tiling so tree variants without tiling compile.
const plugin = @import("plugin");
const tiling_mods = plugin.tiling_mods;
const tiling = @import("tiling_seam").tiling;

/// True after init(); tracking's facade gates every model access on this so
/// boot order never touches the undefined global instance.
pub var initialized: bool = false;

var instance: model_mod.Model = undefined;
pub fn init() void {
    instance = .{}; // bounded lists: no allocator inside the model
    g_sink = .{ .conn = core.getState().conn };
    initialized = true;
    sync.init();
}
/// READ-ONLY access to the WM model (single source of truth). The return type
/// is `*const`, so any attempt to write through this handle is a compile
/// error: the compiler is the mutation tripwire. A MUTABLE handle requires
/// the transition-layer gate (`pipeline.mut`); only modules that own model
/// transitions declare a private `Gate` (actions/window/focus/tracking).
pub inline fn model() *const model_mod.Model {
    if (!initialized) @panic("pipeline.model() called before init()");
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
    if (!initialized) @panic("pipeline.mut() called before init()");
    return &instance;
}

/// Returns the current tiling layout (a registry index, see
/// model.LayoutParams.kind) from the live model state. Falls back to config
/// name resolution pre-init. An unresolvable config name (removed module,
/// unknown spelling) is loud, never silent.
pub inline fn getCurrentLayout() u8 {
    if (initialized) return model().ws[model().current.index].params.kind;
    return defaultIndexForLayoutName(core.getState().config.tiling.layout);
}

/// Resolves a config layout name to a registry index (see
/// model.LayoutParams.kind), collapsing to the neutral default (index 0) when
/// the name does not resolve. Loud, never silent: an unresolvable/removed
/// layout name is a config bug. Shared by getCurrentLayout (pre-init fallback)
/// and persist's restored-layout degradation, so both site types resolve
/// config names identically.
pub fn defaultIndexForLayoutName(name: []const u8) u8 {
    if (!build_options.has_tiling) return 0;
    return tiling.layoutKindOf(name);
}

var g_sink: xcb_sink.XcbSink = undefined;

/// The shared XCB sink: inited once in init(), then free across every use.
inline fn sink() sync.Sink {
    return (&g_sink).sink();
}

var g_ctx: sync.Ctx = undefined;

/// The tiling engine environment for a workspace's layout params, resolved
/// from live config (scaled margins, min_dim, master side, variant index).
/// Shared by `ctx()` and the test fixture's placement expectations, so the
/// fixture mirrors production env resolution instead of hand-building it.
pub fn tilingEnv(p: *const model_mod.LayoutParams) plugin.Env {
    const cs = core.getState();
    const screen_h = cs.screen.height_in_pixels;
    return .{
        .margins = .{
            .gap = utils.scaling.scaleBorderWidth(cs.config.tiling.gap_width, screen_h),
            .border = core.borderWidth(),
        },
        .min_dim = cs.config.tiling.min_window_dim,
        .primary_on_right = cs.config.tiling.master_side == .right,
        // The model already stores the variant index for the current
        // workspace's layout params; pass it through generically. Each
        // layout MODULE translates this index to its own behavior
        // (e.g. monocle.gap_variant, grid.relax_variant) inside its own
        // file — the core carries no layout-feature booleans.
        .variant_idx = p.variant_idx,
    };
}

/// Builds the per-retile Ctx from live state: workarea via bar's helper,
/// margins/min_dim and variant booleans from config, border width from the
/// same scaled config fact (see tilingEnv), colors from config.tiling.
/// Only valid after init().
fn ctx() *sync.Ctx {
    const cs = core.getState();
    const screen_h = cs.screen.height_in_pixels;
    const p = &model().ws[model().current.index].params;
    const env = tilingEnv(p);
    g_ctx = .{
        .sink = sink(),
        .screen = .{
            .x = 0,
            .y = 0,
            .width = cs.screen.width_in_pixels,
            .height = screen_h,
        },
        .workarea = screen.workArea(cs.screen),
        .cfg_bw = env.margins.border,
        .env = env,
        .color_of = colorOf,
        .bar_win = screen.mappedSurfaceWindow(),
    };
    return &g_ctx;
}

/// Focused/unfocused border-pixel pick for the reconcile Ctx. Fullscreen
/// windows get bw=0/pixel=0 through the fullscreen branch policy in sync
/// instead. Reads MODEL focus; focus.zig mirrors every transition into
/// m.focused, so this is the same single source of truth.
fn colorOf(win: model_mod.WindowId, m: *const model_mod.Model) u32 {
    const cfg = &core.getState().config.tiling;
    return if (m.focused == win) cfg.border_focused else cfg.border_unfocused;
}

pub inline fn dragTick(win: model_mod.WindowId) void {
    sync.reconcileDragTick(&instance, sink(), win);
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
    const p = &instance.ws[instance.current.index].params;
    if (p.kind >= tiling_mods.len) return;
    const md = tiling_mods[p.kind];
    if (md.preReconcile == null) return;
    const n = model_mod.tiledCountOnWs(&instance, instance.current);
    const wa = screen.workArea(core.getState().screen);
    p.* = md.preReconcile.?(p.*, n, wa.width);
}

/// Runs a reconcile-family body under one X server grab, always
/// releasing+flushing on exit (defer), so no grab site can forget the
/// atomicity bracket. `body` is a value-capturing struct with a
/// `fn call(self, c: *Ctx) void` method (the codebase's closure idiom); each
/// entry point captures the args its compose needs.
fn withServerGrab(body: anytype) void {
    const c = ctx();
    c.sink.grabServer();
    defer c.sink.ungrabAndFlush();
    body.call(c);
}

/// Grab server, reconcile, then ungrabAndFlush, atomically.
pub inline fn reconcileUnderGrabNow(o: sync.ReconcileOpts) void {
    preReconcileDuties();
    sync.reconcileUnderGrab(&instance, ctx(), o);
}

/// Grab server, run the focus transition, reconcile, then ungrabAndFlush
/// (or the reverse order) atomically.
/// Order of `reconcileGrabFocus`' two phases inside the grab: focus lands
/// before geometry (most actions), or after (mapRequest, where the window
/// must be mapped before xcb_set_input_focus targets it).
pub const FocusOrder = enum {
    before,
    after,
};

pub inline fn reconcileGrabFocus(
    o: sync.ReconcileOpts,
    t: focus.FocusTransition,
    order: FocusOrder,
) void {
    preReconcileDuties();
    withServerGrab(struct {
        o: sync.ReconcileOpts,
        t: focus.FocusTransition,
        order: FocusOrder,
        fn call(self: @This(), c: *sync.Ctx) void {
            if (self.order == .before) focus.applyPendingFocus(self.t);
            sync.reconcile(&instance, c, self.o);
            if (self.order == .after) focus.applyPendingFocus(self.t);
        }
    }{ .o = o, .t = t, .order = order });
}

/// Focus lands before geometry so border colors and stacking are correct on
/// the first frame, but runs `duty` inside the grab after the focus protocol
/// and before the reconcile. Lets a caller fold a model-derived adjustment
/// that depends on the new focus (the viewport snap) into the same reconcile
/// instead of opening a second grab.
pub inline fn reconcileUnderGrabNowWithFocusDuty(
    o: sync.ReconcileOpts,
    t: focus.FocusTransition,
    duty: ?*const fn () void,
) void {
    preReconcileDuties();
    withServerGrab(struct {
        o: sync.ReconcileOpts,
        t: focus.FocusTransition,
        duty: ?*const fn () void,
        fn call(self: @This(), c: *sync.Ctx) void {
            focus.applyPendingFocus(self.t);
            if (self.duty) |d| d();
            sync.reconcile(&instance, c, self.o);
        }
    }{ .o = o, .t = t, .duty = duty });
}

/// Commit a focus transition inside one server grab with no reconcile: for
/// focus-only changes where geometry/stacking cannot differ (hover focus).
/// Borders repaint via the per-batch sweep on the commit's focus bump.
pub inline fn focusOnlyCommit(t: focus.FocusTransition) void {
    withServerGrab(struct {
        t: focus.FocusTransition,
        fn call(self: @This(), _: *sync.Ctx) void {
            focus.applyPendingFocus(self.t);
        }
    }{ .t = t });
}

/// Fullscreen transition classification for the atomic grab path (the fn
/// below): a named kind instead of a bool-pair so enter/exit/switch_ can't be
/// passed inconsistently. Drives the EWMH state writes and the bar
/// hide/show arming inside the grab.
pub const FullscreenKind = enum { enter, exit, switch_ };

/// Grab server, reconcile, do EWMH + bar hide, then ungrabAndFlush, atomically.
/// Specialised for the fullscreen toggle path so EWMH writes and the bar
/// unmap/hide land inside the same grab as geometry (grouped atomicity); the
/// enter path unmaps the bar immediately rather than deferring to ConfigureNotify.
pub inline fn reconcileUnderGrabNowFullscreen(
    o: sync.ReconcileOpts,
    win: model_mod.WindowId,
    prev_fs_win: ?model_mod.WindowId,
    kind: FullscreenKind,
) void {
    preReconcileDuties();
    withServerGrab(struct {
        o: sync.ReconcileOpts,
        win: model_mod.WindowId,
        prev_fs_win: ?model_mod.WindowId,
        kind: FullscreenKind,
        fn call(self: @This(), c: *sync.Ctx) void {
            sync.reconcile(&instance, c, self.o);
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
            // sync.reconcile, so it covers the bar before the unmap reaches
            // the server. Cancel any stale pending bar show from a previous
            // exit (a new enter supersedes it).
            //
            // EXIT: arm the deferred show. The bar reappears after the
            // client's ConfigureNotify confirms non-fullscreen dimensions.
            if (self.kind != .exit) {
                // Immediate bar unmap when fullscreen claims the screen.
                if (build_options.has_bar) surfaces.hideBarForFullscreen();
            } else {
                // Exit: deferred bar show (unchanged path).
                if (instance.focused) |w| {
                    for (window_mods) |m| {
                        if (m.armPendingBarShow) |show| show(w);
                    }
                }
            }
        }
    }{ .o = o, .win = win, .prev_fs_win = prev_fs_win, .kind = kind });
}

/// Flushless reconcile against the current ctx (drag tick path).
pub inline fn reconcileNow() void {
    preReconcileDuties();
    sync.reconcile(&instance, ctx(), .{});
}

/// Run pre-reconcile duties and return the pipeline context for the caller
/// to manage a manual server grab. The caller MUST call
/// ctx.sink.ungrabAndFlush() when done (typically via defer). A manual-grab
/// seam for callers needing a bespoke grab body: switchTo and the fullscreen
/// EWMH write.
pub fn grabCtx() *sync.Ctx {
    preReconcileDuties();
    return ctx();
}
