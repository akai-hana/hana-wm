//! Shared layout infrastructure: geometry constraints, window data cache, and
//! the `configureWithHints` entry point used by every layout module.
//!
//! This file is deliberately free of layout-specific knowledge. It defines the
//! types and helpers that are *passed into* layout modules, keeping each layout
//! decoupled from both each other and from the tiling state.
//!
//! Performance note: WM_NORMAL_HINTS constraints (SizeHints) are embedded
//! directly inside each CacheMap slot alongside the geometry and border color.
//! `configureWithHints` performs a single O(1) hash probe per window per retile,
//! making the full retile pass O(N) in the number of open windows.

const std     = @import("std");
const core    = @import("core");
    const xcb = core.xcb;
const utils   = @import("utils");

const debug = @import("debug");


// WM_NORMAL_HINTS size constraint cache
//
// Populated from WM_NORMAL_HINTS during handleMapRequest; evicted on unmanage.
// `configureWithHints` clamps every rect to stored minimums so terminals always
// receive a geometry they can render.
//
// Implemented as a flat array with a linear scan. Realistic window counts
// (10–80) make a HashMap's O(1) lookup theoretical rather than measurable:
// a linear scan over a handful of cache lines is faster in practice and
// carries zero allocation overhead, no deinit, and no partial-failure states.

/// ICCCM WM_NORMAL_HINTS geometry constraints for a single window.
pub const SizeHints = struct {
    /// PMaxSize: upper bounds on window dimensions.
    /// 0 means unconstrained (no max declared by the client).
    max_width:  u16 = 0,
    max_height: u16 = 0,
    /// PResizeInc: dimensions must satisfy w = base_width + N * inc_width.
    /// 0 means unconstrained (no increment declared by the client).
    inc_width:  u16 = 0,
    inc_height: u16 = 0,
    /// PAspect: aspect ratio bounds (dwm convention).
    /// 0.0 means unconstrained (no aspect hint declared by the client).
    min_aspect: f32 = 0.0,
    max_aspect: f32 = 0.0,
};

// Per-window geometry, border-color, and size-hint cache
//
// Stores the last-applied geometry, border color, AND WM_NORMAL_HINTS
// constraints for each window in a single open-addressing hash table.  All
// three fields share one slot so `configureWithHints` performs ONE O(1) hash
// probe per window per retile — down from O(N) linear scan, making the full
// retile pass O(N) total instead of O(N²).
//
// `configureWithHints` writes `.rect`; `applyBorderColor` writes `.border`;
// `CacheMap.cacheHints` writes `.hints` at map time.
//
// Hash table design:
//   • Open addressing with linear probing.  Hash table avoids heap allocation,
//     keeps no allocator reference, has no deinit, and has no partial-failure
//     states — all the properties the previous flat array offered.
//   • Table capacity = 512 (power of two).  Max live entries = 256 (load ≤ 0.5).
//     At load 0.5 the expected probe chain length is 1.5; worst case is bounded.
//   • Hash: Knuth's multiplicative constant (2654435761 ≈ 2³² / φ).
//     XCB allocates window IDs as near-sequential integers; the multiplicative
//     hash spreads them across all 9 index bits with minimal collision.
//   • Deletion: backward-shift (no tombstones).  When an entry is removed,
//     subsequent entries in the same probe run are pulled back one step so that
//     lookup probes never skip over a gap left by a deletion.  This keeps probe
//     chains short without any bookkeeping beyond the shift itself.
//   • EMPTY_WIN = 0 is the empty-slot sentinel.  XCB never allocates ID 0
//     (it is XCB_NONE), so this is safe for the lifetime of the process.

/// Combined per-window cache entry: last geometry, last border color, and
/// WM_NORMAL_HINTS size constraints.
pub const WindowData = struct {
    /// A zeroed rect is the sentinel for "stale / not yet computed".
    /// The layout engine never produces a 0×0 rect, so the sentinel is
    /// unambiguous. Prefer `hasValidRect()` over open-coding the checks.
    rect:   utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    border: u32 = 0,
    /// WM_NORMAL_HINTS constraints populated at map time via `CacheMap.cacheHints`.
    /// All-zero (the default) means unconstrained — `applyHintsToRect` is a
    /// no-op when every field is zero, so windows without declared hints are
    /// handled correctly with zero branches on the hot retile path.
    hints:  SizeHints = .{},

    /// Returns false when the rect is zeroed, indicating the entry is stale or
    /// has not yet been populated by a retile pass.
    pub fn hasValidRect(self: WindowData) bool {
        return self.rect.width != 0 or self.rect.height != 0;
    }
};

// Hash table parameters
const cache_capacity:  usize = 256; // max live entries; overflow_sentinel fires above this
const hash_table_cap:  usize = 512; // power-of-two slot count; load factor ≤ 0.5
const hash_table_mask: usize = hash_table_cap - 1;
const hash_shift:      u5    = 23;  // 32 - log2(512)
const EMPTY_WIN:       u32   = 0;   // XCB_NONE; never a real window ID

/// Overflow sentinel used by `CacheMap.getOrPut` when the hard cap is exceeded.
///
/// Returning a pointer to this throwaway slot lets every call-site proceed
/// without a null-check while guaranteeing no live cache entry is corrupted.
/// The affected window simply misses the dedup check and receives a redundant
/// configure_window on the next retile — an unconditionally correct outcome.
///
/// SINGLE-THREADED ASSUMPTION: two concurrent overflows would alias to the same
/// pointer.  The WM is single-threaded for all geometry operations.
/// If that invariant ever changes, this sentinel must become per-call or the
/// overflow path must return an error.
var overflow_sentinel: WindowData = .{};

/// Open-addressing hash table mapping window IDs to their last geometry,
/// border color, and WM_NORMAL_HINTS constraints — all three in one slot.
///
/// Public API is identical to the previous flat-array CacheMap; callers need
/// no changes.  The struct is zero-initializable: `CacheMap{}` or `.{}` in
/// tiling.State produces an empty table because EMPTY_WIN = 0.
pub const CacheMap = struct {
    const Slot = struct {
        win:  u32        = EMPTY_WIN,
        data: WindowData = .{},
    };

    pub const GetOrPutResult = struct {
        found_existing: bool,
        value_ptr: *WindowData,
    };

    slots: [hash_table_cap]Slot = std.mem.zeroes([hash_table_cap]Slot),
    count: usize = 0,

    /// Knuth's multiplicative hash for 32-bit keys, producing a 9-bit index
    /// (log2(512) = 9) into the hash table.  Distributes XCB's near-sequential
    /// window IDs uniformly across all slots.
    inline fn hashSlot(win: u32) usize {
        return @intCast((win *% 2654435761) >> hash_shift);
    }

    /// Locate or insert the entry for `win`. Always succeeds — no allocator,
    /// no error union.  When the live-entry count reaches cache_capacity the
    /// insertion is routed to the module-level overflow sentinel (no live entry
    /// is corrupted) and a debug error is logged.
    pub fn getOrPut(self: *CacheMap, win: u32) GetOrPutResult {
        std.debug.assert(win != EMPTY_WIN); // XCB never assigns ID 0
        var idx = hashSlot(win);
        while (true) : (idx = (idx + 1) & hash_table_mask) {
            const slot = &self.slots[idx];
            if (slot.win == win)
                return .{ .found_existing = true, .value_ptr = &slot.data };
            if (slot.win == EMPTY_WIN) {
                if (self.count >= cache_capacity) {
                    debug.err("CacheMap: capacity exceeded, dropping cache for 0x{x}", .{win});
                    overflow_sentinel = .{};
                    return .{ .found_existing = false, .value_ptr = &overflow_sentinel };
                }
                slot.* = .{ .win = win, .data = .{} };
                self.count += 1;
                return .{ .found_existing = false, .value_ptr = &slot.data };
            }
        }
    }

    /// Returns a mutable pointer to the cached WindowData for `win`, or null if absent.
    pub fn getPtr(self: *CacheMap, win: u32) ?*WindowData {
        var idx = hashSlot(win);
        while (true) : (idx = (idx + 1) & hash_table_mask) {
            const slot = &self.slots[idx];
            if (slot.win == win)       return &slot.data;
            if (slot.win == EMPTY_WIN) return null;
        }
    }

    /// Remove the entry for `win` (no-op when absent).
    ///
    /// Uses backward-shift deletion to maintain the linear-probe invariant
    /// (every entry sits in the contiguous run that starts at its ideal slot)
    /// without tombstones.  After the deleted slot becomes a hole, subsequent
    /// entries in the same run are pulled back one step as long as doing so
    /// does not move them before their ideal slot.  This keeps probe chains
    /// compact and avoids the lookup degradation that tombstones cause over time.
    ///
    /// Correctness condition for shifting entry at `j` into the hole at `h`:
    ///   An entry with ideal slot `r` can move from `j` to `h` when the probe
    ///   chain from `r` passes through `h` before `j`, i.e. when h is not
    ///   strictly between r and j in the modular sense.  Equivalently:
    ///     (j − r) mod cap ≥ (j − h) mod cap
    pub fn remove(self: *CacheMap, win: u32) void {
        // Locate the entry.
        var hole: usize = hashSlot(win);
        while (true) : (hole = (hole + 1) & hash_table_mask) {
            if (self.slots[hole].win == EMPTY_WIN) return; // not present
            if (self.slots[hole].win == win)       break;
        }
        self.count -= 1;

        // Backward-shift: pull subsequent entries toward the hole until we
        // reach an empty slot.  Each iteration either shifts an entry back
        // (advancing the hole) or leaves it in place (non-moveable entry) and
        // keeps scanning — both paths advance j, so the loop always terminates.
        var j = (hole + 1) & hash_table_mask;
        while (self.slots[j].win != EMPTY_WIN) {
            const r = hashSlot(self.slots[j].win);
            // Can entry at j (ideal r) move to hole?
            // Yes when (j-r) mod cap >= (j-hole) mod cap.
            if (((j -% r) & hash_table_mask) >= ((j -% hole) & hash_table_mask)) {
                self.slots[hole] = self.slots[j];
                hole = j;
            }
            j = (j + 1) & hash_table_mask;
        }
        self.slots[hole] = .{}; // clear the final hole (original or shifted)
    }

    /// Reset the cache to empty in O(table_size) time.
    /// Zeroes all slots since EMPTY_WIN = 0 and WindowData default is all-zero.
    pub fn clearRetainingCapacity(self: *CacheMap) void {
        self.slots = std.mem.zeroes([hash_table_cap]Slot);
        self.count = 0;
    }

    /// Store WM_NORMAL_HINTS constraints for `win` in its cache entry.
    /// No-op when all hint fields are zero (client published an empty atom).
    /// Creates the entry if absent; updates in-place if already present.
    /// Eviction happens automatically with `remove()` at unmanage time, so no
    /// separate `evictSizeHints` call is required.
    pub fn cacheHints(self: *CacheMap, win: u32, hints: SizeHints) void {
        if (isEmptySizeHints(hints)) return;
        self.getOrPut(win).value_ptr.hints = hints;
    }
};

// Layout context and the configureWithHints entry point

/// Context passed into every layout module's `tileWithOffset` call.
///
/// Carries the XCB connection and geometry cache by pointer so layout modules
/// do not depend on module-level globals, making their dependencies explicit
/// and their behaviour independently verifiable.
pub const LayoutCtx = struct {
    conn: *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache. Always non-null during a retile pass.
    cache: *CacheMap,
    /// When non-null, `configureWithHints` emits a border-color change in the same
    /// cache scan, eliminating the separate updateBorders pass and halving the
    /// number of linear searches over CacheMap per window per retile.
    /// Set by `makeLayoutCtx` during a normal retile; null in contexts that
    /// do not have focus/border information (e.g. direct utils.configureWindow
    /// calls in restoreWorkspaceGeom).
    get_border_color: ?*const fn (win: u32) u32 = null,
    /// When non-null, layout modules should emit this window's configure_window
    /// call LAST within each column or stack group it belongs to.
    ///
    /// Used by swap_master to avoid a one-frame wallpaper gap: after swapping
    /// the focused window into the master slot the growing window (new master)
    /// must not vacate its old stack slot until the shrinking window (old master)
    /// has already been configured into that slot.  Setting defer_configure to
    /// the new master achieves this ordering without changing geometry arithmetic.
    defer_configure: ?u32 = null,
    /// When non-null, `configureWithHints` merges XCB_CONFIG_WINDOW_BORDER_WIDTH
    /// into the geometry configure_window call, reducing 3 requests/window to 2.
    /// Set only during reloadConfig retile; null for all normal retile passes.
    border_width: ?u16 = null,
};

/// Returns true when both rects have identical coordinates and dimensions.
pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

/// Shared implementation for configureWithHints and configureWithHintsAndRaise.
///
/// `raise` is a comptime bool — the compiler eliminates the dead branch, so
/// codegen is identical to the previous two-function approach with zero runtime
/// cost. The two public entry points are thin wrappers that instantiate this.
///
/// When `ctx.border_width` is non-null, the BORDER_WIDTH value is merged into
/// the geometry configure_window call, reducing 3 XCB requests per window to 2.
/// This is only set during reloadConfig; it is null for all normal retile passes.
fn configureWithHintsImpl(comptime raise: bool, ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    // Single scan: gop.value_ptr.hints holds any cached WM_NORMAL_HINTS
    // constraints alongside the geometry and border dedup data.
    const gop = ctx.cache.getOrPut(win);
    const effective = applyHintsToRect(rect, gop.value_ptr.hints);

    if (!effective.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}",
            .{ win, effective.width, effective.height, effective.x, effective.y });
        if (comptime raise) {
            _ = xcb.xcb_configure_window(ctx.conn, win,
                xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
        }
        return;
    }

    const is_rect_changed = !gop.found_existing or !rectsEqual(gop.value_ptr.rect, effective);
    if (is_rect_changed) {
        gop.value_ptr.rect = effective;
        if (comptime raise) {
            _ = xcb.xcb_configure_window(ctx.conn, win,
                xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
                xcb.XCB_CONFIG_WINDOW_STACK_MODE,
                &[_]u32{
                    @bitCast(@as(i32, effective.x)),
                    @bitCast(@as(i32, effective.y)),
                    effective.width,
                    effective.height,
                    xcb.XCB_STACK_MODE_ABOVE,
                });
        } else if (ctx.border_width) |bw| {
            // Merge BORDER_WIDTH into the geometry request — saves one XCB round-trip
            // per window during reloadConfig (the only caller that sets border_width).
            _ = xcb.xcb_configure_window(ctx.conn, win,
                xcb.XCB_CONFIG_WINDOW_X     | xcb.XCB_CONFIG_WINDOW_Y     |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
                xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
                &[_]u32{
                    @bitCast(@as(i32, effective.x)),
                    @bitCast(@as(i32, effective.y)),
                    effective.width,
                    effective.height,
                    bw,
                });
        } else {
            utils.configureWindow(ctx.conn, win, effective);
        }
    } else if (comptime raise) {
        // Geometry unchanged (cache hit) — only raise; no intermediate state possible.
        _ = xcb.xcb_configure_window(ctx.conn, win,
            xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }

    const getBorderColor = ctx.get_border_color orelse return;
    const color = getBorderColor(win);
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    _ = xcb.xcb_change_window_attributes(ctx.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}

/// Apply geometry to `win`, clamped to its WM_NORMAL_HINTS constraints.
///
/// Performs a SINGLE hash probe per window per retile (getOrPut supplies
/// geometry, border dedup data, and SizeHints in one lookup).
///
/// Skips the XCB round-trip when the computed rect matches the cached value.
/// When `ctx.get_border_color` is set, border color is also updated in the same
/// probe at zero additional search cost.  When `ctx.border_width` is set,
/// BORDER_WIDTH is merged into the geometry request (reloadConfig path only).
pub fn configureWithHints(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    configureWithHintsImpl(false, ctx, win, rect);
}

/// Like configureWithHints, but also raises the window atomically.
/// Combines XCB_CONFIG_WINDOW_{X,Y,WIDTH,HEIGHT} with XCB_CONFIG_WINDOW_STACK_MODE
/// in a single request when geometry changes, so the compositor never sees an
/// intermediate frame between the reposition/resize and the raise.
pub fn configureWithHintsAndRaise(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    configureWithHintsImpl(true, ctx, win, rect);
}

// Private helpers

/// Apply ICCCM §4.1.2.3 hint passes to a raw rect.
///
/// Pass 1 (min-size clamping) is intentionally omitted for tiling: the layout
/// engine owns the window's dimensions, and honouring a client's declared
/// minimum would silently pin the effective rect to that minimum on every
/// retile — making the dedup check always a cache hit and preventing
/// mod_h/mod_l from resizing the window at all.  Floating drag already
/// ignores minimums (the drag handler echoes back whatever size the user
/// dragged to), so this makes tiling consistent with floating behaviour.
///
/// Pass 2 (resize-increment snap) is retained so terminal emulators still
/// snap to whole character cells; the base is 0 rather than min_width since
/// we are no longer enforcing the declared minimum.
fn applyHintsToRect(rect: utils.Rect, h: SizeHints) utils.Rect {
    var w:  u16 = rect.width;
    var ht: u16 = rect.height;

    // Pass 2: Snap to resize increments (base = 0; min-size not enforced).
    //   effective = floor(dim / inc) * inc
    w  = snapDimToIncrement(w,  0, h.inc_width);
    ht = snapDimToIncrement(ht, 0, h.inc_height);

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

/// Returns true when all hint fields are zero, indicating the client published no constraints.
inline fn isEmptySizeHints(h: SizeHints) bool {
    return h.max_width == 0 and h.max_height == 0 and
           h.inc_width == 0 and h.inc_height == 0 and
           h.min_aspect == 0.0 and h.max_aspect == 0.0;
}