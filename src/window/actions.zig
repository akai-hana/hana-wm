//! Thin action wrappers used by entry points (REARCHITECTURE_PLAN.md §7.2,
//! Appendix E.6). One action ≙ one §7.2 transition + one sync entry per the
//! §7.6 scheduling table. Train step a: minimize / restore / restoreAll.
//!
//! Division of labor while the strangler runs:
//!   model.*   — state transitions (tiled_order, modes, focus bookkeeping)
//!   sync.*    — geometry/border/stack/park requests (via pipeline slots)
//!   legacy    — X11 focus protocol + input-model resolve stay untouched
//!               until train f (R2); actions dispatch through window.focus.

const std = @import("std");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const sync = @import("sync");
const focus = @import("focus");
const build_options = @import("build_options");

pub const Ctx = struct {
    focused_window_id: ?model_mod.WindowId = null,
};

/// Shared no-op context for internal fallback calls that don't need one.
var noop_ctx: Ctx = .{};

/// Current workspace as seen by the model (single source of truth).
pub inline fn currentWs() model_mod.WSId {
    return pipeline.model().current;
}

// ---------------------------------------------------------------- minimize

/// BC06 atomicity: minimize + fallback-focus + retile land under one grab.
pub fn minimize(ctx: *Ctx, focused: ?model_mod.WindowId) void {
    const win = focused orelse return;
    const m = pipeline.model();
    model_mod.minimize(m, win) catch return; // BC26 pre-refusal (CapacityFull)
    if (ctx.focused_window_id == win) focusFallback(m, ctx);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true }); // BC06 atomicity
}

/// BC06 fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
/// Protocol layer untouched until train f (R2): winner goes through the
/// legacy take-focus dispatch; null winner clears focus. Model and protocol
/// focus are updated together so sync's color/winner pass sees one truth.
pub fn focusFallback(m: *const model_mod.Model, ctx: *Ctx) void {
    _ = ctx;
    if (pickFallback(m)) |winner| {
        const mm: *model_mod.Model = @constCast(m);
        model_mod.setFocus(mm, winner);
        focus.setFocus(winner, .tiling_operation);
    } else {
        model_mod.clearFocus(@constCast(m));
        focus.clearFocus();
    }
}

fn pickFallback(m: *const model_mod.Model) ?model_mod.WindowId {
    const ws = m.current;
    // 1. current-ws focus MRU, newest first, skipping the minimized window
    //    (it is already mode=.minimized here so visibleOn would skip it too).
    const mru = &m.ws[ws].focus_mru;
    var i = mru.items.len;
    while (i > 0) {
        i -= 1;
        const cand = mru.items[i];
        if (model_mod.visibleOn(m, cand, ws)) return cand;
    }
    // 2. reversed tiled_order of the current workspace.
    const order = &m.ws[ws].tiled_order;
    var j = order.items.len;
    while (j > 0) {
        j -= 1;
        const cand = order.items[j];
        if (model_mod.visibleOn(m, cand, ws)) return cand;
    }
    // 3. any floating window on ws (base mode, not in tiled_order).
    for (0..m.store.count()) |k| {
        const it = m.store.at(k);
        if (it.val.mode != .base) continue;
        if (!model_mod.visibleOn(m, it.key, ws)) continue;
        var tiled = false;
        for (order.items) |t| if (t == it.key) {
            tiled = true;
            break;
        };
        if (!tiled) return it.key;
    }
    return null;
}

// ----------------------------------------------------------------- restore

/// Restores a specific minimized window (title-bar click path).
pub fn restore(ctx: *Ctx, win: model_mod.WindowId) void {
    _ = ctx;
    const m = pipeline.model();
    if (!isMinimizedOnAnyWs(m, win)) return;
    model_mod.restore(m, win);
    model_mod.setFocus(m, win);
    focus.setFocus(win, .window_spawn); // protocol untouched until train f
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

pub fn restoreLifo(ctx: *Ctx) void {
    restoreOrdered(ctx, .lifo);
}

pub fn restoreFifo(ctx: *Ctx) void {
    restoreOrdered(ctx, .fifo);
}

fn restoreOrdered(ctx: *Ctx, order: model_mod.RestoreOrder) void {
    _ = ctx;
    const m = pipeline.model();
    const win = model_mod.restoreCandidate(m, currentWs(), order) orelse return;
    model_mod.restore(m, win);
    model_mod.setFocus(m, win);
    focus.setFocus(win, .window_spawn);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

/// BC09: slot-ordered bulk restore of the current workspace. Focus target is
/// the most recently minimized PLAIN window (legacy focuses plain_wins[last];
/// fullscreen-prev windows replay through the same reconcile's fullscreen
/// branch — BC08 straight-back-into-fullscreen).
pub fn restoreAll(ctx: *Ctx) void {
    _ = ctx;
    const m = pipeline.model();
    const ws = currentWs();
    const target = model_mod.latestMinimizedBase(m, ws) orelse return;
    model_mod.restoreAllOnWs(m, ws);
    model_mod.setFocus(m, target);
    focus.setFocus(target, .window_spawn);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

fn isMinimizedOnAnyWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    const e = m.store.get(win) orelse return false;
    return e.mode == .minimized;
}

// -------------------------------------------------------------- fullscreen

/// Fullscreen enter/exit/switch in ONE model transition + ONE reconcile.
///
/// Legacy wire parity notes (fullscreen.zig full read, train-b precondition):
///  - winner: screen rect, bw=0, pixel=0, ABOVE merged — ≙ applyFullscreenGeometry
///  - everyone else parked X+offscreen — ≙ the pushWindowOffscreen loop; the
///    switch case's intermediate "restore A then re-park A" round of requests
///    collapses away (same end state, fewer requests)
///  - floating exit geometry: base.floating rect replays via LastSent diff —
///    ≙ configureWindowGeom(saved)+saveWindowGeom
///  - tiled exit: engine placements — ≙ retileCurrentWorkspace
/// Bar hide/show deferral and EWMH stay protocol-side (R2), driven through
/// fullscreen.zig's pending machinery so events.zig's ConfigureNotify handler
/// works unchanged for both paths.
pub fn fullscreenToggle(ctx: *Ctx) void {
    const m = pipeline.model();
    const win = m.focused orelse return;
    fullscreenToggleWindow(ctx, win);
}

/// MODEL-mode fullscreen query (single source of truth; replaces the legacy
/// fullscreen-record lookup for EWMH and client-message paths).
pub fn isFullscreenMode(win: model_mod.WindowId) bool {
    const m = pipeline.model();
    const e = m.store.get(win) orelse return false;
    return e.mode == .fullscreen;
}

/// Whether any window occupies the fullscreen slot on `ws` (model truth;
/// replaces the deleted legacy fullscreen.zig record store for bar
/// visibility decisions).
pub fn fullscreenOccupiedOnWs(ws: model_mod.WSId) bool {
    return fsOccupantOnWs(pipeline.model(), ws) != null;
}

/// Fullscreen transition for an ARBITRARY window (EWMH _NET_WM_STATE path,
/// title-bar clicks). Keybind path delegates with the focused window.
pub fn fullscreenToggleWindow(ctx: *Ctx, win: model_mod.WindowId) void {
    _ = ctx;
    const core = @import("core");
    if (!core.getState().config.fullscreen_enabled) return;
    const fullscreen = @import("fullscreen");

    const m = pipeline.model();
    // Defense-in-depth parity with legacy toggle(): never fullscreen a window
    // off the viewed workspace (one path once corrupted workspaces doing so).
    if (!model_mod.visibleOn(m, win, m.current)) return;

    // Classify BEFORE toggling so bar deferrals match legacy timing exactly.
    const kind: enum { enter, exit, switch_ } = blk: {
        if (isFullscreenOnWs(m, win, m.current)) break :blk .exit;
        if (fsOccupantOnWs(m, m.current)) |_| break :blk .switch_;
        break :blk .enter;
    };
    const prev_fs_win = fsOccupantOnWs(m, m.current);

    if (!model_mod.toggleFullscreen(m, win)) return;

    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });

    // EWMH advertisement: clear for whoever left fullscreen, set for entrant.
    if (kind == .switch_) {
        if (prev_fs_win) |old| fullscreen.setEwmhFullscreenState(old, false);
    }
    const now_fullscreen = isFullscreenOnWs(pipeline.model(), win, pipeline.model().current);
    fullscreen.setEwmhFullscreenState(win, now_fullscreen);

    switch (kind) {
        .enter, .switch_ => fullscreen.armPendingBarHide(win),
        .exit => {
            if (pipeline.model().focused) |w| fullscreen.armPendingBarShow(w);
        },
    }
}

// ------------------------------------------------- tag-move / pin / all-view

/// move_to_workspace (train e). Model moves mask + home list + fullscreen
/// record in one call; the reconcile's diff parks/repairs geometry globally
/// (legacy evictWindow + retileRedrawAndFlush collapse into it).
pub fn moveWindowTo(ctx: *Ctx, win: model_mod.WindowId, ws_idx: u8) void {
    _ = ctx;
    const constants = @import("constants");
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.model();
    const was_focused = m.focused == win;
    const was_fs_current = isFullscreenOnWs(m, win, m.current);

    model_mod.moveWindowToWs(m, win, ws_idx);
    if (m.store.get(win) == null) return; // unknown window parity

    if (ws_idx != m.current) {
        if (was_focused) focusFallback(m, &noop_ctx);
        if (was_fs_current and build_options.has_bar) @import("bar").setBarState(.show_fullscreen);
    }
    pipeline.reconcileUnderGrabNow(.{});
    if (build_options.has_bar) @import("bar").scheduleRedraw();
}

/// toggle_tag (Mod+Alt+N). Focus is left unchanged on add (multi-tag gesture);
/// removing the CURRENT tag evicts the window and re-focuses per BC06.
pub fn tagToggle(ctx: *Ctx, win: model_mod.WindowId, ws_idx: u8, protect_current: bool) void {
    _ = ctx;
    const constants = @import("constants");
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.model();
    const e = m.store.get(win) orelse return;
    if (e.mode == .minimized) return; // legacy guard

    const had_bit = e.mask & model_mod.bit(ws_idx) != 0;
    const removing_current = ws_idx == m.current;

    if (had_bit) {
        if (!model_mod.tagRemove(m, win, ws_idx)) return; // last tag protected
        if (removing_current and m.focused == win) focusFallback(m, &noop_ctx);
    } else {
        model_mod.tagAdd(m, win, ws_idx, protect_current);
    }

    if (removing_current or (!had_bit and ws_idx == m.current)) {
        // Visible-set changed on the shown workspace: atomic evict/map+retile.
        pipeline.reconcileUnderGrabNow(.{});
    }
    if (!removing_current) {
        // Off-workspace change: just stale-mark that workspace's bar segment.
        if (build_options.has_bar) @import("bar").scheduleRedraw();
    }
}

/// move_to_all_workspaces / toggle_tag_all: pinned ⇄ current-only.
pub fn pinToggle(ctx: *Ctx, win: model_mod.WindowId) void {
    _ = ctx;
    const m = pipeline.model();
    const e = m.store.get(win) orelse return;
    if (e.mode == .minimized) return; // legacy guard
    model_mod.pinToggle(m, win);
    pipeline.reconcileUnderGrabNow(.{});
    if (build_options.has_bar) @import("bar").scheduleRedraw();
}

/// all_workspaces (Mod+5): flag flip; sync maps foreign windows on enter and
/// parks them again on exit through the ordinary diff.
pub fn allViewToggle(ctx: *Ctx) void {
    _ = ctx;
    const m = pipeline.model();
    const entering = model_mod.allViewToggle(m);
    if (!entering and m.focused != null and !model_mod.visibleOn(m, m.focused.?, m.current)) {
        focusFallback(m, &noop_ctx);
    }
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
    if (build_options.has_bar) @import("bar").scheduleRedraw();
}

// --------------------------------------------- tiling ops / drag (train f)

/// toggle_floating_window. Tiled→floating seeds the rect from the window's
/// current on-screen geometry (LastSent); floating→tiled re-enters the home
/// list at the master boundary via the ordinary engine order.
pub fn toggleFloating(ctx: *Ctx, win: model_mod.WindowId) void {
    _ = ctx;
    const m = pipeline.model();
    const e = m.store.getPtr(win) orelse return;
    switch (e.mode) {
        .base => |b| switch (b) {
            .tiled => {
                const r = sync.lastRectFor(win) orelse return;
                e.mode = .{ .base = .{ .floating = r } };
            },
            .floating => e.mode = .{ .base = .tiled },
        },
        else => return,
    }
    if (build_options.has_bar) @import("bar").scheduleRedraw();
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

/// Drag tick (no grab — E.6): model rect is the single source of truth; sync
/// applies it conditionally against the sent ledger (only the dragged
/// window's geometry actually differs). Called from floating.zig's
/// updateDrag instead of its direct configureWindow when the flag is ON.
pub fn dragRect(win: model_mod.WindowId, r: @import("utils").Rect) void {
    const m = pipeline.model();
    model_mod.setFloatingRect(m, win, r);
    pipeline.reconcileNow();
}

/// First motion of a drag on a tiled window detaches it to floating at its
/// current geometry (legacy pending_float + removeWindow + retile).
pub fn detachToFloating(win: model_mod.WindowId) void {
    const m = pipeline.model();
    const e = m.store.getPtr(win) orelse return;
    if (e.mode != .base or e.mode.base != .tiled) return;
    const r = sync.lastRectFor(win) orelse return;
    e.mode = .{ .base = .{ .floating = r } };
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn cycleLayoutKind(ctx: *Ctx, dir: i32) void {
    _ = ctx;
    const m = pipeline.model();
    model_mod.cycleLayout(m, dir);
    if (build_options.has_bar) @import("bar").scheduleFullRedraw();
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn stepVariant(ctx: *Ctx) void {
    stepVariantDir(ctx, 1);
}

pub fn stepVariantDir(ctx: *Ctx, dir: i32) void {
    _ = ctx;
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const n = model_mod.variantCount(p.kind);
    const cur: i32 = @intCast(p.variant_idx);
    const next: i32 = @mod(cur + dir, @as(i32, @intCast(n)));
    p.variant_idx = @intCast(next);
    if (build_options.has_bar) @import("bar").scheduleFullRedraw();
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustMasterWidthAction(ctx: *Ctx, delta: f32) void {
    _ = ctx;
    const m = pipeline.model();
    model_mod.adjustMasterWidth(m, delta);
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustMasterCount(ctx: *Ctx, delta: i32) void {
    _ = ctx;
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const next = @as(i32, p.master_count) + delta;
    p.master_count = @intCast(@max(1, next));
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustStackBalance(ctx: *Ctx, delta: f32) void {
    _ = ctx;
    const max_balance: f32 = 6.0; // legacy max_stack_balance
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    p.stack_balance = std.math.clamp(p.stack_balance + delta, -max_balance, max_balance);
    pipeline.reconcileUnderGrabNow(.{});
}

/// swap_master: focused ⇄ stack head. focus_swap variant moves focus to the
/// displaced window BEFORE the reconcile so monocle-style layouts render the
/// right window on the first pass (legacy defer semantics collapse).
pub fn swapMasterAction(ctx: *Ctx, focus_swap: bool) void {
    _ = ctx;
    const m = pipeline.model();
    const list = &m.ws[m.current].tiled_order;
    if (list.items.len < 2) return;
    const displaced = list.items[0];
    model_mod.swapMaster(m);
    if (focus_swap) {
        if (m.focused != null and m.focused.? != displaced) {
            model_mod.setFocus(m, displaced);
            focus.setFocus(displaced, .tiling_operation);
        }
    }
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn moveFocused(ctx: *Ctx, delta: i32) void {
    _ = ctx;
    const m = pipeline.model();
    const win = m.focused orelse return;
    const h = model_mod.findHome(m, win) orelse return;
    const idx = model_mod.findInOrder(&m.ws[h].tiled_order, win) orelse return;
    const next_i = @as(i64, @intCast(idx)) + delta;
    if (next_i < 0 or next_i >= m.ws[h].tiled_order.len) return;
    model_mod.reorderTiled(m, win, @intCast(next_i));
    pipeline.reconcileUnderGrabNow(.{});
}

/// scroll_view_left/right: one slot per step, clamped to content. The spawn
/// snap-right duty lives in preReconcileDuties (pipeline choke point).
pub fn scrollStep(ctx: *Ctx, dir: i32) void {
    _ = ctx;
    const algo_scroll = @import("scroll");
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    if (p.kind != .scroll) return;
    if (!build_options.has_bar) return;
    const n = tiledCountOnCurrent(m);
    const wa = @import("bar").workAreaRect();
    const slot_w = algo_scroll.slotWidth(wa.width);
    const max_off = algo_scroll.maxOffset(n, slot_w, wa.width);
    p.scroll_offset += dir * slot_w;
    p.scroll_offset = std.math.clamp(p.scroll_offset, 0, max_off);
    p.scroll_prev_count = @intCast(n);
    pipeline.reconcileUnderGrabNow(.{});
}

/// Focus-change scroll snap (WP6 port of tiling.snapScrollToFocused): shift
/// the viewport minimally so the focused window's slot is fully on-screen.
pub fn snapScrollToFocused(ctx: *Ctx) void {
    _ = ctx;
    const algo_scroll = @import("scroll");

    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    if (p.kind != .scroll) return;
    if (!build_options.has_bar) return;
    const win = m.focused orelse return;

    var idx: ?usize = null;
    var n: usize = 0;
    for (m.ws[m.current].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (e.mask & model_mod.bit(m.current) == 0) continue;
        if (w == win) idx = n;
        n += 1;
    }
    const i = idx orelse return;

    const wa = @import("bar").workAreaRect();
    const slot_w = algo_scroll.slotWidth(wa.width);
    const max_off = algo_scroll.maxOffset(n, slot_w, wa.width);
    const i64_slot_w: i64 = slot_w;
    const slot_left = @as(i64, @intCast(i)) * i64_slot_w - p.scroll_offset;
    const slot_right = slot_left + i64_slot_w;
    if (slot_left < 0)
        p.scroll_offset = @intCast(@as(i64, @intCast(i)) * i64_slot_w)
    else if (slot_right > wa.width)
        p.scroll_offset = @intCast(@as(i64, @intCast(i)) * i64_slot_w + i64_slot_w - @as(i64, wa.width));
    p.scroll_offset = std.math.clamp(p.scroll_offset, 0, max_off);
    p.scroll_prev_count = @intCast(n);
    pipeline.reconcileUnderGrabNow(.{});
}

fn tiledCountOnCurrent(m: *const model_mod.Model) usize {
    var n: usize = 0;
    for (m.ws[m.current].tiled_order.constSlice()) |w| {
        const e = m.store.get(w) orelse continue;
        if (e.mask & model_mod.bit(m.current) == 0) continue;
        n += 1;
    }
    return n;
}

// ------------------------------------------------- config reload (train g)

/// Re-seeds every workspace's model params from the NEW config after a
/// reload, mirroring workspaces.applyWorkspaceOverrides semantics: per-ws
/// layout/variant/master-count overrides, global defaults otherwise;
/// runtime-only master_width/stack_balance reset (legacy nulls).
pub fn applyConfigReload() void {
    const types = @import("types");
    const constants = @import("constants");
    const tiling = @import("tiling");
    const cs = @import("core").getState();
    const cfg = &cs.config.tiling;
    const max_ws = constants.max_workspaces;

    const default_layout: types.Layout = tiling.layoutFromString(cfg.layout) orelse tiling.defaultLayout();

    // Last override wins (legacy loop-overwrite semantics).
    var layout_lookup: [max_ws]?usize = .{null} ** max_ws;
    for (cfg.workspace_layout_overrides.items, 0..) |o, oi| {
        if (o.workspace_idx < max_ws) layout_lookup[o.workspace_idx] = oi;
    }
    var count_lookup: [max_ws]?u8 = .{null} ** max_ws;
    for (cfg.workspace_master_count_overrides.items) |o| {
        if (o.workspace_idx < max_ws) count_lookup[o.workspace_idx] = o.count;
    }

    const m = pipeline.model();
    for (&m.ws, 0..) |*s, i| {
        const id: u8 = @intCast(i);
        var layout = default_layout;
        var variant: ?types.LayoutVariantOverride = null;
        if (id < max_ws) {
            if (layout_lookup[id]) |oi| {
                const o = cfg.workspace_layout_overrides.items[oi];
                if (o.layout_idx < cfg.layouts.items.len)
                    layout = tiling.layoutFromString(cfg.layouts.items[o.layout_idx]) orelse default_layout;
                variant = o.variant;
            }
        }
        s.params.kind = layoutKindFromConfig(layout);
        s.params.variant_idx = variantIdx(variant, s.params.kind);
        s.params.master_count = if (id < max_ws)
            (count_lookup[id] orelse cfg.master_count)
        else
            cfg.master_count;
        s.params.master_width = 0.5; // runtime-only in legacy too (null reset)
        s.params.stack_balance = 0;
    }
    pipeline.reconcileUnderGrabNow(.{});
}

fn layoutKindFromConfig(l: anytype) model_mod.LayoutKind {
    return switch (l) {
        .master => .master,
        .monocle => .monocle,
        .grid => .grid,
        .fibonacci => .fibonacci,
        .leaf => .leaf,
        .scroll => .scroll,
        // The engine has no floating layout; windows keep their current
        // params kind. Legacy "floating" means "don't retile", which the
        // model path approximates by leaving placements alone.
        .floating => .master,
    };
}

fn variantIdx(v: anytype, kind: model_mod.LayoutKind) u8 {
    const vov = v orelse return 0;
    return switch (kind) {
        .master => if (vov == .master) @intFromEnum(vov.master) else 0,
        .monocle => if (vov == .monocle) @intFromEnum(vov.monocle) else 0,
        .grid => if (vov == .grid) @intFromEnum(vov.grid) else 0,
        else => 0,
    };
}

fn isFullscreenOnWs(m: *const model_mod.Model, win: model_mod.WindowId, ws: model_mod.WSId) bool {
    const e = m.store.get(win) orelse return false;
    return e.mode == .fullscreen and e.mode.fullscreen.ws == ws;
}

// ---------------------------------------------------------- workspace switch

/// Workspace switch (train c). One model transition + one reconcile; the
/// legacy hide/park + map/restore dance collapses into the LastSent diff
/// (leavers park once, arrivers map+place — see sync_test's switch scenario).
///
/// Kept protocol-side (R2): pointer-hover query, focus suppression reset,
/// and the workspace-switch focus reason. Dual-writes tracking's current
/// workspace while the strangler runs (bar segments and other modules read it).
pub fn switchTo(ctx: *Ctx, ws_idx: u8) void {
    _ = ctx;
    const core = @import("core");
    const constants = @import("constants");
    const xcb = core.xcb;

    const m = pipeline.model();
    if (ws_idx >= constants.max_workspaces) return;
    if (m.current == ws_idx) return;

    // Legacy executeSwitch ordering: suppression/pointer-sync state first.
    const focus_mod = @import("focus");
    focus_mod.setSuppressReason(.none);
    focus_mod.cancelPointerSync();

    // Pointer query BEFORE the grab (round trips can't run inside one).
    // B3/R2 note: this is a deliberate, sanctioned protocol-side duty inside
    // an action — hover-follows-switch needs the pointer position at switch
    // time, and moving the query to every entry-point caller would just
    // duplicate it. Like the EWMH writes below, it is wire traffic that
    // answers the CLIENT/pointer, not layout; the layer allowlist covers it.
    const target = blk: {
        const cs = core.getState();
        const cookie = xcb.xcb_query_pointer(cs.conn, cs.root);
        const reply = xcb.xcb_query_pointer_reply(cs.conn, cookie, null);
        defer if (reply) |r| std.c.free(r);
        if (reply) |r| {
            const child = r.*.child;
            if (child != 0 and child != cs.root and model_mod.visibleOn(m, child, ws_idx)) {
                break :blk @as(?model_mod.WindowId, child);
            }
        }
        break :blk fallbackFocusOnWs(m, ws_idx);
    };

    // All-view exit is a flag flip (BC17 emerges from visibility); temp-window
    // masks do not exist in the model.
    m.all_view_active = false;

    // A4: model.current is the ONLY store for the current workspace; the
    // tracking/workspaces mirrors are deleted (read-through facades now).
    m.current = ws_idx;

    if (target) |t| {
        model_mod.setFocus(m, t);
        focus_mod.setFocus(t, .workspace_switch);
    } else {
        model_mod.clearFocus(m);
        focus_mod.clearFocus();
    }

    // Bar visibility follows the NEW workspace's fullscreen occupant
    // (legacy executeSwitch line ~685), applied before the reconcile batch.
    if (build_options.has_bar) {
        const bar = @import("bar");
        bar.setBarState(if (fsOccupantOnWs(m, ws_idx) != null) .hide_fullscreen else .show_fullscreen);
    }

    // force_restack raises the bar window (I4 hook) ≙ legacy raiseBar tail.
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

/// Post-switch focus fallback: newest-first focus_mru of `ws`, then first
/// visible store entry (≙ lastFocusedOrFirst's tracking-order scan).
fn fallbackFocusOnWs(m: *const model_mod.Model, ws: model_mod.WSId) ?model_mod.WindowId {
    const mru = &m.ws[ws].focus_mru;
    var i = mru.items.len;
    while (i > 0) {
        i -= 1;
        if (model_mod.visibleOn(m, mru.items[i], ws)) return mru.items[i];
    }
    for (0..m.store.count()) |k| {
        const it = m.store.at(k);
        if (model_mod.visibleOn(m, it.key, ws)) return it.key;
    }
    return null;
}

// ------------------------------------------------------- spawn/map lifecycle

/// MapRequest tail (train d). The legacy front-end (event masks, property
/// queries, size-hints cache) has already run; this registers the window in
/// the model and lets ONE reconcile do map+pixel+bw+geom(+ABOVE winner) for
/// on-current spawns. Off-current spawns park by construction — sync sends
/// their border width at first show instead of immediately (invisible either
/// way; one less request).
pub fn mapRequest(ctx: *Ctx, win: model_mod.WindowId, target_ws: u8, on_current: bool) void {
    _ = ctx;
    const wincache = @import("wincache");

    const m = pipeline.model();
    if (m.store.has(win)) return; // double-manage guard parity

    // I8: a defined refusal (store or home-list full) leaves the window
    // unmanaged — same observable outcome as the legacy full-pool path.
    model_mod.register(m, win, if (on_current) null else target_ws) catch {
        std.log.warn("mapRequest: capacity full; window 0x{x} left unmanaged", .{win});
        return;
    };
    // Bridge the cached WM_NORMAL_HINTS into the model entry at registration.
    const e = m.store.getPtr(win);
    if (e) |ep| ep.size_hints = wincache.peekHints(win);
    // Master-fifo variant spawn placement (moved out of model.register — it
    // is SPAWN policy, not membership policy): new window takes the master
    // slot, previous master drops to stack head.
    {
        const home: model_mod.WSId = if (on_current) m.current else @intCast(target_ws);
        const p = &m.ws[home].params;
        if (p.kind == .master and p.variant_idx == 1 and m.ws[home].tiled_order.len > 1) {
            model_mod.reorderTiled(m, win, 0);
        }
    }
    focus.initWindowGrabs(win); // protocol-side keygrabs, both paths did this
    if (build_options.has_bar) @import("bar").scheduleRedraw();

    if (!on_current) return;

    // Model focus first so the reconcile below colors/stacks with the new
    // focus; X input focus afterwards, once the window is actually viewable
    // (focusing an unmapped window is a BadMatch).
    model_mod.setFocus(m, win);
    pipeline.reconcileUnderGrabNow(.{});
    focus.setFocus(win, .window_spawn);
}

/// Unmanage tail (train d): close/destroy/unmap of a managed window. Legacy
/// local bookkeeping (fullscreen record, caches, tiling/minimize/workspaces
/// removes) has already run; this drops the model entry and re-focuses.
/// Inactive-workspace geometry repairs ride the same global LastSent diff —
/// legacy's separate retileInactiveWorkspace call disappears.
pub fn unmanage(ctx: *Ctx, win: model_mod.WindowId) void {
    _ = ctx;
    const m = pipeline.model();
    const was_focused = m.focused == win;
    const was_fs_current = isFullscreenOnWs(m, win, m.current);

    model_mod.unregister(m, win);
    sync.forget(win); // X ids recycle; stale LastSent must not survive (fix P0-4)

    if (was_focused) {
        if (pickFallback(m)) |t| {
            model_mod.setFocus(m, t);
            focus.setFocus(t, .tiling_operation);
        } else {
            model_mod.clearFocus(m);
            focus.clearFocus();
        }
    }
    if (was_fs_current and build_options.has_bar) @import("bar").setBarState(.show_fullscreen);

    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}

/// The window occupying the fullscreen slot on `ws`, if any. Model guarantees
/// at most one visible fullscreen per ws (sync parks the rest).
fn fsOccupantOnWs(m: *const model_mod.Model, ws: model_mod.WSId) ?model_mod.WindowId {
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.mode != .fullscreen) continue;
        if (it.val.mode.fullscreen.ws != ws) continue;
        if (!model_mod.visibleOn(m, it.key, ws)) continue;
        return it.key;
    }
    return null;
}
