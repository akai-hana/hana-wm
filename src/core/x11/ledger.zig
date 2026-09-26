//! The sent ledger: a write-only record of what was last sent per window.
//!
//! Split out of `reconcile.zig` so the DAG reads in one direction —
//! `ledger` <- `reconcile` <- `loop/pipeline` — and so the records have a
//! name of their own. This is a diff base, not a cache of server truth: the
//! model stays authoritative (`reconcile.truthRect` derives geometry from the
//! model first), and the ledger only exists so a reconcile can elide a request
//! whose desired value matches the last one sent. That makes it wrong-by-design
//! to consult from anywhere else, which is why the writes live here and the
//! reconciler is the only writer.
//!
//! `reconcile`'s header documents the four behavioural reads of this ledger.

const model = @import("model");
const contract = @import("contract");

/// What we last sent per window; WRITE-ONLY bookkeeping whose four contract
/// reads are documented in reconcile.zig's header:
///   - has_rect: whether a visible geometry was EVER sent (an explicit flag,
///     not a sentinel rect: a legitimately placed zero-size window at the
///     origin would collide with a "never sent" marker value);
///   - rect: the last VISIBLE geometry sent (survives parks);
///   - parked: whether the latest reconcile parked it;
///   - bw: the last border width sent (0 if never sent);
///   - pixel: the last border pixel sent (0 if never sent).
///
/// bw/pixel deliberately SURVIVE a park. The park write flips only `parked`;
/// zeroing them would make the unpark transition see a changed border and
/// repaint, which is the border flash the park/unpark path exists to avoid.
/// "The last value sent" is the honest invariant: these record what X was
/// told, not what is currently on screen.
pub const SentEntry = struct {
    rect: model.Rect = contract.parked_rect,
    has_rect: bool = false,
    parked: bool = false,
    bw: u16 = 0,
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
/// test verification seam (reconcile_test/tracking_test assert what a
/// reconcile sent); production reads at lastRectFor.
pub fn sentGet(win: model.WindowId) ?SentEntry {
    return st.sent.get(win);
}

/// Ledger get-or-create for `win`: pointer to its record, or null when the
/// ledger is full and `win` has no slot yet. Callers treat both cases the same.
/// pub: the reconciler, plus the test verification seam (perf_test).
pub fn sentGetOrPut(win: model.WindowId) ?*SentEntry {
    if (st.sent.getPtr(win)) |r| return r;
    return st.sent.put(win, .{}) catch null;
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from window actions on unmanage, and by the test seam.
pub fn forget(win: model.WindowId) void {
    _ = st.sent.remove(win);
}

/// Record a border width sent for `win` without disturbing the ledger's
/// geometry/park state. Called by the border-detail path (window.zig) after a
/// width-only send so the next full reconcile's need_bw check
/// (`!last.has_rect or last.bw != bw`) elides the redundant resend. No-op
/// when the ledger is full or the get-or-put errors (sentGetOrPut contract).
/// Note that a parked window changed its own geometry, so the next reconcile
/// must re-park it instead of taking the elision. Called from the
/// ConfigureNotify route for MANAGED windows only: an unmanaged client's
/// configure says nothing about our park.
pub fn markParkedDirty(win: model.WindowId) void {
    const e = sentGet(win) orelse return;
    if (!e.parked) return; // only the parked fast path can elide a repair
    st.sent.getPtr(win).?.parked_dirty = true;
}

pub fn markSentBorderWidth(win: model.WindowId, w: u16) void {
    const gop = sentGetOrPut(win) orelse return;
    gop.bw = w;
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
