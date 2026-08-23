//! INVARIANT(P3): ONLY this module (via its wire sink) sends geometry/border/
//! map/stack requests. Pure orchestration lives here; every raw XCB request
//! lives in the sink file (src/sync/wire.zig) — the sanctioned boundary; raw
//! libxcb symbols may appear only inside its send shims (WP3 acceptance gate).
//!
//! Shims wrap EXISTING xcb patterns — do not invent new ones:
//!   Sink.geom        ≙ window.zig configureWindowGeom / layouts.configureWithHintsImpl
//!   Sink.border_*    ≙ borders.applyWidth + borders.apply + setBorderPixel
//!   Sink.park        ≙ pushWindowOffscreenAndLower (X-offscreen + BELOW in ONE request)
//!   Sink.stack_only  ≙ utils.raiseWindow / restack helpers used today
//!   Sink.flush       ≙ conn.flush()  (caller owns timing, I2)
//!
//! Scroll viewport caller duties (changelog 2026-08-22): snap-right-on-new,
//! clamp, prev_count update happen in ACTIONS before they call reconcile;
//! this module never mutates model params (m is const).
//!
//! RECONCILE ALGORITHM — compute the desired state for every stored window,
//! then APPLY IT CONDITIONALLY against the SENT LEDGER. The ledger records
//! what we last sent per window (visible rect, border width/pixel, parked
//! flag) as a side-effect of sending; a desire IDENTICAL to the ledger is
//! skipped so the common event costs O(changed), not O(store).
//!
//! Skip correctness rests on three invalidation paths:
//!   1. RESET (reconnect): the ledger is cleared, so every window looks
//!      unsent and the next reconcile remaps/reconfigures everything.
//!   2. FORCE_RESTACK / PERIODIC SWEEP: force_restack callers (ws switches,
//!      tiling ops that reorder stacking, bar show/hide) bypass the diff;
//!      additionally every FULL_SWEEP_INTERVAL reconciles run an unconditional
//!      sweep as drift insurance (a client that mutated its own geometry
//!      behind our back is repaired then).
//!   3. TRANSITIONS: park/unpark flips and any rect/bw/pixel difference are
//!      exactly what the ledger detects.
//!
//! Three derived-trigger readers remain:
//!   1. Multi-tag orphans (tiled mode, mask shows them here, but no layout
//!      owns them because their home tiled list lives elsewhere): legacy
//!      keeps them at their previous real geometry rather than parking.
//!      "Previous real geometry" is by definition what we last sent; park
//!      transitions preserve it (parked=true flips, rect survives), so an
//!      all-view orphan with history resurfaces at its old slot.
//!   2. Winner-raise derivation: today's stacking policy raises the winner
//!      only when its geometry moved, when it unparked, or under
//!      force_restack. Reproduced by comparing want.rect against the ledger
//!      and reading the parked flag — reads that derive triggers, never
//!      omit sends.
//!   3. Floating-detach (actions.lastRectFor): the live rect as the new
//!      floating base, null while parked — same contract as before.

const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");
const build_options = @import("build_options");
const model = @import("model");
const engine = @import("engine");

pub const Stack = enum { above, below };

/// Request sink. Production wires XcbSink; tests wire a recorder. One batch
/// = everything queued between caller flushes (xcb buffers requests; I2 says
/// the CALLER decides when to flush).
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

/// Caller-resolved environment (config-derived); resolved once per retile by
/// the pipeline exactly as invokeLayout did (§7.4 step 3 keeps variant
/// resolution caller-side). Single definition lives in engine (F7).
pub const Env = engine.Env;

pub const Ctx = struct {
    sink: Sink,
    /// Full screen rect (fullscreen branch geometry).
    screen: utils.Rect,
    /// Screen minus bar — workArea(ctx) of §7.4 step 1; computed by the
    /// caller with the existing bar-offset helper.
    workarea: utils.Rect,
    /// cfgBW(): config.tiling.border_width, already scaled at load.
    cfg_bw: u16,
    env: Env = .{},
    /// colorFn(win, m): focus/mode color — ported from borders.color minus
    /// its fullscreen check (fullscreen zeroes via bw/pixel policy instead).
    color_of: *const fn (model.WindowId, *const model.Model) u32,
    /// Bar/top window raised by force_restack (I4 hook); null when no bar.
    bar_win: ?model.WindowId = null,
};

pub const ReconcileOpts = struct { force_restack: bool = false };

/// Sentinel meaning "no visible geometry ever sent to this window".
const never_sent: utils.Rect = engine.parked_rect;

/// What we last sent per window — the skip cache AND the trigger source
/// (see header):
///   - rect: the last VISIBLE geometry sent (survives parks — an all-view
///     orphan with history resurfaces at its old slot, per legacy);
///   - parked: whether the latest pass parked it (an unparking winner
///     re-raises; lastRectFor reports null while parked, per legacy);
///   - bw/pixel: the last appearance sent (skips redundant border traffic).
const SentEntry = struct {
    rect: utils.Rect = engine.parked_rect,
    parked: bool = false,
    bw: u16 = 0,
    pixel: u32 = 0,
};

/// Reconciles between unconditional full sweeps (drift insurance: repairs a
/// client that mutated its own geometry behind our back).
pub const full_sweep_interval: u64 = 256;

pub const State = struct {
    /// Ledger of sent state (see SentEntry); also the diff baseline.
    sent: std.AutoArrayHashMapUnmanaged(model.WindowId, SentEntry) = .empty,
    gpa: std.mem.Allocator = undefined,
    /// Reconciles since the last unconditional sweep.
    since_full_sweep: u64 = 0,
    bench_cfg: usize = 0,
    bench_border: usize = 0,
    bench_park: usize = 0,
};

/// Owned by the compositor process; reset() on reconnect.
pub var st: State = .{};

pub fn init(gpa: std.mem.Allocator) void {
    st = .{ .gpa = gpa };
}

pub fn deinit() void {
    st.sent.deinit(st.gpa);
    st = .{};
}

/// Reset on reconnect WITHOUT releasing the map's backing memory. Correct by
/// construction: a cleared ledger makes every window look unsent, so the next
/// reconcile remaps and reconfigures everything — exactly what an unknown
/// server state needs.
pub fn reset() void {
    st.sent.clearRetainingCapacity();
}

/// Drop a window's ledger record (X ids recycle: after a destroy, a new
/// client can appear with the same id, and a stale record would feed the
/// orphan keep-last branch geometry belonging to the previous incarnation).
/// Called from actions.unmanage.
pub fn forget(win: model.WindowId) void {
    _ = st.sent.swapRemove(win);
}

/// Coalesced end-of-dispatch reconcile flag (§7.6 scheduling table:
/// focus-change class). Consumed by pipeline.postDispatch in WP5.
pub var scheduled: bool = false;

pub fn schedule(_ctx: *Ctx) void {
    _ = _ctx;
    scheduled = true;
}

/// Consume-and-clear for pipeline.postDispatch (fix P1-4).
pub fn takeScheduled() bool {
    const s = scheduled;
    scheduled = false;
    return s;
}

/// Internal per-entry desire, mirroring §7.4 step 4.
const Desired = struct {
    rect: utils.Rect,
    bw: u16,
    pixel: u32,
    parked: bool,
};

pub fn reconcileUnderGrab(m: *const model.Model, ctx: *Ctx, opts: ReconcileOpts) void {
    // I4: grab_server -> reconcile(opts) -> optional top/bar restack ->
    // ungrabAndFlush. Zero round trips inside (BC24).
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
    if (fs_win == null) {
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
        engine.compute(params.kind, view, &placements);
    }

    // STEP 4: desired map over ALL store entries (store seq order).
    var desired_buf: [model.store_capacity]Desired = undefined;
    const count = m.store.count();
    // Winner (STEP 5): fullscreen winner, else focused when visibly placed,
    // else first visible in iteration order.
    var winner: ?model.WindowId = if (fs_win) |w| w else blk: {
        if (m.focused) |f| {
            if (!desiredIsParkedAt(f, m, &placements, fs_win)) break :blk f;
        }
        break :blk null;
    };

    for (0..count) |i| {
        const it = m.store.at(i);
        const win = it.key;
        const e: *const model.Entry = it.val;

        if (fs_win != null) {
            if (win == fs_win.?) {
                desired_buf[i] = .{ .rect = ctx.screen, .bw = 0, .pixel = 0, .parked = false };
                if (winner == null) winner = win;
            } else {
                // Parked: rect irrelevant (§7.4 step 4).
                desired_buf[i] = .{ .rect = engine.parked_rect, .bw = ctx.cfg_bw, .pixel = ctx.color_of(win, m), .parked = true };
            }
            continue;
        }

        switch (e.mode) {
            .minimized => desired_buf[i] = .{ .rect = engine.parked_rect, .bw = 0, .pixel = 0, .parked = true },
            .fullscreen => desired_buf[i] = .{ .rect = engine.parked_rect, .bw = 0, .pixel = 0, .parked = true },
            .base => |b| switch (b) {
                .floating => |r| {
                    if (model.visibleOn(m, win, m.current)) {
                        desired_buf[i] = .{ .rect = r, .bw = ctx.cfg_bw, .pixel = ctx.color_of(win, m), .parked = false };
                    } else {
                        desired_buf[i] = .{ .rect = r, .bw = ctx.cfg_bw, .pixel = ctx.color_of(win, m), .parked = true };
                    }
                },
                .tiled => {
                    if (findPlacement(&placements, win)) |p| {
                        desired_buf[i] = .{ .rect = p.rect, .bw = ctx.cfg_bw, .pixel = ctx.color_of(win, m), .parked = !p.visible };
                    } else if (model.visibleOn(m, win, m.current)) {
                        // Multi-tagged window whose home list isn't the shown
                        // ws: legacy never hides it and no layout owns it here,
                        // so it stays at its previous real geometry — which is
                        // precisely the ledger's record of what we last sent.
                        // Park only when nothing was ever sent (first sight /
                        // registered offscreen).
                        const prev = st.sent.get(win) orelse SentEntry{};
                        if (prev.rect.eql(never_sent)) {
                            desired_buf[i] = .{ .rect = engine.parked_rect, .bw = 0, .pixel = 0, .parked = true };
                        } else {
                            desired_buf[i] = .{ .rect = prev.rect, .bw = ctx.cfg_bw, .pixel = ctx.color_of(win, m), .parked = false };
                        }
                    } else {
                        desired_buf[i] = .{ .rect = engine.parked_rect, .bw = 0, .pixel = 0, .parked = true };
                    }
                },
            },
        }
        // Off-ws windows are parked by construction above (no placement /
        // visibleOn false), which is exactly "mask lacks bit(shown)".
    }

    // Fallback winner: first non-parked desire in store order.
    if (winner == null and fs_win == null) {
        for (0..count) |i| {
            if (!desired_buf[i].parked) {
                winner = m.store.at(i).key;
                break;
            }
        }
    }

    // STEPS 5..8: apply conditionally against the ledger, ordered
    // map -> pixel -> bw -> geometry(stack merged); parked windows merge
    // X-offscreen + BELOW into ONE configure_window (Sink.park). Unchanged
    // desires are skipped; force_restack and the periodic sweep bypass the
    // diff entirely. The winner rides .above exactly when its geometry moved,
    // when it unparked, or under restack pressure — triggers derived from
    // the ledger, never remembered separately.

    // Reserve ledger capacity UP FRONT so the apply loop below cannot
    // allocate mid-batch: a `catch return` inside the loop would abandon a
    // half-applied batch (earlier windows queued and ledgered, later ones
    // untouched) with zero diagnostics. One reservation before ANY send
    // makes the loop infallible; failure bails before the first request.
    st.sent.ensureTotalCapacity(st.gpa, st.sent.count() + count) catch {
        std.log.err("sync.reconcile: ledger allocation failed; batch skipped", .{});
        return;
    };

    const full_sweep = opts.force_restack or blk: {
        st.since_full_sweep += 1;
        if (st.since_full_sweep >= full_sweep_interval) {
            st.since_full_sweep = 0;
            break :blk true;
        }
        break :blk false;
    };

    for (0..count) |i| {
        const it = m.store.at(i);
        const win = it.key;
        const want = desired_buf[i];
        const is_winner = winner != null and winner.? == win;

        // Ledger read: skip baseline AND trigger source.
        const gop = st.sent.getOrPutAssumeCapacity(win);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const last = gop.value_ptr.*;

        if (want.parked) {
            // Park is idempotent (X-offscreen + BELOW in one request): send
            // only on a parked->parked transition or a full sweep. The rect
            // deliberately SURVIVES the park in the ledger so a later
            // all-view orphan resurfaces at its old slot.
            if (full_sweep or !last.parked) {
                ctx.sink.park(win);
                if (build_options.bench) {
                    st.bench_cfg += 1;
                    st.bench_park += 1;
                }
            }
            gop.value_ptr.parked = true;
            continue;
        }

        const unpark_transition = last.parked;
        const first_send = last.rect.eql(never_sent);
        const moved = !last.rect.eql(want.rect); // first send: sentinel differs
        const pixel_changed = last.pixel != want.pixel;
        const bw_changed = last.bw != want.bw;
        const raise_winner = is_winner and (moved or unpark_transition or opts.force_restack);

        // Map BEFORE geometry so a first-show/unparking client exposes at its
        // final rect. Steady-state passes skip map+border traffic entirely;
        // pixel and width are skipped independently of each other.
        const need_map = full_sweep or unpark_transition or first_send;
        if (need_map) ctx.sink.map(win);
        if (need_map or pixel_changed) {
            ctx.sink.borderPixel(win, want.pixel);
            if (build_options.bench) st.bench_border += 1;
        }
        if (need_map or bw_changed) {
            ctx.sink.borderWidth(win, want.bw);
            if (build_options.bench) st.bench_border += 1;
        }

        // Geometry goes out when something moved, when an unpark must bring
        // the window back on-screen at its surviving rect, when the winner
        // needs its raise merged, or under a full sweep.
        if (full_sweep or moved or unpark_transition or raise_winner) {
            ctx.sink.geom(win, want.rect, if (raise_winner) .above else null);
            if (build_options.bench) st.bench_cfg += 1;
        }

        // Ledger write: record what we sent.
        gop.value_ptr.* = .{ .rect = want.rect, .parked = false, .bw = want.bw, .pixel = want.pixel };
    }

    // STEP 5 (I4 hook): force_restack additionally raises bar/top.
    if (opts.force_restack) {
        if (ctx.bar_win) |bar| ctx.sink.stackOnly(bar, .above);
    }

    // STEP 9: DO NOT FLUSH HERE. Caller owns flushing (I2).
}

/// PIPELINE (train f): last visible geometry we sent to `win`, or null when
/// never sent / currently parked. Floating-detach and toggle-float need the
/// live rect as the new floating base.
pub fn lastRectFor(win: model.WindowId) ?utils.Rect {
    const e = st.sent.get(win) orelse return null;
    if (e.parked) return null;
    if (e.rect.eql(never_sent)) return null;
    return e.rect;
}

/// Best known live geometry for `win` without a server round trip (A5: the
/// single geometry source for drag-start / ConfigureRequest echo / title
/// prefetch — replaces the deleted wincache rect store):
///   1. floating base rect from the model (authoritative while floating),
///   2. else the last visible geometry we sent (null while parked/unsent).
pub fn truthRect(m: *const model.Model, win: model.WindowId) ?utils.Rect {
    const e = m.store.get(win) orelse return null;
    if (e.mode == .base and e.mode.base == .floating) return e.mode.base.floating;
    return lastRectFor(win);
}

fn findPlacement(placements: *const engine.List, win: model.WindowId) ?engine.Placement {
    for (placements.constSlice()) |p| {
        if (p.win == win) return p;
    }
    return null;
}

/// Winner pre-check for the focused window: does it have a non-parked
/// desire under current model/placements? Cheap re-evaluation without
/// materializing the whole desired array first.
fn desiredIsParkedAt(
    win: model.WindowId,
    m: *const model.Model,
    placements: *const engine.List,
    fs_win: ?model.WindowId,
) bool {
    if (fs_win != null and win != fs_win.?) return true;
    const e = m.store.get(win) orelse return true;
    if (e.mode != .base) return true;
    if (!model.visibleOn(m, win, m.current)) return true;
    switch (e.mode.base) {
        .floating => return false,
        .tiled => {
            const p = findPlacement(placements, win) orelse return true;
            return !p.visible;
        },
    }
}
