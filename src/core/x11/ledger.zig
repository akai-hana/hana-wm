//! The sent ledger: a write-only record of what was last sent per window.
//!
//! Split out of `reconcile.zig` so the DAG reads in one direction —
//! `ledger` <- `reconcile` <- `loop/pipeline` — and so the records have a
//! name of their own. This is a diff base, not a cache of server truth: the
//! model stays authoritative (`reconcile.truthRect` derives geometry from
//! the model first), and the ledger only exists so a reconcile can elide a
//! request whose desired value matches the last one sent. That makes it
//! wrong-by-design to consult from anywhere else, which is why the writes
//! live here behind dedicated marks.
//!
//! `reconcile`'s header owns the behavioural reads of this ledger; the field
//! semantics live on `SentEntry` below.
//!
//! The FLOAT RAISE ORDER (`floatRaise`/`floatOrder`) is the one sibling
//! record: an ordered list of which floating windows the wire last raised,
//! bottom to top. It is wire state, not a server-truth cache — it never
//! claims where windows ARE, only the order hana last asked for them — so
//! the reconciler consults it (the end-of-pass re-assert replays it) while
//! the raise sites write it: focus click (`focus.applyPendingFocus`), drag
//! start (`floating.startDrag`), and the reconciler's own winner raise.
//! Parked windows keep their slot (an unpark replays them into their old
//! position), a float that detaches to tiled keeps a stale slot the
//! replay's anchor filter skips until it floats again, and `forget` drops
//! the slot with the record (recycled ids).

const std = @import("std");

const model = @import("model");

/// What we last sent per window; WRITE-ONLY bookkeeping (the file header owns
/// why it is wrong-by-design to consult from anywhere else). Field semantics
/// are documented HERE; reconcile.zig's header owns the behavioural reads.
///
/// bw/pixel deliberately SURVIVE a park. The park write flips only `parked`;
/// zeroing them would make the unpark transition see a changed border and
/// repaint, which is the border flash the park/unpark path exists to avoid.
/// "The last value sent" is the honest invariant: these record what X was
/// told, not what is currently on screen.
pub const SentEntry = struct {
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
    pub fn blank() SentEntry {
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

pub fn init() void {
    st = .{};
}

/// Ledger read of a window's last-sent record. pub because it is also the
/// test verification seam (reconcile_test/query_test assert what a
/// reconcile sent); production reads at lastRectFor.
pub fn sentGet(win: model.WindowId) ?SentEntry {
    return st.sent.get(win);
}

/// Ledger get-or-create for `win`: pointer to its record, or null when the
/// ledger is full and `win` has no slot yet. Callers treat both cases the same.
/// pub: the reconciler, plus the test verification seam (perf_test).
pub fn sentGetOrPut(win: model.WindowId) ?*SentEntry {
    if (st.sent.getPtr(win)) |r| return r;
    return st.sent.put(win, SentEntry.blank()) catch null;
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from window actions on unmanage, and by the test seam. Also drops
/// the float-raise-order slot: a dead XID must never be replayed by the
/// re-assert (BadWindow), and the next incarnation must not inherit a
/// stale stacking position.
pub fn forget(win: model.WindowId) void {
    _ = st.sent.remove(win);
    if (floatIndexOf(win)) |i| floatRemoveAt(i);
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
/// This is the ONE border-pixel dedup. It was in `title_cache` (`border_color`)
/// while the reconcile's own dedup read THIS record's `pixel` field, so the
/// same fact was tracked in two places that could disagree: the reconcile sent
/// a pixel through the sink without touching the cache, and the sweep sent
/// through the cache without touching the ledger. Deriving both from one record
/// is what removes the class of bug, not just the duplicate field.
///
/// Two reasons the answer is not simply `pixel != new`:
///  * `has_rect` gates the comparison. A blank record's `pixel` is 0, and a
///    genuinely black border must still be SENT -- without the gate, the very
///    first sweep would elide a real 0-pixel send. `has_rect` means "a visible
///    geometry was ever sent", i.e. "we know the server's current pixel".
///  * a full ledger returns TRUE (send anyway). A missed dedup costs one
///    redundant ChangeWindowAttributes; a missed send leaves a wrong border,
///    which is the same fallback the cache-full case used to have.
pub fn markSentBorderPixelIfChanged(win: model.WindowId, pixel: u32) bool {
    const gop = sentGetOrPut(win) orelse return true;
    if (gop.has_rect and gop.pixel == pixel) return false;
    gop.pixel = pixel;
    return true;
}

/// Record a visible (non-parked) send in the ledger. Shared by the full
/// reconcile (border width/pixel known) and the drag-tick fast path (0,0).
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
