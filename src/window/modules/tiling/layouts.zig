//! Common layout interface and utilities shared by all layout modules.

const core  = @import("core");
const xcb   = core.xcb;
const utils = @import("utils");
const debug = @import("debug");

// WM_NORMAL_HINTS size hint cache
//
// Populated from WM_NORMAL_HINTS during handleMapRequest; evicted on unmanage.
// configureSafe clamps every rect to stored minimums so terminals always
// receive a geometry they can render.
//
// Implemented as a flat array with a linear scan. Realistic window counts
// (10–80) make a HashMap's O(1) lookup theoretical rather than measurable:
// a linear scan over a handful of cache lines is faster in practice and
// carries zero allocation overhead, no deinit, and no partial-failure states.

pub const SizeHints = struct {
    min_width:  u16 = 0,
    min_height: u16 = 0,
    /// ICCCM PMaxSize: upper bounds on window dimensions.
    /// 0 means unconstrained (no max declared by the client).
    max_width:  u16 = 0,
    max_height: u16 = 0,
    /// ICCCM PResizeInc: window dimensions must satisfy
    ///   w = min_width  + N * inc_width   for some non-negative integer N
    ///   h = min_height + N * inc_height  for some non-negative integer N
    /// 0 means unconstrained (no increment declared by the client).
    inc_width:  u16 = 0,
    inc_height: u16 = 0,
    /// ICCCM PAspect.
    ///   min_aspect — lower bound on h/w (= min_aspect.y / min_aspect.x).
    ///   max_aspect — upper bound on w/h (= max_aspect.x / max_aspect.y).
    /// Matching dwm's convention: if maxa < w/h, shrink w; if mina < h/w, shrink h.
    /// 0.0 means unconstrained (no aspect hint declared by the client).
    min_aspect: f32 = 0.0,
    max_aspect: f32 = 0.0,
};

const MAX_HINT_ENTRIES: usize = 256;
const HintEntry = struct { win: u32, hints: SizeHints };
var g_hints_buf: [MAX_HINT_ENTRIES]HintEntry = undefined;
var g_hints_len: usize = 0;

pub fn cacheSizeHints(win: u32, hints: SizeHints) void {
    if (hints.min_width == 0 and hints.min_height == 0 and
        hints.max_width == 0 and hints.max_height == 0 and
        hints.inc_width == 0 and hints.inc_height == 0 and
        hints.min_aspect == 0.0 and hints.max_aspect == 0.0) return;
    // Update in-place when an entry already exists.
    for (g_hints_buf[0..g_hints_len]) |*e| {
        if (e.win == win) { e.hints = hints; return; }
    }
    if (g_hints_len >= MAX_HINT_ENTRIES) {
        debug.err("cacheSizeHints: hint table full, dropping hints for 0x{x}", .{win});
        return;
    }
    g_hints_buf[g_hints_len] = .{ .win = win, .hints = hints };
    g_hints_len += 1;
}

pub fn evictSizeHints(win: u32) void {
    for (g_hints_buf[0..g_hints_len], 0..) |e, i| {
        if (e.win == win) {
            // Swap-and-decrement: O(1), order-independent.
            g_hints_buf[i] = g_hints_buf[g_hints_len - 1];
            g_hints_len -= 1;
            return;
        }
    }
}

// Per-window combined cache entry
//
// Stores the last-applied geometry and border color per window.
// configureSafe writes only `.rect`; sendBorderColor writes only `.border`.
// Both fields live in the same entry, located by a single linear scan, so
// there is no "two write paths that must stay in sync" liability.

pub const WindowData = struct {
    /// A zeroed rect is used as a sentinel for "not yet computed / stale cache
    /// entry". The layout engine never produces a 0x0 rect in practice, so the
    /// sentinel is unambiguous. Use hasValidRect() rather than open-coding the
    /// width/height checks at each call site.
    rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    border: u32 = 0,

    /// Returns false when the rect is zeroed, indicating the entry is stale or
    /// has not yet been populated by a retile pass.
    pub fn hasValidRect(self: WindowData) bool {
        return self.rect.width != 0 or self.rect.height != 0;
    }
};

// Per-window geometry and border-color cache.
//
// Implemented as a fixed-size flat array with a linear scan.
//
// Why not AutoHashMap?
//   n is bounded by open windows — realistic: 10–80; hard cap: CACHE_CAPACITY.
//   At that scale a linear scan over contiguous memory is faster than a hash
//   probe (cache locality beats asymptotic complexity). More importantly, the
//   flat array eliminates every structural cost the HashMap carried:
//     - No heap allocation; no deinit; no error path in getOrPut.
//     - getOrPut is infallible: callers drop their `catch` blocks entirely.
//     - reloadConfig reduces to clearRetainingCapacity() (sets len = 0).
//     - No allocation-failure fallback paths that leave the cache partially
//       populated.

const CACHE_CAPACITY: usize = 256;

// Overflow sentinel for getOrPut when the hard cap is exceeded.
//
// Returning a pointer to this throwaway slot lets every call-site proceed
// without a null-check while guaranteeing no real cache entry is corrupted.
// Writes to the sentinel are discarded on the next cache operation; the
// affected window simply misses the dedup check and receives a redundant
// configure_window on the next retile — an unconditionally correct outcome.
var g_overflow_sentinel: WindowData = .{};

pub const CacheMap = struct {
    const Entry = struct { win: u32, data: WindowData };

    pub const GetOrPutResult = struct {
        found_existing: bool,
        value_ptr: *WindowData,
    };

    buf: [CACHE_CAPACITY]Entry = undefined,
    len: usize = 0,

    fn findEntry(self: *CacheMap, win: u32) ?*Entry {
        for (self.buf[0..self.len]) |*e| if (e.win == win) return e;
        return null;
    }

    /// Locate the entry for `win`, creating one if absent. Always succeeds —
    /// no allocator, no error union. When the buffer is full the write is
    /// routed to a module-level sentinel (no live entry is corrupted) and a
    /// debug error is logged; this is a hard-cap violation that should never
    /// occur in normal use.
    pub fn getOrPut(self: *CacheMap, win: u32) GetOrPutResult {
        for (self.buf[0..self.len]) |*e| {
            if (e.win == win) return .{ .found_existing = true, .value_ptr = &e.data };
        }
        if (self.len < CACHE_CAPACITY) {
            self.buf[self.len] = .{ .win = win, .data = .{} };
            const vp = &self.buf[self.len].data;
            self.len += 1;
            return .{ .found_existing = false, .value_ptr = vp };
        }
        // Hard cap exceeded: route the write to the module-level sentinel so
        // no live cache entry is corrupted.  The sentinel is reset on every
        // overflow hit so stale data from a previous victim cannot leak.
        // The affected window misses the dedup check and gets a redundant
        // configure_window on the next retile — correct, just not optimal.
        debug.err("CacheMap: capacity exceeded, dropping cache for 0x{x}", .{win});
        g_overflow_sentinel = .{};
        return .{ .found_existing = false, .value_ptr = &g_overflow_sentinel };
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
            if (e.win == win) {
                self.buf[i] = self.buf[self.len - 1];
                self.len -= 1;
                return;
            }
        }
    }

    /// Reset the cache to empty. The backing buffer is left untouched;
    /// only the fill counter is zeroed. O(1).
    pub fn clearRetainingCapacity(self: *CacheMap) void {
        self.len = 0;
    }
};

// Layout context
//
// Every layout module receives a *const LayoutCtx; configureSafe reads the
// cache from it rather than from a module-level global, making the dependency
// explicit and eliminating hidden call-site ordering requirements.
// `allocator` is retained for layout modules that may need it; configureSafe
// itself no longer requires one.

pub const LayoutCtx = struct {
    conn: *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache. Always non-null during a retile pass.
    cache: *CacheMap,
    /// When non-null, configureSafe emits a border-color change in the same
    /// cache scan, eliminating the separate updateBorders pass and halving the
    /// number of linear searches over the CacheMap per window per retile.
    /// Set by makeLayoutCtx during a normal retile; null in contexts that do
    /// not have focus/border information (e.g. direct utils.configureWindow
    /// calls in restoreWorkspaceGeom).
    get_border_color: ?*const fn (win: u32) u32 = null,
};

/// Compares two Rects by value across all four fields.
pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

/// The single call-site every layout module uses to apply geometry.
/// Clamps to WM_NORMAL_HINTS minimums and skips the XCB call for windows
/// whose rect matches the last applied value.
pub fn configureSafe(
    ctx: *const LayoutCtx,
    win: u32,
    rect: utils.Rect,
) void {
    // Clamp to WM_NORMAL_HINTS minimums and snap to resize increments via
    // linear scan over the flat hint table.
    //
    // Increment snapping (ICCCM §4.1.2.3):
    //   effective_dim = base + floor((available - base) / inc) * inc
    // where `base` is min_width/min_height (the smallest valid size).
    // Without this, terminal emulators receive fractional character cells
    // and render ragged grids.
    const effective: utils.Rect = blk: {
        for (g_hints_buf[0..g_hints_len]) |e| {
            if (e.win != win) continue;

            // 1. Clamp to declared minimum.
            var w: u16 = @max(rect.width,  e.hints.min_width);
            var h: u16 = @max(rect.height, e.hints.min_height);

            // 2. Snap to resize increments (ICCCM §4.1.2.3).
            //    effective = base + floor((available - base) / inc) * inc
            if (e.hints.inc_width > 0 and w > e.hints.min_width) {
                const over = w - e.hints.min_width;
                w = e.hints.min_width + (over / e.hints.inc_width) * e.hints.inc_width;
            }
            if (e.hints.inc_height > 0 and h > e.hints.min_height) {
                const over = h - e.hints.min_height;
                h = e.hints.min_height + (over / e.hints.inc_height) * e.hints.inc_height;
            }

            // 3. Clamp to declared maximum (applied after increment snap so we
            //    never exceed the max even after rounding up to the next increment).
            if (e.hints.max_width  > 0) w = @min(w, e.hints.max_width);
            if (e.hints.max_height > 0) h = @min(h, e.hints.max_height);

            // 4. Aspect ratio (ICCCM §4.1.2.3, matching dwm's applysizehints).
            //    min_aspect = min_aspect.y / min_aspect.x  — lower bound on h/w
            //    max_aspect = max_aspect.x / max_aspect.y  — upper bound on w/h
            //    If w/h exceeds max_aspect, shrink w.
            //    If h/w exceeds 1/min_aspect (i.e. min_aspect > h/w), shrink h.
            if (e.hints.min_aspect > 0.0 and e.hints.max_aspect > 0.0) {
                const fw: f32 = @floatFromInt(w);
                const fh: f32 = @floatFromInt(h);
                if (e.hints.max_aspect < fw / fh) {
                    w = @intFromFloat(@round(fh * e.hints.max_aspect));
                    if (e.hints.max_width  > 0) w = @min(w, e.hints.max_width);
                } else if (e.hints.min_aspect < fh / fw) {
                    h = @intFromFloat(@round(fw * e.hints.min_aspect));
                    if (e.hints.max_height > 0) h = @min(h, e.hints.max_height);
                }
            }

            break :blk .{ .x = rect.x, .y = rect.y, .width = w, .height = h };
        }
        break :blk rect;
    };

    if (!effective.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}",
            .{ win, effective.width, effective.height, effective.x, effective.y });
        return;
    }

    // Single cache scan for both rect and border — getOrPut is infallible.
    const gop = ctx.cache.getOrPut(win);
    const rect_changed = !gop.found_existing or !rectsEqual(gop.value_ptr.rect, effective);
    if (rect_changed) {
        gop.value_ptr.rect = effective;
        utils.configureWindow(ctx.conn, win, effective);
    }

    // When a border-color provider is available, update the border in the same
    // scan rather than in a separate updateBorders pass. This halves the number
    // of linear searches over the CacheMap per window per retile.
    const getBorderColor = ctx.get_border_color orelse return;
    const color = getBorderColor(win);
    if (gop.found_existing and gop.value_ptr.border == color) return;
    gop.value_ptr.border = color;
    _ = xcb.xcb_change_window_attributes(ctx.conn, win,
        xcb.XCB_CW_BORDER_PIXEL, &[_]u32{color});
}
