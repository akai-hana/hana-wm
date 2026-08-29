//! Thin action wrappers: one action = one model transition + one sync entry.
//! Model state, wire requests, and focus protocol live in model, sync, and focus.

const std = @import("std");
const model_mod = @import("model");
const pipeline = @import("pipeline");
const sync = @import("sync");
const focus = @import("focus");
const screen = @import("screen");
const build_options = @import("build_options");
const debug = @import("debug");
// The build-generated window sub-system registry: the auto-discovered
// `[N]WindowModule` array (dispatch order == deterministic filesystem scan
// order). The floating drag commands and the fullscreen bar-arming reach the
// compiled-in sub-systems through uniform loops over this array, never by
// naming a sub-system module here.
const window_mods = @import("window_modules").modules;

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

/// Shared tail of the trivial flip-actions (C): bump the relevant core fact
/// and push ONE reconcile through the grab (scroll snap/clamp duties run
/// inside the pipeline choke point). Bumping a fact revision is a pure
/// counter increment with zero X traffic, so doing it before the reconcile is
/// wire-identical to doing it after. Actions whose pinned side-effect ORDER
/// differs (setBarState before the reconcile, armPendingBarHide after,
/// reconcile-only tails) keep their bespoke tails instead of growing this
/// helper flags.
fn retileAndNotify(restack: bool, full_redraw: bool) void {
    // Bump core's fact revision for the arrange; the bar (a consumer of the
    // fact) redraws from its own poll. Core is never informed of "the bar".
    if (full_redraw) @import("core").bumpLayout() else @import("core").bumpWindow();
    pipeline.reconcileUnderGrabNow(if (restack) .{ .force_restack = true } else .{});
}

/// Same as retileAndNotify but commits a focus transition inside the grab.
fn retileAndNotifyWithFocus(restack: bool, full_redraw: bool, ft: focus.FocusTransition) void {
    if (full_redraw) @import("core").bumpLayout() else @import("core").bumpWindow();
    pipeline.reconcileUnderGrabNowWithFocus(if (restack) .{ .force_restack = true } else .{}, ft);
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
/// the reconcile because the bar must have updated its screen claim (the
/// usable-area fact the reconcile reads) before placement is re-derived.
pub fn minimize(focused: ?model_mod.WindowId) void {
    if (!build_options.has_minimize) return;
    const win = focused orelse return;
    const m = pipeline.model();
    const was_focused = m.focused == win;
    const fs_ws_before = if (build_options.has_fullscreen) @import("fullscreen").fullscreenWsOf(m, win) else null;

    if (build_options.has_minimize) @import("minimize").minimize(m, win) catch return; // Pre-refusal (CapacityFull)

    const ft: focus.FocusTransition = if (was_focused) focusFallback(m) else .none;

    @import("core").bumpWindow(); // minimization itself refreshes the title segment
    // If the minimized window was the current workspace's fullscreen occupant,
    // its removal changed fullscreen occupancy: bump the core fact and let the
    // bar (a consumer) react, instead of poking it by name.
    if (fs_ws_before) |fs_ws| {
        if (fs_ws == m.current) @import("core").bumpFullscreen();
    }

    pipeline.reconcileUnderGrabNowWithFocus(.{ .force_restack = true }, ft); // Atomicity
}

/// Fallback: own-workspace scope only. Order: current ws focus_mru ->
/// reversed tiled_order -> any floating on ws. First visibleOn(current) wins.
/// Returns a FocusTransition for the caller to commit inside its server grab.
/// Model and protocol focus are updated together: the model update runs
/// before the grab, the protocol commit runs inside it.
fn focusFallback(m: *model_mod.Model) focus.FocusTransition {
    // Tier policy lives in the model layer so tests can exercise it without
    // linking the protocol side (see model.fallbackFocusCandidate).
    if (model_mod.fallbackFocusCandidate(m, m.current)) |winner| {
        model_mod.setFocus(m, winner);
        return focus.prepareFocus(winner, .tiling_operation);
    } else {
        model_mod.clearFocus(m);
        return focus.prepareClearFocus();
    }
}

// ----------------------------------------------------------------- restore

/// Restores a specific minimized window (title-bar click path).
pub fn restore(win: model_mod.WindowId) void {
    if (!build_options.has_minimize) return;
    const m = pipeline.model();
    if (!isMinimizedOnAnyWs(m, win)) return;
    const had_occupant_before = if (build_options.has_fullscreen) @import("fullscreen").fullscreenOccupantOnWs(m, m.current) != null else false;
    if (build_options.has_minimize) @import("minimize").restore(m, win);
    restoreAndFocus(m, win);
    armFullscreenBarHideIfNeeded(m, win, had_occupant_before);
}

/// Slot-ordered single restore (LIFO/FIFO keybind paths).
pub fn restoreOrdered(order: model_mod.RestoreOrder) void {
    if (!build_options.has_minimize) return;
    const m = pipeline.model();
    const win = (if (build_options.has_minimize) @import("minimize").restoreCandidate(m, m.current, order) else null) orelse return;
    const had_occupant_before = if (build_options.has_fullscreen) @import("fullscreen").fullscreenOccupantOnWs(m, m.current) != null else false;
    if (build_options.has_minimize) @import("minimize").restore(m, win);
    restoreAndFocus(m, win);
    armFullscreenBarHideIfNeeded(m, win, had_occupant_before);
}

/// Slot-ordered bulk restore of the current workspace. Focus target is
/// the most recently minimized PLAIN window (legacy focuses plain_wins[last];
/// fullscreen-prev windows replay through the same reconcile's fullscreen
/// branch, straight back into fullscreen).
pub fn restoreAll() void {
    if (!build_options.has_minimize) return;
    const m = pipeline.model();
    const ws = m.current;
    const target = (if (build_options.has_minimize) @import("minimize").latestMinimizedBase(m, ws) else null) orelse return;
    const had_occupant_before = if (build_options.has_fullscreen) @import("fullscreen").fullscreenOccupantOnWs(m, ws) != null else false;
    if (build_options.has_minimize) @import("minimize").restoreAllOnWs(m, ws);
    restoreAndFocus(m, target);
    if (build_options.has_fullscreen) {
        if (@import("fullscreen").fullscreenOccupantOnWs(m, ws)) |occ| armFullscreenBarHideIfNeeded(m, occ, had_occupant_before);
    }
}

fn armFullscreenBarHideIfNeeded(m: *const model_mod.Model, win: model_mod.WindowId, had_occupant_before: bool) void {
    const is_fs = if (build_options.has_fullscreen) @import("fullscreen").isFullscreenOnWs(m, win, m.current) else false;
    if (build_options.has_bar and !had_occupant_before and is_fs) {
        for (window_mods) |wm| if (wm.armPendingBarHide) |f| f(win);
    }
}

fn isMinimizedOnAnyWs(m: *const model_mod.Model, win: model_mod.WindowId) bool {
    if (!build_options.has_minimize) return false;
    return @import("minimize").isMinimized(m, win);
}

fn restoreAndFocus(m: *model_mod.Model, win: model_mod.WindowId) void {
    model_mod.setFocus(m, win);
    const ft = focus.prepareFocus(win, .window_spawn);
    pipeline.reconcileUnderGrabNowWithFocus(.{ .force_restack = true }, ft);
}

// -------------------------------------------------------------- fullscreen

/// Fullscreen enter/exit/switch for an arbitrary window in ONE model
/// transition + ONE reconcile.
///
/// Legacy wire parity notes (fullscreen.zig full read, train-b precondition):
///  - winner: screen rect, bw=0, pixel=0, ABOVE merged, matching applyFullscreenGeometry.
///  - everyone else parked X+offscreen; the switch case's intermediate
///    "restore A then re-park A" round of requests collapses away.
///  - floating exit geometry: base.floating rect replays via LastSent diff.
///  - tiled exit: engine placements, matching retileCurrentWorkspace.
///
/// Bar hide/show deferral and EWMH stay protocol-side (R2), driven through the
/// window_modules registry's pending machinery so events.zig's ConfigureNotify
/// handler works unchanged. The keybind path resolves the focused window at
/// the dispatch site and lands here too.
pub fn fullscreenToggleWindow(win: model_mod.WindowId) void {
    const core = @import("core");
    if (!build_options.has_fullscreen) return;
    if (!core.getState().config.fullscreen_enabled) return;

    const m = pipeline.model();
    // Defense-in-depth parity with legacy toggle(): never fullscreen a window
    // off the viewed workspace (one path once corrupted workspaces doing so).
    if (!model_mod.visibleOn(m, win, m.current)) return;

    // Classify BEFORE toggling so bar deferrals match legacy timing exactly.
    // Cache the occupant scan; both the classification and prev_fs_win need
    // the same result, saving one full store scan.
    const prev_fs_win = if (build_options.has_fullscreen) @import("fullscreen").fullscreenOccupantOnWs(m, m.current) else null;
    const kind: enum { enter, exit, switch_ } = blk: {
        if (build_options.has_fullscreen) {
            if (@import("fullscreen").isFullscreenOnWs(m, win, m.current)) break :blk .exit;
        }
        if (prev_fs_win != null) break :blk .switch_;
        break :blk .enter;
    };

    if (build_options.has_fullscreen) {
        if (!@import("fullscreen").toggleFullscreen(m, win)) return;
    }

    // EWMH writes + bar arming land inside the same grab as geometry
    // (Gap 2 atomicity fix). All fire-and-forget or pure state.
    pipeline.reconcileUnderGrabNowFullscreen(
        .{ .force_restack = true },
        win,
        prev_fs_win,
        kind == .exit,
        kind == .switch_,
    );
}

// ------------------------------------------------- tag-move / pin / all-view

/// move_to_workspace (train e). Model moves mask + home list + fullscreen
/// record in one call; the reconcile's diff parks/repairs geometry globally
/// (legacy evictWindow + retileRedrawAndFlush collapse into it).
pub fn moveWindowTo(win: model_mod.WindowId, ws_idx: u8) void {
    const constants = @import("constants");
    if (!build_options.has_workspaces) return;
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.model();
    const was_focused = m.focused == win;
    const was_fs_current = if (build_options.has_fullscreen) @import("fullscreen").isFullscreenOnWs(m, win, m.current) else false;

    if (build_options.has_workspaces) @import("workspaces").moveWindowToWs(m, win, ws_idx);
    if (m.store.get(win) == null) return; // unknown window parity

    var ft: focus.FocusTransition = .none;
    if (ws_idx != m.current) {
        if (was_focused) ft = focusFallback(m);
        // Moving the current workspace's fullscreen window away changes the
        // workspace's fullscreen occupancy: bump the core fact; bar reacts.
        if (was_fs_current) @import("core").bumpFullscreen();
    }
    retileAndNotifyWithFocus(false, false, ft);
}

/// toggle_tag (Mod+Alt+N). Focus is left unchanged on add (multi-tag gesture);
/// removing the CURRENT tag evicts the window and re-focuses.
pub fn tagToggle(win: model_mod.WindowId, ws_idx: u8, protect_current: bool) void {
    const constants = @import("constants");
    if (!build_options.has_workspaces) return;
    if (ws_idx >= constants.max_workspaces) return;

    const m = pipeline.model();
    const e = m.store.get(win) orelse return;
    if (build_options.has_minimize) {
        if (@import("minimize").isMinimized(m, win)) return;
    }

    const had_bit = e.mask & model_mod.bit(ws_idx) != 0;
    const removing_current = ws_idx == m.current;

    var ft: focus.FocusTransition = .none;
    if (had_bit) {
        if (build_options.has_workspaces) {
            if (!@import("workspaces").tagRemove(m, win, ws_idx)) return; // last tag protected
        }
        if (removing_current and m.focused == win) ft = focusFallback(m);
    } else {
        if (build_options.has_workspaces) @import("workspaces").tagAdd(m, win, ws_idx, protect_current);
    }

    if (removing_current or (!had_bit and ws_idx == m.current)) {
        // Visible-set changed on the shown workspace: atomic evict/map+retile.
        pipeline.reconcileUnderGrabNowWithFocus(.{}, ft);
    }
    if (!removing_current) {
        // Off-workspace change: the tag set changed; bump the fact so the
        // workspace-aware consumers redraw.
        @import("core").bumpWindow();
    }
}

/// move_to_all_workspaces / toggle_tag_all: pinned <-> current-only.
pub fn pinToggle(win: model_mod.WindowId) void {
    if (!build_options.has_workspaces) return;
    const m = pipeline.model();
    if (m.store.get(win) == null) return; // unknown window parity
    if (build_options.has_minimize) {
        if (@import("minimize").isMinimized(m, win)) return;
    }
    if (build_options.has_workspaces) @import("workspaces").pinToggle(m, win);
    retileAndNotify(false, false);
}

/// all_workspaces (Mod+5): flag flip; sync maps foreign windows on enter and
/// parks them again on exit through the ordinary diff.
pub fn allViewToggle() void {
    if (!build_options.has_workspaces) return;
    const m = pipeline.model();
    const entering = if (build_options.has_workspaces) @import("workspaces").allViewToggle(m) else false;
    var ft: focus.FocusTransition = .none;
    if (!entering and m.focused != null and !model_mod.visibleOn(m, m.focused.?, m.current)) {
        ft = focusFallback(m);
    }
    retileAndNotifyWithFocus(true, false, ft);
}

// --------------------------------------------- tiling ops / drag (train f)

/// toggle_floating_window. Tiled->floating seeds the rect from the window's
/// current on-screen geometry (LastSent); floating->tiled re-enters the home
/// list at the master boundary via the ordinary engine order.
pub fn toggleFloating(win: model_mod.WindowId) void {
    const m = pipeline.model();
    const e = m.store.getPtr(win) orelse return;
    switch (e.mode) {
        .base => |b| switch (b) {
            .tiled => {
                const r = sync.lastRectFor(win) orelse return;
                e.mode = .{ .base = .{ .floating = r } };
                e.home_ws = null; // no longer in tiled_order
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
                    e.home_ws = h;
                }
            },
        },
        else => return,
    }
    retileAndNotify(true, false);
}

/// Drag tick (no grab; E.6): model rect is the single source of truth; sync
/// applies it conditionally against the sent ledger (only the dragged
/// window's geometry actually differs). Called from floating.zig's
/// updateDrag instead of its direct configureWindow when the flag is ON.
pub fn dragRect(win: model_mod.WindowId, r: @import("utils").Rect) void {
    if (!build_options.has_floating) return;
    const m = pipeline.model();
    if (build_options.has_floating) @import("floating").setFloatingRect(m, win, r);
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
    e.home_ws = null;
    pipeline.reconcileUnderGrabNow(.{});
}

// ------------------------------------ floating drag commands (uniform loop)
//
// Legacy loop-tier callers (input.zig button/motion dispatch, window.zig drag
// guards, bar.zig's dragging snapshot) no longer import floating.zig by name;
// that coupling runs through the build-generated `window_modules` registry via
// these thin command wrappers. Each is a uniform dispatch loop over the
// compiled-in sub-system set: a module that provides the hook runs it, and a
// tree without floating simply has no provider, so the loop no-ops; dropping
// floating.zig (and its entire subtree) leaves zero residue here.

/// Pointer-press drag begin (floating.startDrag).
pub fn startDrag(win: model_mod.WindowId, button: u8, x: i16, y: i16) void {
    for (window_mods) |m| if (m.startDrag) |f| f(win, button, x, y);
}

/// Drag end (floating.stopDrag): commits any in-flight detach/rect.
pub fn stopDrag() void {
    for (window_mods) |m| if (m.stopDrag) |f| f();
}

/// Motion tick during an active drag (floating.updateDrag).
pub fn updateDrag(x: i16, y: i16) void {
    for (window_mods) |m| if (m.updateDrag) |f| f(x, y);
}

/// Whether a floating drag/resize is currently in flight. In practice only
/// one module provides this hook, so the loop's first true wins, preserving
/// the old "true iff floating.isDragging()" semantics.
pub fn isDragging() bool {
    for (window_mods) |m| {
        if (m.isDragging) |f| {
            if (f()) return true;
        }
    }
    return false;
}

/// Whether `win` is the current resize target (drag guard).
pub fn isResizingWindow(win: model_mod.WindowId) bool {
    for (window_mods) |m| {
        if (m.isResizingWindow) |f| {
            if (f(win)) return true;
        }
    }
    return false;
}

/// Last committed drag rect, for resize-path geometry replay. Zero rect
/// fallback when no module provides the hook, matching the old no-floating
/// default.
pub fn getDragLastRect() @import("utils").Rect {
    for (window_mods) |m| {
        if (m.getDragLastRect) |f| return f();
    }
    return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
}

/// Cancels any active drag targeting `win` (unmanage path).
pub fn cancelDragForWindow(win: model_mod.WindowId) void {
    for (window_mods) |m| if (m.cancelDragForWindow) |f| f(win);
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

/// swap_master: focused <-> stack head. focus_swap variant moves focus to the
/// displaced window BEFORE the reconcile so monocle-style layouts render the
/// right window on the first pass (legacy defer semantics collapse).
pub fn swapMasterAction(focus_swap: bool) void {
    const m = pipeline.model();
    const list = &m.ws[m.current].tiled_order;
    if (list.items.len < 2) return;
    const displaced = list.items[0];
    model_mod.swapMaster(m);
    var ft: focus.FocusTransition = .none;
    if (focus_swap) {
        if (m.focused != null and m.focused.? != displaced) {
            model_mod.setFocus(m, displaced);
            ft = focus.prepareFocus(displaced, .tiling_operation);
        }
    }
    pipeline.reconcileUnderGrabNowWithFocus(.{}, ft);
}

pub fn moveFocused(delta: i32) void {
    const m = pipeline.model();
    const win = m.focused orelse return;
    const h = model_mod.findHome(m, win) orelse return;
    const idx = m.ws[h].tiled_order.indexOfScalar(win) orelse return;
    const next_i = @as(i64, @intCast(idx)) + delta;
    if (next_i < 0 or next_i >= m.ws[h].tiled_order.len) return;
    model_mod.reorderTiled(m, win, @intCast(next_i));
    pipeline.reconcileUnderGrabNow(.{});
}

/// scroll_view_left/right: one slot per step, clamped to content. The spawn
/// snap-right duty lives in preReconcileDuties (pipeline choke point).
pub fn scrollStep(dir: i32) void {
    if (!build_options.has_tiling) return;
    const m = pipeline.model();
    const p = &m.ws[m.current].params;
    if (p.kind != .scroll) return;
    if (!build_options.has_bar) return;
    const sc = scrollContext(m);
    p.scroll_offset += dir * sc.slot_w;
    p.scroll_offset = std.math.clamp(p.scroll_offset, 0, sc.max_off);
    p.scroll_prev_count = @intCast(sc.tiled_count);
    pipeline.reconcileUnderGrabNow(.{});
}

/// Focus-change scroll snap (port of tiling.snapScrollToFocused): shift
/// the viewport minimally so the focused window's slot is fully on-screen.
pub fn snapScrollToFocused() void {
    if (!build_options.has_tiling) return;
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

    const sc = scrollContext(m);
    const wa = screen.workArea(@import("core").getState().screen);
    const i64_slot_w: i64 = sc.slot_w;
    const slot_left = @as(i64, @intCast(i)) * i64_slot_w - p.scroll_offset;
    const slot_right = slot_left + i64_slot_w;
    if (slot_left < 0)
        p.scroll_offset = @intCast(@as(i64, @intCast(i)) * i64_slot_w)
    else if (slot_right > wa.width)
        p.scroll_offset = @intCast(@as(i64, @intCast(i)) * i64_slot_w + i64_slot_w - @as(i64, wa.width));
    p.scroll_offset = std.math.clamp(p.scroll_offset, 0, sc.max_off);
    p.scroll_prev_count = @intCast(n);
    pipeline.reconcileUnderGrabNow(.{});
}

const ScrollContext = struct {
    tiled_count: usize,
    slot_w: i32,
    max_off: i32,
};

fn scrollContext(m: *const model_mod.Model) ScrollContext {
    if (!build_options.has_tiling) return .{ .tiled_count = 0, .slot_w = 0, .max_off = 0 };
    if (!build_options.has_layout_scroll) return .{ .tiled_count = 0, .slot_w = 0, .max_off = 0 };
    const algo_scroll = if (build_options.has_layout_scroll) @import("scroll") else return .{ .tiled_count = 0, .slot_w = 0, .max_off = 0 };
    const n = model_mod.tiledCountOnWs(m, m.current);
    const wa = screen.workArea(@import("core").getState().screen);
    const slot_w = algo_scroll.slotWidth(wa.width);
    const max_off = algo_scroll.maxOffset(n, slot_w, wa.width);
    return .{ .tiled_count = n, .slot_w = slot_w, .max_off = max_off };
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
    if (!build_options.has_tiling) return;
    const types = @import("types");
    const constants = @import("constants");
    const cs = @import("core").getState();
    const cfg = &cs.config.tiling;
    const max_ws = constants.max_workspaces;

    const default_layout: types.Layout = @import("core").layoutFromString(cfg.layout) orelse @import("core").defaultLayout();

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
                    layout = @import("core").layoutFromString(cfg.layouts.items[o.layout_idx]) orelse default_layout;
                variant = o.variant;
            }
        }
        s.params.kind = layoutKindFromConfig(layout);
        // A variant override that doesn't belong to the workspace's active
        // layout is silently dropped by variantIdx; say so once per affected
        // workspace instead of failing invisibly.
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
/// (leavers park once, arrivers map+place; see sync_test's switch scenario).
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

    // Fire the pointer query BEFORE the grab so the round trip (client-side
    // _xcb_conn_wait / poll) happens outside the grab window. The cookie is
    // consumed INSIDE the grab; by then the reply is already in the XCB
    // receive buffer (the server processed it between queue and flush), so
    // consumption is a zero-latency buffer read.
    const pointer_cookie = xcb.xcb_query_pointer(core.getState().conn, core.getState().root);

    // All-view exit is a flag flip (emerges from visibility); temp-window
    // masks do not exist in the model.
    m.all_view_active = false;

    // model.current is the ONLY store for the current workspace; the
    // tracking/workspaces mirrors are deleted (read-through facades now).
    m.current = ws_idx;

    // Bump the window fact: the workspace indicator always changes on switch.
    // prepareClearFocus returns .none when last_applied is null (empty-to-empty
    // switch), so the focus fact alone can't guarantee a redraw; bumping the
    // window fact here makes the bar redraw at end-of-batch.
    @import("core").bumpWindow();
    // Bar visibility follows the NEW workspace's fullscreen occupant. Bump the
    // core fullscreen fact; the bar reacts and re-derives its claim. (Applied
    // before the reconcile batch below so the bar's drop of its claim is
    // visible to the placement that follows.)
    @import("core").bumpFullscreen();

    // Inline the server grab so pointer resolution, model focus, protocol
    // focus, and geometry all land atomically (Gap 4 atomicity fix).
    const c = pipeline.grabCtx();
    c.sink.grabServer();
    defer c.sink.ungrabAndFlush();

    // Consume the pipelined pointer cookie INSIDE the grab. The round trip
    // already completed before the grab; this is just a buffer read.
    const target: ?model_mod.WindowId = blk: {
        const cs = core.getState();
        const reply = xcb.xcb_query_pointer_reply(cs.conn, pointer_cookie, null);
        defer if (reply) |r| std.c.free(r);
        if (reply) |r| {
            const child = r.*.child;
            if (child != 0 and child != cs.root and model_mod.visibleOn(m, child, ws_idx)) {
                break :blk @as(?model_mod.WindowId, child);
            }
        }
        // Delegate to the model's tiered fallback (newest-first MRU, then
        // reversed tiled_order, then floating) — same policy as focusFallback.
        break :blk model_mod.fallbackFocusCandidate(m, ws_idx);
    };

    const ft: focus.FocusTransition = blk: {
        if (target) |t| {
            model_mod.setFocus(m, t);
            break :blk focus_mod.prepareFocus(t, .workspace_switch);
        } else {
            model_mod.clearFocus(m);
            break :blk focus_mod.prepareClearFocus();
        }
    };

    focus_mod.applyPendingFocus(ft);

    // force_restack raises the bar window.
    sync.reconcile(m, c, .{ .force_restack = true });
}

// ------------------------------------------------------- spawn/map lifecycle

/// MapRequest tail (train d). The legacy front-end (event masks, property
/// queries, size-hints cache) has already run; this registers the window in
/// the model and lets ONE reconcile do map+pixel+bw+geom(+ABOVE winner) for
/// on-current spawns. Off-current spawns park by construction; sync sends
/// their border width at first show instead of immediately (invisible either
/// way; one less request).
pub fn mapRequest(win: model_mod.WindowId, target_ws: u8, on_current: bool) void {
    const wincache = @import("wincache");

    const m = pipeline.model();
    if (m.store.has(win)) return; // double-manage guard parity

    // A defined refusal (store or home-list full) leaves the window
    // unmanaged, same observable outcome as the legacy full-pool path.
    model_mod.register(m, win, if (on_current) null else target_ws) catch {
        std.log.warn("mapRequest: capacity full; window 0x{x} left unmanaged", .{win});
        return;
    };
    // Bridge the cached WM_NORMAL_HINTS into the model entry at registration.
    const e = m.store.getPtr(win);
    if (e) |ep| ep.size_hints = wincache.peekHints(win);
    // Master-fifo variant spawn placement (moved out of model.register; it
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
    @import("core").bumpWindow(); // a window was admitted

    if (!on_current) return;

    // Model focus first so the reconcile below colors/stacks with the new
    // focus. X input focus AFTER reconcile (inside the same grab): the
    // window must be mapped before xcb_set_input_focus, and the map happens
    // during reconcile. Both map+focus land under one grab (Gap 3 fix).
    model_mod.setFocus(m, win);
    const ft = focus.prepareFocus(win, .window_spawn);
    pipeline.reconcileUnderGrabNowWithFocusAfter(.{}, ft);
}

/// Unmanage tail (train d): close/destroy/unmap of a managed window. Legacy
/// local bookkeeping (fullscreen record, caches, tiling/minimize/workspaces
/// removes) has already run; this drops the model entry and re-focuses.
/// Inactive-workspace geometry repairs ride the same global LastSent diff;
/// legacy's separate retileInactiveWorkspace call disappears.
pub fn unmanage(ctx: *Ctx, win: model_mod.WindowId) void {
    const m = pipeline.model();
    // Fullscreen and focus truth arrive via ctx: the sole caller (window.
    // unmanageWindow) removes the model entry (workspaces.removeWindow ->
    // unregister) BEFORE this action runs, so reading the store here could
    // never see either; closing the fullscreen occupant never restored the
    // bar, and the withdrawn window's focus ownership was unknowable.
    const was_fs_current = if (ctx.withdrawn_fullscreen_ws) |ws| ws == m.current else false;
    const was_focused = ctx.withdrawn_was_focused;

    model_mod.unregister(m, win);
    sync.forget(win); // X ids recycle; stale LastSent must not survive

    // Close fallback (parity with minimize): when the withdrawn window
    // held focus, hand it to the previously focused window on this ws
    // (MRU newest-first -> reversed tiled_order -> floating); with no
    // candidate left, focus clears. Model update runs before the grab;
    // protocol commit runs inside the grab (Gap 1 atomicity fix).
    const ft: focus.FocusTransition = if (was_focused) focusFallback(m) else .none;

    @import("core").bumpWindow(); // window removed; title segment drops it
    // Closing the current workspace's fullscreen occupant releases the area:
    // bump the core fact (bar reacts, re-derives its claim before the reconcile
    // below reads the work area).
    if (was_fs_current) @import("core").bumpFullscreen();

    pipeline.reconcileUnderGrabNowWithFocus(.{ .force_restack = true }, ft);
}
