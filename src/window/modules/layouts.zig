//! Shared tiling layout infrastructure
//! Provides the geometry constraints and the configuration entry point shared by all layout modules.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");

const debug = @import("debug");
const constants = @import("constants");

// WM_NORMAL_HINTS size constraint cache
//
// Populated from WM_NORMAL_HINTS during handleMapRequest; evicted on unmanage.
// `configureWithHints` clamps every rect to stored minimums so terminals always
// receive a geometry they can render.

/// ICCCM WM_NORMAL_HINTS geometry constraints for a single window.
pub const SizeHints = struct {
    /// PMaxSize: upper bounds on window dimensions.
    /// 0 means unconstrained (no max declared by the client).
    max_width: u16 = 0,
    max_height: u16 = 0,
    /// PResizeInc: dimensions must satisfy w = base_width + N * inc_width.
    /// 0 means unconstrained (no increment declared by the client).
    inc_width: u16 = 0,
    inc_height: u16 = 0,
    /// PAspect: aspect ratio bounds (dwm convention).
    /// 0.0 means unconstrained (no aspect hint declared by the client).
    min_aspect: f32 = 0.0,
    max_aspect: f32 = 0.0,
};

// Per-window geometry, border-color, and size-hint cache

/// Combined per-window cache entry: last geometry, last border color, and
/// WM_NORMAL_HINTS size constraints.
pub const WindowData = struct {
    /// A zeroed rect is the sentinel for "stale / not yet computed".
    /// The layout engine never produces a 0×0 rect, so the sentinel is
    /// unambiguous. Prefer `hasValidRect()` over open-coding the checks.
    rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    border: u32 = 0,
    /// WM_NORMAL_HINTS constraints populated at map time via `CacheMap.cacheHints`.
    /// All-zero (the default) means unconstrained — `applyHintsToRect` is a
    /// no-op when every field is zero, so windows without declared hints are
    /// handled correctly with zero branches on the hot retile path.
    hints: SizeHints = .{},

    /// Returns false when the rect is zeroed, indicating the entry is stale or
    /// has not yet been populated by a retile pass.
    ///
    /// Both dimensions must be non-zero: a rect with width=0 but height=200 is
    /// still degenerate and must not be treated as a valid on-screen position.
    /// Using OR here would let monocle skip the offscreen-push for such a window,
    /// allowing it to bleed through a transparent top window.
    pub fn hasValidRect(self: WindowData) bool {
        return self.rect.width != 0 and self.rect.height != 0;
    }
};

// Per-window geometry, border-color, and size-hint cache

/// Window ID → per-window geometry, border-color, and size-hint cache.
///
/// Backed by `std.AutoHashMap(u32, WindowData)`. Initialise with
/// `CacheMap.init(allocator)` and release with `.deinit()`.
/// Use `cacheHints(cache, win, hints)` to store WM_NORMAL_HINTS constraints.
pub const CacheMap = std.AutoHashMap(u32, WindowData);

/// Store WM_NORMAL_HINTS constraints for `win` in its cache entry.
/// No-op when all hint fields are zero (client published an empty atom).
/// Creates the entry if absent; updates in-place if already present.
/// Eviction happens automatically via `.remove()` at unmanage time, so no
/// separate eviction step is required.
pub fn cacheHints(cache: *CacheMap, win: u32, hints: SizeHints) void {
    if (isEmptySizeHints(hints)) return;
    const gop = cache.getOrPut(win) catch return; // OOM: leave hints uncached for this window
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.hints = hints;
}

// Layout context and the configureWithHints entry point

/// The pattern layout modules actually follow today (each under
/// `src/window/modules/tiling/modules/`):
///   - `shrinkClamped` (below) converts a slot's raw dimension into the
///     window size actually sent to the X server, applying the gap/border
///     margin and clamping to `constants.MIN_WINDOW_DIM` on underflow.
///   - `emitOrDefer` (below) implements the `defer_win` protocol: every
///     window's rect is routed through it so the master/stack-swap window's
///     final placement can be deferred to the end of the retile pass.
///   - The actual row/column/spiral split arithmetic (how a screen area is
///     divided into per-window slots) is hand-rolled per layout, since each
///     layout's partitioning shape differs enough (grid cells, BSP splits,
///     Fibonacci spirals, master/stack columns) that a shared splitting
///     abstraction was tried and abandoned; there is no shared `Region`-style
///     helper for it.

/// Context passed into every layout module's `tileWithOffset` call.
///
/// Carries the XCB connection and geometry cache by pointer so layout modules
/// do not depend on module-level globals, making their dependencies explicit
/// and their behaviour independently verifiable.
///
/// Border-color updates are not threaded through this struct: colors are
/// refreshed in a dedicated pass after the layout runs (see `tiling.zig`'s
/// `updateBorders`). `border_width` isn't carried here either — reloadConfig
/// sends it as an explicit, separate XCB request rather than smuggling it
/// through here.
pub const LayoutCtx = struct {
    conn: *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache. Always non-null during a retile pass.
    cache: *CacheMap,
    /// The currently focused window, supplied by tiling.zig via focus.getFocused().
    /// Used by monocle to raise the correct window rather than the arbitrary list
    /// tail. Null when the layout context is constructed outside the normal
    /// retile path (e.g. restoreWorkspaceGeom) — monocle falls back to the list
    /// tail in that case, preserving the previous behaviour.
    focused_win: ?u32 = null,
    /// When non-null, names the window whose configure_window call must be the
    /// LAST one sent during this retile, so it doesn't vacate its old slot
    /// until every other window — in particular the one taking its place —
    /// has already been moved. Set by swap_master via tiling.zig's
    /// retileCurrentWorkspaceDeferred(Prebuilt) to eliminate a one-frame
    /// wallpaper gap. Layout modules never check this directly — they call
    /// `emitOrDefer` for every window and leave capture and flush entirely to
    /// `emitOrDefer` and `invokeLayout` respectively (see `emitOrDefer`'s doc
    /// comment for the contract).
    defer_win: ?u32 = null,
    /// Scratch slot for the rect `emitOrDefer` stashes when a window matches
    /// `defer_win`. Points at a slot owned by the caller (tiling.zig's
    /// `invokeLayout` caller), not at LayoutCtx itself — `LayoutCtx` is
    /// passed as `*const` throughout, so mutation happens through this
    /// pointer rather than through the struct's own fields. `invokeLayout`
    /// flushes it once, after the layout function returns; layout modules
    /// never read or flush it themselves.
    deferred: *?utils.Rect,
};

/// Returns true when both rects have identical coordinates and dimensions.
pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

/// Sends `rect` for `win` immediately via `configureWithHints`, unless `win`
/// is the window named by `ctx.defer_win` — in which case the rect is
/// stashed into `ctx.deferred` for `invokeLayout` to send once, after every
/// other window in this retile pass (see `LayoutCtx.defer_win` for why this
/// exists: it eliminates swap_master's one-frame wallpaper gap).
///
/// Shared by every tiling layout that honours `defer_win`, instead of each
/// layout carrying its own copy — fibonacci, master, grid, leaf, and scroll
/// would otherwise each need a local or inline re-derivation of the same
/// check. Layout modules call this for every window and never touch
/// `ctx.defer_win` or `ctx.deferred` directly: capturing the deferred rect is
/// `emitOrDefer`'s job, flushing it is `invokeLayout`'s, and no third party
/// needs to be involved.
pub inline fn emitOrDefer(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    if (ctx.defer_win == win) {
        ctx.deferred.* = rect;
    } else {
        configureWithHints(ctx, win, rect);
    }
}

/// Shrinks `dim` by `margin` (gap and/or border allowance), floored to
/// `constants.MIN_WINDOW_DIM` so a layout never hands a client a zero or
/// negative size when margins exceed the available space.
///
/// Shared by every tiling layout that turns a slot dimension into window
/// content size, instead of each layout defining its own copy of the
/// identical `if (dim > margin) dim - margin else MIN_WINDOW_DIM` check under
/// a different name — as master's `calcInnerWidth`, grid's
/// `cellToWindowSize`, scroll's `calcContentH`, or an inline re-derivation in
/// leaf, monocle, and fibonacci's overflow path.
pub inline fn shrinkClamped(dim: u16, margin: u16) u16 {
    return if (dim > margin) dim - margin else constants.MIN_WINDOW_DIM;
}

/// Shared implementation for configureWithHints and configureWithHintsAndRaise.
///
/// `raise` is a comptime bool — the compiler eliminates the dead branch, so
/// codegen has zero runtime cost despite the two public entry points sharing
/// one implementation. Those entry points are thin wrappers that instantiate
/// this.
fn configureWithHintsImpl(comptime raise: bool, ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    // Single probe: gop.value_ptr.hints holds any cached WM_NORMAL_HINTS
    // constraints alongside the geometry and border dedup data.
    const gop = ctx.cache.getOrPut(win) catch {
        debug.err("CacheMap: allocation failed for window 0x{x}", .{win});
        return;
    };
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const effective = applyHintsToRect(rect, gop.value_ptr.hints);

    if (effective.width == 0 or effective.height == 0) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}", .{ win, effective.width, effective.height, effective.x, effective.y });
        if (comptime raise) {
            _ = xcb.xcb_configure_window(ctx.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
        }
        return;
    }

    const is_rect_changed = !gop.found_existing or !rectsEqual(gop.value_ptr.rect, effective);
    if (is_rect_changed) {
        gop.value_ptr.rect = effective;
        if (comptime raise) {
            _ = xcb.xcb_configure_window(ctx.conn, win, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
                xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{
                @bitCast(@as(i32, effective.x)),
                @bitCast(@as(i32, effective.y)),
                effective.width,
                effective.height,
                xcb.XCB_STACK_MODE_ABOVE,
            });
        } else {
            utils.configureWindow(ctx.conn, win, effective);
        }
    } else if (comptime raise) {
        // Geometry unchanged (cache hit) — only raise; no intermediate state possible.
        _ = xcb.xcb_configure_window(ctx.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{xcb.XCB_STACK_MODE_ABOVE});
    }
}

/// Apply geometry to `win`, clamped to its WM_NORMAL_HINTS constraints.
/// Skips the XCB round-trip when the rect is unchanged. Border color is
/// refreshed in a separate pass — call `tiling.zig`'s border-refresh pass
/// after the layout has run.
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
/// snap to whole character cells; the base is 0 rather than min_width,
/// matching pass 1's decision not to enforce the declared minimum.
fn applyHintsToRect(rect: utils.Rect, h: SizeHints) utils.Rect {
    if (isEmptySizeHints(h)) return rect; // fast path for unconstrained windows
    var w: u16 = rect.width;
    var ht: u16 = rect.height;

    // Pass 2: Snap to resize increments (base = 0; min-size not enforced).
    //   effective = floor(dim / inc) * inc
    w = snapDimToIncrement(w, 0, h.inc_width);
    ht = snapDimToIncrement(ht, 0, h.inc_height);

    // Pass 3: Clamp to declared maximum (after increment snap so we never
    //   exceed the max even after rounding up to the next increment).
    if (h.max_width > 0) w = @min(w, h.max_width);
    if (h.max_height > 0) ht = @min(ht, h.max_height);

    // Pass 4: Aspect ratio (ICCCM §4.1.2.3, matching dwm's applysizehints).
    //   min_aspect = min_aspect.y / min_aspect.x — lower bound on h/w
    //   max_aspect = max_aspect.x / max_aspect.y — upper bound on w/h
    //
    // Divisions replaced with cross-multiplications to avoid two FP divides on
    // every retile for windows that declare PAspect hints (terminals, players):
    //   fw/fh > max_aspect  →  fw > fh * max_aspect
    //   fh/fw > min_aspect  →  fh > fw * min_aspect
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(ht);
        if (fw > fh * h.max_aspect) {
            w = @intFromFloat(@round(fh * h.max_aspect));
            if (h.max_width > 0) w = @min(w, h.max_width);
        } else if (fh > fw * h.min_aspect) {
            ht = @intFromFloat(@round(fw * h.min_aspect));
            if (h.max_height > 0) ht = @min(ht, h.max_height);
        }
    }

    // Centre the (possibly reduced) window inside the slot that the layout
    // allocated.  All hint passes above only shrink dimensions, so both deltas
    // are always non-negative and no clamping guard is required.
    const dx: i16 = @intCast((rect.width - w) / 2);
    const dy: i16 = @intCast((rect.height - ht) / 2);
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = w, .height = ht };
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