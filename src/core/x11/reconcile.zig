//! The reconciler: plans every X request the WM owes as a delta against the
//! sent ledger, under a server grab. Sends are planned here and dispatched by
//! sink.zig's shims (the sanctioned seam); raw XCB primitives live in
//! requests.zig; check-layers.sh Rules 1-2 allowlist this file. Scroll
//! viewport duties run in pipeline.preReconcileDuties; m is const.
//!
//! ALGORITHM - UNCONDITIONAL COMPUTE, DELTA SEND. Every reconcile computes the
//! desired state of every stored window that needs it (an OFF-WORKSPACE fast
//! path elides windows provably already parked), so a client that mutated its
//! geometry/border behind our back is repaired on the next reconcile --
//! drift-proof, no diff cache. The SEND is diffed against the sent ledger: a
//! request whose desired value matches the last one sent is elided. Parked
//! windows get ONE merged park request on the park transition; visible windows
//! send only what changed, ordered map -> pixel -> geometry, with stack mode
//! and border width folded into the geometry request.
//!
//! FLOAT-ABOVE-TILED STACKING. A raised or newly sent TILED window (or a
//! FLOATING window coming on screen) rides to the absolute top and would bury
//! the floating layer, so such a pass arms a final RE-ASSERT phase that
//! replays the ledger's float raise order (bottom first) over the tiled layer,
//! preserving overlapping floats' exact click/drag order. It runs before the
//! force_restack bar raise so chrome stays topmost, and is elided when no
//! floating window is present.
//!
//! RESIZE-PARKED (opt-in, Opts.resize_parked): armed ONLY by the bar
//! visibility toggle (its workarea change must reach every workspace while the
//! normal pass computes only the current one), deliberately NOT by the
//! fullscreen-driven bar hide/show. Rationale at `Opts.resize_parked`.
//!
//! The SENT LEDGER is a write-only record of what was actually sent (field
//! semantics: `SentEntry`). Exactly five reads of it are behavioral contract:
//!   0. OFF-WORKSPACE FAST PATH: `parked` elides provably parked windows.
//!   1. Multi-tag orphans keep their previous real geometry rather than
//!      parking; a history-less orphan parks.
//!   2. Winner-raise rides .above only on geometry move, unpark, or
//!      force_restack, derived from the sent rect and its parked flag.
//!   3. Floating-detach / title prefetch (lastRectFor, truthRect): the live
//!      rect as the new floating base, null while parked.
//!   4. `parked_dirty` (the client moved a parked window behind our back)
//!      forces a recompute/re-park instead of the elision.

const std = @import("std");
const build_options = @import("build_options");
const model = @import("model");
const log = std.log.scoped(.reconcile);

/// The tiling engine is reached through the build-generated `tiling_seam`:
/// with no tiling subsystem the seam is an empty struct and every `tiling.*`
/// use sits behind a `has_tiling` gate, so reconcile still runs (park/map/
/// stack) with the layout compute skipped. The interchange TYPES come from
/// tiling_contract.zig, shared by the engine and this reconciler.
const contract = @import("tiling_contract");
const tiling = @import("tiling_seam").tiling;
const trace = @import("trace");

/// The sent ledger: what was last sent per window, WRITE-ONLY. A diff base,
/// NOT a cache of server truth (the model stays authoritative; see
/// `reconcile.truthRect`): it exists only so a reconcile can elide a request
/// whose desired value matches the last one sent. Field semantics live HERE;
/// the file header owns the behavioural reads.
///
/// The FLOAT RAISE ORDER (`floatRaise`/`floatOrder`) is the one sibling record:
/// which floating windows the wire last raised, bottom to top. Wire state, not
/// a server-truth cache -- it never claims where windows ARE, only the order
/// hana last asked for them. Parked windows keep their slot, a float detached
/// to tiled keeps a stale slot the replay's anchor filter skips, and `forget`
/// drops the slot with the record.
///
/// bw/pixel deliberately SURVIVE a park: the park write flips only `parked`;
/// zeroing them would make the unpark see a changed border. "The last value
/// sent" is what X was told, not what is on screen.
const SentEntry = struct {
    /// Last VISIBLE geometry sent. Undefined until `has_rect` says a geometry
    /// was sent -- deliberately NO sentinel default: `has_rect` is the explicit
    /// "never sent" flag.
    rect: model.Rect,
    /// Whether a visible geometry was EVER sent: an explicit flag, not a
    /// sentinel rect, because a legitimately placed zero-size window at the
    /// origin would collide with a "never sent" marker value.
    has_rect: bool = false,
    /// Whether the latest reconcile parked it.
    parked: bool = false,
    /// The last border width sent (0 if never sent).
    bw: u16 = 0,
    /// The last border pixel sent (0 if never sent).
    pixel: u32 = 0,

    /// Set when a ConfigureNotify says this window changed its own geometry
    /// while we had it parked offscreen. The off-workspace fast path elides
    /// windows already parked in the ledger, and would otherwise strand a
    /// client that moved itself back on-screen.
    parked_dirty: bool = false,

    /// A record for a window nothing has been sent to yet: `has_rect` false is
    /// the ONLY thing that makes this a valid blank, so every reader must gate
    /// on `has_rect` first (`visibleSent` does). `rect` has no struct-literal
    /// default, so construction is explicit here.
    fn blank() SentEntry {
        return .{ .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    }
};

const State = struct {
    /// Ledger of sent state (see SentEntry), keyed by window id in the
    /// model.Store's sorted-key array: binary search, no parallel id index.
    sent: model.Store(model.WindowId, SentEntry, model.store_capacity) = .{},
    /// The FLOAT RAISE ORDER (see file header): one slot per window, index 0 =
    /// bottom-most float, `float_len - 1` = top-most. `undefined` like any
    /// other never-read-before storage; `float_len` is the explicit extent.
    float_order: [model.store_capacity]model.WindowId = undefined,
    float_len: usize = 0,
};

/// Process-lifetime; init() only re-arms between tests.
var st: State = .{};

pub fn init() void {
    st = .{};
}

/// Ledger read of a window's last-sent record; pub for the test seam
/// (production reads use lastRectFor).
pub fn sentGet(win: model.WindowId) ?SentEntry {
    return st.sent.get(win);
}

/// Ledger get-or-create: pointer to the record, or null when the ledger is
/// full and `win` has no slot -- callers treat both cases the same. Pub for
/// test verification (perf_test).
pub fn sentGetOrPut(win: model.WindowId) ?*SentEntry {
    if (st.sent.getPtr(win)) |r| return r;
    return st.sent.put(win, SentEntry.blank()) catch null;
}

/// Drop a window's ledger record. X ids recycle: a stale record would feed
/// the orphan keep-last branch geometry belonging to the previous incarnation,
/// and its float slot would replay a dead XID. Called from window.unmanage and
/// the test seam.
pub fn forget(win: model.WindowId) void {
    _ = st.sent.remove(win);
    requests.forgetSequence(win);
    if (floatIndexOf(win)) |i| floatRemoveAt(i);
}

/// Note that a parked window changed its own geometry, so the next reconcile
/// must re-park it instead of taking the elision. MANAGED windows only: an
/// unmanaged client's configure says nothing about our park.
pub fn markParkedDirty(win: model.WindowId) void {
    const e = sentGet(win) orelse return;
    if (!e.parked) return; // only the parked fast path can elide a repair
    st.sent.getPtr(win).?.parked_dirty = true;
}

/// Record a border width sent for `win` without disturbing the ledger's
/// geometry/park state, so the next full reconcile's need_bw check elides the
/// redundant resend. No-op when the ledger is full (sentGetOrPut contract).
pub fn markSentBorderWidth(win: model.WindowId, w: u16) void {
    const gop = sentGetOrPut(win) orelse return;
    gop.bw = w;
}

/// Record a border-pixel send unless that exact pixel is already recorded,
/// and report whether the caller must actually send. This is the ONE
/// border-pixel dedup: the reconcile pass and the border sweep both derive
/// from this record, and two copies of one fact can disagree.
///
/// Two reasons the answer is not simply `pixel != new`:
///  * `has_rect` gates the comparison: a blank record's `pixel` is 0, and a
///    genuinely black border must still be SENT.
///  * a full ledger returns TRUE (send anyway): a missed dedup costs one
///    redundant request; a missed send leaves a wrong border.
pub fn markSentBorderPixelIfChanged(win: model.WindowId, pixel: u32) bool {
    const gop = sentGetOrPut(win) orelse return true;
    if (gop.has_rect and gop.pixel == pixel) return false;
    gop.pixel = pixel;
    return true;
}

/// Record a visible (non-parked) send in the ledger; pub for the test seam.
pub fn markSentVisible(e: *SentEntry, rect: model.Rect, bw: u16, pixel: u32) void {
    e.* = .{ .rect = rect, .has_rect = true, .parked = false, .bw = bw, .pixel = pixel };
}

fn visibleSent(win: model.WindowId) ?SentEntry {
    const e = sentGet(win) orelse return null;
    if (!e.has_rect or e.parked) return null;
    return e;
}

pub fn lastRectFor(win: model.WindowId) ?model.Rect {
    const e = visibleSent(win) orelse return null;
    return e.rect;
}

/// Last border width sent (null when never sent / parked). Feeds the
/// synthetic ConfigureNotify echo, so the width it reports matches the
/// window's actual X border rather than the global config default.
pub fn lastBorderWidthFor(win: model.WindowId) ?u16 {
    const e = visibleSent(win) orelse return null;
    return e.bw;
}

fn floatIndexOf(win: model.WindowId) ?usize {
    for (st.float_order[0..st.float_len], 0..) |w, i| {
        if (w == win) return i;
    }
    return null;
}

fn floatRemoveAt(i: usize) void {
    const tail = st.float_len - i - 1;
    if (tail > 0) std.mem.copyForwards(
        model.WindowId,
        st.float_order[i .. i + tail],
        st.float_order[i + 1 .. st.float_len],
    );
    st.float_len -= 1;
}

/// Read seam for the re-assert's "adopt floats never raised yet" phase.
pub fn floatContains(win: model.WindowId) bool {
    return floatIndexOf(win) != null;
}

/// The float raise order, bottom (index 0) to top (last entry). The
/// re-assert replays it in this order, so the LAST entry ends topmost.
pub fn floatOrder() []const model.WindowId {
    return st.float_order[0..st.float_len];
}

/// Record a raise of `win`: it moves to the TOP of the float raise order, one
/// slot per window. Called from every raise site — focus click, drag start,
/// winner raise — and NEVER from the re-assert's replay, which only reads the
/// order. A full table drops the least recently raised slot: a missed slot
/// self-heals at the next re-assert.
pub fn floatRaise(win: model.WindowId) void {
    if (floatIndexOf(win)) |i| floatRemoveAt(i);
    if (st.float_len == model.store_capacity) floatRemoveAt(0);
    st.float_order[st.float_len] = win;
    st.float_len += 1;
}

/// Scratch for the opt-in X trace line; only ever written when tracing is
/// armed for this window, so the common path never touches it.
var trace_buf: [96]u8 = undefined;
const sink = @import("sink");
const requests = @import("requests");

pub const Ctx = struct {
    sink: sink.Sink,
    /// Full screen rect (fullscreen branch geometry).
    screen: model.Rect,
    /// Screen minus bar, computed by the caller via the bar-offset helper
    /// (workArea(ctx)); used for tiled geometry.
    workarea: model.Rect,
    env: contract.Env = .{},
    /// Focus/mode border color via the window layer's borders module hook
    /// (`window.borderColorOf`, P2-47); constant 0 when that module is absent
    /// (deletion semantics). Fullscreen zeroes via bw/pixel policy instead.
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
    /// Whether a layout module may place windows. The CALLER resolves it (so
    /// this file asks the same question the bar asks without reading core
    /// config itself, and the reconcile stays drivable with a bare model).
    layout_active: bool = true,
};

pub const Opts = struct {
    force_restack: bool = false,
    /// Opt-in phase (the ONE caller that arms it is the bar visibility
    /// toggle): after the normal pass, recompute each OTHER workspace's layout
    /// against the current workarea and size-only-resize its offscreen windows
    /// (no X/Y: they stay parked) so their clients re-render while hidden. A
    /// later switch then unparks windows already at the new size -- a pure
    /// position change at show time, not the visible re-size flicker slow apps
    /// show. NOT set by the fullscreen-driven bar hide/show.
    resize_parked: bool = false,
};

/// Fast-path reconcile for drag ticks: sends ONLY geometry for the dragged
/// window, skipping all other windows, the tiling compute, and border/map
/// requests. Safe during a drag because nothing else can change: no
/// appear/disappear, no focus flip, no layout change, no fullscreen transition.
pub fn reconcileDragTick(m: *const model.Model, snk: sink.Sink, win: model.WindowId) void {
    const e = m.store.get(win) orelse return;
    if (e.presence != .present) return;
    const rect: model.Rect = switch (e.anchor) {
        .floating => |r| r,
        .tiled => return,
    };

    snk.configure(win, .{ .rect = rect });
    // Flush immediately: a video player (mpv) recreates its swapchain on every
    // size change, so a configure left buffered until the end of the event
    // batch delays that resize into a burst.
    snk.flush();

    // Carry the last real border width/pixel across the drag: writing 0,0 here
    // would make the next full reconcile resend a border the server already has.
    const gop = sentGetOrPut(win) orelse return;
    markSentVisible(gop, rect, gop.bw, gop.pixel);
}

/// The layout half of a reconcile: the coverage winner plus a layout module's
/// placements and the per-slot lookup that resolves them in O(1).
/// Fixed-capacity stack scratch; lives in `run`'s frame.
const Plan = struct {
    /// Which covering window owns the current workspace's screen (core model
    /// helper; `.anchored_or_visible` rule).
    fs_win: ?model.WindowId = null,
    placements: contract.List = .{},
    /// `pl_of_slot[i]` = index into `placements` of the placement for store
    /// slot `i`, or null when that window has none. Built alongside the layout
    /// compute, so the fused store loop resolves placements in O(1).
    pl_of_slot: [model.store_capacity]?usize = [_]?usize{null} ** model.store_capacity,
};

/// One full reconcile: plan (work area + winner + layout), seed the raise
/// winner, fuse-compute-and-send every stored window, the conditional float
/// re-assert, the optional resize-parked phase, then the bar raise.
pub fn run(m: *const model.Model, ctx: *Ctx, opts: Opts) void {
    var plan: Plan = .{};
    computeLayout(m, ctx, &plan);
    var winner = seedWinner(m, &plan);
    // The one condition that arms the re-assert below (see sendAll).
    const reassert = sendAll(m, ctx, opts, &plan, &winner);
    if (reassert) reassertFloats(m, ctx, &plan);
    if (opts.resize_parked) resizeParkedForWorkspaces(m, ctx);

    // force_restack additionally raises bar/top, always AFTER the float
    // re-assert so a replayed float can never bury the bar.
    if (opts.force_restack) {
        if (ctx.bar_win) |bar| ctx.sink.stackOnly(bar, .above);
    }

    // DO NOT FLUSH HERE. Caller owns flushing.
}

/// Phase 1: coverage winner plus the layout compute over the shown workspace.
/// `plan` starts from its struct defaults, so nothing needs re-clearing.
fn computeLayout(m: *const model.Model, ctx: *Ctx, plan: *Plan) void {
    computeLayoutForWs(m, ctx, plan, m.current);
}

/// The layout compute for ONE workspace: coverage winner plus placements.
/// Shared by the current-workspace pass (`computeLayout`) and the
/// resize-parked phase, so there is exactly ONE answer to "what layout does
/// this workspace want under this workarea".
fn computeLayoutForWs(m: *const model.Model, ctx: *Ctx, plan: *Plan, ws: model.WSId) void {
    const wa = ctx.workarea;

    plan.fs_win = model.coveringOccupantOn(m, ws, .anchored_or_visible);

    var order_buf: [model.store_capacity]model.WindowId = undefined;
    var hints_buf: [model.store_capacity]model.SizeHints = undefined;
    // ONE activation gate, and it also SUPPLIES the geometry: gating on the
    // resolved kind keeps geometry in step with what the bar reports as the
    // active layout (enabled AND registered).
    const params = &m.ws[ws.index].params;
    if (plan.fs_win == null) {
        var n: usize = 0;
        const tiled = &m.ws[ws.index].tiled_order;
        for (tiled.constSlice()) |w| {
            const slot = m.store.indexOf(w) orelse continue;
            const e = m.store.at(slot).val;
            if (!model.taggedOn(e.*, ws)) continue;
            // First write wins; the store holds each id once (defensive).
            if (plan.pl_of_slot[slot] == null) plan.pl_of_slot[slot] = n;
            order_buf[n] = w;
            hints_buf[n] = e.size_hints;
            n += 1;
        }
        if (n > 0) {
            // `comptime` on the build flag is load-bearing: it prunes the
            // `tiling.compute` reference in a no-tiling build, where the seam
            // is an empty struct. A plain runtime `ctx.layout_active` would
            // not, and the seam lookup would fail to compile.
            const float_all = if (comptime !build_options.has_tiling) true else !ctx.layout_active;
            if (float_all) {
                // Tiling off: every window floats at the full work area.
                // Emitting nothing is NOT a neutral "no layout" -- a `.tiled`
                // entry with no placement is parked on first sight and then
                // frozen wherever it last was. "No layout modules" and
                // "layout disabled" share ONE answer.
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

/// The resize-parked phase (Opts.resize_parked owns the WHY): size every
/// OTHER workspace's offscreen windows to what its layout computes under the
/// CURRENT workarea, via a size-only configure. Scope guards, load-bearing:
///  - skip `m.current` (the normal pass already sent its placements);
///  - skip a workspace covered by a fullscreen occupant (its windows' sizes
///    are bar-independent -- screen, not workarea);
///  - skip a window still VISIBLE on the current workspace (a multi-tag
///    orphan's geometry is owned by the current pass, not by its home ws);
///  - skip a window whose ledger already holds the target width/height.
///
/// The ledger's rect w/h is updated in place -- x/y and `parked` untouched --
/// so the later unpark's moved-check sees the resize already done. `has_rect`
/// is deliberately NOT flipped.
fn resizeParkedForWorkspaces(m: *const model.Model, ctx: *Ctx) void {
    var plan: Plan = .{};
    for (0..model.max_workspaces) |i| {
        const ws = model.WSId.fromIndex(i);
        if (ws.eql(m.current)) continue;
        // Cheap guard: tiled_order is the membership the compute iterates.
        if (m.ws[i].tiled_order.len == 0) continue;
        // Covered workspaces compute no placements; skip the compute outright.
        if (model.coveringOccupantOn(m, ws, .anchored_or_visible) != null) continue;
        plan.placements = .{};
        plan.pl_of_slot = [_]?usize{null} ** model.store_capacity;
        computeLayoutForWs(m, ctx, &plan, ws);
        for (plan.placements.constSlice()) |pl| {
            const e = m.store.get(pl.win) orelse continue;
            // Visible right now: the current-workspace pass owns its geometry.
            if (model.visibleEntry(m, &e, m.current)) continue;
            // Minimized or covering; neither is ours to resize.
            if (e.presence != .present) continue;
            const last = sentGet(pl.win) orelse continue;
            // Dedup: a shown-then-parked window's ledger holds its last
            // visible size. A never-shown window's record is blank, so its
            // size is unknown and always sent.
            if (last.has_rect and last.rect.width == pl.rect.width and
                last.rect.height == pl.rect.height) continue;
            ctx.sink.configure(pl.win, .{ .size = .{
                .width = pl.rect.width,
                .height = pl.rect.height,
            } });
            // Record the new size so the NEXT toggle can dedup against it.
            if (sentGetOrPut(pl.win)) |g| {
                if (g.has_rect) {
                    g.rect.width = pl.rect.width;
                    g.rect.height = pl.rect.height;
                }
            }
        }
    }
}

/// Phase 2: winner seed: fullscreen winner outright; else the focused window
/// when its desire will be non-parked (checked here so no earlier store entry
/// can shadow it); else the fused loop elects the first non-parked desire.
/// Mirrors computeDesire via `desireIsNonParked` with has_kept_rect = false.
fn seedWinner(m: *const model.Model, plan: *const Plan) ?model.WindowId {
    var winner: ?model.WindowId = plan.fs_win;
    if (winner == null) if (m.focused) |f| blk: {
        const slot = m.store.indexOf(f) orelse break :blk;
        const fe = m.store.at(slot).val.*;
        const placement = placementOfSlot(&plan.placements, &plan.pl_of_slot, slot);
        const on_cur = model.visibleEntry(m, &fe, m.current);
        if (fe.presence == .present and desireIsNonParked(fe, plan.fs_win, placement, false, on_cur))
            winner = f;
    };
    return winner;
}

/// Phase 3: one fused loop over the store: compute a window's desire, then
/// SEND it immediately, honoring two invariants: map precedes geometry so a
/// first-show/unparking client exposes at its final rect, and border width
/// merges into the geometry configure when both change (parked windows emit
/// ONE merged park request instead: offscreen X + BELOW).
///
/// The ledger reads inside are contract, not optimization (file header): the
/// orphan branch keeps the last real geometry (read 1), raise triggers derive
/// from rect/parked comparisons (read 2), and everything written here feeds
/// lastRectFor/truthRect (read 3). Sends never consult the ledger to SKIP
/// anything. `winner` arrives seeded and is still mutable here.
///
/// Returns whether the float re-assert must run (see `armReassert`).
fn sendAll(
    m: *const model.Model,
    ctx: *Ctx,
    opts: Opts,
    plan: *const Plan,
    winner: *?model.WindowId,
) bool {
    const fs_win = plan.fs_win;
    const placements = &plan.placements;
    const pl_of_slot = &plan.pl_of_slot;

    const count = m.store.count();
    // One warn per reconcile when a record couldn't be written, not one per
    // window (the condition is structural: ledger at store_capacity).
    var ledger_overflow = false;
    // Re-assert arming (file header): `reassert` latches when this pass could
    // stack a tiled window above the floating layer or show one; `saw_visible_float`
    // keeps the phase free when no float is on screen.
    var reassert = false;
    var saw_visible_float = false;
    for (0..count) |i| {
        const it = m.store.at(i);
        const win = it.key;
        const e: *const model.Entry = it.val;

        // One get-or-create per window: the same record backs the pre-send
        // contract reads AND the post-send write, read before any send and
        // written after, so raises derive from what we last sent. When the
        // ledger is full, `gop` is null: reads see a fresh blank, the write is
        // lost (warned once), sends unaffected.
        const gop = sentGetOrPut(win);
        const last = (if (gop) |g| g.* else SentEntry.blank());

        // OFF-WORKSPACE FAST PATH (file header read 0): provably parked and
        // already parked in the ledger needs no recompute and no send.
        const is_fs = win == fs_win;
        const on_current = model.visibleEntry(m, e, m.current);
        // The one fact that makes the re-assert worth running.
        if (e.presence == .present and e.anchor == .floating and on_current)
            saw_visible_float = true;
        const definitely_parked_desire = e.presence == .parked or !on_current;
        // `parked_dirty`: the client moved this parked window behind our back,
        // so the elision would strand it on screen (see SentEntry.parked_dirty).
        if (!is_fs and definitely_parked_desire and last.parked and !last.parked_dirty) continue;

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

        const tracing = trace.enabled() and trace.watches(win);
        if (parked) {
            sendParkTransition(ctx.sink, win, last, tracing);
        } else {
            const p = planShow(last, rect, bw, pixel, is_winner, opts.force_restack);
            armReassert(e, win, p, &reassert);

            if (p.need_map) {
                if (tracing) trace.outbound(win, "map", "");
                ctx.sink.map(win);
            }
            if (p.need_pixel) sendBorderPixel(ctx.sink, win, pixel, tracing);
            if (p.need_bw or p.need_geom) {
                sendConfigure(ctx.sink, win, rect, bw, .{ .geom = p.need_geom, .bw = p.need_bw, .raise = p.raise }, tracing);
            }
        }

        if (recordSent(gop, parked, rect, bw, pixel)) ledger_overflow = true;
    }
    if (ledger_overflow) log.err("reconcile: ledger full; some sends applied, records lost", .{});
    return reassert and saw_visible_float;
}

/// Ledger-write trailer of the fused loop: a park records that the window is
/// where we want it (and clears the dirty flag); an unpark overwrites wholesale.
/// Returns true when the record was LOST, so the caller warns once per
/// reconcile.
fn recordSent(
    gop: ?*SentEntry,
    parked: bool,
    rect: model.Rect,
    bw: u16,
    pixel: u32,
) bool {
    if (gop) |g| {
        if (parked) g.parked = true else markSentVisible(g, rect, bw, pixel);
        g.parked_dirty = false;
        return false;
    }
    return true;
}

/// What a VISIBLE (non-parked) window's send must carry this pass, derived
/// from the ledger against this pass's desire. Raise triggers per the ledger
/// contract (file header read 2): winner .above on geometry motion, unpark, or
/// restack pressure only. `bw` is owned by need_bw.
const ShowPlan = struct {
    first_send: bool,
    unpark: bool,
    raise: bool,
    need_map: bool,
    need_bw: bool,
    need_pixel: bool,
    need_geom: bool,
};

fn planShow(last: SentEntry, rect: model.Rect, bw: u16, pixel: u32, is_winner: bool, force_restack: bool) ShowPlan {
    const first_send = !last.has_rect;
    const moved = first_send or !last.rect.eqlGeom(rect);
    const unpark = last.parked;
    const raise = is_winner and (moved or unpark or force_restack);
    return .{
        .first_send = first_send,
        .unpark = unpark,
        .raise = raise,
        .need_map = first_send or unpark,
        .need_bw = !last.has_rect or last.bw != bw,
        .need_pixel = !last.has_rect or last.pixel != pixel,
        .need_geom = moved or unpark or raise,
    };
}

/// Raise bookkeeping for the float re-assert (file header): a raised FLOAT
/// records its new top slot; a raised TILED window, a newly sent tiled frame,
/// or a float coming on screen all arm the re-assert.
fn armReassert(e: *const model.Entry, win: model.WindowId, p: ShowPlan, reassert: *bool) void {
    if (p.raise) {
        if (e.anchor == .floating) floatRaise(win) else reassert.* = true;
    }
    if (p.first_send and e.anchor == .tiled) reassert.* = true;
    if (e.anchor == .floating and (p.first_send or p.unpark)) reassert.* = true;
}

/// Visibility concern: the park transition. Re-send on the transition OR when
/// the client moved itself while parked (`last.parked` stays true across the
/// drift). Already parked and clean sends nothing.
fn sendParkTransition(snk: sink.Sink, win: model.WindowId, last: SentEntry, tracing: bool) void {
    if (!last.parked or last.parked_dirty) {
        if (tracing) trace.outbound(win, "park", "unpark-then-park");
        // Map before park: a fresh window's own map request was redirected by
        // SubstructureRedirect, so the offscreen park would leave it unmapped
        // and a focus issued for it would fail with BadMatch.
        if (!last.has_rect) snk.map(win);
        snk.park(win);
    } else if (tracing) {
        // "hana said nothing BECAUSE it skipped the window" is a different
        // finding from "hana said nothing".
        trace.outbound(win, "park-elided", "already parked");
    }
}

/// Borders concern: the border-pixel delta (a focus flip recolors without
/// moving). State-atoms are deliberately NOT a reconcile concern: EWMH
/// fullscreen state rides the fullscreen module, outside this loop.
fn sendBorderPixel(snk: sink.Sink, win: model.WindowId, pixel: u32, tracing: bool) void {
    if (tracing) trace.outbound(win, "border_pixel", "");
    snk.borderPixel(win, pixel);
}

/// Geometry+borders concern: ONE configure carrying everything that changed --
/// bw and geometry travel together on the switch/unpark shape and cannot be two
/// separate requests here. The trace prints exactly the fields the request
/// carries, guarded as the send is.
const ConfigureFlags = struct { geom: bool, bw: bool, raise: bool };

fn sendConfigure(
    snk: sink.Sink,
    win: model.WindowId,
    rect: model.Rect,
    bw: u16,
    flags: ConfigureFlags,
    tracing: bool,
) void {
    if (tracing) trace.outbound(win, "configure", switch (flags.geom) {
        true => if (flags.bw) std.fmt.bufPrint(&trace_buf, "{d}x{d}+{d}+{d} bw={d} stack={s}", .{
            rect.width,                        rect.height, rect.x, rect.y, bw,
            if (flags.raise) "above" else "-",
        }) catch "rect" else std.fmt.bufPrint(&trace_buf, "{d}x{d}+{d}+{d} stack={s}", .{
            rect.width,                        rect.height, rect.x, rect.y,
            if (flags.raise) "above" else "-",
        }) catch "rect",
        false => std.fmt.bufPrint(&trace_buf, "bw={d} stack={s}", .{
            bw,
            if (flags.raise) "above" else "-",
        }) catch "bw",
    });
    snk.configure(win, .{
        .rect = if (flags.geom) rect else null,
        .bw = if (flags.bw) bw else null,
        .stack = if (flags.raise) .above else null,
    });
}

/// Phase 4 (conditional, armed per the file header): re-assert the floating
/// layer above every tiled window by replaying the ledger's float raise order
/// bottom-first, so overlapping floats keep their exact click/drag order.
/// Covered siblings park offscreen under a fullscreen winner. Floats not yet
/// in the order are adopted at the top first.
fn reassertFloats(m: *const model.Model, ctx: *Ctx, plan: *const Plan) void {
    if (plan.fs_win != null) return;

    // Adopt: every visible float holds a slot before the replay reads the
    // order (one pass; no wire traffic of its own).
    const count = m.store.count();
    for (0..count) |i| {
        const it = m.store.at(i);
        const e: *const model.Entry = it.val;
        if (e.presence != .present or e.anchor != .floating) continue;
        if (!model.visibleEntry(m, e, m.current)) continue;
        if (!floatContains(it.key)) floatRaise(it.key);
    }

    // Replay bottom -> top, so the order list's last entry ends topmost.
    for (floatOrder()) |win| {
        const e = m.store.get(win) orelse continue;
        if (e.presence != .present or e.anchor != .floating) continue;
        if (!model.visibleEntry(m, &e, m.current)) continue;
        ctx.sink.stackOnly(win, .above);
    }
}

/// Best known live geometry for `win` without a server round trip:
///   1. floating base rect from the model (authoritative while floating),
///   2. else the last visible geometry we sent (null while parked/unsent).
pub fn truthRect(m: *const model.Model, win: model.WindowId) ?model.Rect {
    const e = m.store.get(win) orelse return null;
    if (e.presence == .present and e.anchor == .floating) return e.anchor.floating;
    return lastRectFor(win);
}

const Desire = struct {
    rect: model.Rect,
    bw: u16,
    pixel: u32,
    parked: bool,
};

fn markParked(bw: *u16, pixel: *u32, parked: *bool) void {
    bw.* = 0;
    pixel.* = 0;
    parked.* = true;
}

/// True when a `.present` entry's desire will be non-parked on the current
/// workspace. Under a fullscreen covering winner everything parks regardless of
/// anchor; a float must be on-workspace-visible; a tiled window needs a visible
/// placement, or -- with none (multi-tag orphan) -- on-workspace visibility AND
/// a kept last-sent rect. Shared by the winner seed and computeDesire.
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

/// Compute the desired state for a single store entry. The `winner` pointer is
/// mutated when this is the first non-parked entry in store order (fallback
/// winner election). `last` is the pre-send record for orphan keep-last.
fn computeDesire(
    m: *const model.Model,
    ctx: *Ctx,
    e: *const model.Entry,
    win: model.WindowId,
    fs_win: ?model.WindowId,
    placement: ?contract.Placement,
    winner: *?model.WindowId,
    last: SentEntry,
    on_current: bool,
) Desire {
    var rect: model.Rect = contract.parked_rect;
    var bw: u16 = ctx.env.margins.border;
    var pixel: u32 = ctx.color_of(win, m);
    var parked = false;

    switch (e.presence) {
        // Parked entries always park. Covering records: the winner owns the
        // full screen, borderless; siblings park too (bw/pixel preserved for
        // the exit replay); no winner resolves -> park outright.
        .parked, .covering => {
            if (e.presence == .parked or fs_win == null) {
                markParked(&bw, &pixel, &parked);
            } else if (win == fs_win) {
                rect = ctx.screen;
                bw = 0;
                pixel = 0;
            } else {
                // Deliberately NOT markParked: that zeroes bw/pixel, which is
                // right for the "park from a clean slate" arms above and wrong
                // here -- the exit replay needs the borders the window was last
                // given, or it comes back undecorated.
                parked = true;
            }
        },
        // A covering window owns the screen: every other present window is a
        // covered sibling and parks (geometry preserved for the exit replay).
        .present => {
            // Parked-ness comes from the shared predicate (desireIsNonParked).
            parked = !desireIsNonParked(e.*, fs_win, placement, last.has_rect, on_current);
            switch (e.anchor) {
                .floating => |r| rect = r,
                .tiled => if (placement) |p| {
                    rect = p.rect;
                } else if (on_current and last.has_rect) {
                    // Multi-tagged orphan never hidden: keep the last-sent
                    // rect, parked only when nothing was ever sent.
                    rect = last.rect;
                } else markParked(&bw, &pixel, &parked),
            }
        },
    }

    // Fallback winner: first non-parked desire in store order.
    if (winner.* == null and !parked) winner.* = win;
    return .{ .rect = rect, .bw = bw, .pixel = pixel, .parked = parked };
}

/// O(1) placement lookup: placement for store slot `slot`, or null when the
/// window has none this reconcile (multi-tag orphan, off-workspace, no-tiling
/// build). Degrades to null, never out of bounds.
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
