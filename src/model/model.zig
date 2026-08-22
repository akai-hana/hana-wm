//! INVARIANT(P1): single source of truth for management state.
//! Layer rule: imports are std + utils + constants ONLY. No X11 access.
const std = @import("std");
const utils = @import("utils");
const constants = @import("constants");

pub const WindowId = u32;
/// Local alias so model never imports core. Convert core.WorkspaceId via
/// `.index` at entry points (refines decision C-D6).
pub const WSId = u16;
pub const Mask = u64;

pub inline fn bit(ws: WSId) Mask {
    return @as(Mask, 1) << @intCast(ws);
}

/// REUSE the exact identifier that exists in constants.zig for the max
/// workspace count (`max_workspaces`); if named differently there, alias it
/// here under MAX_WS without renaming the original.
const MAX_WS = constants.max_workspaces;
/// REUSE the exact identifier for the minimize capacity constant used by
/// legacy minimize.zig (`max_minimized`).
const MAX_MINIMIZED = constants.max_minimized;

pub const ALL_MASK: Mask = blk: {
    var m: Mask = 0;
    for (0..MAX_WS) |i| m |= @as(Mask, 1) << @intCast(i);
    break :blk m;
};

/// STRANGLER COPY: duplicate of layouts.SizeHints. Field-for-field identical;
/// pipeline converts between the two during migration (E.7). Do NOT import
/// layouts from here (layer rule).
pub const SizeHints = struct {
    max_width: u16 = 0, // PMaxSize
    max_height: u16 = 0,
    inc_width: u16 = 0, // PResizeInc: w = base_width + N * inc_width
    inc_height: u16 = 0,
    min_aspect: f32 = 0.0, // PAspect (dwm convention)
    max_aspect: f32 = 0.0,
};

pub const LayoutKind = enum { master, monocle, fibonacci, grid, leaf, scroll };

pub const LayoutParams = struct {
    kind: LayoutKind = .master,
    variant_idx: u8 = 0,
    master_width: f32 = 0.5,
    master_count: u8 = 1,
    stack_balance: f32 = 0,
    scroll_prev: ?WindowId = null, // decision C-D2
    /// Scroll viewport state (changelog 2026-08-22): model-owned so the
    /// layout engine stays pure. Legacy scroll.zig mutated its runtime state
    /// inside the retile; the snap-right-on-new-window and clamp duties now
    /// belong to callers (actions/sync, train steps e/f).
    scroll_offset: i32 = 0,
    scroll_prev_count: u32 = 0,
};

pub const BaseMode = union(enum) {
    /// Home workspace membership is DERIVED (exactly one ws.tiled_order list
    /// holds a tiled window; findHome). Visibility on other tagged workspaces
    /// is a sync-time mask filter (engine stays mask-agnostic).
    tiled,
    floating: utils.Rect,
};

/// Contract refinement vs §7.2 (changelog 2026-08-21): minimized stores the
/// ENTIRE previous mode plus its tiled slot, which preserves BC08 exactly
/// (restore pops straight back into fullscreen when that was prior).
pub const FullscreenPayload = struct { ws: WSId, base: BaseMode };

/// Previous-mode payload of minimized. Flattened one level (approved
/// 2026-08-22): a by-value recursive `prev: Mode` cannot compile, and the
/// recursion depth is provably <= 1 because minimize() only accepts
/// base/fullscreen states. Same information content as the spec's recursive
/// field; BC08 semantics unchanged.
pub const PrevMode = union(enum) {
    base: BaseMode,
    fullscreen: FullscreenPayload,
};

pub const MinimizedPayload = struct { prev: PrevMode, slot: ?usize, seq: u32 = 0 };

pub const Mode = union(enum) {
    base: BaseMode,
    fullscreen: FullscreenPayload,
    minimized: MinimizedPayload,
};

pub const Entry = struct {
    mask: Mask,
    mode: Mode,
    size_hints: SizeHints = .{},
};

pub const WsState = struct {
    tiled_order: std.ArrayListUnmanaged(WindowId) = .empty,
    focus_mru: std.ArrayListUnmanaged(WindowId) = .empty, // changelog 2026-08-21
    params: LayoutParams = .{},
};

pub const store_capacity = 512;
pub const mru_capacity = 16;
pub const StoreT = @import("store").Store(WindowId, Entry, store_capacity);

pub fn lowestBit(m: Mask) WSId {
    return @intCast(@ctz(m));
}

pub const Model = struct {
    gpa: std.mem.Allocator,
    store: StoreT = .{},
    ws: [MAX_WS]WsState = [_]WsState{.{}} ** MAX_WS,
    current: WSId = 0,
    focused: ?WindowId = null,
    all_view_active: bool = false,
    /// Monotonic minimize counter; stamps MinimizedPayload.seq so actions can
    /// pick LIFO/FIFO restore targets without a side buffer.
    next_seq: u32 = 0,
};

const Order = std.ArrayListUnmanaged(WindowId);

pub fn findInOrder(list: *const Order, win: WindowId) ?usize {
    for (list.items, 0..) |w, i| {
        if (w == win) return i;
    }
    return null;
}

fn removeValue(list: *Order, win: WindowId) void {
    if (findInOrder(list, win)) |i| _ = list.orderedRemove(i);
}

/// Public remove-by-value for facades (tracking focus-MRU purge paths).
pub fn removeValuePub(list: *Order, win: WindowId) void {
    removeValue(list, win);
}

/// The workspace whose tiled_order holds win (single-membership invariant).
pub fn findHome(m: *const Model, win: WindowId) ?WSId {
    for (&m.ws, 0..) |*s, i| {
        if (findInOrder(&s.tiled_order, win) != null) return @intCast(i);
    }
    return null;
}

fn baseOf(mode: Mode) BaseMode {
    return switch (mode) {
        .base => |b| b,
        .fullscreen => |f| f.base,
        .minimized => |mm| switch (mm.prev) {
            .base => |b| b,
            .fullscreen => |f| f.base,
        },
    };
}

fn countMinimized(m: *const Model) usize {
    var n: usize = 0;
    for (0..m.store.count()) |i| {
        if (m.store.at(i).val.mode == .minimized) n += 1;
    }
    return n;
}

fn removeFromMruAll(m: *Model, win: WindowId) void {
    for (&m.ws) |*s| removeValue(&s.focus_mru, win);
}

pub fn register(m: *Model, win: WindowId, hint_ws: ?WSId) void {
    if (m.store.has(win)) return;
    const target: WSId = hint_ws orelse m.current;
    // INVARIANT(I8): StoreFull ⇒ refuse BEFORE any mutation; roll back on OOM.
    _ = m.store.put(win, .{
        .mask = bit(target),
        .mode = .{ .base = .tiled },
    }) catch return;
    m.ws[target].tiled_order.append(m.gpa, win) catch {
        _ = m.store.remove(win);
        return;
    };
    // Master fifo variant (train g): a new window takes the master slot and
    // the previous master drops to the stack head. Legacy enforced this in
    // its spawn placement; the model path does it here so every caller gets
    // it for free.
    const p = &m.ws[target].params;
    if (p.kind == .master and p.variant_idx == 1 and m.ws[target].tiled_order.items.len > 1) {
        reorderTiled(m, win, 0);
    }
}

pub fn unregister(m: *Model, win: WindowId) void {
    _ = m.store.getPtr(win) orelse return;
    if (findHome(m, win)) |h| removeValue(&m.ws[h].tiled_order, win);
    removeFromMruAll(m, win);
    for (&m.ws) |*s| {
        if (s.params.scroll_prev == win) s.params.scroll_prev = null;
    }
    if (m.focused == win) m.focused = null;
    _ = m.store.remove(win);
}

pub const MinimizeError = error{CapacityFull};

pub fn minimize(m: *Model, win: WindowId) MinimizeError!void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mode == .minimized) return;
    // INVARIANT(I8): capacity check BEFORE any mutation (T17).
    if (countMinimized(m) >= MAX_MINIMIZED) return error.CapacityFull;
    var slot: ?usize = null;
    if (findHome(m, win)) |h| {
        slot = findInOrder(&m.ws[h].tiled_order, win);
        removeValue(&m.ws[h].tiled_order, win);
    }
    const prev: PrevMode = switch (e.mode) {
        .base => |b| .{ .base = b },
        .fullscreen => |f| .{ .fullscreen = f },
        .minimized => return, // guarded above; unreachable in practice
    };
    e.mode = .{ .minimized = .{ .prev = prev, .slot = slot, .seq = m.next_seq } };
    m.next_seq += 1;
}

pub fn restore(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mode != .minimized) return;
    const mm = e.mode.minimized;
    // Only tiled-prev windows re-enter a home list (fix P2-7): floating-prev
    // restores to its saved rect directly; appending it would create a
    // phantom layout member that shifts every other window's slot.
    if (mm.prev == .base and mm.prev.base == .tiled) {
        const h: WSId = lowestBit(e.mask); // follows tag-moves made while hidden (BC12)
        const list = &m.ws[h].tiled_order;
        list.append(m.gpa, win) catch return;
        if (mm.slot) |s| {
            const last = list.items.len - 1;
            if (s < last) {
                _ = list.orderedRemove(last);
                list.insert(m.gpa, s, win) catch {};
            }
        }
    }
    e.mode = switch (mm.prev) {
        .base => |b| .{ .base = b },
        .fullscreen => |f| .{ .fullscreen = f },
    };
}

fn slotLess(a: ?usize, b: ?usize) bool {
    if (a == null) return false;
    if (b == null) return true;
    return a.? < b.?;
}

/// Restore-order target selection over minimized windows on `ws` (BC06/BC07):
/// `.fifo` = oldest minimize seq, `.lifo` = newest. Returns null when nothing
/// on `ws` is minimized.
pub fn restoreCandidate(m: *const Model, ws: WSId, order: RestoreOrder) ?WindowId {
    var best: ?WindowId = null;
    var best_seq: u32 = 0;
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.mode != .minimized) continue;
        if (it.val.mask & bit(ws) == 0) continue;
        const seq = it.val.mode.minimized.seq;
        const better = switch (order) {
            .fifo => best == null or seq < best_seq,
            .lifo => best == null or seq > best_seq,
        };
        if (better) {
            best = it.key;
            best_seq = seq;
        }
    }
    return best;
}

pub const RestoreOrder = enum { lifo, fifo };

/// Most recently minimized PLAIN window on `ws` (BC09 focus target: legacy
/// focuses plain_wins[last]; fullscreen-prev windows are excluded).
pub fn latestMinimizedBase(m: *const Model, ws: WSId) ?WindowId {
    var best: ?WindowId = null;
    var best_seq: u32 = 0;
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.mode != .minimized) continue;
        if (it.val.mask & bit(ws) == 0) continue;
        if (it.val.mode.minimized.prev != .base) continue;
        if (best == null or it.val.mode.minimized.seq > best_seq) {
            best = it.key;
            best_seq = it.val.mode.minimized.seq;
        }
    }
    return best;
}

pub fn restoreAllOnWs(m: *Model, ws: WSId) void {
    var wins: [MAX_MINIMIZED]WindowId = undefined;
    var slots: [MAX_MINIMIZED]?usize = undefined;
    var n: usize = 0;
    for (0..m.store.count()) |i| {
        const it = m.store.at(i);
        if (it.val.mode == .minimized and it.val.mask & bit(ws) != 0) {
            wins[n] = it.key;
            slots[n] = it.val.mode.minimized.slot;
            n += 1;
        }
    }
    // insertion sort by slot ascending, nulls last (BC09)
    for (1..n) |a| {
        const w = wins[a];
        const s = slots[a];
        var b = a;
        while (b > 0 and slotLess(s, slots[b - 1])) : (b -= 1) {
            wins[b] = wins[b - 1];
            slots[b] = slots[b - 1];
        }
        wins[b] = w;
        slots[b] = s;
    }
    for (0..n) |i| restore(m, wins[i]);
}

pub fn toggleFullscreen(m: *Model, win: WindowId) bool {
    const e = m.store.getPtr(win) orelse return false;
    switch (e.mode) {
        .base => |b| {
            e.mode = .{ .fullscreen = .{ .ws = m.current, .base = b } };
            return true;
        },
        .fullscreen => |f| {
            e.mode = .{ .base = f.base };
            return true;
        },
        .minimized => return false,
    }
}

pub fn switchTo(m: *Model, ws: WSId) void {
    m.current = ws;
}

pub fn moveWindowToWs(m: *Model, win: WindowId, ws: WSId) void {
    const e = m.store.getPtr(win) orelse return;
    if (e.mask == ALL_MASK) return; // pinned stays everywhere-visible
    if (e.mode == .minimized) {
        e.mask = bit(ws); // BC12: record follows the move
        return;
    }
    // Fullscreen record follows the move (legacy transferFullscreenRecord);
    // destination occupied ⇒ drop this one rather than clobber the resident.
    if (e.mode == .fullscreen and e.mode.fullscreen.ws != ws) {
        var occupied = false;
        for (0..m.store.count()) |i| {
            const it = m.store.at(i);
            if (it.key == win) continue;
            if (it.val.mode == .fullscreen and it.val.mode.fullscreen.ws == ws) occupied = true;
        }
        if (occupied) {
            e.mode = .{ .base = e.mode.fullscreen.base };
        } else {
            e.mode.fullscreen.ws = ws;
        }
    }
    e.mask = bit(ws);
    if (findHome(m, win)) |h| {
        if (h != ws) {
            removeValue(&m.ws[h].tiled_order, win);
            m.ws[ws].tiled_order.append(m.gpa, win) catch {};
        }
    }
}

/// Remove tag `ws`; the last remaining tag is protected (returns false).
/// Fullscreen-on-removed-ws transfers to the lowest remaining bit, or drops
/// when that destination is occupied (legacy transferFullscreenRecord).
pub fn tagRemove(m: *Model, win: WindowId, ws: WSId) bool {
    const e = m.store.getPtr(win) orelse return false;
    if (@popCount(e.mask) <= 1) return false;
    e.mask &= ~bit(ws);
    if (e.mode == .fullscreen and e.mode.fullscreen.ws == ws) {
        const dest = lowestBit(e.mask);
        var occupied = false;
        for (0..m.store.count()) |i| {
            const it = m.store.at(i);
            if (it.key == win) continue;
            if (it.val.mode == .fullscreen and it.val.mode.fullscreen.ws == dest) occupied = true;
        }
        if (occupied) {
            e.mode = .{ .base = e.mode.fullscreen.base };
        } else {
            e.mode.fullscreen.ws = dest;
        }
    }
    return true;
}

pub fn tagAdd(m: *Model, win: WindowId, ws: WSId, protect_current: bool) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask |= bit(ws);
    if (protect_current) e.mask |= bit(m.current);
}

pub fn pinToggle(m: *Model, win: WindowId) void {
    const e = m.store.getPtr(win) orelse return;
    e.mask = if (e.mask == ALL_MASK) bit(m.current) else ALL_MASK;
}

pub fn allViewToggle(m: *Model) bool {
    m.all_view_active = !m.all_view_active;
    return m.all_view_active;
}

pub fn reorderTiled(m: *Model, win: WindowId, idx_in: usize) void {
    const h = findHome(m, win) orelse return;
    const list = &m.ws[h].tiled_order;
    const from = findInOrder(list, win) orelse return;
    const idx = @min(idx_in, list.items.len - 1);
    _ = list.orderedRemove(from);
    list.insert(m.gpa, idx, win) catch {};
}

pub fn swapMaster(m: *Model) void {
    const list = &m.ws[m.current].tiled_order;
    if (list.items.len < 2) return;
    const tmp = list.items[0];
    list.items[0] = list.items[1];
    list.items[1] = tmp;
}

pub fn cycleLayout(m: *Model, dir: i32) void {
    const p = &m.ws[m.current].params;
    const n: i32 = @typeInfo(LayoutKind).@"enum".fields.len;
    const cur: i32 = @intCast(@intFromEnum(p.kind));
    var next = @mod(cur + dir, n);
    if (next < 0) next += n;
    p.kind = @enumFromInt(@as(u3, @intCast(next)));
    p.variant_idx = 0;
}

/// Variant count per layout kind (caller-side variant resolution, §7.4
/// step 3): master lifo/fifo, monocle gapless/gaps, grid rigid/relaxed;
/// the rest have exactly one.
pub fn variantCount(kind: LayoutKind) u8 {
    return switch (kind) {
        .master, .monocle, .grid => 2,
        else => 1,
    };
}

pub fn adjustMasterWidth(m: *Model, delta: f32) void {
    const p = &m.ws[m.current].params;
    p.master_width = std.math.clamp(p.master_width + delta, 0.05, 0.95);
}

pub fn setFloatingRect(m: *Model, win: WindowId, r: utils.Rect) void {
    const e = m.store.getPtr(win) orelse return;
    switch (e.mode) {
        .base => |*bm| switch (bm.*) {
            .floating => |*fr| fr.* = r,
            .tiled => {},
        },
        else => {},
    }
}

pub const ConfigureReq = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
};

pub const HonorDecision = enum { geometry_applied, border_only, ignored };

pub fn honorConfigureRequest(m: *Model, win: WindowId, req: ConfigureReq) HonorDecision {
    const e = m.store.getPtr(win) orelse return .ignored;
    switch (e.mode) {
        .base => |*bm| switch (bm.*) {
            .floating => |*r| {
                if (req.x) |v| r.x = v;
                if (req.y) |v| r.y = v;
                if (req.width) |v| r.width = v;
                if (req.height) |v| r.height = v;
                return .geometry_applied;
            },
            .tiled => {
                // Geometry denied. BW honored; recording is SYNC's job (P5/I5).
                if (req.border_width != null) return .border_only;
                return .ignored;
            },
        },
        .fullscreen => return .ignored,
        .minimized => return .ignored,
    }
}

pub fn applyConfigReload(m: *Model, tpl: LayoutParams) void {
    for (&m.ws) |*s| {
        const keep_prev = s.params.scroll_prev;
        s.params = tpl;
        s.params.scroll_prev = keep_prev;
    }
}

pub fn setFocus(m: *Model, win: WindowId) void {
    _ = m.store.getPtr(win) orelse return;
    m.focused = win;
    const list = &m.ws[m.current].focus_mru;
    removeValue(list, win);
    list.insert(m.gpa, 0, win) catch {};
    if (list.items.len > mru_capacity) list.shrinkRetainingCapacity(mru_capacity);
    if (m.ws[m.current].params.kind == .scroll) {
        m.ws[m.current].params.scroll_prev = win; // decision C-D2
    }
}

/// Model-side focus drop (minimize/close with no eligible successor).
pub fn clearFocus(m: *Model) void {
    m.focused = null;
}

pub fn visibleOn(m: *const Model, win: WindowId, ws: WSId) bool {
    const e = m.store.get(win) orelse return false;
    if (e.mode == .minimized) return false;
    if (m.all_view_active) return true;
    return e.mask & bit(ws) != 0;
}
