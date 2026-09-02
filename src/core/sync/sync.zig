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
//! RECONCILE ALGORITHM - UNCONDITIONAL APPLY. Every pass computes the desired
//! state for every stored window and SENDS it: parked windows get ONE merged
//! park request; visible windows replay map -> pixel -> bw -> geometry in
//! order, with any stacking mode merged into the geometry request itself.
//! X configure/map requests are idempotent, so replaying full desired state
//! is drift-proof by construction: a client that mutated its own geometry
//! behind our back is repaired on the very next pass. No diff cache, no sweep
//! counter, no staging buffer.
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
    env: tiling.Env = .{},
    /// Focus/mode border color; ported from borders.color minus its
    /// fullscreen check (fullscreen zeroes via bw/pixel policy instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
};

pub const ReconcileOpts = struct { force_restack: bool = false };

// DESIGN NOTE: The sent ledger uses inline parallel arrays instead of
// model.Store because (1) it needs no iteration-order guarantees (unlike the
// model, whose sorted-key order reconcile walks), and (2) the API surface
// needed is minimal (get, put, remove, clear).
//
// The ledger's hottest operation is reconcile's one get-or-create per window
// (every pass). A bare linear scan over the compact array is O(N) per window
// = O(N^2) per pass, the dominant hot path. So sent_keys/sent_vals are backed
// by a parallel open-addressing hash index (sent_index) mapping window-id ->
// slot, giving amortized O(1) get/get-or-create. The compact arrays remain
// the source of truth for iteration and swap-remove; sent_index is kept
// consistent on every insert and every swap-remove (see sentSwapRemove).

/// What we last sent per window; WRITE-ONLY bookkeeping whose three contract
/// reads are documented in the header:
///   - has_rect: whether a visible geometry was EVER sent (an explicit flag,
///     not a sentinel rect: a legitimately placed zero-size window at the
///     origin would collide with a "never sent" marker value);
///   - rect: the last VISIBLE geometry sent (survives parks);
///   - parked: whether the latest pass parked it.
const SentEntry = struct {
    rect: utils.Rect = tiling.parked_rect,
    has_rect: bool = false,
    parked: bool = false,
};

const empty_mark: usize = std.math.maxInt(usize);
const tomb_mark: usize = empty_mark - 1;

pub const State = struct {
    /// Ledger of sent state (see SentEntry).
    sent_keys: [model.store_capacity]model.WindowId = undefined,
    sent_vals: [model.store_capacity]SentEntry = undefined,
    sent_count: usize = 0,
    /// O(1) lookup index over the compact ledger: open-addressed hash (linear
    /// probing) from window-id -> slot into sent_keys/sent_vals. A bucket is
    /// EMPTY_MARK when free, TOMB_MARK after a removal (re-usable on insert),
    /// otherwise the slot holding that window. Kept consistent with the
    /// compact arrays on every insert and swap-remove.
    sent_index: [model.store_capacity]usize = [_]usize{empty_mark} ** model.store_capacity,
};

/// Owned by the compositor process; re-init() on reconnect.
pub var st: State = .{};

pub fn init() void {
    st = .{};
}

pub fn deinit() void {
    st = .{};
}

fn bucketOf(win: model.WindowId) usize {
    return @intCast(win % model.store_capacity);
}

/// Slot holding `win` in the compact arrays, or null when absent.
fn sentFind(win: model.WindowId) ?usize {
    const cap = model.store_capacity;
    var h = bucketOf(win);
    for (0..cap) |_| {
        const v = st.sent_index[h];
        if (v == empty_mark) return null;
        if (v != tomb_mark and st.sent_keys[v] == win) return v;
        h = (h + 1) % cap;
    }
    return null;
}

/// Record that `slot` now holds `win`. Call only when `win` has no entry.
fn sentIndexInsert(win: model.WindowId, slot: usize) void {
    const cap = model.store_capacity;
    var h = bucketOf(win);
    for (0..cap) |_| {
        const v = st.sent_index[h];
        if (v == empty_mark or v == tomb_mark) {
            st.sent_index[h] = slot;
            return;
        }
        h = (h + 1) % cap;
    }
    unreachable; // sentIndexInsert only runs below capacity; a bucket is free.
}

/// Tombstone the index bucket mapping `win` to `slot`.
fn sentIndexRemove(win: model.WindowId, slot: usize) void {
    const cap = model.store_capacity;
    var h = bucketOf(win);
    for (0..cap) |_| {
        const v = st.sent_index[h];
        // Skip tombstones: a tombstone between `win`'s home and its entry is
        // legitimate (a removal of an interleaved window whose bucket falls
        // earlier in the probe chain). Stopping on one here would miss `win`'s
        // bucket entirely and leave a stale slot pointer that shadows the
        // swap-remove that follows. An EMPTY bucket is the true chain end.
        if (v == empty_mark) return;
        if (v == slot and st.sent_keys[slot] == win) {
            st.sent_index[h] = tomb_mark;
            return;
        }
        h = (h + 1) % cap;
    }
}

/// After a swap-remove relocated `win` from `old_slot` to `new_slot`, re-point
/// its index bucket so lookups still land on the (now moved) compact entry.
fn sentIndexMove(win: model.WindowId, old_slot: usize, new_slot: usize) void {
    const cap = model.store_capacity;
    var h = bucketOf(win);
    for (0..cap) |_| {
        const v = st.sent_index[h];
        // Skip tombstones for the same reason as sentIndexRemove: two windows
        // can share a home bucket (they differ only mod capacity > cap), and
        // a removal between them leaves a tombstone that the probe for the
        // other one must step over. Only an empty bucket is a stop.
        if (v == empty_mark) break;
        if (v == old_slot and st.sent_keys[old_slot] == win) {
            st.sent_index[h] = new_slot;
            return;
        }
        h = (h + 1) % cap;
    }
    unreachable; // reached only when sentIndexMove runs for a window absent from the index
}

pub fn sentGet(win: model.WindowId) ?SentEntry {
    const slot = sentFind(win) orelse return null;
    return st.sent_vals[slot];
}

pub fn sentGetOrPut(win: model.WindowId) !struct {
    found_existing: bool,
    value_ptr: *SentEntry,
} {
    if (sentFind(win)) |slot| {
        return .{ .found_existing = true, .value_ptr = &st.sent_vals[slot] };
    }
    if (st.sent_count >= model.store_capacity) return error.SentLedgerFull;
    const idx = st.sent_count;
    st.sent_count += 1;
    st.sent_keys[idx] = win;
    st.sent_vals[idx] = .{};
    sentIndexInsert(win, idx);
    return .{ .found_existing = false, .value_ptr = &st.sent_vals[idx] };
}

pub fn sentSwapRemove(win: model.WindowId) void {
    const slot = sentFind(win) orelse return;
    const last = st.sent_count - 1;
    sentIndexRemove(win, slot);
    if (slot != last) {
        const moved = st.sent_keys[last];
        st.sent_keys[slot] = moved;
        st.sent_vals[slot] = st.sent_vals[last];
        sentIndexMove(moved, last, slot);
    }
    st.sent_count = last;
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from actions.unmanage.
pub fn forget(win: model.WindowId) void {
    sentSwapRemove(win);
}

pub fn reconcileUnderGrab(m: *const model.Model, ctx: *Ctx, opts: ReconcileOpts) void {
    // grab_server -> reconcile(opts) -> optional top/bar restack ->
    // ungrabAndFlush. Zero round trips inside.
    ctx.sink.grabServer();
    defer ctx.sink.ungrabAndFlush();
    reconcile(m, ctx, opts);
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
            ctx.sink.park(win);
        } else {
            // Raise triggers derive from the ledger (header read 2): the
            // winner rides .above exactly when its geometry moved, when it
            // unparked, or under restack pressure, never on mere presence.
            const last = ledger;
            const first_send = !last.has_rect;
            const moved = first_send or !last.rect.eql(rect);
            const unpark_transition = last.parked;
            const raise_winner = is_winner and (moved or unpark_transition or opts.force_restack);

            ctx.sink.map(win);
            ctx.sink.borderPixel(win, pixel);
            ctx.sink.borderWidth(win, bw);
            ctx.sink.geom(win, rect, if (raise_winner) .above else null);
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
        if (!g.found_existing) g.value_ptr.* = .{};
        if (parked) {
            g.value_ptr.parked = true;
        } else {
            g.value_ptr.* = .{ .rect = rect, .has_rect = true, .parked = false };
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
/// batch atomicity); drag ticks afterward stay flushless (reconcileNow).
pub fn raiseNow(ctx: *Ctx, win: model.WindowId) void {
    ctx.sink.stackOnly(win, .above);
    ctx.sink.flush();
}

/// Set or clear the EWMH _NET_WM_STATE_FULLSCREEN property on `win` via the
/// sink. Queued only (no flush here): fullscreenToggle callers invoke this
/// inside the enclosing grab, whose ungrabAndFlush lands it atomically with
/// geometry. The EWMH atoms are resolved by the fullscreen module and passed
/// through; the fullscreen module's XCB_ATOM_NONE guard already ran.
pub fn setEwmhFullscreen(ctx: *Ctx, win: model.WindowId, state_atom: u32, fs_atom: u32, is_fullscreen: bool) void {
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
        bw = 0;
        pixel = 0;
        parked = true;
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
        bw = 0;
        pixel = 0;
        parked = true;
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
                    bw = 0;
                    pixel = 0;
                    parked = true;
                } else {
                    rect = ledger.rect;
                }
            } else {
                bw = 0;
                pixel = 0;
                parked = true;
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
