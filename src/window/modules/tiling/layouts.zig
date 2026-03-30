//! Shared layout infrastructure: geometry constraints, window data cache, and
//! the `configureSafe` entry point used by every layout module.
//!
//! This file is deliberately free of layout-specific knowledge. It defines the
//! types and helpers that are *passed into* layout modules, keeping each layout
//! decoupled from both each other and from the tiling state.

const core  = @import("core");
const xcb   = core.xcb;
const utils = @import("utils");
const debug = @import("debug");

// ============================================================================
// WM_NORMAL_HINTS size constraint cache
//
// Populated from WM_NORMAL_HINTS during handleMapRequest; evicted on unmanage.
// `configureSafe` clamps every rect to stored minimums so terminals always
// receive a geometry they can render.
//
// Implemented as a flat array with a linear scan. Realistic window counts
// (10–80) make a HashMap's O(1) lookup theoretical rather than measurable:
// a linear scan over a handful of cache lines is faster in practice and
// carries zero allocation overhead, no deinit, and no partial-failure states.
// ============================================================================

/// ICCCM WM_NORMAL_HINTS geometry constraints for a single window.
pub const SizeHints = struct {
    min_width:  u16 = 0,
    min_height: u16 = 0,
    /// PMaxSize: upper bounds on window dimensions.
    /// 0 means unconstrained (no max declared by the client).
    max_width:  u16 = 0,
    max_height: u16 = 0,
    /// PResizeInc: dimensions must satisfy w = min_width + N * inc_width.
    /// 0 means unconstrained (no increment declared by the client).
    inc_width:  u16 = 0,
    inc_height: u16 = 0,
    /// PAspect: aspect ratio bounds (dwm convention).
    /// 0.0 means unconstrained (no aspect hint declared by the client).
    min_aspect: f32 = 0.0,
    max_aspect: f32 = 0.0,
};

const hint_table_capacity: usize = 256;
const HintEntry = struct { win: u32, hints: SizeHints };

var hints_buf: [hint_table_capacity]HintEntry = undefined;
var hints_len: usize = 0;

/// Store WM_NORMAL_HINTS constraints for `win`.
/// No-ops when all hint fields are zero — the client published an empty atom.
/// Updates in-place when an entry already exists (e.g. the client re-set hints).
pub fn cacheSizeHints(win: u32, hints: SizeHints) void {
    if (isEmptySizeHints(hints)) return;

    for (hints_buf[0..hints_len]) |*e| {
        if (e.win == win) { e.hints = hints; return; }
    }
    if (hints_len >= hint_table_capacity) {
        debug.err("cacheSizeHints: hint table full, dropping hints for 0x{x}", .{win});
        return;
    }
    hints_buf[hints_len] = .{ .win = win, .hints = hints };
    hints_len += 1;
}

/// Remove the size-hint entry for `win`. Called at unmanage time.
pub fn evictSizeHints(win: u32) void {
    for (hints_buf[0..hints_len], 0..) |e, i| {
        if (e.win != win) continue;
        // Swap-and-decrement: O(1), order-independent.
        hints_buf[i] = hints_buf[hints_len - 1];
        hints_len -= 1;
        return;
    }
}

// ============================================================================
// Per-window geometry and border-color cache
//
// Stores the last-applied geometry and border color for each window in a single
// flat array. `configureSafe` writes `.rect`; `applyBorderColor` writes
// `.border`. Both fields share one entry and one linear scan, eliminating
// any two-path synchronisation concern.
//
// Why not AutoHashMap?
//   n is bounded by open windows — realistic: 10–80; hard cap: cache_capacity.
//   At that scale a linear scan over contiguous memory is faster than a hash
//   probe (cache locality beats asymptotic complexity). The flat array also
//   eliminates every structural cost HashMap carries:
//     - No heap allocation; no deinit; no error path in getOrPut.
//     - clearRetainingCapacity reduces to a single `len = 0` assignment.
//     - No allocation-failure fallback paths that leave cache partially filled.
// ============================================================================

/// Combined per-window cache entry holding last geometry and last border color.
pub const WindowData = struct {
    /// A zeroed rect is the sentinel for "stale / not yet computed".
    /// The layout engine never produces a 0×0 rect, so the sentinel is
    /// unambiguous. Prefer `hasValidRect()` over open-coding the checks.
    rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    border: u32 = 0,

    /// Returns false when the rect is zeroed, indicating the entry is stale or
    /// has not yet been populated by a retile pass.
    pub fn hasValidRect(self: WindowData) bool {
        return self.rect.width != 0 or self.rect.height != 0;
    }
};

const cache_capacity: usize = 256;

/// Overflow sentinel used by `CacheMap.getOrPut` when the hard cap is exceeded.
///
/// Returning a pointer to this throwaway slot lets every call-site proceed
/// without a null-check while guaranteeing no live cache entry is corrupted.
/// The affected window simply misses the dedup check and receives a redundant
/// configure_window on the next retile — an unconditionally correct outcome.
var overflow_sentinel: WindowData = .{};

/// Fixed-capacity cache mapping window IDs to their last geometry and border color.
pub const CacheMap = struct {
    const Entry = struct { win: u32, data: WindowData };

    pub const GetOrPutResult = struct {
        found_existing: bool,
        value_ptr: *WindowData,
    };

    buf: [cache_capacity]Entry = undefined,
    len: usize = 0,

    /// Locate the entry for `win`, creating one if absent. Always succeeds —
    /// no allocator, no error union. When the buffer is full the write is
    /// routed to the module-level overflow sentinel (no live entry is corrupted)
    /// and a debug error is logged; this is a hard-cap violation that should
    /// never occur in normal use.
    pub fn getOrPut(self: *CacheMap, win: u32) GetOrPutResult {
        for (self.buf[0..self.len]) |*e| {
            if (e.win == win) return .{ .found_existing = true, .value_ptr = &e.data };
        }
        if (self.len < cache_capacity) {
            self.buf[self.len] = .{ .win = win, .data = .{} };
            const value_ptr = &self.buf[self.len].data;
            self.len += 1;
            return .{ .found_existing = false, .value_ptr = value_ptr };
        }
        debug.err("CacheMap: capacity exceeded, dropping cache for 0x{x}", .{win});
        overflow_sentinel = .{};
        return .{ .found_existing = false, .value_ptr = &overflow_sentinel };
    }

    pub fn get(self: *const CacheMap, win: u32) ?WindowData {
        return if (@constCast(self).findEntry(win)) |e| e.data else null;
    }

    pub fn getPtr(self: *CacheMap, win: u32) ?*WindowData {
        return if (self.findEntry(win)) |e| &e.data else null;
    }

    /// Swap-and-decrement removal: O(1), order-independent.
    pub fn remove(self: *CacheMap, win: u32) void {
        for (self.buf[0..self.len], 0..) |e, i| {
            if (e.win != win) continue;
            self.buf[i] = self.buf[self.len - 1];
            self.len -= 1;
            return;
        }
    }

    /// Reset the cache to empty. The backing buffer is left untouched;
    /// only the fill counter is zeroed. O(1).
    pub fn clearRetainingCapacity(self: *CacheMap) void {
        self.len = 0;
    }

    fn findEntry(self: *CacheMap, win: u32) ?*Entry {
        for (self.buf[0..self.len]) |*e| if (e.win == win) return e;
        return null;
    }
};

// ============================================================================
// Layout context and the configureSafe entry point
// ============================================================================

/// Context passed into every layout module's `tileWithOffset` call.
///
/// Carries the XCB connection and geometry cache by pointer so layout modules
/// do not depend on module-level globals, making their dependencies explicit
/// and their behaviour independently verifiable.
pub const LayoutCtx = struct {
    conn: *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache. Always non-null during a retile pass.
    cache: *CacheMap,
    /// When non-null, `configureSafe` emits a border-color change in the same
    /// cache scan, eliminating the separate updateBorders pass and halving the
    /// number of linear searches over CacheMap per window per retile.
    /// Set by `buildLayoutCtx` during a normal retile; null in contexts that
    /// do not have focus/border information (e.g. direct utils.configureWindow
    /// calls in restoreWorkspaceGeom).
    get_border_color: ?*const fn (win: u32) u32 = null,
};

/// Returns true when both rects have identical coordinates and dimensions.
pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

/// Apply geometry to `win`, clamped to its WM_NORMAL_HINTS constraints.
///
/// Skips the XCB round-trip when the computed rect matches the cached value,
/// deduplicating configure_window calls across retile passes. When the
/// LayoutCtx provides a `get_border_color` callback, the border color is also
/// updated in the same cache scan at zero additional search cost.
pub fn configureSafe(
    ctx: *const LayoutCtx,
    win: u32,
    rect: utils.Rect,
) void {
    const effective = clampRectToSizeHints(win, rect);

    if (!effective.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}",
            .{ win, effective.width, effective.height, effective.x, effective.y });
        return;
    }

    const gop = ctx.cache.getOrPut(win);
    const is_rect_changed = !gop.found_existing or !rectsEqual(gop.value_ptr.rect, effective);
    if (is_rect_changed) {
        gop.value_ptr.rect = effective;
        utils.configureWindow(ctx.conn, win, effective);
    }

    const getBorderColor = ctx.get_border_color orelse return;
    const color = getBorderColor(win);
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    _ = xcb.xcb_change_window_attributes(ctx.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

// ============================================================================
// Private helpers
// ============================================================================

/// Clamp `rect` to the stored WM_NORMAL_HINTS for `win`.
/// Returns `rect` unchanged when no hints are stored for `win`.
fn clampRectToSizeHints(win: u32, rect: utils.Rect) utils.Rect {
    for (hints_buf[0..hints_len]) |e| {
        if (e.win == win) return applyHintsToRect(rect, e.hints);
    }
    return rect;
}

/// Apply all ICCCM §4.1.2.3 hint passes in order to a raw rect.
fn applyHintsToRect(rect: utils.Rect, h: SizeHints) utils.Rect {
    // Pass 1: Clamp to declared minimum.
    var w:  u16 = @max(rect.width,  h.min_width);
    var ht: u16 = @max(rect.height, h.min_height);

    // Pass 2: Snap to resize increments.
    //   effective = base + floor((dim - base) / inc) * inc
    w  = snapDimToIncrement(w,  h.min_width,  h.inc_width);
    ht = snapDimToIncrement(ht, h.min_height, h.inc_height);

    // Pass 3: Clamp to declared maximum (after increment snap so we never
    //   exceed the max even after rounding up to the next increment).
    if (h.max_width  > 0) w  = @min(w,  h.max_width);
    if (h.max_height > 0) ht = @min(ht, h.max_height);

    // Pass 4: Aspect ratio (ICCCM §4.1.2.3, matching dwm's applysizehints).
    //   min_aspect = min_aspect.y / min_aspect.x — lower bound on h/w
    //   max_aspect = max_aspect.x / max_aspect.y — upper bound on w/h
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(ht);
        if (h.max_aspect < fw / fh) {
            w = @intFromFloat(@round(fh * h.max_aspect));
            if (h.max_width > 0) w = @min(w, h.max_width);
        } else if (h.min_aspect < fh / fw) {
            ht = @intFromFloat(@round(fw * h.min_aspect));
            if (h.max_height > 0) ht = @min(ht, h.max_height);
        }
    }

    return .{ .x = rect.x, .y = rect.y, .width = w, .height = ht };
}

/// Snap `dim` to the nearest multiple of `inc` above `base`.
/// Returns `dim` unchanged when `inc` is zero or dim does not exceed `base`.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const excess = dim - base;
    return base + (excess / inc) * inc;
}

inline fn isEmptySizeHints(h: SizeHints) bool {
    return h.min_width == 0 and h.min_height == 0 and
           h.max_width == 0 and h.max_height == 0 and
           h.inc_width == 0 and h.inc_height == 0 and
           h.min_aspect == 0.0 and h.max_aspect == 0.0;
}
