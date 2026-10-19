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
//! covering winner, not on the current workspace, or presence parked -- and already
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
//! FLOAT-ABOVE-TILED STACKING. The winner raise alone cannot uphold the
//! invariant that floating windows always overlap tiled ones — a raised
//! tiled window (winner on motion, unpark, or force_restack) rides to the
//! absolute top and would bury the floating layer — so any pass that raises
//! or newly sends a TILED window, or shows a FLOATING window (first-send /
//! unpark), arms a final RE-ASSERT phase. That phase replays the ledger's
//! float raise order (bottom first) over the tiled layer, so overlapping
//! floats keep their exact click/drag order; the replay never rewrites the
//! order (floatRaise at the raise sites does), a listed window that has
//! since detached to tiled is skipped by the anchor filter, and floats not
//! yet listed (fresh spawn, session adoption) are adopted at the top. The
//! phase runs before the force_restack bar raise so chrome stays topmost,
//! and is elided entirely when no floating window is present — steady-state
//! and float-free reconciles still send nothing.
//!
//! RESIZE-PARKED (opt-in, Opts.resize_parked). The bar visibility toggle is
//! the one caller that arms it: its workarea change must reach every
//! workspace, but the normal pass only computes the CURRENT one, so parked
//! windows on other workspaces would keep the old size until their switch
//! reconcile — and that reconcile unparks and sizes them in the SAME flush,
//! which is the visible re-size slow apps (Electron) render as flicker. The
//! phase therefore reuses the layout compute for every other workspace
//! against the CURRENT workarea and size-only-resizes (WIDTH/HEIGHT, no
//! X/Y) its offscreen windows, so their clients re-render while hidden and
//! the later switch is a pure position change. Fullscreen-driven bar
//! hide/show deliberately does NOT arm it (that workarea change is local
//! and recomputed at every switch; pre-sizing there would only make the
//! switch size the windows back on show).
//!
//! The SENT LEDGER is a write-only record of what was actually sent (field
//! semantics: `SentEntry`). Exactly five reads of it are behavioral
//! contract:
//!   0. OFF-WORKSPACE FAST PATH: reads `parked` to elide windows provably
//!      already parked (no recompute, no park resend, never a fallback
//!      winner) -- skipped otherwise by the full path below.
//!   1. Multi-tag orphans: kept at their previous real geometry
//!      rather than parking. A history-less orphan parks (first sight /
//!      registered offscreen).
//!   2. Winner-raise derivation: rides .above ONLY when geometry moved,
//!      when it unparked, or under force_restack, derived by comparing the
//!      new rect against the sent ledger and reading its parked flag.
//!   3. Floating-detach / title prefetch (lastRectFor,
//!      reconcile.truthRect): the live rect as the new floating base, null
//!      while parked.
//!   4. Parked drift: `parked_dirty` (set when the client moved a parked
//!      window behind our back) forces a recompute/re-park instead of the
//!      elision -- two reads, the fast-path `continue` and the park send.
//!

const std = @import("std");
const build_options = @import("build_options");
const model = @import("model");
const log = std.log.scoped(.reconcile);

/// The tiling engine is reached through the build-generated `tiling_seam`:
/// when no tiling subsystem is present the seam is an empty struct, and every
/// `tiling.*` member use below sits behind a `has_tiling` gate, so the
/// reconcile path still runs (park/map/stack) with the layout-computation
/// block skipped and the placement lookup table left empty. The interchange
/// TYPES (View/List/Placement/Env/HintsView/parked_rect) come from the tiling
/// contract (tiling_contract.zig), which both the tiling engine and this reconciler
/// reference — no mirrored duplicate to keep in lockstep, and no local stub.
const contract = @import("tiling_contract");
const tiling = @import("tiling_seam").tiling;
const trace = @import("trace");

/// The sent ledger: a write-only record of what was last sent per window.
///
/// This is a diff base, not a cache of server truth: the model stays authoritative
/// (`reconcile.truthRect` derives geometry from the model first), and the ledger
/// only exists so a reconcile can elide a request whose desired value matches the
/// last one sent. It is wrong-by-design to consult from anywhere else.
///
/// The FLOAT RAISE ORDER (`floatRaise`/`floatOrder`) is the one sibling record:
/// an ordered list of which floating windows the wire last raised, bottom to top.
/// It is wire state, not a server-truth cache — it never claims where windows ARE,
/// only the order hana last asked for them — so the reconciler consults it (the
/// end-of-pass re-assert replays it) while the raise sites write it: focus click,
/// drag start, and the reconciler's own winner raise. Parked windows keep their
/// slot (an unpark replays them into their old position), a float that detaches
/// to tiled keeps a stale slot the replay's anchor filter skips until it floats
/// again, and `forget` drops the slot with the record (recycled ids).
/// What we last sent per window; WRITE-ONLY bookkeeping. Field semantics are
/// documented HERE; reconcile.zig's header owns the behavioural reads.
///
/// bw/pixel deliberately SURVIVE a park. The park write flips only `parked`;
/// zeroing them would make the unpark transition see a changed border and
/// repaint, which is the border flash the park/unpark path exists to avoid.
/// "The last value sent" is the honest invariant: these record what X was told,
/// not what is currently on screen.
const SentEntry = struct {
    /// Last VISIBLE geometry sent. Undefined until `has_rect` says a geometry
    /// was sent -- there is deliberately NO sentinel default: `has_rect`
    /// is the explicit "never sent" flag, so a sentinel rect would be dead
    /// weight that reads like a load-bearing marker. The claim that bw/pixel
    /// survive a park is about THESE two fields, not `rect`.
    rect: model.Rect,
    /// Whether a visible geometry was EVER sent (an explicit flag, not a
    /// sentinel rect: a legitimately placed zero-size window at the origin
    /// would collide with a "never sent" marker value).
    has_rect: bool = false,
    /// Whether the latest reconcile parked it.
    parked: bool = false,
    /// The last border width sent (0 if never sent).
    bw: u16 = 0,
    /// The last border pixel sent (0 if never sent).
    pixel: u32 = 0,

    /// Set when a ConfigureNotify says this window changed its own geometry
    /// while we had it parked offscreen. The reconcile's off-workspace fast
    /// path elides windows already parked in the ledger, which is what makes
    /// the sweep cheap -- but it would also elide a client that moved itself
    /// back on-screen behind our back, leaving it visibly stranded until some
    /// unrelated event happened to force a full recompute. This flag is the
    /// escape hatch: it costs one flag, and it only ever makes the reconciler
    /// do MORE work, never less.
    parked_dirty: bool = false,

    /// A record for a window nothing has been sent to yet. `has_rect` is
    /// false, which is the ONLY thing that makes this a valid blank -- `rect`
    /// holds a meaningless zero and every reader must gate on `has_rect`
    /// first (`visibleSent` does). `rect` has no struct-literal default,
    /// so the sentinel could not be mistaken for a real marker; construction
    /// is explicit here instead of implicit at every use site.
    fn blank() SentEntry {
        return .{ .rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
    }
};

const State = struct {
    /// Ledger of sent state (see SentEntry), keyed by window id in the
    /// model.Store's sorted-key array: get-or-put / forget resolve records
    /// by binary search with no parallel id index to keep in lockstep.
    sent: model.Store(model.WindowId, SentEntry, model.store_capacity) = .{},
    /// The FLOAT RAISE ORDER (see file header): each window holds exactly
    /// one slot, index 0 = bottom-most float, `float_len - 1` = top-most.
    /// `undefined` like any other never-read-before storage; `float_len` is
    /// the explicit extent (same discipline as SentEntry.has_rect).
    float_order: [model.store_capacity]model.WindowId = undefined,
    float_len: usize = 0,
};

/// Owned by the compositor process (process-lifetime; init() only re-arms
/// between tests). Module-private: all access goes through this file's API.
var st: State = .{};

/// Initialize (or re-initialize between tests) the sent ledger.
pub fn init() void {
    st = .{};
}

/// Ledger read of a window's last-sent record. Public for test verification
/// seam (reconcile_test/query_test assert what a reconcile sent); production
/// reads use lastRectFor.
pub fn sentGet(win: model.WindowId) ?SentEntry {
    return st.sent.get(win);
}

/// Ledger get-or-create for `win`: pointer to its record, or null when the
/// ledger is full and `win` has no slot yet. Callers treat both cases the same.
/// Public for test verification (perf_test).
pub fn sentGetOrPut(win: model.WindowId) ?*SentEntry {
    if (st.sent.getPtr(win)) |r| return r;
    return st.sent.put(win, SentEntry.blank()) catch null;
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from window.unmanage, and by the test seam. Also drops the
/// float-raise-order slot: a dead XID must never be replayed by the
/// re-assert (BadWindow), and the next incarnation must not inherit a
/// stale stacking position.
pub fn forget(win: model.WindowId) void {
    _ = st.sent.remove(win);
    requests.forgetSequence(win);
    if (floatIndexOf(win)) |i| floatRemoveAt(i);
}

/// Note that a parked window changed its own geometry, so the next
/// reconcile must re-park it instead of taking the elision. Called from the
/// ConfigureNotify route for MANAGED windows only: an unmanaged client's
/// configure says nothing about our park.
pub fn markParkedDirty(win: model.WindowId) void {
    const e = sentGet(win) orelse return;
    if (!e.parked) return; // only the parked fast path can elide a repair
    st.sent.getPtr(win).?.parked_dirty = true;
}

/// Record a border width sent for `win` without disturbing the ledger's
/// geometry/park state. Called by the border-detail path (window.zig) after a
/// width-only send so the next full reconcile's need_bw check
/// (`!last.has_rect or last.bw != bw`) elides the redundant resend. No-op
/// when the ledger is full or the get-or-put errors (sentGetOrPut contract).
pub fn markSentBorderWidth(win: model.WindowId, w: u16) void {
    const gop = sentGetOrPut(win) orelse return;
    gop.bw = w;
}

/// Record a border-pixel send unless that exact pixel is already recorded, and
/// report whether the caller must actually send.
///
/// This is the ONE border-pixel dedup: the reconcile pass and the border
/// sweep both derive from this record. Two copies of one fact can disagree
/// (one send path updates one copy, the other send path updates the other);
/// deriving both from one record removes the class of bug, not just the
/// duplicate field.
///
/// Two reasons the answer is not simply `pixel != new`:
///  * `has_rect` gates the comparison. A blank record's `pixel` is 0, and a
///    genuinely black border must still be SENT -- without the gate, the very
///    first sweep would elide a real 0-pixel send. `has_rect` means "a visible
///    geometry was ever sent", i.e. "we know the server's current pixel".
///  * a full ledger returns TRUE (send anyway). A missed dedup costs one
///    redundant ChangeWindowAttributes; a missed send leaves a wrong border.
pub fn markSentBorderPixelIfChanged(win: model.WindowId, pixel: u32) bool {
    const gop = sentGetOrPut(win) orelse return true;
    if (gop.has_rect and gop.pixel == pixel) return false;
    gop.pixel = pixel;
    return true;
}

/// Record a visible (non-parked) send in the ledger. Shared by the full
/// reconcile (border width/pixel known) and the drag-tick fast path (0,0).
/// Public for test verification.
pub fn markSentVisible(e: *SentEntry, rect: model.Rect, bw: u16, pixel: u32) void {
    e.* = .{ .rect = rect, .has_rect = true, .parked = false, .bw = bw, .pixel = pixel };
}

/// The ledger record for `win` when a visible (non-parked) geometry was
/// ever sent; null otherwise.
fn visibleSent(win: model.WindowId) ?SentEntry {
    const e = sentGet(win) orelse return null;
    if (!e.has_rect or e.parked) return null;
    return e;
}

/// Last visible geometry we sent to `win`, or null when never sent /
/// currently parked.
pub fn lastRectFor(win: model.WindowId) ?model.Rect {
    const e = visibleSent(win) orelse return null;
    return e.rect;
}

/// Border width last sent for `win`, or null when never sent / currently
/// parked. Feeds the synthetic ConfigureNotify echo so the width it reports
/// matches the window's actual X border rather than the global config default.
pub fn lastBorderWidthFor(win: model.WindowId) ?u16 {
    const e = visibleSent(win) orelse return null;
    return e.bw;
}

/// Index of `win` in the float raise order, or null when it holds no slot.
fn floatIndexOf(win: model.WindowId) ?usize {
    for (st.float_order[0..st.float_len], 0..) |w, i| {
        if (w == win) return i;
    }
    return null;
}

/// Remove the slot at `i` (closure by shifting the tail down one).
fn floatRemoveAt(i: usize) void {
    const tail = st.float_len - i - 1;
    if (tail > 0) std.mem.copyForwards(
        model.WindowId,
        st.float_order[i .. i + tail],
        st.float_order[i + 1 .. st.float_len],
    );
    st.float_len -= 1;
}

/// True when `win` currently holds a slot in the float raise order. Read
/// seam for the re-assert's "adopt floats never raised yet" phase.
pub fn floatContains(win: model.WindowId) bool {
    return floatIndexOf(win) != null;
}

/// The float raise order, bottom (index 0) to top (last entry). The
/// re-assert replays it in this order, so the LAST entry ends topmost.
pub fn floatOrder() []const model.WindowId {
    return st.float_order[0..st.float_len];
}

/// Record a raise of `win`: it moves to the TOP of the float raise order
/// (remove-if-present + append, so each window holds exactly one slot).
/// Called from every raise site — focus click, drag start, the reconciler's
/// winner raise — and NEVER from the re-assert's replay, which only reads
/// the order (a replay that rewrote it would permute the order it is
/// restoring). A full table drops the bottom-most slot (the least recently
/// raised) rather than refusing the raise: a missed slot self-heals at the
/// next re-assert (the window is adopted at the top), a refused raise
/// would leave the order claiming a position the wire never got.
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
    /// Screen minus bar; computed by the caller with the existing
    /// bar-offset helper (workArea(ctx)). Used for tiled geometry.
    workarea: model.Rect,
    env: contract.Env = .{},
    /// Focus/mode border color; same resolution as borders.resolveBorderColorWith,
    /// minus its fullscreen check (fullscreen zeroes via bw/pixel policy
    /// instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
    /// Whether a layout module may place windows. The CALLER resolves
    /// it -- normally `contract.activeLayoutKind(kind) != null` -- so this file
    /// asks the same question the bar asks without reading core config state
    /// itself, and so the reconcile stays drivable with a bare model.
    layout_active: bool = true,
};

pub const Opts = struct {
    force_restack: bool = false,
    /// Opt-in phase (bar visibility toggle): after the normal pass, recompute
    /// each OTHER workspace's layout against the current workarea and
    /// resize its offscreen windows to the placements — a size-only
    /// configure (WIDTH/HEIGHT, no X/Y: they stay parked) so the client
    /// re-renders while still hidden. A later switch to that workspace then
    /// unparks windows already at the new size: a pure position change at
    /// show time, not the visible re-size flicker slow apps (Electron) show
    /// when the first frame at the new geometry lags the unpark.
    ///
    /// Deliberately NOT set by the fullscreen-driven bar hide/show: that
    /// change is local and recomputed at every switch (the bar returns for a
    /// non-fullscreen target workspace), so pre-sizing parked windows to the
    /// full screen there would only make the switch re-size them back at show
    /// time — the exact flicker this phase exists to remove.
    resize_parked: bool = false,
};

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
    // Flush immediately: a video player (mpv) recreates its swapchain on every
    // size change, and leaving the configure in XCB's buffer until the end of
    // the event batch delays that work into a burst. Flushing here lets the
    // client start the resize as soon as the size is committed.
    snk.flush();

    // Update sent ledger so lastRectFor / toggleFloating see the live position.
    // Carry the last real border width/pixel across the drag. Writing
    // 0,0 here would revert them, and the next full reconcile would resend a
    // border the server already has -- a visible repaint flash on the
    // dragged window every tick.
    const gop = sentGetOrPut(win) orelse return;
    markSentVisible(gop, rect, gop.bw, gop.pixel);
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
    /// present + recorded on `ws`); sync must not enumerate optional modules,
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
/// seed the raise winner, fuse-compute-and-send every stored window, the
/// conditional float re-assert, the optional resize-parked phase, then the
/// force_restack bar raise. Split into phases for readability; the fused
/// per-window loop stays whole because that fusion IS the algorithm.
pub fn run(m: *const model.Model, ctx: *Ctx, opts: Opts) void {
    var plan: Plan = .{};
    computeLayout(m, ctx, &plan);
    var winner = seedWinner(m, &plan);
    // sendAll reports whether this pass disturbed stacking in a way that
    // could bury the floating layer (or show a floating window): the one
    // condition that arms the re-assert below.
    const reassert = sendAll(m, ctx, opts, &plan, &winner);
    if (reassert) reassertFloats(m, ctx, &plan);
    // Opt-in only (bar visibility toggle): pre-resize every other
    // workspace's offscreen windows to the new workarea, so a later switch
    // unparks them at their final size instead of re-sizing them on show.
    if (opts.resize_parked) resizeParkedForWorkspaces(m, ctx);

    // force_restack additionally raises bar/top. Always AFTER the float
    // re-assert, so a replayed float can never bury the bar.
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
    computeLayoutForWs(m, ctx, plan, m.current);
}

/// The layout compute for ONE workspace: coverage winner plus placements.
/// Shared by the current-workspace pass (`computeLayout`) and the
/// resize-parked phase, so there is exactly ONE answer to "what layout does
/// this workspace want under this workarea" — a second copy would be the
/// kind of drift the single-compute invariant exists to prevent. `ws` is a
/// parameter (not `m.current` reads sprinkled through) so the sharing is
/// structural: the phase cannot accidentally half-share.
fn computeLayoutForWs(m: *const model.Model, ctx: *Ctx, plan: *Plan, ws: model.WSId) void {
    // Work-area (screen minus bar) and coverage winner: see `Plan`.
    const wa = ctx.workarea;

    plan.fs_win = model.coveringOccupantOnWs(m, ws);

    var order_buf: [model.store_capacity]model.WindowId = undefined;
    var hints_buf: [model.store_capacity]model.SizeHints = undefined;
    // ONE activation gate, and it also SUPPLIES the geometry. Gating on the
    // resolved kind keeps geometry in step with what the bar reports as the
    // active layout (`contract.activeLayoutKind`, enabled AND registered): a
    // compile-time `has_tiling` gate would leave a runtime-disabled tiling
    // showing "no layout" in the bar while the geometry still tiled -- two
    // answers to one question. The resolved kind also subsumes the no-tiling
    // build (an empty registry resolves to null).
    const params = &m.ws[ws.index].params;
    if (plan.fs_win == null) {
        var n: usize = 0;
        const tiled = &m.ws[ws.index].tiled_order;
        for (tiled.constSlice()) |w| {
            // One binary search per window: indexOf locates the row once; the
            // entry comes from `at` instead of a second `get` lookup.
            const slot = m.store.indexOf(w) orelse continue;
            const e = m.store.at(slot).val;
            if (!model.taggedOn(e.*, ws)) continue;
            // First write wins; the store holds each id once so this is
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

/// The resize-parked phase (Opts.resize_parked): size every OTHER
/// workspace's offscreen windows to what its layout would compute under the
/// CURRENT workarea, via a size-only configure (WIDTH/HEIGHT, no X/Y) so
/// they stay parked while their clients re-render. The bar visibility toggle
/// arms this: its workarea change would otherwise only reach those windows
/// at switch time — as a visible re-size of a client that has just been
/// shown, the flicker slow apps exhibit.
///
/// Scope guards, each load-bearing:
///  - skip `m.current` (the normal pass above already sent its placements);
///  - skip a workspace whose screen is covered by a fullscreen occupant
///    (its windows' sizes are bar-independent — screen, not workarea — and
///    the switch reconcile computes no placements for it either);
///  - skip a window still VISIBLE on the current workspace (a multi-tag
///    orphan's geometry is owned by the current pass, not by its home ws);
///  - skip a window whose ledger already holds the target width/height
///    (idempotent resend; a repeat toggle back to the original sizes sends
///    again because the ledger tracked the intermediate change).
///
/// The ledger's rect w/h is updated in place — x/y untouched, `parked`
/// untouched — so the later unpark's moved-check sees the resize already
/// done. `has_rect` is deliberately NOT flipped: the record's contract is
/// "last VISIBLE geometry sent", and nothing was sent that put the window
/// on screen.
fn resizeParkedForWorkspaces(m: *const model.Model, ctx: *Ctx) void {
    var plan: Plan = .{};
    for (0..model.max_workspaces) |i| {
        const ws = model.WSId.fromIndex(i);
        if (ws.eql(m.current)) continue;
        // Cheap guard before the layout compute: an empty workspace has
        // nothing to resize, and tiled_order is the membership the compute
        // would iterate anyway.
        if (m.ws[i].tiled_order.len == 0) continue;
        // Covered workspaces compute no placements (and their windows' sizes
        // don't depend on the workarea); skip the compute outright.
        if (model.coveringOccupantOnWs(m, ws) != null) continue;
        plan.placements = .{};
        plan.pl_of_slot = [_]?usize{null} ** model.store_capacity;
        computeLayoutForWs(m, ctx, &plan, ws);
        for (plan.placements.constSlice()) |pl| {
            const e = m.store.get(pl.win) orelse continue;
            // Visible right now: the current-workspace pass owns its geometry.
            if (model.visibleEntry(m, &e, m.current)) continue;
            // presence != .present: minimized (absent from tiled_order anyway)
            // or covering; neither is ours to resize.
            if (e.presence != .present) continue;
            const last = sentGet(pl.win) orelse continue;
            // Dedup: a shown-then-parked window's ledger holds its last
            // visible size; when that already equals the target, a previous
            // toggle already resized it offscreen and resending would be a
            // no-op the server discards. A never-shown window's record is
            // blank (has_rect false): its size is unknown, so the resize is
            // always sent (first show then happens at the right size).
            if (last.has_rect and last.rect.width == pl.rect.width and
                last.rect.height == pl.rect.height) continue;
            ctx.sink.configure(pl.win, .{ .size = .{
                .width = pl.rect.width,
                .height = pl.rect.height,
            } });
            // Record the new size so the NEXT toggle can dedup against it.
            // x/y stay as the last VISIBLE position (the unpark sends the
            // full rect anyway via its transition); has_rect is NOT flipped:
            // nothing here put the window on screen, and rect is documented
            // as undefined until has_rect says a geometry was sent.
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
        const placement = placementOfSlot(&plan.placements, &plan.pl_of_slot, slot);
        const on_cur = model.visibleEntry(m, &fe, m.current);
        if (fe.presence == .present and desireIsNonParked(fe, plan.fs_win, placement, false, on_cur))
            winner = f;
    };
    return winner;
}

/// Phase 3: one fused loop over the store: compute a window's desire, then
/// SEND it immediately. Ordering is via the Sink adapter, honoring two
/// invariants here:
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
///
/// Returns whether the float re-assert must run after this pass: true when
/// the pass raised or newly sent a tiled window (either could sit above the
/// floating layer), showed a floating window (it must come back above the
/// tiled layer), AND at least one floating window is present to re-assert.
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
    // One warn per reconcile when any window's record couldn't be written, not one
    // per window: the condition is structural (ledger at store_capacity), so
    // a full reconcile would otherwise log per window.
    var ledger_overflow = false;
    // Re-assert arming (file header, FLOAT-ABOVE-TILED STACKING): `reassert`
    // latches when this pass could have stacked a tiled window above the
    // floating layer or showed a floating window; `saw_visible_float` keeps
    // the whole phase free when no float is on screen.
    var reassert = false;
    var saw_visible_float = false;
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
        const gop = sentGetOrPut(win);
        const last = (if (gop) |g| g.* else SentEntry.blank());

        // OFF-WORKSPACE FAST PATH: a desire that is PROVABLY parked (not the
        // covering winner, not on the current workspace, or presence parked) and is
        // already parked in the ledger needs no recompute and no send -- the
        // full path would derive parked, elide the park resend (last.parked
        // already true), never be a fallback winner, and rewrite the same
        // parked=true.
        const is_fs = win == fs_win;
        const on_current = model.visibleEntry(m, e, m.current);
        // A floating window that will be on screen this pass: the one fact
        // that makes the re-assert worth running (see reassertFloats, which
        // re-derives the same eligibility per window when it replays).
        if (e.presence == .present and e.anchor == .floating and on_current)
            saw_visible_float = true;
        const definitely_parked_desire = e.presence == .parked or !on_current;
        // `parked_dirty` means the client moved this parked window behind our
        // back, so the elision below would strand it on screen; recompute and
        // re-park it. See SentEntry.parked_dirty.
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

        const tracing = trace.enabled() and trace.watches(win);
        if (parked) {
            sendParkTransition(ctx.sink, win, last, tracing);
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

            // Raise bookkeeping for the float re-assert (file header):
            // a raised FLOAT records its new top slot in the ledger; a
            // raised TILED window, a newly sent tiled frame (X-default
            // stack position may sit above everything), or a floating
            // window coming back on screen all arm the re-assert.
            if (raise_winner) {
                if (e.anchor == .floating) floatRaise(win) else reassert = true;
            }
            if (first_send and e.anchor == .tiled) reassert = true;
            if (e.anchor == .floating and (first_send or unpark_transition)) reassert = true;

            const need_map = first_send or unpark_transition;
            const need_bw = !last.has_rect or last.bw != bw;
            const need_pixel = !last.has_rect or last.pixel != pixel;
            const need_geom = moved or unpark_transition or raise_winner;

            if (need_map) {
                if (tracing) trace.outbound(win, "map", "");
                ctx.sink.map(win);
            }
            if (need_pixel) sendBorderPixel(ctx.sink, win, pixel, tracing);
            if (need_bw or need_geom) {
                sendConfigure(ctx.sink, win, rect, bw, .{ .geom = need_geom, .bw = need_bw, .raise = raise_winner }, tracing);
            }
        }

        // Ledger write: record what we actually sent. A park preserves the
        // previous record's rect/has_rect; an unpark overwrites wholesale.
        if (gop) |g| {
            // A park (fresh or drift repair) records that the window is where
            // we want it, which is also what clears the dirty flag.
            if (parked) g.parked = true else markSentVisible(g, rect, bw, pixel);
            g.parked_dirty = false;
        } else ledger_overflow = true;
    }
    if (ledger_overflow) log.err("reconcile: ledger full; some sends applied, records lost", .{});
    return reassert and saw_visible_float;
}

/// Visibility concern: the park transition. Re-send on the transition OR
/// when the client moved itself while parked (`last.parked` stays true
/// across the drift, so without the dirty term the recompute above would
/// compute a fresh park and then throw it away). A park already recorded as
/// parked and clean sends nothing — only the trace distinguishes "already
/// parked where we put it" from "skipped by the fast path above".
fn sendParkTransition(snk: sink.Sink, win: model.WindowId, last: SentEntry, tracing: bool) void {
    if (!last.parked or last.parked_dirty) {
        if (tracing) trace.outbound(win, "park", "unpark-then-park");
        // Map before park: a fresh window's own map request was redirected
        // by SubstructureRedirect (never performed by the server), so the
        // offscreen park would otherwise leave it unmapped, and a focus
        // issued for it (spawn under a covering winner, cross-workspace
        // spawn) fails with BadMatch.
        if (!last.has_rect) snk.map(win);
        snk.park(win);
    } else if (tracing) {
        // The fast path elided this window entirely: it was already
        // parked where we put it. Logged because "hana said nothing"
        // and "hana said nothing BECAUSE it skipped the window" are
        // different findings, and a trace has to distinguish them.
        trace.outbound(win, "park-elided", "already parked");
    }
}

/// Borders concern: the border-pixel delta. Pixel-only (no geometry):
/// a focus flip recolors without moving. State-atoms are deliberately NOT
/// a reconcile concern — EWMH fullscreen state rides the fullscreen
/// module's `setEwmhFullscreenState` through the sink, outside this loop.
fn sendBorderPixel(snk: sink.Sink, win: model.WindowId, pixel: u32, tracing: bool) void {
    if (tracing) trace.outbound(win, "border_pixel", "");
    snk.borderPixel(win, pixel);
}

/// Geometry+borders concern: ONE configure carrying everything that
/// changed. Border width and geometry travel together on the common
/// switch/unpark shape, and this cannot express them as two separate
/// requests. The trace prints exactly the fields the request carries,
/// guarded by the same conditions as the send (over-reporting is worse
/// than silence).
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
            rect.width,                         rect.height, rect.x, rect.y, bw,
            if (flags.raise) "above" else "-",
        }) catch "rect" else std.fmt.bufPrint(&trace_buf, "{d}x{d}+{d}+{d} stack={s}", .{
            rect.width,                         rect.height, rect.x, rect.y,
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

/// Phase 4 (conditional): re-assert the floating layer above every tiled
/// window by replaying the ledger's float raise order bottom-first, so
/// overlapping floats keep their exact click/drag order. Armed by sendAll
/// (see the file header's FLOAT-ABOVE-TILED STACKING paragraph). Covered
/// siblings park offscreen under a fullscreen winner, so there is nothing
/// to re-assert there. Floats not yet in the order (fresh spawn, session
/// adoption) are adopted at the top before the replay; the replay filters
/// present + floating + on-current, which skips a listed window that has
/// since detached to tiled (its stale slot is re-entered by its next float
/// raise) and parks of other workspaces (their slots are kept, so an unpark
/// replays them into their old position).
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

    // Replay bottom -> top: each stackOnly(above) lands the window one step
    // higher, so the order list's last entry ends topmost.
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
/// emits fewer placements than ordered windows degrades to null instead of
/// indexing out of bounds.
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
