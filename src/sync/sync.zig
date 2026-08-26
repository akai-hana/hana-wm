//! ONLY this module (via its wire sink) sends geometry/border/map/stack
//! requests. Pure orchestration lives here; every raw XCB request lives in
//! the sink file (src/sync/wire.zig) — the sanctioned boundary; raw
//! libxcb symbols may appear only inside its send shims.
//!
//! Shims wrap EXISTING xcb patterns — do not invent new ones:
//!   Sink.geom        ≙ utils.configureWindow (+ merged stack-mode variant)
//!   Sink.border_*    ≙ borders.applyWidth + borders.apply + setBorderPixel
//!   Sink.park        ≙ X-offscreen + BELOW configure_window in ONE request
//!   Sink.stack_only  ≙ utils.raiseWindow / restack helpers used today
//!   Sink.flush       ≙ conn.flush()  (caller owns timing)
//!
//! Scroll viewport caller duties: snap-right-on-new, clamp, prev_count
//! update happen in ACTIONS before they call reconcile; this module never
//! mutates model params (m is const).
//!
//! RECONCILE ALGORITHM — UNCONDITIONAL APPLY. Every pass computes the desired
//! state for every stored window and SENDS it: parked windows get ONE merged
//! park request; visible windows replay map -> pixel -> bw -> geometry in
//! order, with any stacking mode merged into the geometry request itself.
//! X configure/map requests are idempotent, so replaying full desired state
//! is drift-proof by construction — a client that mutated its own geometry
//! behind our back is repaired on the very next pass. No diff cache, no sweep
//! counter, no staging buffer.
//!
//! The SENT LEDGER is a WRITE-ONLY record of what was actually sent
//! ({rect, has_rect, parked} per window; a park flips `parked` and preserves
//! rect/has_rect). Exactly three reads of it are behavioral contract:
//!   1. Multi-tag orphans: legacy keeps them at their previous real geometry
//!      rather than parking. A history-less orphan parks (first sight /
//!      registered offscreen).
//!   2. Winner-raise derivation: rides .above ONLY when geometry moved,
//!      when it unparked, or under force_restack — derived by comparing the
//!      new rect against the ledger and reading its parked flag.
//!   3. Floating-detach / title prefetch (actions.lastRectFor,
//!      sync.truthRect): the live rect as the new floating base, null while
//!      parked.

const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");
const build_options = @import("build_options");
const model = @import("model");

/// When tiling is absent, provide stub types/constants so the rest of sync
/// compiles.  The reconcile path still runs (park/map/stack), but the layout
/// computation block is skipped and findPlacement always returns null.
const engine = if (build_options.has_tiling) @import("engine") else struct {
    pub const Env = struct {
        margins: utils.Margins = .{ .gap = 0, .border = 0 },
        min_dim: u16 = 0,
        master_on_right: bool = false,
        grid_relaxed: bool = false,
        monocle_gaps: bool = false,
    };
    pub const parked_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    pub const Placement = struct {
        win: model.WindowId = 0,
        rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        visible: bool = false,
    };
    pub const List = utils.BoundedList(Placement, model.store_capacity);
    pub const HintsView = struct {
        order: []const model.WindowId = &.{},
        hints: []const model.SizeHints = &.{},
    };
    pub const View = struct {
        order: []const model.WindowId = &.{},
        params: *const model.LayoutParams = undefined,
        workarea: utils.Rect = .{},
        hints: *const HintsView = undefined,
        focused: ?model.WindowId = null,
        env: Env = .{},
    };
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
    /// Screen minus bar — workArea(ctx); computed by the caller with the
    /// existing bar-offset helper.
    workarea: utils.Rect,
    /// cfgBW(): config.tiling.border_width, already scaled at load.
    cfg_bw: u16,
    env: engine.Env = .{},
    /// colorFn(win, m): focus/mode color — ported from borders.color minus
    /// its fullscreen check (fullscreen zeroes via bw/pixel policy instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack; null when no bar.
    bar_win: ?model.WindowId = null,
};

pub const ReconcileOpts = struct { force_restack: bool = false };

// DESIGN NOTE: The sent ledger uses inline parallel arrays instead of
// model.Store because (1) it needs no iteration-order guarantees,
// (2) the heap allocation of Store's backing memory is undesirable in
// the hot reconcile path, and (3) the API surface needed is minimal
// (get, put, remove, clear).

/// What we last sent per window — WRITE-ONLY bookkeeping whose three
/// contract reads are documented in the header:
///   - has_rect: whether a visible geometry was EVER sent (an explicit flag,
///     not a sentinel rect: a legitimately placed zero-size window at the
///     origin would collide with a "never sent" marker value);
///   - rect: the last VISIBLE geometry sent (survives parks);
///   - parked: whether the latest pass parked it.
const SentEntry = struct {
    rect: utils.Rect = engine.parked_rect,
    has_rect: bool = false,
    parked: bool = false,
};

pub const State = struct {
    /// Ledger of sent state (see SentEntry).
    sent_keys: [model.store_capacity]model.WindowId = undefined,
    sent_vals: [model.store_capacity]SentEntry = undefined,
    sent_count: usize = 0,
};

/// Owned by the compositor process; re-init() on reconnect.
pub var st: State = .{};

pub fn init() void {
    st = .{};
}

pub fn deinit() void {
    st = .{};
}

pub fn sentGet(win: model.WindowId) ?SentEntry {
    for (0..st.sent_count) |i| {
        if (st.sent_keys[i] == win) return st.sent_vals[i];
    }
    return null;
}

pub fn sentGetOrPut(win: model.WindowId) !struct {
    found_existing: bool,
    value_ptr: *SentEntry,
} {
    for (0..st.sent_count) |i| {
        if (st.sent_keys[i] == win) return .{ .found_existing = true, .value_ptr = &st.sent_vals[i] };
    }
    if (st.sent_count >= model.store_capacity) return error.SentLedgerFull;
    const idx = st.sent_count;
    st.sent_count += 1;
    st.sent_keys[idx] = win;
    st.sent_vals[idx] = .{};
    return .{ .found_existing = false, .value_ptr = &st.sent_vals[idx] };
}

pub fn sentSwapRemove(win: model.WindowId) void {
    for (0..st.sent_count) |i| {
        if (st.sent_keys[i] == win) {
            st.sent_count -= 1;
            st.sent_keys[i] = st.sent_keys[st.sent_count];
            st.sent_vals[i] = st.sent_vals[st.sent_count];
            return;
        }
    }
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

    // STEP 2: fullscreen winner scan.
    var fs_win: ?model.WindowId = null;
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.mode != .fullscreen) continue;
        const f = it.val.mode.fullscreen;
        if (model.visibleOn(m, it.key, m.current) or f.ws == m.current) {
            fs_win = it.key;
            break;
        }
    }

    // STEP 3 (else branch): run layout.compute over the shown workspace.
    var order_buf: [model.store_capacity]model.WindowId = undefined;
    var hints_buf: [model.store_capacity]model.SizeHints = undefined;
    var placements: engine.List = .{};
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
        const hv = engine.HintsView{ .order = order_buf[0..n], .hints = hints_buf[0..n] };
        const params = &m.ws[m.current].params;
        const view = engine.View{
            .order = order_buf[0..n],
            .params = params,
            .workarea = wa,
            .hints = &hv,
            .focused = m.focused,
            .env = ctx.env,
        };
        // n == 0 leaves placements empty (no layout owns a window); layouts
        // are also individually n==0-safe, this just skips the work.
        if (n > 0) {
            engine.compute(params.kind, view, &placements);
            // Sort by window ID once after compute for O(log n) binary search.
            std.sort.pdq(engine.Placement, placements.slice(), {}, struct {
                fn lessThan(_: void, a: engine.Placement, b: engine.Placement) bool {
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
                if (fe.mode == .base and model.visibleOn(m, f, m.current)) {
                    switch (fe.mode.base) {
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
    // then SEND it immediately — unconditionally. Send order per window:
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

        // -- desire, computed inline ------------------------------------------
        var rect: utils.Rect = engine.parked_rect;
        var bw: u16 = ctx.cfg_bw;
        var pixel: u32 = ctx.color_of(win, m);
        var parked = false;

        if (fs_win != null) {
            if (win == fs_win.?) {
                rect = ctx.screen;
                bw = 0;
                pixel = 0;
            } else {
                // Parked: rect irrelevant.
                parked = true;
            }
        } else switch (e.mode) {
            .minimized => {
                bw = 0;
                pixel = 0;
                parked = true;
            },
            .fullscreen => {
                bw = 0;
                pixel = 0;
                parked = true;
            },
            .base => |b| switch (b) {
                .floating => |r| {
                    rect = r;
                    parked = !model.visibleOn(m, win, m.current);
                },
                .tiled => {
                    if (findPlacement(&placements, win)) |p| {
                        rect = p.rect;
                        parked = !p.visible;
                    } else if (model.visibleOn(m, win, m.current)) {
                        // Multi-tagged window whose home list isn't the shown
                        // ws: legacy never hides it and no layout owns it here,
                        // so it stays at its previous real geometry — which is
                        // precisely the ledger's record of what we last sent.
                        // Park only when nothing was ever sent (first sight /
                        // registered offscreen).
                        const prev = sentGet(win) orelse SentEntry{};
                        if (!prev.has_rect) {
                            bw = 0;
                            pixel = 0;
                            parked = true;
                        } else {
                            rect = prev.rect;
                        }
                    } else {
                        bw = 0;
                        pixel = 0;
                        parked = true;
                    }
                },
            },
        }
        // Off-ws windows are parked by construction above (no placement /
        // visibleOn false), which is exactly "mask lacks bit(shown)".

        // Fallback winner: first non-parked desire in store order.
        if (winner == null and !parked) winner = win;
        const is_winner = winner != null and winner.? == win;

        if (parked) {
            // ONE merged request (X-offscreen + BELOW). Idempotent by nature,
            // so replaying every pass is safe. The ledger's rect deliberately
            // SURVIVES the park so a later all-view orphan resurfaces at its
            // old slot.
            ctx.sink.park(win);
        } else {
            // Raise triggers derive from the ledger (header read 2): the
            // winner rides .above exactly when its geometry moved, when it
            // unparked, or under restack pressure — never on mere presence.
            const last = sentGet(win) orelse SentEntry{};
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
        // Written AFTER the sends: under SentLedgerFull the pass still applied (sends
        // never depend on the ledger) and only the record is lost until the
        // next successful write — no half-applied batch can exist.
        const gop = sentGetOrPut(win) catch {
            std.log.err("sync.reconcile: ledger full; sends applied, record lost", .{});
            continue;
        };
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (parked) {
            gop.value_ptr.parked = true;
        } else {
            gop.value_ptr.* = .{ .rect = rect, .has_rect = true, .parked = false };
        }
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
    if (e.parked) return null;
    if (!e.has_rect) return null;
    return e.rect;
}

/// Best known live geometry for `win` without a server round trip:
///   1. floating base rect from the model (authoritative while floating),
///   2. else the last visible geometry we sent (null while parked/unsent).
pub fn truthRect(m: *const model.Model, win: model.WindowId) ?utils.Rect {
    const e = m.store.get(win) orelse return null;
    if (e.mode == .base and e.mode.base == .floating) return e.mode.base.floating;
    return lastRectFor(win);
}

fn findPlacement(placements: *const engine.List, win: model.WindowId) ?engine.Placement {
    const slice = placements.constSlice();
    const idx = std.sort.binarySearch(engine.Placement, slice, win, struct {
        fn cmp(w: model.WindowId, p: engine.Placement) std.math.Order {
            return std.math.order(w, p.win);
        }
    }.cmp) orelse return null;
    return slice[idx];
}
