//! INVARIANT(P3): ONLY this module (plus its sinks) sends geometry/border/
//! map/stack requests. Pure orchestration lives here; every raw XCB request
//! lives in the sink file (src/sync/xcb sink, see xcb sink source) — the
//! sanctioned boundary; raw libxcb symbols may appear only inside its send
//! shims (WP3 acceptance gate).
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
//! RECONCILE ALGORITHM — §7.4 steps are normative; see step comments below.

const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");
const build_options = @import("build_options");
const model = @import("model");
const engine = @import("engine");

pub const Stack = enum { above, below };

pub const LastSent = struct {
    rect: utils.Rect,
    bw: u16,
    pixel: u32,
    parked: bool,
    /// False until we have sent map_window at least once. Windows registered
    /// while their workspace was hidden were never mapped server-side
    /// (registerWindowOffscreen consumed their MapRequest); the first visible
    /// reconcile must map them or they stay invisible. Defaults false so the
    /// first sight of ANY window maps it (harmless server-side no-op when
    /// already mapped; correctness over request budget).
    mapped: bool = false,

    const parked_entry: LastSent = .{ .rect = engine.parked_rect, .bw = 0, .pixel = 0, .parked = true };
};

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
/// resolution caller-side).
pub const Env = struct {
    margins: utils.Margins = .{ .gap = 0, .border = 0 },
    min_dim: u16 = 0,
    master_on_right: bool = false,
    grid_relaxed: bool = false,
    monocle_gaps: bool = false,
};

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

pub const State = struct {
    last_sent: std.AutoArrayHashMapUnmanaged(model.WindowId, LastSent) = .empty,
    gpa: std.mem.Allocator = undefined,
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
    st.last_sent.deinit(st.gpa);
    st = .{};
}

/// Reset on reconnect WITHOUT releasing the map's backing memory.
pub fn reset() void {
    st.last_sent.clearRetainingCapacity();
}

/// Drop a window's LastSent record (fix P0-4). X recycles window ids: after
/// a destroy, a new client can appear with the same id, and a stale
/// "mapped=true" record makes sync skip its map request — the window stays
/// invisible forever. Called from actions.unmanage.
pub fn forget(win: model.WindowId) void {
    _ = st.last_sent.swapRemove(win);
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
    const wa = workArea(ctx);

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
    var placements: engine.List = .{};
    if (fs_win == null) {
        var n: usize = 0;
        const tiled = &m.ws[m.current].tiled_order;
        for (tiled.items) |w| {
            const e = m.store.get(w) orelse continue;
            if (e.mask & model.bit(m.current) == 0) continue;
            order_buf[n] = w;
            n += 1;
        }
        const hv = engine.HintsView{ .m = m };
        const params = &m.ws[m.current].params;
        const view = engine.View{
            .order = order_buf[0..n],
            .params = params,
            .workarea = wa,
            .hints = &hv,
            .focused = m.focused,
            .margins = ctx.env.margins,
            .min_dim = ctx.env.min_dim,
            .master_on_right = ctx.env.master_on_right,
            .grid_relaxed = ctx.env.grid_relaxed,
            .monocle_gaps = ctx.env.monocle_gaps,
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
        // store.at's const flavor hands back *const V for val.
        const e: *const model.Entry = it.val;

        if (fs_win != null) {
            if (win == fs_win.?) {
                desired_buf[i] = .{ .rect = ctx.screen, .bw = 0, .pixel = 0, .parked = false };
                if (winner == null) winner = win;
            } else {
                // Parked: rect irrelevant, keep last (§7.4 step 4).
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
                        // so it stays at its previous geometry (keep-last via
                        // LastSent). Park only when we have never sent real
                        // geometry (first sight / registered offscreen).
                        const prev = st.last_sent.get(win) orelse LastSent.parked_entry;
                        if (prev.parked and prev.rect.eql(engine.parked_rect)) {
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

    // STEP 5..8: diff vs last_sent; queue ONLY deltas, ordered
    // pixel -> bw -> geometry(+stack merged); parked transitions merge
    // X-offscreen + BELOW into ONE configure_window (Sink.park).
    for (0..count) |i| {
        const it = m.store.at(i);
        const win = it.key;
        const want = desired_buf[i];
        const is_winner = winner != null and winner.? == win;

        const gop = st.last_sent.getOrPut(st.gpa, win) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = LastSent.parked_entry;
        }
        const last = gop.value_ptr.*;

        if (want.parked) {
            if (!last.parked) {
                ctx.sink.park(win);
                if (build_options.bench) {
                    st.bench_cfg += 1;
                    st.bench_park += 1;
                }
                gop.value_ptr.parked = true;
            }
            continue;
        }

        const unpark_transition = last.parked;

        // First show after a hidden registration: map BEFORE geometry so the
        // client exposes at its final rect and ConfigureNotify flows once.
        if (!last.mapped) {
            ctx.sink.map(win);
            gop.value_ptr.mapped = true;
        }

        if (unpark_transition or last.pixel != want.pixel) {
            ctx.sink.borderPixel(win, want.pixel);
            if (build_options.bench) st.bench_border += 1;
        }
        if (unpark_transition or last.bw != want.bw) {
            ctx.sink.borderWidth(win, want.bw);
            if (build_options.bench) st.bench_border += 1;
        }
        const geom_changed = unpark_transition or !last.rect.eql(want.rect);
        if (geom_changed) {
            ctx.sink.geom(win, want.rect, if (is_winner) .above else null);
            if (build_options.bench) st.bench_cfg += 1;
        } else if (is_winner and opts.force_restack) {
            ctx.sink.stackOnly(win, .above);
            if (build_options.bench) st.bench_cfg += 1;
        }

        gop.value_ptr.* = .{
            .rect = if (geom_changed or last.parked) want.rect else last.rect,
            .bw = want.bw,
            .pixel = want.pixel,
            .parked = false,
            .mapped = true, // visible desire ⇒ mapped (sent above if first show)
        };
    }

    // STEP 5 (I4 hook): force_restack additionally raises bar/top.
    if (opts.force_restack) {
        if (ctx.bar_win) |bar| ctx.sink.stackOnly(bar, .above);
    }

    // STEP 8: bench counters bumped at queue sites above.
    // STEP 9: DO NOT FLUSH HERE. Caller owns flushing (I2).
}

fn workArea(ctx: *const Ctx) utils.Rect {
    return ctx.workarea;
}

/// PIPELINE (train f): current on-screen geometry of `win` per LastSent, or
/// null when never sent / parked. Floating-detach and toggle-float need the
/// live rect as the new floating base.
pub fn lastRectFor(win: model.WindowId) ?utils.Rect {
    const ls = st.last_sent.get(win) orelse return null;
    if (ls.parked) return null;
    return ls.rect;
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
