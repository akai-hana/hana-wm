//! Sends are planned in sync.zig and dispatched by sync/sink.zig's shims
//! (the sanctioned seam); sync.Sink's inline methods are thin dispatchers
//! over that seam; the raw XCB primitives those shims call are defined
//! in core/x11/wire.zig (allowlisted primitive home); a small documented
//! allowlist covers bar lifecycle, client-protocol, and non-mutation flushes
//! (see dev/scripts/check-layers.sh Rules 1-2).
//!
//! Scroll viewport caller duties (snap-right-on-new, clamp, prev_count update)
//! run in pipeline.preReconcileDuties -- the single choke point -- before any
//! reconcile; this module never mutates model params (m is const).
//!
//! RECONCILE ALGORITHM - UNCONDITIONAL COMPUTE, DELTA SEND. Every pass
//! computes the desired state for every stored window that needs it (an
//! OFF-WORKSPACE fast path elides windows provably already parked -- not the
//! covering winner, not on the current ws, or presence parked -- and already
//! parked in the ledger: no recompute, no resend), so a client that mutated
//! its own geometry/border behind our back is repaired on the very next pass
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
//! The SENT LEDGER is a WRITE-ONLY record of what was actually sent
//! ({rect, has_rect, parked, bw, pixel} per window; a park flips `parked` and
//! preserves rect/has_rect). Exactly four reads of it are behavioral contract:
//!   0. OFF-WORKSPACE FAST PATH: reads `parked` to elide windows provably
//!      already parked (no recompute, no park resend, never a fallback
//!      winner) -- skipped otherwise by the full path below.
//!   1. Multi-tag orphans: kept at their previous real geometry
//!      rather than parking. A history-less orphan parks (first sight /
//!      registered offscreen).
//!   2. Winner-raise derivation: rides .above ONLY when geometry moved,
//!      when it unparked, or under force_restack, derived by comparing the
//!      new rect against the ledger and reading its parked flag.
//!   3. Floating-detach / title prefetch (actions.lastRectFor,
//!      sync.truthRect): the live rect as the new floating base, null while
//!      parked.

const std = @import("std");
const utils = @import("utils");
const build_options = @import("build_options");
const model = @import("model");
const debug = @import("debug");

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

pub const Stack = enum { above };

/// Request sink. Production wires XcbSink; tests wire a recorder. One batch
/// = everything queued between caller flushes (xcb buffers requests; the
/// CALLER decides when to flush).
pub const Sink = struct {
    ptr: *anyopaque,
    vt: *const VTable,

    pub const VTable = struct {
        map: *const fn (*anyopaque, model.WindowId) void,
        geom: *const fn (*anyopaque, model.WindowId, utils.Rect, ?Stack) void,
        geom_bordered: *const fn (*anyopaque, model.WindowId, utils.Rect, u16, ?Stack) void,
        border_width: *const fn (*anyopaque, model.WindowId, u16) void,
        border_pixel: *const fn (*anyopaque, model.WindowId, u32) void,
        park: *const fn (*anyopaque, model.WindowId) void,
        stack_only: *const fn (*anyopaque, model.WindowId, Stack) void,
        set_ewmh_fullscreen: *const fn (*anyopaque, model.WindowId, u32, u32, bool) void,
        flush: *const fn (*anyopaque) void,
        grab_server: *const fn (*anyopaque) void,
        ungrab_and_flush: *const fn (*anyopaque) void,
    };

    pub inline fn map(self: Sink, win: model.WindowId) void {
        self.vt.map(self.ptr, win);
    }
    pub inline fn geom(self: Sink, win: model.WindowId, rect: utils.Rect, stack: ?Stack) void {
        self.vt.geom(self.ptr, win, rect, stack);
    }
    /// Geometry + border width merged into one configure request; the shape a
    /// workspace switch emits for every arriving window.
    pub inline fn geomBordered(self: Sink, win: model.WindowId, rect: utils.Rect, bw: u16, stack: ?Stack) void {
        self.vt.geom_bordered(self.ptr, win, rect, bw, stack);
    }
    pub inline fn borderWidth(self: Sink, win: model.WindowId, bw: u16) void {
        self.vt.border_width(self.ptr, win, bw);
    }
    pub inline fn borderPixel(self: Sink, win: model.WindowId, pixel: u32) void {
        self.vt.border_pixel(self.ptr, win, pixel);
    }
    pub inline fn park(self: Sink, win: model.WindowId) void {
        self.vt.park(self.ptr, win);
    }
    pub inline fn stackOnly(self: Sink, win: model.WindowId, s: Stack) void {
        self.vt.stack_only(self.ptr, win, s);
    }
    pub inline fn setEwmhFullscreen(self: Sink, win: model.WindowId, state_atom: u32, fs_atom: u32, is_fullscreen: bool) void {
        self.vt.set_ewmh_fullscreen(self.ptr, win, state_atom, fs_atom, is_fullscreen);
    }
    pub inline fn flush(self: Sink) void {
        self.vt.flush(self.ptr);
    }
    pub inline fn grabServer(self: Sink) void {
        self.vt.grab_server(self.ptr);
    }
    pub inline fn ungrabAndFlush(self: Sink) void {
        self.vt.ungrab_and_flush(self.ptr);
    }
};

pub const Ctx = struct {
    sink: Sink,
    /// Full screen rect (fullscreen branch geometry).
    screen: utils.Rect,
    /// Screen minus bar; computed by the caller with the existing
    /// bar-offset helper (workArea(ctx)). Used for tiled geometry.
    workarea: utils.Rect,
    env: contract.Env = .{},
    /// Focus/mode border color; ported from borders.resolveBorderColor minus
    /// its fullscreen check (fullscreen zeroes via bw/pixel policy instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
};

pub const ReconcileOpts = struct { force_restack: bool = false };

/// What we last sent per window; WRITE-ONLY bookkeeping whose four contract
/// reads are documented in the header:
///   - has_rect: whether a visible geometry was EVER sent (an explicit flag,
///     not a sentinel rect: a legitimately placed zero-size window at the
///     origin would collide with a "never sent" marker value);
///   - rect: the last VISIBLE geometry sent (survives parks);
///   - parked: whether the latest pass parked it;
///   - bw: the last border width sent for a visible window (0 while parked/never);
///   - pixel: the last border pixel sent for a visible window (0 while parked/never).
const SentEntry = struct {
    rect: utils.Rect = contract.parked_rect,
    has_rect: bool = false,
    parked: bool = false,
    bw: u16 = 0,
    pixel: u32 = 0,
};

const State = struct {
    /// Ledger of sent state (see SentEntry), keyed by window id in the
    /// model.Store's sorted-key array: get-or-put / forget resolve records
    /// by binary search with no parallel id index to keep in lockstep.
    sent: model.Store(model.WindowId, SentEntry, model.store_capacity) = .{},
};

/// Owned by the compositor process; re-init() on reconnect. Module-private:
/// all access goes through this file's API.
var st: State = .{};

pub fn init() void {
    st = .{};
}

/// Ledger read of a window's last-sent record. pub because it is also the
/// test verification seam (sync_test/tracking_test assert what a pass sent);
/// production reads at lastRectFor/truthRect.
pub fn sentGet(win: model.WindowId) ?SentEntry {
    return st.sent.get(win);
}

/// Ledger get-or-create for `win`: pointer to its record, or null when the
/// ledger is full and `win` has no slot yet. Callers treat both cases the same.
/// pub: production reconcile, plus the test verification seam (perf_test).
pub fn sentGetOrPut(win: model.WindowId) ?*SentEntry {
    if (st.sent.getPtr(win)) |r| return r;
    return st.sent.put(win, .{}) catch null;
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from `forget` (actions.unmanage / test seam).
pub fn forget(win: model.WindowId) void {
    _ = st.sent.remove(win);
}

/// Record a border width sent for `win` without disturbing the ledger's
/// geometry/park state. Called by the border-detail path (win.zig) after a
/// width-only send so the next full reconcile's need_bw check
/// (`!last.has_rect or last.bw != bw`) elides the redundant resend. No-op
/// when the ledger is full or the get-or-put errors (sentGetOrPut contract).
pub fn markSentBorderWidth(win: model.WindowId, w: u16) void {
    const gop = sentGetOrPut(win) orelse return;
    gop.bw = w;
}

/// Record a visible (non-parked) send in the ledger. Shared by the full
/// reconcile (border width/pixel known) and the drag-tick fast path (0,0).
fn markSentVisible(e: *SentEntry, rect: utils.Rect, bw: u16, pixel: u32) void {
    e.* = .{ .rect = rect, .has_rect = true, .parked = false, .bw = bw, .pixel = pixel };
}

/// Opt-in retile latency instrumentation (RETILE_PROF). Measures the wall
/// clock held by each server-grab retile -- the exact latency a user feels
/// across a tiling op -- plus how many store entries were walked (the full
/// path walks every entry each pass, modulo the off-workspace fast path).
/// Gated by `build_options.profile_key` (the same flag as the key-dispatch
/// path) so release WMs compile it out.
const retile_prof = utils.WindowedProfiler(
    build_options.profile_key,
    "[RETILE_PROF] last {} grab-retiles: avg={d:.0}ns min={d}ns max={d}ns",
    std.log.info,
);

pub fn reconcileUnderGrab(m: *const model.Model, ctx: *Ctx, opts: ReconcileOpts) void {
    // grab_server -> reconcile(opts) -> optional top/bar restack ->
    // ungrabAndFlush. Zero round trips inside.
    const t0: i128 = if (retile_prof.enabled) utils.monotonicNs() else 0;
    ctx.sink.grabServer();
    defer {
        ctx.sink.ungrabAndFlush();
        if (retile_prof.enabled) retile_prof.note(utils.monotonicNs() - t0);
    }
    reconcile(m, ctx, opts);
}

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
pub fn reconcileDragTick(m: *const model.Model, sink: Sink, win: model.WindowId) void {
    const e = m.store.get(win) orelse return;
    if (e.presence != .present) return;
    const rect: utils.Rect = switch (e.anchor) {
        .floating => |r| r,
        .tiled => return,
    };

    sink.geom(win, rect, null);

    // Update sent ledger so lastRectFor / toggleFloating see the live position.
    // Carry the last real border width/pixel across the drag. Writing
    // 0,0 here would revert them, and the next full reconcile would resend a
    // border the server already has -- a visible repaint flash on the
    // dragged window every tick.
    const gop = sentGetOrPut(win) orelse return;
    markSentVisible(gop, rect, gop.bw, gop.pixel);
}

pub fn reconcile(m: *const model.Model, ctx: *Ctx, opts: ReconcileOpts) void {
    // Work-area (screen minus bar) and coverage winner: the core model helper
    // resolves which covering window owns the current workspace's screen.
    // OR semantics (anchor-or-visible over the store), deliberately distinct
    // from the fullscreen module's AND scan (rec + present + recorded on ws);
    // sync must not enumerate optional modules, so it reads model truth.
    const wa = ctx.workarea;

    const fs_win: ?model.WindowId = model.coveringOccupantOnWs(m, m.current);

    // Layout compute over the shown workspace (skipped when a covering window
    // owns the screen, or when the tiling subsystem is absent).
    var order_buf: [model.store_capacity]model.WindowId = undefined;
    var hints_buf: [model.store_capacity]model.SizeHints = undefined;
    var placements: contract.List = .{};
    // Per-window placement lookup: `pl_of_slot[i]` is the index into
    // `placements` of the placement for store slot `i`, or null when that
    // window has no placement this pass. Built alongside the layout compute
    // below (one write per ordered window), then the fused store pass below
    // -- which already knows each window's slot via m.store.at(i) -- resolves
    // its placement in O(1) instead of an O(N) scan per window. Stack scratch,
    // no allocation, matching the file's fixed-capacity style.
    var pl_of_slot: [model.store_capacity]?usize = [_]?usize{null} ** model.store_capacity;
    if (build_options.has_tiling and fs_win == null) {
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
            if (pl_of_slot[slot] == null) pl_of_slot[slot] = n;
            order_buf[n] = w;
            hints_buf[n] = e.size_hints;
            n += 1;
        }
        const hv = contract.HintsView{ .order = order_buf[0..n], .hints = hints_buf[0..n] };
        const params = &m.ws[m.current.index].params;
        const view: contract.View = .{ .order = order_buf[0..n], .params = params, .workarea = wa, .hints = &hv, .focused = m.focused, .env = ctx.env };
        if (n > 0) {
            tiling.compute(params.kind, &view, &placements);
        }
    }

    // Winner seed: fullscreen winner outright; else the focused window when
    // its desire will be non-parked (checked here so no earlier store entry
    // can shadow it); else the pass elects the first non-parked desire.
    var winner: ?model.WindowId = fs_win;
    // Mirrors computeDesire's ownership of parked-ness (desireIsNonParked,
    // with has_kept_rect = false: the ledger is unknowable pre-pass, so a
    // placement-less visible orphan is left to the first-desire fallback).
    // The fast-path visibility is derived here exactly once (shared with
    // the fused pass below; the seed spans only this focused-window test).
    if (winner == null) if (m.focused) |f| blk: {
        const slot = m.store.indexOf(f) orelse break :blk;
        const fe = m.store.at(slot).val.*;
        if (fe.presence == .present and desireIsNonParked(fe, fs_win, placementOfSlot(&placements, &pl_of_slot, slot), false, model.visibleEntry(m, &fe, m.current))) winner = f;
    };

    // One fused pass over the store: compute a window's desire, then SEND it
    // immediately. Ordering is via the Sink adapter below (a widening PR
    // proved the contract survives reordering), honoring two invariants here:
    // map precedes geometry so a first-show/unparking client exposes at its
    // final rect, and border width is merged into the geometry configure when
    // both change (parked windows emit ONE merged park request instead:
    // offscreen X + BELOW).
    //
    // The ledger reads below are contract, not optimization (header): the
    // orphan branch keeps the last real geometry (read 1), raise triggers
    // derive from rect/parked comparisons (read 2), and everything written
    // here feeds lastRectFor/truthRect (read 3). Sends never consult the
    // ledger to SKIP anything.
    const count = m.store.count();
    // One warn per pass when any window's record couldn't be written, not one
    // per window: the condition is structural (ledger at store_capacity), so
    // a full pass would otherwise log per window.
    var ledger_overflow = false;
    for (0..count) |i| {
        const it = m.store.at(i);
        const win = it.key;
        const e: *const model.Entry = it.val;

        // One get-or-create per window: the same record backs the pre-send
        // contract reads AND the post-send write, so a visible window costs a
        // single scan. The record is read before any send and only written
        // after, so raises still derive from what we last sent, never from
        // this pass's sends. When the ledger is full and `win` has no record
        // yet, `gop` is null: reads see a fresh blank entry and the write is
        // lost (one per-pass warning at the loop's end; sends never depend on
        // the ledger).
        const gop = sentGetOrPut(win);
        const ledger = (if (gop) |g| g.* else SentEntry{});

        // OFF-WORKSPACE FAST PATH: a desire that is PROVABLY parked (not the
        // covering winner, not on the current ws, or presence parked) and is
        // already parked in the ledger needs no recompute and no send -- the
        // full path would derive parked, elide the park resend (ledger.parked
        // already true), never be a fallback winner, and rewrite the same
        // parked=true.
        const is_fs = win == fs_win;
        const on_current = model.visibleEntry(m, e, m.current);
        const definitely_parked_desire = e.presence == .parked or !on_current;
        if (!is_fs and definitely_parked_desire and ledger.parked) continue;

        // Resolve this tiled window's placement in O(1): the lookup table is
        // indexed by store slot, which this store iteration already provides.
        const placement = if (e.anchor == .tiled)
            placementOfSlot(&placements, &pl_of_slot, i)
        else
            null;
        const desire = computeDesire(m, ctx, e, win, fs_win, placement, &winner, ledger, on_current);
        const rect = desire.rect;
        const bw = desire.bw;
        const pixel = desire.pixel;
        const parked = desire.parked;
        const is_winner = winner == win;

        if (parked) {
            if (!ledger.parked) ctx.sink.park(win);
        } else {
            // Raise triggers per the ledger contract (header read 2): winner
            // .above on geometry motion, unpark, or restack pressure only.
            const first_send = !ledger.has_rect;
            const moved = first_send or !ledger.rect.eql(rect);
            const unpark_transition = ledger.parked;
            const raise_winner = is_winner and (moved or unpark_transition or opts.force_restack);

            const need_map = first_send or unpark_transition;
            const need_bw = !ledger.has_rect or ledger.bw != bw;
            const need_pixel = !ledger.has_rect or ledger.pixel != pixel;
            const need_geom = moved or unpark_transition or raise_winner;

            if (need_map) ctx.sink.map(win);
            if (need_pixel) ctx.sink.borderPixel(win, pixel);
            // Merge border width into the geometry configure when both change
            // (the common switch/unpark shape): one request instead of two.
            if (need_bw and need_geom) {
                ctx.sink.geomBordered(win, rect, bw, if (raise_winner) .above else null);
            } else {
                if (need_bw) ctx.sink.borderWidth(win, bw);
                if (need_geom) ctx.sink.geom(win, rect, if (raise_winner) .above else null);
            }
        }

        // Ledger write: record what we actually sent. A park preserves the
        // previous record's rect/has_rect; an unpark overwrites wholesale.
        if (gop) |g| {
            if (parked) g.parked = true else markSentVisible(g, rect, bw, pixel);
        } else ledger_overflow = true;
    }
    if (ledger_overflow) debug.err("sync.reconcile: ledger full; some sends applied, records lost", .{});

    // force_restack additionally raises bar/top.
    if (opts.force_restack) {
        if (ctx.bar_win) |bar| ctx.sink.stackOnly(bar, .above);
    }

    // DO NOT FLUSH HERE. Caller owns flushing.
}

/// The ledger record for `win` when a visible (non-parked) geometry was
/// ever sent; null otherwise.
fn visibleSent(win: model.WindowId) ?SentEntry {
    const e = sentGet(win) orelse return null;
    if (!e.has_rect or e.parked) return null;
    return e;
}

/// Pipeline: last visible geometry we sent to `win`, or null when never sent
/// / currently parked.
pub fn lastRectFor(win: model.WindowId) ?utils.Rect {
    const e = visibleSent(win) orelse return null;
    return e.rect;
}

/// Pipeline: border width last sent for `win`, or null when never sent /
/// currently parked. Feeds the synthetic ConfigureNotify echo so the width it
/// reports matches the window's actual X border rather than the global config
/// default.
pub fn lastBorderWidthFor(win: model.WindowId) ?u16 {
    const e = visibleSent(win) orelse return null;
    return e.bw;
}

/// Best known live geometry for `win` without a server round trip:
///   1. floating base rect from the model (authoritative while floating),
///   2. else the last visible geometry we sent (null while parked/unsent).
pub fn truthRect(m: *const model.Model, win: model.WindowId) ?utils.Rect {
    const e = m.store.get(win) orelse return null;
    if (e.presence == .present and e.anchor == .floating) return e.anchor.floating;
    return lastRectFor(win);
}

const Desire = struct {
    rect: utils.Rect,
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
/// there, so placement-less orphans stay on the pass's first-desire
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
    ledger: SentEntry,
    on_current: bool,
) Desire {
    var rect: utils.Rect = contract.parked_rect;
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
            } else parked = true;
        },
        // A covering window owns the screen this pass: every other present
        // window is a covered sibling and parks (geometry preserved for the
        // exit replay), regardless of anchor.
        .present => {
            // Parked-ness comes from the shared predicate (see
            // desireIsNonParked); the arms below fill geometry, and the
            // orphan/offscreen arm's markParked keeps its border/pixel
            // side effects.
            parked = !desireIsNonParked(e.*, fs_win, placement, ledger.has_rect, on_current);
            switch (e.anchor) {
                .floating => |r| rect = r,
                .tiled => if (placement) |p| {
                    rect = p.rect;
                } else if (on_current and ledger.has_rect) {
                    // Multi-tagged orphan never hidden; keep last-sent rect,
                    // parked only when nothing was ever sent (first sight /
                    // offscreen) -- exactly what desireIsNonParked saw.
                    rect = ledger.rect;
                } else markParked(&bw, &pixel, &parked),
            }
        },
    }

    // Fallback winner: first non-parked desire in store order.
    if (winner.* == null and !parked) winner.* = win;
    return .{ .rect = rect, .bw = bw, .pixel = pixel, .parked = parked };
}

/// O(1) placement lookup: placement for store slot `slot`, or null when the window
/// has no placement this pass (multi-tag orphan, off-workspace, no-tiling
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
