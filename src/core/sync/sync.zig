//! Sends are planned in sync.zig and dispatched by sync/sink.zig's shims
//! (the sanctioned seam); the raw XCB primitives those shims call are defined
//! in core/x11/wire.zig (allowlisted primitive home); a small documented
//! allowlist covers bar lifecycle, client-protocol, and non-mutation flushes
//! (see dev/scripts/check-layers.sh Rules 1-2).
//!
//! Scroll viewport caller duties (snap-right-on-new, clamp, prev_count update)
//! happen in ACTIONS before they call reconcile; this module never mutates
//! model params (m is const).
//!
//! RECONCILE ALGORITHM - UNCONDITIONAL COMPUTE, DELTA SEND. Every pass
//! computes the desired state for EVERY stored window (so a client that
//! mutated its own geometry/border behind our back is repaired on the very
//! next pass -- drift-proof by construction, no diff cache, no sweep counter,
//! no staging buffer). The SEND is then diffed against the sent ledger: a
//! request whose desired value matches the last one sent is elided, because
//! resending an idempotent configure/map/park request is a pure no-op the X
//! server would discard. Parked windows get ONE merged park request only on
//! the park transition; visible windows send only the map/pixel/bw/geometry
//! requests that actually changed, in the order map -> pixel -> bw -> geometry
//! (stacking mode merged into the geometry request). Sending full desired
//! state on change is still drift-proofing; we only avoid replaying what the
//! server already has.
//!
//! The SENT LEDGER is a WRITE-ONLY record of what was actually sent
//! ({rect, has_rect, parked} per window; a park flips `parked` and preserves
//! rect/has_rect). Exactly three reads of it are behavioral contract:
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
const constants = @import("constants");
const build_options = @import("build_options");
const model = @import("model");
const debug = @import("debug");

/// The tiling engine is reached through the build-generated `tiling_seam`:
/// when no tiling subsystem is present the seam is an empty struct, and every
/// `tiling.*` member use below sits behind a `has_tiling` gate, so the
/// reconcile path still runs (park/map/stack) with the layout-computation
/// block skipped and the placement lookup table left empty. The interchange
/// TYPES (View/List/Placement/Env/HintsView/parked_rect) come from the tiling
/// contract (plugin.zig), which both the tiling engine and this reconciler
/// reference — no mirrored duplicate to keep in lockstep, and no local stub.
const plugin = @import("plugin");
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
    /// config.tiling.border_width, already scaled at load.
    cfg_bw: u16,
    env: plugin.Env = .{},
    /// Focus/mode border color; ported from borders.resolveBorderColor minus
    /// its fullscreen check (fullscreen zeroes via bw/pixel policy instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
};

pub const ReconcileOpts = struct { force_restack: bool = false };

/// What we last sent per window; WRITE-ONLY bookkeeping whose three contract
/// reads are documented in the header:
///   - has_rect: whether a visible geometry was EVER sent (an explicit flag,
///     not a sentinel rect: a legitimately placed zero-size window at the
///     origin would collide with a "never sent" marker value);
///   - rect: the last VISIBLE geometry sent (survives parks);
///   - parked: whether the latest pass parked it;
///   - bw: the last border width sent for a visible window (0 while parked/never);
///   - pixel: the last border pixel sent for a visible window (0 while parked/never).
const SentEntry = struct {
    id: model.WindowId = 0,
    rect: utils.Rect = plugin.parked_rect,
    has_rect: bool = false,
    parked: bool = false,
    bw: u16 = 0,
    pixel: u32 = 0,
};

pub const State = struct {
    /// Ledger of sent state (see SentEntry), keyed by `.id`.
    sent: utils.BoundedList(SentEntry, model.store_capacity) = .{},
    /// O(1) index from a window id to its `sent` slot (see utils.IdMap), so
    /// the get-or-put / forget paths resolve a record without scanning the
    /// ledger. Backed by the same open-addressing recipe as the ICCCM cache.
    sent_index: utils.IdMap(usize, model.store_capacity) = .{},
};

/// Owned by the compositor process; re-init() on reconnect. Module-private:
/// all access goes through this file's API.
var st: State = .{};

pub fn init() void {
    st = .{};
}

/// Ledger slot holding `win`, resolved through the O(1) index; null when absent.
fn sentSlot(win: model.WindowId) ?usize {
    return st.sent_index.get(win);
}

pub fn sentGet(win: model.WindowId) ?SentEntry {
    const slot = sentSlot(win) orelse return null;
    return st.sent.items[slot];
}

/// Ledger get-or-create for `win`: pointer to its record, or null when the
/// ledger is full and `win` has no slot yet. Null replaces the former
/// `.found_existing` struct: callers treat both cases the same (reads see a
/// fresh blank record; writes are logged+lost).
pub fn sentGetOrPut(win: model.WindowId) ?*SentEntry {
    if (sentSlot(win)) |slot| return &st.sent.items[slot];
    if (st.sent.len >= model.store_capacity) return null;
    const idx = st.sent.len;
    st.sent.len += 1;
    st.sent.items[idx] = .{ .id = win };
    _ = st.sent_index.put(win, idx);
    return &st.sent.items[idx];
}

pub fn sentSwapRemove(win: model.WindowId) void {
    const slot = sentSlot(win) orelse return;
    st.sent.swapRemove(slot);
    // Keep ledger and index in lockstep. Swap-remove moves the LAST record
    // into this slot; its id is unchanged but its slot number moved, so drop
    // the removed id's entry then repoint the moved one.
    _ = st.sent_index.remove(win);
    if (slot < st.sent.len) _ = st.sent_index.put(st.sent.items[slot].id, slot);
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from actions.unmanage.
pub fn forget(win: model.WindowId) void {
    sentSwapRemove(win);
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
fn markSentVisible(e: *SentEntry, win: model.WindowId, rect: utils.Rect, bw: u16, pixel: u32) void {
    e.* = .{ .id = win, .rect = rect, .has_rect = true, .parked = false, .bw = bw, .pixel = pixel };
}

/// Opt-in retile latency instrumentation (RETILE_PROF). Measures the wall
/// clock held by each server-grab retile -- the exact latency a user feels
/// across a tiling op -- plus how many store entries were walked (all of
/// them, since reconcile replays every window's desire each pass). Gated by
/// `build_options.profile_key` (the same flag as the key-dispatch path) so
/// release WMs compile it out.
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
    markSentVisible(gop, win, rect, gop.bw, gop.pixel);
}

pub fn reconcile(m: *const model.Model, ctx: *Ctx, opts: ReconcileOpts) void {
    // Work-area (screen minus bar) and coverage winner: the core model helper
    // resolves which covering window owns the current workspace's screen.
    const wa = ctx.workarea;

    const fs_win: ?model.WindowId = model.coveringOccupantOnWs(m, m.current);

    // Layout compute over the shown workspace (skipped when a covering window
    // owns the screen, or when the tiling subsystem is absent).
    var order_buf: [model.store_capacity]model.WindowId = undefined;
    var hints_buf: [model.store_capacity]model.SizeHints = undefined;
    var placements: plugin.List = .{};
    // Per-window placement lookup (P1): `pl_of_slot[i]` is the index into
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
            const e = m.store.get(w) orelse continue;
            if (e.mask & model.bit(m.current) == 0) continue;
            // First write wins, mirroring the removed findPlacement's
            // first-match semantics; the store holds each id once so this is
            // just defensive.
            if (m.store.slotOf(w)) |slot| {
                if (pl_of_slot[slot] == null) pl_of_slot[slot] = n;
            }
            order_buf[n] = w;
            hints_buf[n] = e.size_hints;
            n += 1;
        }
        const hv = plugin.HintsView{ .order = order_buf[0..n], .hints = hints_buf[0..n] };
        const params = &m.ws[m.current.index].params;
        const view: plugin.View = .{ .order = order_buf[0..n], .params = params, .workarea = wa, .hints = &hv, .focused = m.focused, .env = ctx.env };
        if (n > 0) {
            tiling.compute(params.kind, view, &placements);
        }
    }

    // Winner seed: fullscreen winner outright; else the focused window when
    // its desire will be non-parked (checked here so no earlier store entry
    // can shadow it); else the pass elects the first non-parked desire.
    var winner: ?model.WindowId = fs_win;
    if (winner == null) if (m.focused) |f| if (m.store.get(f)) |fe| {
        if (fe.presence == .present and model.visibleOn(m, f, m.current)) {
            switch (fe.anchor) {
                .floating => winner = f,
                .tiled => if (placementOf(m, &placements, &pl_of_slot, f)) |p| {
                    if (p.visible) winner = f;
                },
            }
        }
    };

    // One fused pass over the store: compute a window's desire, then SEND it
    // immediately. Send order per window: map -> pixel -> bw -> geometry
    // (stack merged into that request); parked windows emit ONE merged park
    // request instead (offscreen X + BELOW). Map precedes geometry so a
    // first-show/unparking client exposes at its final rect.
    //
    // The ledger reads below are contract, not optimization (header): the
    // orphan branch keeps the last real geometry (read 1), raise triggers
    // derive from rect/parked comparisons (read 2), and everything written
    // here feeds lastRectFor/truthRect (read 3). Sends never consult the
    // ledger to SKIP anything.
    const count = m.store.count();
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
        // logged+lost, exactly as before (sends never depend on the ledger).
        const gop = sentGetOrPut(win);
        const ledger = (if (gop) |g| g.* else SentEntry{});

        // OFF-WORKSPACE FAST PATH: a desire that is PROVABLY parked (not the
        // covering winner, not on the current ws, or presence parked) and is
        // already parked in the ledger needs no recompute and no send -- the
        // full path would derive parked, elide the park resend (ledger.parked
        // already true), never be a fallback winner, and rewrite the same
        // parked=true.
        const is_fs = win == fs_win;
        const on_current = m.all_view_active or (e.mask & model.bit(m.current)) != 0;
        const definitely_parked_desire = e.presence == .parked or !on_current;
        if (!is_fs and definitely_parked_desire and ledger.parked) continue;

        // Resolve this tiled window's placement in O(1): the lookup table is
        // indexed by store slot, which this store iteration already provides.
        const placement = if (e.anchor == .tiled)
            placementOfSlot(&placements, &pl_of_slot, i)
        else
            null;
        const desire = computeDesire(m, ctx, e, win, fs_win, placement, &winner, ledger);
        const rect = desire.rect;
        const bw = desire.bw;
        const pixel = desire.pixel;
        const parked = desire.parked;
        const is_winner = desire.is_winner;

        if (parked) {
            if (!ledger.parked) ctx.sink.park(win);
        } else {
            // Raise triggers per the ledger contract (header read 2): winner
            // .above on geometry motion, unpark, or restack pressure only.
            const last = ledger;
            const first_send = !last.has_rect;
            const moved = first_send or !last.rect.eql(rect);
            const unpark_transition = last.parked;
            const raise_winner = is_winner and (moved or unpark_transition or opts.force_restack);

            const need_map = first_send or unpark_transition;
            const need_bw = !last.has_rect or last.bw != bw;
            const need_pixel = !last.has_rect or last.pixel != pixel;
            const need_geom = moved or unpark_transition or raise_winner;

            if (need_map) ctx.sink.map(win);
            if (need_pixel) ctx.sink.borderPixel(win, pixel);
            if (need_bw) ctx.sink.borderWidth(win, bw);
            if (need_geom) ctx.sink.geom(win, rect, if (raise_winner) .above else null);
        }

        // Ledger write: record what we actually sent. A park preserves the
        // previous record's rect/has_rect; an unpark overwrites wholesale.
        if (gop) |g| {
            if (parked) g.parked = true else markSentVisible(g, win, rect, bw, pixel);
        } else debug.err("sync.reconcile: ledger full; sends applied, record lost", .{});
    }

    // force_restack additionally raises bar/top.
    if (opts.force_restack) {
        if (ctx.bar_win) |bar| ctx.sink.stackOnly(bar, .above);
    }

    // DO NOT FLUSH HERE. Caller owns flushing.
}

/// Pipeline: last visible geometry we sent to `win`, or null when never sent
/// / currently parked.
pub fn lastRectFor(win: model.WindowId) ?utils.Rect {
    const e = sentGet(win) orelse return null;
    if (!e.has_rect or e.parked) return null;
    return e.rect;
}

/// Pipeline: border width last sent for `win`, or null when never sent /
/// currently parked. Feeds the synthetic ConfigureNotify echo so the width it
/// reports matches the window's actual X border rather than the global config
/// default (W3).
pub fn lastBorderWidthFor(win: model.WindowId) ?u16 {
    const e = sentGet(win) orelse return null;
    if (!e.has_rect or e.parked) return null;
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
    is_winner: bool,
};

/// Park a desire: zero the border width/pixel and set the parked flag.
/// Shared trailer of the four parked arms of computeDesire.
fn markParked(bw: *u16, pixel: *u32, parked: *bool) void {
    bw.* = 0;
    pixel.* = 0;
    parked.* = true;
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
    placement: ?plugin.Placement,
    winner: *?model.WindowId,
    ledger: SentEntry,
) Desire {
    var rect: utils.Rect = plugin.parked_rect;
    var bw: u16 = ctx.cfg_bw;
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
        .present => if (fs_win != null) {
            parked = true;
        } else switch (e.anchor) {
            .floating => |r| {
                rect = r;
                parked = !model.visibleOn(m, win, m.current);
            },
            .tiled => if (placement) |p| {
                rect = p.rect;
                parked = !p.visible;
            } else if (model.visibleOn(m, win, m.current)) {
                // Multi-tagged orphan never hidden; keep last-sent rect, park
                // only when nothing was ever sent (first sight / offscreen).
                if (!ledger.has_rect) markParked(&bw, &pixel, &parked) else rect = ledger.rect;
            } else markParked(&bw, &pixel, &parked),
        },
    }

    // Fallback winner: first non-parked desire in store order.
    if (winner.* == null and !parked) winner.* = win;
    const is_winner = winner.* == win;
    return .{ .rect = rect, .bw = bw, .pixel = pixel, .parked = parked, .is_winner = is_winner };
}

/// O(1) placement lookup: placement for store slot `slot`, or null when the window
/// has no placement this pass (multi-tag orphan, off-workspace, no-tiling
/// build). `slot` must be < m.store.count(); the table was built alongside
/// placements in reconcile. Indexes into a copy-cached slice so a module that
/// emits fewer placements than ordered windows degrades to null (same as the
/// removed linear scan) instead of indexing out of bounds.
fn placementOfSlot(
    placements: *const plugin.List,
    pl_of_slot: *const [model.store_capacity]?usize,
    slot: usize,
) ?plugin.Placement {
    const idx = pl_of_slot[slot] orelse return null;
    const slice = placements.constSlice();
    if (idx >= slice.len) return null;
    return slice[idx];
}

/// Placement for `win`, resolved id -> store slot -> O(1) table. Only used on
/// the cold winner-seed path; the hot fused pass passes its known slot.
fn placementOf(
    m: *const model.Model,
    placements: *const plugin.List,
    pl_of_slot: *const [model.store_capacity]?usize,
    win: model.WindowId,
) ?plugin.Placement {
    const slot = m.store.slotOf(win) orelse return null;
    return placementOfSlot(placements, pl_of_slot, slot);
}
