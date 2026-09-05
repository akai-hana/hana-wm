//! ONLY this module (via its wire sink) sends geometry/border/map/stack
//! requests. Pure orchestration lives here; every raw XCB request lives in
//! the sink file (src/core/sync/wire.zig), the sanctioned boundary. Raw
//! libxcb symbols may appear only inside its send shims.
//!
//! Shims wrap EXISTING xcb patterns; do not invent new ones:
//!   Sink.geom        ~ utils.configureWindow (+ merged stack-mode variant)
//!   Sink.border_*    ~ borders.applyWidth + borders.apply + setBorderPixel
//!   Sink.park        ~ X-offscreen + BELOW configure_window in ONE request
//!   Sink.stack_only  ~ utils.raiseWindow / restack helpers used today
//!   Sink.set_ewmh_fullscreen ~ xcb_change_property for _NET_WM_STATE_FULLSCREEN
//!   Sink.flush       ~ conn.flush() (caller owns timing)
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

/// When tiling is absent, provide a compute stub so the rest of sync
/// compiles. The interchange TYPES (View/List/Placement/Env/HintsView/
/// parked_rect) come from the tiling contract (plugin.zig), which both the
/// tiling and this reconciler reference — so there is no mirrored duplicate
/// to keep in lockstep. The reconcile path still runs (park/map/stack), but
/// the layout computation block is skipped and findPlacement is null.
const plugin = @import("plugin");
const tiling = if (build_options.has_tiling) @import("tiling") else struct {
    pub const Env = plugin.Env;
    pub const parked_rect = plugin.parked_rect;
    pub const Placement = plugin.Placement;
    pub const List = plugin.List;
    pub const HintsView = plugin.HintsView;
    pub const View = plugin.View;
    pub fn compute(_: anytype, _: anytype, _: anytype) void {}
};

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
    pub inline fn setEwmhFullscreen(
        self: Sink,
        win: model.WindowId,
        state_atom: u32,
        fs_atom: u32,
        is_fullscreen: bool,
    ) void {
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
    env: tiling.Env = .{},
    /// Focus/mode border color; ported from borders.color minus its
    /// fullscreen check (fullscreen zeroes via bw/pixel policy instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
};

pub const ReconcileOpts = struct { force_restack: bool = false };

// The sent ledger is a compact parallel array (get/put/swap-remove/clear; no
// iteration-order needs, unlike model.Store). Lookups are a linear scan over
// the OCCUPIED prefix: the ledger is bounded at model.store_capacity (128) and
// reconcile replays every window's desire (and thus one get-or-put) per pass,
// so a hash index over a fixed 128-slot table costs more bookkeeping than it
// saves. Latency-verified: perf_test "sent ledger" shows the scan is on par
// with the removed open-addressing index at the realistic 64-window ceiling.

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
    rect: utils.Rect = tiling.parked_rect,
    has_rect: bool = false,
    parked: bool = false,
    bw: u16 = 0,
    pixel: u32 = 0,
};

pub const State = struct {
    /// Ledger of sent state (see SentEntry), keyed by `.id`.
    sent: utils.BoundedList(SentEntry, model.store_capacity) = .{},
};

/// Owned by the compositor process; re-init() on reconnect.
pub var st: State = .{};

pub fn init() void {
    st = .{};
}

pub fn deinit() void {
    init();
}

/// Slot holding `win` in the ledger, or null when absent. Linear scan over the
/// occupied prefix (see header note on why a hash index is not worth it).
fn sentFind(win: model.WindowId) ?usize {
    return st.sent.indexOfById(win);
}

pub fn sentGet(win: model.WindowId) ?SentEntry {
    const slot = sentFind(win) orelse return null;
    return st.sent.items[slot];
}

pub fn sentGetOrPut(win: model.WindowId) !struct {
    found_existing: bool,
    value_ptr: *SentEntry,
} {
    if (sentFind(win)) |slot| {
        return .{ .found_existing = true, .value_ptr = &st.sent.items[slot] };
    }
    if (st.sent.len >= model.store_capacity) return error.SentLedgerFull;
    const idx = st.sent.len;
    st.sent.len += 1;
    st.sent.items[idx] = .{ .id = win };
    return .{ .found_existing = false, .value_ptr = &st.sent.items[idx] };
}

pub fn sentSwapRemove(win: model.WindowId) void {
    const slot = sentFind(win) orelse return;
    st.sent.swapRemove(slot);
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from actions.unmanage.
pub fn forget(win: model.WindowId) void {
    sentSwapRemove(win);
}

/// Opt-in retile latency instrumentation (RETILE_PROF). Measures the wall
/// clock held by each server-grab retile -- the exact latency a user feels
/// across a tiling op -- plus how many store entries were walked (all of
/// them, since reconcile replays every window's desire each pass). Gated by
/// `build_options.profile_key` (the same flag as the key-dispatch path) so
/// release WMs compile it out.
const retile_prof = utils.WindowedProfiler(
    build_options.profile_key,
    "RETILE_PROF",
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
    const gop = sentGetOrPut(win) catch return;
    gop.value_ptr.* = .{ .id = win, .rect = rect, .has_rect = true, .parked = false };
}

pub fn reconcile(m: *const model.Model, ctx: *Ctx, opts: ReconcileOpts) void {
    // STEP 1: wa := workArea(ctx) (screen minus bar).
    const wa = ctx.workarea;

    // STEP 2: coverage winner scan. The core model helper (coveringOccupantOnWs)
    // resolves which covering window owns the screen on the current workspace,
    // replacing the former per-module registry enumeration.
    const fs_win: ?model.WindowId = model.coveringOccupantOnWs(m, m.current);

    // STEP 3 (else branch): run layout.compute over the shown workspace.
    var order_buf: [model.store_capacity]model.WindowId = undefined;
    var hints_buf: [model.store_capacity]model.SizeHints = undefined;
    var placements: tiling.List = .{};
    if (build_options.has_tiling and fs_win == null) {
        var n: usize = 0;
        const tiled = &m.ws[m.current].tiled_order;
        for (tiled.constSlice()) |w| {
            const e = m.store.get(w) orelse continue;
            if (e.mask & model.bit(m.current) == 0) continue;
            order_buf[n] = w;
            hints_buf[n] = e.size_hints;
            n += 1;
        }
        const hv = tiling.HintsView{ .order = order_buf[0..n], .hints = hints_buf[0..n] };
        const params = &m.ws[m.current].params;
        const view = tiling.View{
            .order = order_buf[0..n],
            .params = params,
            .workarea = wa,
            .hints = &hv,
            .focused = m.focused,
            .env = ctx.env,
        };
        // n == 0 leaves placements empty (no layout owns a window); layouts
        // are individually n==0-safe too, this only skips the work.
        if (n > 0) {
            tiling.compute(params.kind, view, &placements);
            // Sort by window ID once after compute for O(log n) binary search.
            std.sort.pdq(tiling.Placement, placements.slice(), {}, struct {
                fn lessThan(_: void, a: tiling.Placement, b: tiling.Placement) bool {
                    return a.win < b.win;
                }
            }.lessThan);
        }
    }

    // Winner seed (STEP 5): fullscreen winner outright; else the focused
    // window when its desire below will be non-parked (checked here so no
    // earlier store entry can shadow it); else the pass elects the first
    // non-parked desire in store order as it goes.
    var winner: ?model.WindowId = fs_win;
    if (winner == null) {
        if (m.focused) |f| {
            if (m.store.get(f)) |fe| {
                if (fe.presence == .present and model.visibleOn(m, f, m.current)) {
                    switch (fe.anchor) {
                        .floating => winner = f,
                        .tiled => if (findPlacement(&placements, f)) |p| {
                            if (p.visible) winner = f;
                        },
                    }
                }
            }
        }
    }

    // STEPS 4..8 fused into ONE pass: compute the desire for a store entry,
    // then SEND it immediately, unconditionally. Send order per window:
    // map -> pixel -> bw -> geometry (stack merged into that request);
    // parked windows emit ONE merged park request instead (offscreen X +
    // BELOW). Map precedes geometry so a first-show/unparking client
    // exposes at its final rect.
    //
    // The ledger reads below are contract, not optimization: the orphan
    // branch keeps the last real geometry (header read 1), raise triggers
    // derive from rect/parked comparisons (read 2), and everything written
    // here feeds lastRectFor/truthRect (read 3). Sends never consult the
    // ledger to SKIP anything.
    const count = m.store.count();
    for (0..count) |i| {
        const it = m.store.at(i);
        const win = it.key;
        const e: *const model.Entry = it.val;

        // One ledger get-or-create per window: the same record backs the
        // pre-send contract reads (orphan keep-last, raise rule) AND the
        // post-send write, so a visible window costs a single scan instead
        // of two. The record is read before any send and only written after,
        // so raises still derive from what we last sent, never from this
        // pass's sends. When the ledger is full and `win` has no record yet,
        // `gop` is null: reads see a fresh blank entry and the write is
        // logged+lost after the sends, exactly as before (sends never depend
        // on the ledger).
        const gop = sentGetOrPut(win) catch null;
        const ledger = (if (gop) |g| g.value_ptr.* else SentEntry{});

        // OFF-WORKSPACE FAST PATH. A window whose desire is PROVABLY parked and
        // which is ALREADY parked in the sent ledger needs no recompute and no
        // send this pass: its record is unchanged, and parked windows (offscreen)
        // have no geometry/border drift to repair, so unconditional compute is
        // preserved for every window that could actually be visible.
        //
        // Every NON-parked desire satisfies `presence == .parked` false AND
        // `all_view_active or mask has current ws` -- except the fullscreen/covering
        // winner (fs_win), whose screen ownership can carry it without a current-ws
        // mask bit. So skipping when those all fail AND it isn't fs_win AND it's
        // already parked is identity-safe: the full path would derive parked,
        // elide the park resend (ledger.parked already true), never be a fallback
        // winner (parked), and rewrite the ledger to the same parked=true.
        const is_fs = fs_win != null and win == fs_win.?;
        const on_current = m.all_view_active or (e.mask & model.bit(m.current)) != 0;
        const definitely_parked_desire = e.presence == .parked or !on_current;
        if (!is_fs and definitely_parked_desire and ledger.parked) continue;

        const desire = computeDesire(m, ctx, e, win, fs_win, &placements, &winner, ledger);
        const rect = desire.rect;
        const bw = desire.bw;
        const pixel = desire.pixel;
        const parked = desire.parked;
        const is_winner = desire.is_winner;

        if (parked) {
            // ONE merged request (X-offscreen + BELOW). Idempotent by nature,
            // so replaying every pass is safe. The ledger's rect deliberately
            // SURVIVES the park so a later all-view orphan resurfaces at its
            // old slot.
            //
            // Skip the park entirely when the previous pass already parked
            // this window: the offscreen X + BELOW request is idempotent and
            // a repeated park is a pure no-op, so dropping it shrinks the
            // grab's request run without losing any state.
            if (!ledger.parked) ctx.sink.park(win);
        } else {
            // Raise triggers derive from the ledger (header read 2): the
            // winner rides .above exactly when its geometry moved, when it
            // unparked, or under restack pressure, never on mere presence.
            const last = ledger;
            const first_send = !last.has_rect;
            const moved = first_send or !last.rect.eql(rect);
            const unpark_transition = last.parked;
            const raise_winner = is_winner and (moved or unpark_transition or opts.force_restack);

            // Delta-apply: skip any request whose desired value is byte-equal
            // to the last one SENT (from the ledger). UNCONDITIONAL COMPUTE is
            // preserved -- every window's desire is still re-derived every
            // pass, so drift (a client that mutated its own geometry/border
            // behind our back) is repaired exactly as before, and any request
            // we DO send is still full desired state. We only elide resends
            // of a request the server has already seen, which is the dominant
            // cost of a retile grab (each queued configure/map/property request
            // the server must process). The skip is never a correctness risk:
            // an unchanged desire sent again would have been an idempotent
            // no-op anyway.
            //
            // map: needed on first show / on unpark (a parked window's map may
            // have been withdrawn); skipping it for a window that has stayed
            // visible in the same rect drops a redundant XMapWindow per pass.
            // border width/pixel: window attributes that persist on the client;
            // only resend when the desired value differs from the last sent.
            // geometry: resend only when the rect changed, it is a first send,
            // or a raise is owed (raise merges the stack mode into this one
            // request). Other-wise keep the previous geometry.
            const need_map = first_send or unpark_transition;
            const need_bw = !last.has_rect or last.bw != bw;
            const need_pixel = !last.has_rect or last.pixel != pixel;
            const need_geom = moved or unpark_transition or raise_winner;

            // Send order preserved from the unconditional path: map -> pixel
            // -> bw -> geometry (stack merged into that request), so a
            // first-show/unparking client exposes at its final rect.
            if (need_map) ctx.sink.map(win);
            if (need_pixel) ctx.sink.borderPixel(win, pixel);
            if (need_bw) ctx.sink.borderWidth(win, bw);
            if (need_geom) ctx.sink.geom(win, rect, if (raise_winner) .above else null);
        }

        // Ledger write: record what we actually sent. A park preserves the
        // previous record's rect/has_rect; an unpark overwrites wholesale.
        // Written AFTER the sends: under SentLedgerFull the pass still
        // applied (sends never depend on the ledger) and only the record is
        // lost until the next successful write, so no half-applied batch
        // can exist.
        const g = gop orelse {
            std.log.err("sync.reconcile: ledger full; sends applied, record lost", .{});
            continue;
        };
        if (parked) {
            g.value_ptr.parked = true;
        } else {
            g.value_ptr.* = .{
                .id = win,
                .rect = rect,
                .has_rect = true,
                .parked = false,
                .bw = bw,
                .pixel = pixel,
            };
        }
    }

    // force_restack additionally raises bar/top.
    if (opts.force_restack) {
        if (ctx.bar_win) |bar| ctx.sink.stackOnly(bar, .above);
    }

    // DO NOT FLUSH HERE. Caller owns flushing.
}

/// Raise `win` to the top of the stack immediately, then flush. Used by
/// floating drag-start, where the raise must be visible right away. The caller
/// owns this invoke OUTSIDE any server grab (a flush under a grab would break
/// batch atomicity); drag ticks afterward stay flushless (reconcileDragTick).
pub fn raiseNow(ctx: *Ctx, win: model.WindowId) void {
    ctx.sink.stackOnly(win, .above);
    ctx.sink.flush();
}

/// Set or clear the EWMH _NET_WM_STATE_FULLSCREEN property on `win` via the
/// sink. Queued only (no flush here): fullscreenToggle callers invoke this
/// inside the enclosing grab, whose ungrabAndFlush lands it atomically with
/// geometry. The EWMH atoms are resolved by the fullscreen module and passed
/// through; the fullscreen module's XCB_ATOM_NONE guard already ran.
pub fn setEwmhFullscreen(
    ctx: *Ctx,
    win: model.WindowId,
    state_atom: u32,
    fs_atom: u32,
    is_fullscreen: bool,
) void {
    ctx.sink.setEwmhFullscreen(win, state_atom, fs_atom, is_fullscreen);
}

/// Pipeline: last visible geometry we sent to `win`, or null when never sent
/// / currently parked.
pub fn lastRectFor(win: model.WindowId) ?utils.Rect {
    const e = sentGet(win) orelse return null;
    if (e.parked) return null;
    if (!e.has_rect) return null;
    return e.rect;
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
    placements: *const tiling.List,
    winner: *?model.WindowId,
    ledger: SentEntry,
) Desire {
    var rect: utils.Rect = tiling.parked_rect;
    var bw: u16 = ctx.cfg_bw;
    var pixel: u32 = ctx.color_of(win, m);
    var parked = false;

    if (e.presence == .parked) {
        markParked(&bw, &pixel, &parked);
    } else if (fs_win != null) {
        if (win == fs_win.?) {
            rect = ctx.screen;
            bw = 0;
            pixel = 0;
        } else {
            // Parked: rect irrelevant.
            parked = true;
        }
    } else if (e.presence == .covering) {
        // Fullscreen-carrying window NOT claimed by the coverage module
        // for this workspace (its base isn't visible / its rec targets
        // another ws): parked, matching the coverage scan that skipped it
        // and the covering-parked model arm.
        markParked(&bw, &pixel, &parked);
    } else switch (e.anchor) {
        .floating => |r| {
            rect = r;
            parked = !model.visibleOn(m, win, m.current);
        },
        .tiled => {
            if (findPlacement(placements, win)) |p| {
                rect = p.rect;
                parked = !p.visible;
            } else if (model.visibleOn(m, win, m.current)) {
                // Multi-tagged window whose home list isn't the shown
                // ws: never hidden (no layout owns it here), so it stays
                // at its previous real geometry, which is precisely the
                // ledger's record of what we last sent.
                // Park only when nothing was ever sent (first sight /
                // registered offscreen).
                if (!ledger.has_rect) {
                    markParked(&bw, &pixel, &parked);
                } else {
                    rect = ledger.rect;
                }
            } else {
                markParked(&bw, &pixel, &parked);
            }
        },
    }
    // Off-ws windows are parked by construction above (no placement /
    // visibleOn false), which is exactly "mask lacks bit(shown)".

    // Fallback winner: first non-parked desire in store order.
    if (winner.* == null and !parked) winner.* = win;
    const is_winner = winner.* != null and winner.*.? == win;

    return .{
        .rect = rect,
        .bw = bw,
        .pixel = pixel,
        .parked = parked,
        .is_winner = is_winner,
    };
}

fn findPlacement(placements: *const tiling.List, win: model.WindowId) ?tiling.Placement {
    const slice = placements.constSlice();
    const idx = std.sort.binarySearch(tiling.Placement, slice, win, struct {
        fn cmp(w: model.WindowId, p: tiling.Placement) std.math.Order {
            return std.math.order(w, p.win);
        }
    }.cmp) orelse return null;
    return slice[idx];
}
