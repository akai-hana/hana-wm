//! Thin action wrappers used by entry points. One action = one state
//! transition + one sync entry.
//!
//! Division of labor:
//!   model.*   — state transitions (tiled_order, modes, focus bookkeeping)
//!   sync.*    — geometry/border/stack/park requests (via pipeline slots)
//!   focus     — X11 focus protocol + input-model resolve.

const std = @import("std");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const sync = @import("sync");
const focus = @import("focus");
const build_options = @import("build_options");
const debug = @import("debug");

/// Withdrawal facts for actions.unmanage. The sole caller (window.
/// unmanageWindow) removes the model entry BEFORE the action runs, so both
/// fields are captured up front and ride the context in; every other entry
/// point reads live model truth and needs no context at all.
pub const Ctx = struct {
    /// Fullscreen workspace record of the window being withdrawn, captured
    /// by unmanageWindow BEFORE workspaces.removeWindow drops the model
    /// entry (after which no store query could recover it).
    withdrawn_fullscreen_ws: ?model_mod.WSId = null,
    /// Whether the withdrawn window held MODEL focus at withdrawal time,
    /// captured BEFORE removal clears m.focused. Drives the close
    /// fallback (parity with minimize): the previous focus owner must hand
    /// over, otherwise the workspace stays unfocused until a pointer event.
    withdrawn_was_focused: bool = false,
};

/// Shared tail of the trivial flip-actions (§C): mark the bar stale and push
/// ONE reconcile through the grab (scroll snap/clamp duties run inside the
/// pipeline choke point). scheduleRedraw/scheduleFullRedraw are pure dirty-
/// flag sets with zero X traffic, so marking before the reconcile is wire-
/// identical to marking after. Actions whose pinned side-effect ORDER differs
/// (setBarState before the reconcile, armPendingBarHide after, reconcile-only
/// tails) keep their bespoke tails instead of growing this helper flags.
fn retileAndNotify(restack: bool, full_redraw: bool) void {
    if (build_options.has_bar) {
        const bar = @import("bar");
        if (full_redraw) bar.scheduleFullRedraw() else bar.scheduleRedraw();
    }
    pipeline.reconcileUnderGrabNow(if (restack) .{ .force_restack = true } else .{});
}

// ---------------------------------------------------------------- minimize

/// Atomicity: minimize + fallback-focus + retile land under one grab.
///
/// Focus policy reads MODEL truth (`m.focused`): minimizing the focused
/// window hands focus over via focusFallback, otherwise m.focused would keep
/// pointing at the hidden window (stale title segment, stale border colors
/// until the next unrelated focus event).
///
/// Minimizing THE fullscreen occupant also frees the bar-hide reason: the
/// bar comes back (setBarState re-derives occupancy itself and no-ops when
/// another occupant remains or the user toggled the bar off). It runs BEFORE
/// the reconcile because workAreaRect() depends on bar visibility.
pub fn minimize(focused: ?model_mod.WindowId) void {
    const win = focused orelse return;
    const m = pipeline.model();
    const was_focused = m.focused == win;
    const fs_ws_before = model_mod.fullscreenWsOf(m, win);

    model_mod.minimize(m, win) catch return; // Pre-refusal (CapacityFull)

    if (was_focused) focusFallback(m);

    if (build_options.has_bar) {
        const bar = @import("bar");
        if (fs_ws_before) |fs_ws| {
            if (fs_ws == m.current) bar.setBarState(.show_fullscreen);
        }
        bar.scheduleRedraw(); // minimization itself refreshes the title segment
    }

    pipeline.reconcileUnderGrabNow(.{ .force_restack = true }); // Atomicity
}

/// Fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
/// Protocol layer untouched until train f (R2): winner goes through the
/// legacy take-focus dispatch; null winner clears focus. Model and protocol
/// focus are updated together so sync's color/winner pass sees one truth.
/// (focus.clearFocus already clears the model — the one-store seam —
/// so the null branch needs no separate model write.)
fn focusFallback(m: *model_mod.Model) void {
    // Tier policy lives in the model layer so tests can exercise it without
    // linking the protocol side (see model.fallbackFocusCandidate).
    if (model_mod.fallbackFocusCandidate(m, m.current)) |winner| {
        model_mod.setFocus(m, winner);
        focus.setFocus(winner, .tiling_operation);
    } else {
        focus.clearFocus();
    }
}

// ----------------------------------------------------------------- restore

/// Restores a specific minimized window (title-bar click path).
pub fn restore(win: model_mod.WindowId) void {
    const m = pipeline.model();
    if (!isMinimizedOnAnyWs(m, win)) return;
    // A pre-existing fullscreen occupant means sync will park the restored
    // window's fullscreen record anyway; only an unoccupied slot may defer
    // a bar hide (win itself is minimized here, so any occupant is "other").
    const had_occupant_before = model_mod.fullscreenOccupantOnWs(m, m.current) != null;
    model_mod.restore(m, win);
    model_mod.setFocus(m, win);
    focus.setFocus(win, .window_spawn); // protocol untouched until train f
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
    // Straight-back-into-fullscreen: defer the bar hide to the window's
    // ConfigureNotify confirmation — exactly like an enter-fullscreen toggle
    // (arming the hide also clears leftover pending-show state).
    if (build_options.has_bar and !had_occupant_before and
        model_mod.isFullscreenOnWs(pipeline.model(), win, pipeline.model().current))
    {
        @import("fullscreen").armPendingBarHide(win);
    }
}

/// Slot-ordered single restore (LIFO/FIFO keybind paths).
pub fn restoreOrdered(order: model_mod.RestoreOrder) void {
    const m = pipeline.model();
    const win = model_mod.restoreCandidate(m, m.current, order) orelse return;
    const had_occupant_before = model_mod.fullscreenOccupantOnWs(m, m.current) != null;
    model_mod.restore(m, win);
    model_mod.setFocus(m, win);
    focus.setFocus(win, .window_spawn);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
    if (build_options.has_bar and !had_occupant_before and
        model_mod.isFullscreenOnWs(pipeline.model(), win, pipeline.model().current))
    {
        @import("fullscreen").armPendingBarHide(win);
    }
}

/// Slot-ordered bulk restore of the current workspace. Focus target is
/// the most recently minimized PLAIN window (legacy focuses plain_wins[last];
/// fullscreen-prev windows replay through the same reconcile's fullscreen
/// branch — straight-back-into-fullscreen).
pub fn restoreAll() void {
    const m = pipeline.model();
    const ws = m.current;
    const target = model_mod.latestMinimizedBase(m, ws) orelse return;
    const had_occupant_before = model_mod.fullscreenOccupantOnWs(m, ws) != null;
    model_mod.restoreAllOnWs(m, ws);
    model_mod.setFocus(m, target);
    focus.setFocus(target, .window_spawn);
    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
    if (build_options.has_bar and !had_occupant_before) {
        if (model_mod.fullscreenOccupantOnWs(m, ws)) |occ| @import("fullscreen").armPendingBarHide(occ);
    }
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
///  - everyone else parked X+offscreen — the switch case's intermediate
///    "restore A then re-park A" round of requests collapses away (same end
///    state, fewer requests)
///  - floating exit geometry: base.floating rect replays via LastSent diff —
///    ≙ replay saved rect + saveWindowGeom
///  - tiled exit: engine placements — ≙ retileCurrentWorkspace
/// Bar hide/show deferral and EWMH stay protocol-side (R2), driven through
/// fullscreen.zig's pending machinery so events.zig's ConfigureNotify handler
/// works unchanged for both paths.
/// MODEL-mode fullscreen query (single source of truth; replaces the legacy
/// fullscreen-record lookup for EWMH and client-message paths).
///
/// Retained as a one-line model delegation: protocol-side callers outside
/// this layer's scope (borders.color, floating drag guards) hold no model
/// handle of their own and ask through here.
pub fn isFullscreenMode(win: model_mod.WindowId) bool {
    return model_mod.isFullscreenMode(pipeline.model(), win);
}

/// Whether any window occupies the fullscreen slot on `ws` (model truth;
/// replaces the deleted legacy fullscreen.zig record store for bar
/// visibility decisions). Retained for the bar's out-of-layer callers.
pub fn fullscreenOccupiedOnWs(ws: model_mod.WSId) bool {
    return model_mod.fullscreenOccupantOnWs(pipeline.model(), ws) != null;
}

/// Fullscreen transition for an ARBITRARY window (EWMH _NET_WM_STATE path,
/// title-bar clicks). The keybind path resolves the focused window at the
/// dispatch site and lands here too.
pub fn fullscreenToggleWindow(win: model_mod.WindowId) void {
    const core = @import("core");
    if (!core.getState().config.fullscreen_enabled) return;
    const fullscreen = @import("fullscreen");

    const m = pipeline.model();
    // Defense-in-depth parity with legacy toggle(): never fullscreen a window
    // off the viewed workspace (one path once corrupted workspaces doing so).
    if (!model_mod.visibleOn(m, win, m.current)) return;

    // Classify BEFORE toggling so bar deferrals match legacy timing exactly.
    const kind: enum { enter, exit, switch_ } = blk: {
        if (model_mod.isFullscreenOnWs(m, win, m.current)) break :blk .exit;
        if (model_mod.fullscreenOccupantOnWs(m, m.current) != null) break :blk .switch_;
        break :blk .enter;
    };
    const prev_fs_win = model_mod.fullscreenOccupantOnWs(m, m.current);

    if (!model_mod.toggleFullscreen(m, win)) return;

    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });

    // EWMH advertisement: clear for whoever left fullscreen, set for entrant.
    if (kind == .switch_) {
        if (prev_fs_win) |old| fullscreen.setEwmhFullscreenState(old, false);
    }
    const now_fullscreen = model_mod.isFullscreenOnWs(pipeline.model(), win, pipeline.model().current);
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
pub fn moveWindowTo(win: model_mod.WindowId, ws_idx: u8) void {
    const constants = @import("constants");
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.model();
    const was_focused = m.focused == win;
    const was_fs_current = model_mod.isFullscreenOnWs(m, win, m.current);

    model_mod.moveWindowToWs(m, win, ws_idx);
    if (m.store.get(win) == null) return; // unknown window parity

    if (ws_idx != m.current) {
        if (was_focused) focusFallback(m);
        if (was_fs_current and build_options.has_bar) @import("bar").setBarState(.show_fullscreen);
    }
    retileAndNotify(false, false);
}

/// toggle_tag (Mod+Alt+N). Focus is left unchanged on add (multi-tag gesture);
/// removing the CURRENT tag evicts the window and re-focuses.
pub fn tagToggle(win: model_mod.WindowId, ws_idx: u8, protect_current: bool) void {
    const constants = @import("constants");
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.model();
    const e = m.store.get(win) orelse return;
    if (e.mode == .minimized) return; // legacy guard

    const had_bit = e.mask & model_mod.bit(ws_idx) != 0;
    const removing_current = ws_idx == m.current;

    if (had_bit) {
        if (!model_mod.tagRemove(m, win, ws_idx)) return; // last tag protected
        if (removing_current and m.focused == win) focusFallback(m);
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
pub fn pinToggle(win: model_mod.WindowId) void {
    const m = pipeline.model();
    const e = m.store.get(win) orelse return;
    if (e.mode == .minimized) return; // legacy guard
    model_mod.pinToggle(m, win);
    retileAndNotify(false, false);
}

/// all_workspaces (Mod+5): flag flip; sync maps foreign windows on enter and
/// parks them again on exit through the ordinary diff.
pub fn allViewToggle() void {
    const m = pipeline.model();
    const entering = model_mod.allViewToggle(m);
    if (!entering and m.focused != null and !model_mod.visibleOn(m, m.focused.?, m.current)) {
        focusFallback(m);
    }
    retileAndNotify(true, false);
}

// --------------------------------------------- tiling ops / drag (train f)

/// toggle_floating_window. Tiled→floating seeds the rect from the window's
/// current on-screen geometry (LastSent); floating→tiled re-enters the home
/// list at the master boundary via the ordinary engine order.
pub fn toggleFloating(win: model_mod.WindowId) void {
    const m = pipeline.model();
    const e = m.store.getPtr(win) orelse return;
    switch (e.mode) {
        .base => |b| switch (b) {
            .tiled => {
                const r = sync.lastRectFor(win) orelse return;
                e.mode = .{ .base = .{ .floating = r } };
            },
            .floating => {
                e.mode = .{ .base = .tiled };
                // Defense in depth (the stranded-slot bug class): a
                // tiled-mode window must ALWAYS have a home-list entry
                // (single-membership invariant). Repair legacy-stranded
                // state instead of leaving an engine-invisible window that
                // this very toggle could never fix again.
                if (model_mod.findHome(m, win) == null) {
                    const h: model_mod.WSId = model_mod.lowestBit(e.mask);
                    _ = m.ws[h].tiled_order.append(win);
                }
            },
        },
        else => return,
    }
    retileAndNotify(true, false);
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

pub fn cycleLayoutKind(dir: i32) void {
    const m = pipeline.model();
    model_mod.cycleLayout(m, dir);
    retileAndNotify(false, true);
}

pub fn stepVariantDir(dir: i32) void {
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const n = model_mod.variantCount(p.kind);
    const cur: i32 = @intCast(p.variant_idx);
    const next: i32 = @mod(cur + dir, @as(i32, @intCast(n)));
    p.variant_idx = @intCast(next);
    retileAndNotify(false, true);
}

pub fn adjustMasterWidthAction(delta: f32) void {
    const m = pipeline.model();
    model_mod.adjustMasterWidth(m, delta);
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustMasterCount(delta: i32) void {
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    const next = @as(i32, p.master_count) + delta;
    // Upper clamp: layouts clamp downstream per-tile, but the model
    // param itself used to drift unbounded, desyncing bar/inspect state.
    // store_capacity/4 keeps the bound proportional to the window budget.
    const max_count: i32 = @max(1, model_mod.store_capacity / 4);
    p.master_count = @intCast(std.math.clamp(next, 1, max_count));
    pipeline.reconcileUnderGrabNow(.{});
}

pub fn adjustStackBalance(delta: f32) void {
    const max_balance: f32 = 6.0; // legacy max_stack_balance
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    p.stack_balance = std.math.clamp(p.stack_balance + delta, -max_balance, max_balance);
    pipeline.reconcileUnderGrabNow(.{});
}

/// swap_master: focused ⇄ stack head. focus_swap variant moves focus to the
/// displaced window BEFORE the reconcile so monocle-style layouts render the
/// right window on the first pass (legacy defer semantics collapse).
pub fn swapMasterAction(focus_swap: bool) void {
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

pub fn moveFocused(delta: i32) void {
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
pub fn scrollStep(dir: i32) void {
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

/// Focus-change scroll snap (port of tiling.snapScrollToFocused): shift
/// the viewport minimally so the focused window's slot is fully on-screen.
pub fn snapScrollToFocused() void {
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

/// Seeds every workspace's model params from the CURRENT config. Shared by
/// boot-time initialization (without this the config's tiling
/// params/workspace overrides stay inert until the first explicit reload)
/// and post-reload re-seeding; mirrors workspaces.applyWorkspaceOverrides
/// semantics: per-ws layout/variant/master-count overrides, global defaults
/// otherwise; runtime-only master_width/stack_balance reset (legacy nulls).
/// No reconcile: callers decide when to push state to X.
pub fn seedParamsFromConfig() void {
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
        // A variant override that doesn't belong to the workspace's active
        // workspace's active layout is silently dropped by variantIdx — say
        // so once per affected workspace instead of failing invisibly.
        if (variant) |v| {
            const applies = switch (s.params.kind) {
                .master => v == .master,
                .monocle => v == .monocle,
                .grid => v == .grid,
                else => false,
            };
            if (!applies)
                debug.warn("Config: workspace {d} layout variant ignored — not a variant of the active layout", .{i});
        }
        s.params.variant_idx = variantIdx(variant, s.params.kind);
        s.params.master_count = if (id < max_ws)
            (count_lookup[id] orelse cfg.master_count)
        else
            cfg.master_count;
        s.params.master_width = 0.5; // runtime-only in legacy too (null reset)
        s.params.stack_balance = 0;
    }
}

pub fn applyConfigReload() void {
    seedParamsFromConfig();
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

// ---------------------------------------------------------- workspace switch

/// Workspace switch (train c). One model transition + one reconcile; the
/// legacy hide/park + map/restore dance collapses into the LastSent diff
/// (leavers park once, arrivers map+place — see sync_test's switch scenario).
///
/// Kept protocol-side (R2): pointer-hover query, focus suppression reset,
/// and the workspace-switch focus reason. Dual-writes tracking's current
/// workspace while the strangler runs (bar segments and other modules read it).
pub fn switchTo(ws_idx: u8) void {
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

    // All-view exit is a flag flip (emerges from visibility); temp-window
    // masks do not exist in the model.
    m.all_view_active = false;

    // model.current is the ONLY store for the current workspace; the
    // tracking/workspaces mirrors are deleted (read-through facades now).
    m.current = ws_idx;

    if (target) |t| {
        model_mod.setFocus(m, t);
        focus_mod.setFocus(t, .workspace_switch);
    } else {
        // focus.clearFocus clears the model first (one-store seam) — no
        // separate model write needed here.
        focus_mod.clearFocus();
    }

    // Bar visibility follows the NEW workspace's fullscreen occupant
    // (legacy executeSwitch line ~685), applied before the reconcile batch.
    if (build_options.has_bar) {
        const bar = @import("bar");
        bar.setBarState(if (model_mod.fullscreenOccupantOnWs(m, ws_idx) != null) .hide_fullscreen else .show_fullscreen);
    }

    // force_restack raises the bar window.
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
pub fn mapRequest(win: model_mod.WindowId, target_ws: u8, on_current: bool) void {
    const wincache = @import("wincache");

    const m = pipeline.model();
    if (m.store.has(win)) return; // double-manage guard parity

    // A defined refusal (store or home-list full) leaves the window
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
    const m = pipeline.model();
    // Fullscreen and focus truth arrive via ctx: the sole caller (window.
    // unmanageWindow) removes the model entry (workspaces.removeWindow →
    // unregister) BEFORE this action runs, so reading the store here could
    // never see either — closing the fullscreen occupant never restored the
    // bar, and the withdrawn window's focus ownership was unknowable.
    const was_fs_current = if (ctx.withdrawn_fullscreen_ws) |ws| ws == m.current else false;
    const was_focused = ctx.withdrawn_was_focused;

    model_mod.unregister(m, win);
    sync.forget(win); // X ids recycle; stale LastSent must not survive

    // Close fallback (parity with minimize): when the withdrawn window
    // held focus, hand it to the previously focused window on this ws
    // (MRU newest-first -> reversed tiled_order -> floating); with no
    // candidate left, focus clears. Runs BEFORE the reconcile so border
    // colors and the winner raise are derived from the new focus, and
    // OUTSIDE the grab like every other focusFallback call site.
    // (Supersedes the old stay-unfocused policy per user request:
    // with the pointer parked away from windows, nothing re-focused the
    // workspace after a close.)
    if (was_focused) focusFallback(m);

    if (build_options.has_bar) {
        const bar = @import("bar");
        if (was_fs_current) bar.setBarState(.show_fullscreen); // before reconcile: workAreaRect() depends on visibility
        bar.scheduleRedraw(); // title segment drops the closed window
    }

    pipeline.reconcileUnderGrabNow(.{ .force_restack = true });
}
