//! Pure focus SELECTION and the model-side focus writers. Everything here
//! takes the model (or reads it through the caller) and touches no X and no
//! live pipeline state: the protocol side (focus.zig) binds these to the
//! live model/focus reads at its commit points. Kept beside `query.zig`:
//! both are the state/ half of the window layer — light, importable without
//! dragging the focus protocol's X chain.

const std = @import("std");
const model_mod = @import("model");
const types = @import("types");

/// Writes `win` as the model's focused window and moves it to the front of
/// the focus MRU. Unknown windows are ignored.
pub fn setFocus(m: *model_mod.Model, win: model_mod.WindowId) void {
    if (!m.store.has(win)) return;
    m.focused = win;
    const list = &m.ws[m.current.index].focus_mru;
    // Re-focusing an already-tracked window moves it to the front WITHOUT
    // spending an eviction, so the newest `mru_capacity` DISTINCT windows
    // are the ones retained. One call, so the order (evict, then insert)
    // cannot be transposed at the call site.
    const already = list.removeValue(win);
    if (!already) _ = list.pushFrontEvictingTail(win) else _ = list.insert(0, win);
}

/// Model-side focus drop (minimize/close with no eligible successor).
pub fn clearFocus(m: *model_mod.Model) void {
    m.focused = null;
}

/// The ONE focused/unfocused border-pixel pick: the focus state is what the
/// pick reads, so it sits with the focus writers. A second copy of the same
/// ternary in the window layer could drift from this one and nothing would
/// notice. `m` supplies the focus source so the caller cannot pass an answer
/// that differs from `m.focused`.
pub inline fn focusedBorderColor(m: *const model_mod.Model, win: model_mod.WindowId, focused_px: u32, unfocused_px: u32) u32 {
    return if (m.focused == win) focused_px else unfocused_px;
}

/// Whether `cand` is eligible as a focus-fallback candidate on `ws`: not
/// the `excluded` window, and visible there (parked entries fail
/// visibleOn). Tier-specific extra criteria stay at each tier's call site.
fn qualifies(m: *const model_mod.Model, cand: model_mod.WindowId, ws: model_mod.WSId, excluded: ?model_mod.WindowId) bool {
    if (cand == excluded) return false;
    return model_mod.visibleOn(m, cand, ws);
}

/// The most recently focused window on `ws` other than `focused` that can
/// still take focus there: focus MRU newest first, skipping `focused` and
/// every entry that is not visible on `ws` (parked/minimized, or moved to
/// another workspace). Null when no earlier visible window remains. This is
/// the "previously focused" answer for swap_master focus_swap; unlike the
/// minimize fallback it does not widen the scan to never-focused windows.
pub fn previousFocusCandidate(m: *const model_mod.Model, ws: model_mod.WSId, focused: model_mod.WindowId) ?model_mod.WindowId {
    const mru = &m.ws[ws.index].focus_mru;
    for (mru.constSlice()) |cand| {
        if (cand == focused) continue;
        if (model_mod.visibleOn(m, cand, ws)) return cand;
    }
    return null;
}

/// Minimize-fallback target policy. Tier order on workspace `ws`: focus MRU
/// (newest first), reversed tiled_order, then any visible floating-base
/// window not in tiled_order. First `visibleOn(ws)` candidate wins; null
/// when nothing qualifies. `excluded` is a candidate the caller already
/// rejected (e.g. a no_input window that can never hold X focus) — it is
/// skipped across all tiers so the caller can re-scan.
pub fn fallbackFocusCandidate(m: *const model_mod.Model, ws: model_mod.WSId, excluded: ?model_mod.WindowId) ?model_mod.WindowId {
    // 1. focus MRU, newest first (mru[0] is the MOST RECENT focus, so
    //    minimizing the focused window falls back to the previously focused
    //    one). visibleOn rejects parked entries, including the just-parked
    //    window itself.
    const mru = &m.ws[ws.index].focus_mru;
    for (mru.constSlice()) |cand| {
        if (qualifies(m, cand, ws, excluded)) return cand;
    }
    // 2. reversed tiled_order.
    var j = m.ws[ws.index].tiled_order.len;
    while (j > 0) {
        j -= 1;
        const cand = m.ws[ws.index].tiled_order.items[j];
        if (qualifies(m, cand, ws, excluded)) return cand;
    }
    // 3. any floating window on the workspace (base geometry, not in
    //    tiled_order). A covering window owns the screen, so it is not a
    //    fallback target. Linear membership check per floating entry; adequate
    //    for <50 windows.
    var it = m.store.iterator();
    while (it.next()) |row| {
        if (row.val.anchor != .floating or row.val.presence == .covering) continue;
        if (row.key == excluded or !model_mod.visibleEntry(m, row.val, ws)) continue;
        if (m.ws[ws.index].tiled_order.indexOfScalar(row.key) == null) return row.key;
    }
    return null;
}

/// The visible windows of `ws` in ON-SCREEN order, for focus cycling: writes
/// them into `buf` and returns the count (0 when `buf` is empty). Ordered by
/// layout, not by window id, because the cycle must follow the arrangement:
/// `ws`'s tiled_order first (master slots lead, stack follows), then the
/// visible windows with no tiled slot here — floating ones and multi-tagged
/// windows homed on another workspace — in store order. A covering occupant
/// collapses the pool to that one window. `seen` marks store slots already
/// admitted, so the two passes can't double-admit a window.
pub fn collectCyclePool(m: *const model_mod.Model, ws: model_mod.WSId, buf: []model_mod.WindowId) usize {
    if (model_mod.coveringOccupantOn(m, ws, .anchored_or_visible)) |occ| {
        if (buf.len == 0) return 0;
        buf[0] = occ;
        return 1;
    }
    var seen: [model_mod.store_capacity]bool = [_]bool{false} ** model_mod.store_capacity;
    var n: usize = 0;
    // Pass 1: the shown workspace's tiled order == screen order. indexOf
    // locates the store row, at() reads it -- one search per window.
    for (m.ws[ws.index].tiled_order.constSlice()) |w| {
        if (n == buf.len) break;
        const slot = m.store.indexOf(w) orelse continue;
        const e = m.store.at(slot).val;
        if (!model_mod.visibleEntry(m, e, ws)) continue;
        seen[slot] = true;
        buf[n] = w;
        n += 1;
    }
    // Pass 2: the untiled tail, after the tiled run. Store order, so floating
    // windows keep a stable order among themselves.
    for (0..m.store.count()) |slot| {
        if (n == buf.len) break;
        if (seen[slot]) continue;
        const row = m.store.at(slot);
        if (!model_mod.visibleEntry(m, row.val, ws)) continue;
        buf[n] = row.key;
        n += 1;
    }
    return n;
}

/// Resolve the visible window a focus-cycle step would land on, or null when
/// the step is a no-op (no visible windows, or the only visible window is
/// already focused). Pure read: no focus change, no grab. `focused` is the
/// caller's current focus (the protocol side passes its live read; tests
/// pass one they control), so this function never touches the pipeline
/// singleton. The pool comes from `collectCyclePool`, which anchors the
/// cycle on tiled_order — so Mod+j/k follows the arrangement and a
/// move/swap reorders the cycle with it.
pub fn cycleTarget(m: *const model_mod.Model, focused: ?model_mod.WindowId, dir: types.Dir) ?model_mod.WindowId {
    const forward = dir == .forward;
    // Caller-owned scratch, like every other snapshot buffer in this layer
    // (query.zig).
    var buf: [model_mod.store_capacity]model_mod.WindowId = undefined;
    const len = collectCyclePool(m, m.current, &buf);
    if (len == 0) return null;
    const wins = buf[0..len];
    // Single visible window: the only sensible cycle step is to focus it
    // when it isn't focused already; the modulo wrap below would otherwise
    // spin a redundant grabFocus against the same id.
    if (len == 1) {
        const only = wins[0];
        return if (focused == only) null else only;
    }
    // When the focused window isn't in the visible list, wrap so the very
    // next step lands on wins[0] (forward) or wins[len-1] (backward).
    const sentinel: usize = if (forward) len - 1 else 0;
    const idx = if (focused) |w|
        std.mem.indexOfScalar(model_mod.WindowId, wins, w) orelse sentinel
    else
        sentinel;
    return wins[model_mod.wrapIndex(idx, if (forward) 1 else -1, len)];
}
