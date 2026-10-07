//! The reconciler: plans every X request the WM owes, as a delta against the
//! sent ledger, under a server grab.
//!
//! Sends are planned here and dispatched by sink.zig's shims
//! (the sanctioned seam); Sink's inline methods are thin dispatchers
//! over that seam; the raw XCB primitives those shims call are defined
//! in core/x11/requests.zig (allowlisted primitive home); a small documented
//! allowlist covers bar lifecycle, client-protocol, and non-mutation flushes
//! (see dev/scripts/check-layers.sh Rules 1-2).
//!
//! Scroll viewport caller duties (snap-right-on-new, clamp, prev_count update)
//! run in pipeline.preReconcileDuties -- the single choke point -- before any
//! reconcile; this module never mutates model params (m is const).
//!
//! RECONCILE ALGORITHM - UNCONDITIONAL COMPUTE, DELTA SEND. Each reconcile
//! computes the desired state for every stored window that needs it (an
//! OFF-WORKSPACE fast path elides windows provably already parked -- not the
//! covering winner, not on the current ws, or presence parked -- and already
//! parked in the ledger: no recompute, no resend), so a client that mutated
//! its own geometry/border behind our back is repaired on the very next reconcile
//! -- drift-proof by construction, no diff cache, no sweep counter, no
//! staging buffer). The SEND is then diffed against the sent ledger: a
//! request whose desired value matches the last one sent is elided, because
//! resending an idempotent configure/map/park request is a pure no-op the X
//! server would discard. Parked windows get ONE merged park request only on
//! the park transition; visible windows send only the map/pixel/bw/geometry
//! requests that actually changed, in the order map -> pixel -> geometry
//! (stacking mode merged into the geometry request, and the border width
//! folded into it too when both change -- the switch/unpark shape). Sending
//! full desired state on change is still drift-proofing; we only avoid
//! replaying what the server already has.
//!
//! The SENT LEDGER is a write-only record of what was actually sent (field
//! semantics: `ledger.SentEntry`). Exactly five reads of it are behavioral
//! contract:
//!   0. OFF-WORKSPACE FAST PATH: reads `parked` to elide windows provably
//!      already parked (no recompute, no park resend, never a fallback
//!      winner) -- skipped otherwise by the full path below.
//!   1. Multi-tag orphans: kept at their previous real geometry
//!      rather than parking. A history-less orphan parks (first sight /
//!      registered offscreen).
//!   2. Winner-raise derivation: rides .above ONLY when geometry moved,
//!      when it unparked, or under force_restack, derived by comparing the
//!      new rect against the ledger and reading its parked flag.
//!   3. Floating-detach / title prefetch (ledger.lastRectFor,
//!      reconcile.truthRect): the live rect as the new floating base, null
//!      while parked.
//!   4. Parked drift: `parked_dirty` (set when the client moved a parked
//!      window behind our back) forces a recompute/re-park instead of the
//!      elision -- two reads, the fast-path `continue` and the park send.
//!

const std = @import("std");
const build_options = @import("build_options");
const model = @import("model");
const log = @import("log");

/// The tiling engine is reached through the build-generated `tiling_seam`:
/// when no tiling subsystem is present the seam is an empty struct, and every
/// `tiling.*` member use below sits behind a `has_tiling` gate, so the
/// reconcile path still runs (park/map/stack) with the layout-computation
/// block skipped and the placement lookup table left empty. The interchange
/// TYPES (View/List/Placement/Env/HintsView/parked_rect) come from the tiling
/// contract (contract.zig), which both the tiling engine and this reconciler
/// reference — no mirrored duplicate to keep in lockstep, and no local stub.
const contract = @import("contract");
const tiling = @import("tiling_seam").tiling;
const ledger = @import("ledger");
const xtrace = @import("xtrace");

/// Scratch for the opt-in X trace line; only ever written when tracing is
/// armed for this window, so the common path never touches it.
var trace_buf: [96]u8 = undefined;
const sink = @import("sink");

pub const Ctx = struct {
    sink: sink.Sink,
    /// Full screen rect (fullscreen branch geometry).
    screen: model.Rect,
    /// Screen minus bar; computed by the caller with the existing
    /// bar-offset helper (workArea(ctx)). Used for tiled geometry.
    workarea: model.Rect,
    env: contract.Env = .{},
    /// Focus/mode border color; ported from borders.resolveBorderColor minus
    /// its fullscreen check (fullscreen zeroes via bw/pixel policy instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
    /// Whether a layout module may place windows (13.6). The CALLER resolves
    /// it -- normally `contract.activeLayoutKind(kind) != null` -- so this file
    /// asks the same question the bar asks without reading core config state
    /// itself, and so the reconcile stays drivable with a bare model.
    layout_active: bool = true,
};

pub const Opts = struct { force_restack: bool = false };

/// Fast-path reconcile for drag ticks: sends ONLY geometry for the dragged
/// window, skipping all other windows, the tiling compute, and border/map
/// requests. Safe during a drag because:
///   - No windows appear/disappear (no map/unmap transitions)
///   - No focus changes (border color stays the same)
///   - No tiling layout changes (the dragged window is floating)
///   - No fullscreen transitions
///   - The dragged window is already mapped with the correct border
/// Reduces XCB calls from 4×N (full reconcile) to 1 per tick.
/// Takes just the Sink (not the full Ctx) because it only sends the dragged
/// window's geometry — the workarea/env/color machinery is never consulted.
pub fn reconcileDragTick(m: *const model.Model, snk: sink.Sink, win: model.WindowId) void {
    const e = m.store.get(win) orelse return;
    if (e.presence != .present) return;
    const rect: model.Rect = switch (e.anchor) {
        .floating => |r| r,
        .tiled => return,
    };

    snk.configure(win, .{ .rect = rect });

    // Update sent ledger so lastRectFor / toggleFloating see the live position.
    // Carry the last real border width/pixel across the drag. Writing
    // 0,0 here would revert them, and the next full reconcile would resend a
    // border the server already has -- a visible repaint flash on the
    // dragged window every tick.
    const gop = ledger.sentGetOrPut(win) orelse return;
    ledger.markSentVisible(gop, rect, gop.bw, gop.pixel);
}

/// The layout half of a reconcile: the coverage winner (which window owns
/// the current workspace's screen this tick) plus the placements a layout
/// module produced and the per-slot lookup that resolves them in O(1).
/// Fixed-capacity stack scratch, no allocation: the plan lives in `run`'s
/// frame and is read by the winner seed and the fused send loop.
const Plan = struct {
    /// The core model helper resolves which covering window owns the current
    /// workspace's screen. OR semantics (anchor-or-visible over the store),
    /// deliberately distinct from the fullscreen module's AND scan (rec +
    /// present + recorded on ws); sync must not enumerate optional modules,
    /// so it reads model truth.
    fs_win: ?model.WindowId = null,
    placements: contract.List = .{},
    /// Per-window placement lookup: `pl_of_slot[i]` is the index into
    /// `placements` of the placement for store slot `i`, or null when that
    /// window has no placement this reconcile. Built alongside the layout
    /// compute (one write per ordered window); the fused store loop in
    /// `sendAll` already knows each window's slot via m.store.at(i) and so
    /// resolves its placement in O(1) instead of an O(N) scan per window.
    /// Stack scratch, no allocation, matching the file's fixed-capacity style.
    pl_of_slot: [model.store_capacity]?usize = [_]?usize{null} ** model.store_capacity,
};

/// One full reconcile: plan (work area + coverage winner + layout compute),
/// seed the raise winner, fuse-compute-and-send every stored window, then the
/// force_restack bar raise. Split into phases for readability; the fused
/// per-window loop stays whole because that fusion IS the algorithm.
pub fn run(m: *const model.Model, ctx: *Ctx, opts: Opts) void {
    var plan: Plan = .{};
    computeLayout(m, ctx, &plan);
    var winner = seedWinner(m, &plan);
    sendAll(m, ctx, opts, &plan, &winner);

    // force_restack additionally raises bar/top.
    if (opts.force_restack) {
        if (ctx.bar_win) |bar| ctx.sink.stackOnly(bar, .above);
    }

    // DO NOT FLUSH HERE. Caller owns flushing.
}

/// Phase 1: coverage winner plus the layout compute over the shown workspace
/// (skipped when a covering window owns the screen, or when the tiling
/// subsystem is absent). `plan.placements`/`plan.pl_of_slot` start from the
/// struct defaults (empty / all-null), so nothing needs re-clearing here.
fn computeLayout(m: *const model.Model, ctx: *Ctx, plan: *Plan) void {
    // Work-area (screen minus bar) and coverage winner: see `Plan`.
    const wa = ctx.workarea;

    plan.fs_win = model.coveringOccupantOnWs(m, m.current);

    var order_buf: [model.store_capacity]model.WindowId = undefined;
    var hints_buf: [model.store_capacity]model.SizeHints = undefined;
    // 13.6: ONE activation gate, and it also SUPPLIES the geometry. This used
    // to be `build_options.has_tiling` (a COMPILE-time fact) while the bar
    // reported the active layout from `contract.activeLayoutKind` (enabled AND
    // registered), so with `tiling.enabled = false` the bar showed "no layout"
    // and the geometry still tiled -- two answers to one question. Gating on
    // the resolved kind also subsumes the no-tiling build (an empty registry
    // resolves to null).
    const params = &m.ws[m.current.index].params;
    if (plan.fs_win == null) {
        var n: usize = 0;
        const tiled = &m.ws[m.current.index].tiled_order;
        for (tiled.constSlice()) |w| {
            // One binary search per window: indexOf locates the row once; the
            // entry comes from `at` instead of a second `get` lookup.
            const slot = m.store.indexOf(w) orelse continue;
            const e = m.store.at(slot).val;
            if (!model.taggedOn(e.*, m.current)) continue;
            // First write wins, mirroring the removed findPlacement's
            // first-match semantics; the store holds each id once so this is
            // just defensive.
            if (plan.pl_of_slot[slot] == null) plan.pl_of_slot[slot] = n;
            order_buf[n] = w;
            hints_buf[n] = e.size_hints;
            n += 1;
        }
        if (n > 0) {
            // `comptime` on the build flag is load-bearing: it prunes the
            // `tiling.compute` reference in a no-tiling build, where the seam
            // is an empty struct (the file-header invariant). A plain runtime
            // `ctx.layout_active` would not, and the seam lookup would fail to
            // compile in exactly the build that must not mention tiling.
            const float_all = if (comptime !build_options.has_tiling) true else !ctx.layout_active;
            if (float_all) {
                // Tiling off: every window floats at the full work area. The
                // alternative -- emit nothing -- is not a neutral "no layout",
                // it is a broken screen: a `.tiled` entry with no placement is
                // parked on first sight (invisible) and thereafter frozen at
                // whatever rect it last had (windows piled on one spot). The
                // same fallback is what a no-tiling build gets, so "no layout
                // modules" and "layout disabled" have ONE answer.
                for (order_buf[0..n]) |w| {
                    _ = plan.placements.append(.{ .win = w, .rect = wa, .visible = true });
                }
            } else {
                const view: contract.View = .{ .order = order_buf[0..n], .params = params, .workarea = wa, .hints = hints_buf[0..n], .focused = m.focused, .env = ctx.env };
                tiling.compute(params.kind, &view, &plan.placements);
            }
        }
    }
}

/// Phase 2: winner seed: fullscreen winner outright; else the focused window
/// when its desire will be non-parked (checked here so no earlier store entry
/// can shadow it); else the fused loop elects the first non-parked desire.
/// Mirrors computeDesire's ownership of parked-ness (desireIsNonParked,
/// with has_kept_rect = false: the ledger is unknowable pre-reconcile, so a
/// placement-less visible orphan is left to the first-desire fallback).
/// The fast-path visibility is derived here exactly once (shared with
/// the fused loop below; the seed spans only this focused-window test).
fn seedWinner(m: *const model.Model, plan: *const Plan) ?model.WindowId {
    var winner: ?model.WindowId = plan.fs_win;
    if (winner == null) if (m.focused) |f| blk: {
        const slot = m.store.indexOf(f) orelse break :blk;
        const fe = m.store.at(slot).val.*;
        if (fe.presence == .present and desireIsNonParked(fe, plan.fs_win, placementOfSlot(&plan.placements, &plan.pl_of_slot, slot), false, model.visibleEntry(m, &fe, m.current))) winner = f;
    };
    return winner;
}

/// Phase 3: one fused loop over the store: compute a window's desire, then
/// SEND it immediately. Ordering is via the Sink adapter (a widening PR
/// proved the contract survives reordering), honoring two invariants here:
/// map precedes geometry so a first-show/unparking client exposes at its
/// final rect, and border width is merged into the geometry configure when
/// both change (parked windows emit ONE merged park request instead:
/// offscreen X + BELOW).
///
/// The ledger reads inside are contract, not optimization (file header): the
/// orphan branch keeps the last real geometry (read 1), raise triggers derive
/// from rect/parked comparisons (read 2), and everything written here feeds
/// lastRectFor/truthRect (read 3). Sends never consult the ledger to SKIP
/// anything. `winner` arrives seeded and is still mutable here: the first
/// non-parked desire in store order elects itself (fallback election).
fn sendAll(
    m: *const model.Model,
    ctx: *Ctx,
    opts: Opts,
    plan: *const Plan,
    winner: *?model.WindowId,
) void {
    const fs_win = plan.fs_win;
    const placements = &plan.placements;
    const pl_of_slot = &plan.pl_of_slot;

    const count = m.store.count();
    // One warn per reconcile when any window's record couldn't be written, not one
    // per window: the condition is structural (ledger at store_capacity), so
    // a full reconcile would otherwise log per window.
    var ledger_overflow = false;
    for (0..count) |i| {
        const it = m.store.at(i);
        const win = it.key;
        const e: *const model.Entry = it.val;

        // One get-or-create per window: the same record backs the pre-send
        // contract reads AND the post-send write, so a visible window costs a
        // single scan. The record is read before any send and only written
        // after, so raises still derive from what we last sent, never from
        // this reconcile's sends. When the ledger is full and `win` has no record
        // yet, `gop` is null: reads see a fresh blank entry and the write is
        // lost (one per-reconcile warning at the loop's end; sends never depend on
        // the ledger).
        const gop = ledger.sentGetOrPut(win);
        const last = (if (gop) |g| g.* else ledger.SentEntry.blank());

        // OFF-WORKSPACE FAST PATH: a desire that is PROVABLY parked (not the
        // covering winner, not on the current ws, or presence parked) and is
        // already parked in the ledger needs no recompute and no send -- the
        // full path would derive parked, elide the park resend (last.parked
        // already true), never be a fallback winner, and rewrite the same
        // parked=true.
        const is_fs = win == fs_win;
        const on_current = model.visibleEntry(m, e, m.current);
        const definitely_parked_desire = e.presence == .parked or !on_current;
        // `parked_dirty` means the client moved this parked window behind our
        // back, so the elision below would strand it on screen; recompute and
        // re-park it. See ledger.SentEntry.parked_dirty.
        if (!is_fs and definitely_parked_desire and last.parked and !last.parked_dirty) continue;

        // Resolve this tiled window's placement in O(1): the lookup table is
        // indexed by store slot, which this store iteration already provides.
        const placement = if (e.anchor == .tiled)
            placementOfSlot(placements, pl_of_slot, i)
        else
            null;
        const desire = computeDesire(m, ctx, e, win, fs_win, placement, winner, last, on_current);
        const rect = desire.rect;
        const bw = desire.bw;
        const pixel = desire.pixel;
        const parked = desire.parked;
        const is_winner = winner.* == win;

        const tracing = xtrace.enabled() and xtrace.watches(win);
        if (parked) {
            // Re-send on the transition OR when the client moved itself while
            // parked: `last.parked` stays true across the drift, so without
            // the dirty term the recompute above would compute a fresh park
            // and then throw it away.
            if (!last.parked or last.parked_dirty) {
                if (tracing) xtrace.outbound(win, "park", "unpark-then-park");
                // Map before park: a fresh window's own map request was
                // redirected by SubstructureRedirect (never performed by the
                // server), so the offscreen park would otherwise leave it
                // unmapped, and a focus issued for it (spawn under a covering
                // winner, cross-workspace spawn) fails with BadMatch.
                if (!last.has_rect) ctx.sink.map(win);
                ctx.sink.park(win);
            } else if (tracing) {
                // The fast path elided this window entirely: it was already
                // parked where we put it. Logged because "hana said nothing"
                // and "hana said nothing BECAUSE it skipped the window" are
                // different findings, and a trace has to distinguish them.
                xtrace.outbound(win, "park-elided", "already parked");
            }
        } else {
            // Raise triggers per the ledger contract (file header read 2): winner
            // .above on geometry motion, unpark, or restack pressure only.
            const first_send = !last.has_rect;
            // Geometry only: `border_width` is owned by the separate `need_bw`
            // check below (last.bw), so letting it into `moved` would make a
            // border-only change look like motion and raise for nothing.
            const moved = first_send or !last.rect.eqlGeom(rect);
            const unpark_transition = last.parked;
            const raise_winner = is_winner and (moved or unpark_transition or opts.force_restack);

            const need_map = first_send or unpark_transition;
            const need_bw = !last.has_rect or last.bw != bw;
            const need_pixel = !last.has_rect or last.pixel != pixel;
            const need_geom = moved or unpark_transition or raise_winner;

            // Opt-in X trace (see core/loop/xtrace.zig). Each line is guarded
            // by the SAME condition as the send it describes, so the log can
            // never claim a request that did not happen -- a trace that
            // over-reports is worse than no trace. Recorded before the send so
            // the order matches what the server sees. This is the outbound half
            // of the pairing that makes a trace decisive: it shows whether hana
            // ever re-asserted a geometry, or stayed silent while the window's
            // on-screen contents diverged from its state.
            if (need_map) {
                if (tracing) xtrace.outbound(win, "map", "");
                ctx.sink.map(win);
            }
            if (need_pixel) {
                if (tracing) xtrace.outbound(win, "border_pixel", "");
                ctx.sink.borderPixel(win, pixel);
            }
            // One configure carrying everything that changed. Border width and
            // geometry travel together on the common switch/unpark shape, and
            // this can no longer express them as two separate requests.
            if (need_bw or need_geom) {
                if (tracing) xtrace.outbound(win, "configure", switch (need_geom) {
                    true => std.fmt.bufPrint(&trace_buf, "{d}x{d}+{d}+{d} bw={d} stack={s}", .{
                        rect.width,                         rect.height, rect.x, rect.y, bw,
                        if (raise_winner) "above" else "-",
                    }) catch "rect",
                    false => std.fmt.bufPrint(&trace_buf, "bw={d} stack={s}", .{
                        bw,
                        if (raise_winner) "above" else "-",
                    }) catch "bw",
                });
                ctx.sink.configure(win, .{
                    .rect = if (need_geom) rect else null,
                    .bw = if (need_bw) bw else null,
                    .stack = if (raise_winner) .above else null,
                });
            }
        }

        // Ledger write: record what we actually sent. A park preserves the
        // previous record's rect/has_rect; an unpark overwrites wholesale.
        if (gop) |g| {
            // A park (fresh or drift repair) records that the window is where
            // we want it, which is also what clears the dirty flag.
            if (parked) g.parked = true else ledger.markSentVisible(g, rect, bw, pixel);
            g.parked_dirty = false;
        } else ledger_overflow = true;
    }
    if (ledger_overflow) log.err("reconcile: ledger full; some sends applied, records lost", .{});
}

/// Best known live geometry for `win` without a server round trip:
///   1. floating base rect from the model (authoritative while floating),
///   2. else the last visible geometry we sent (null while parked/unsent).
pub fn truthRect(m: *const model.Model, win: model.WindowId) ?model.Rect {
    const e = m.store.get(win) orelse return null;
    if (e.presence == .present and e.anchor == .floating) return e.anchor.floating;
    return ledger.lastRectFor(win);
}

const Desire = struct {
    rect: model.Rect,
    bw: u16,
    pixel: u32,
    parked: bool,
};

/// Park a desire: zero the border width/pixel and set the parked flag.
/// Shared trailer of computeDesire's parking arms.
fn markParked(bw: *u16, pixel: *u32, parked: *bool) void {
    bw.* = 0;
    pixel.* = 0;
    parked.* = true;
}

/// True when a `.present` entry's desire will be non-parked (seen/signaled
/// on screen) on the current workspace. A window under a fullscreen covering
/// winner parks regardless of anchor (covered sibling); a floating window
/// must be on-workspace-visible; a tiled window needs a visible placement, or
/// -- with none (multi-tag orphan) -- on-workspace visibility AND a kept
/// last-sent rect (`has_kept_rect`). Shared by the winner seed and
/// computeDesire so the focused window's priority cannot drift from its
/// desire: the seed passes `has_kept_rect = false` (the ledger is unknowable
/// there, so placement-less orphans stay on the reconcile's first-desire
/// fallback).
fn desireIsNonParked(
    e: model.Entry,
    fs_win: ?model.WindowId,
    placement: ?contract.Placement,
    has_kept_rect: bool,
    on_current: bool,
) bool {
    if (fs_win != null) return false;
    switch (e.anchor) {
        .floating => return on_current,
        .tiled => return if (placement) |p| p.visible else (on_current and has_kept_rect),
    }
}

/// Compute the desired state for a single store entry. The `winner` pointer
/// is mutated when this is the first non-parked entry in store order (fallback
/// winner election). `ledger` is the pre-send record for orphan keep-last.
fn computeDesire(
    m: *const model.Model,
    ctx: *Ctx,
    e: *const model.Entry,
    win: model.WindowId,
    fs_win: ?model.WindowId,
    placement: ?contract.Placement,
    winner: *?model.WindowId,
    last: ledger.SentEntry,
    on_current: bool,
) Desire {
    var rect: model.Rect = contract.parked_rect;
    var bw: u16 = ctx.env.margins.border;
    var pixel: u32 = ctx.color_of(win, m);
    var parked = false;

    switch (e.presence) {
        // Parked entries always park. Covering records: the winner owns the
        // full screen, borderless; siblings park too (bw/pixel preserved for
        // the exit replay); when no winner resolves, park outright.
        .parked, .covering => {
            if (e.presence == .parked or fs_win == null) {
                markParked(&bw, &pixel, &parked);
            } else if (win == fs_win) {
                rect = ctx.screen;
                bw = 0;
                pixel = 0;
            } else {
                // Deliberately NOT markParked: this branch keeps bw/pixel, and
                // so does the doc above. markParked zeroes both, which is
                // right for the "park from a clean slate" arms above and wrong
                // here -- the exit replay needs the borders the window was
                // last given, or it comes back undecorated.
                parked = true;
            }
        },
        // A covering window owns the screen this reconcile: every other present
        // window is a covered sibling and parks (geometry preserved for the
        // exit replay), regardless of anchor.
        .present => {
            // Parked-ness comes from the shared predicate (see
            // desireIsNonParked); the arms below fill geometry, and the
            // orphan/offscreen arm's markParked keeps its border/pixel
            // side effects.
            parked = !desireIsNonParked(e.*, fs_win, placement, last.has_rect, on_current);
            switch (e.anchor) {
                .floating => |r| rect = r,
                .tiled => if (placement) |p| {
                    rect = p.rect;
                } else if (on_current and last.has_rect) {
                    // Multi-tagged orphan never hidden; keep last-sent rect,
                    // parked only when nothing was ever sent (first sight /
                    // offscreen) -- exactly what desireIsNonParked saw.
                    rect = last.rect;
                } else markParked(&bw, &pixel, &parked),
            }
        },
    }

    // Fallback winner: first non-parked desire in store order.
    if (winner.* == null and !parked) winner.* = win;
    return .{ .rect = rect, .bw = bw, .pixel = pixel, .parked = parked };
}

/// O(1) placement lookup: placement for store slot `slot`, or null when the window
/// has no placement this reconcile (multi-tag orphan, off-workspace, no-tiling
/// build). `slot` must be < m.store.count(); the table was built alongside
/// placements in reconcile. Indexes into a copy-cached slice so a module that
/// emits fewer placements than ordered windows degrades to null (same as the
/// removed linear scan) instead of indexing out of bounds.
fn placementOfSlot(
    placements: *const contract.List,
    pl_of_slot: *const [model.store_capacity]?usize,
    slot: usize,
) ?contract.Placement {
    const idx = pl_of_slot[slot] orelse return null;
    const slice = placements.constSlice();
    if (idx >= slice.len) return null;
    return slice[idx];
}
