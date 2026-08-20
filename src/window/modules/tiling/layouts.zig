//! Shared tiling layout infrastructure
//! Provides the geometry constraints and the configuration entry point shared by all layout modules.

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");

const debug = @import("debug");

/// ICCCM WM_NORMAL_HINTS geometry constraints for one window. Zero fields
/// mean "unconstrained" (client declared no hint).
pub const SizeHints = struct {
    max_width: u16 = 0, // PMaxSize
    max_height: u16 = 0,
    inc_width: u16 = 0, // PResizeInc: w = base_width + N * inc_width
    inc_height: u16 = 0,
    min_aspect: f32 = 0.0, // PAspect (dwm convention)
    max_aspect: f32 = 0.0,
};

/// Sentinel zero rect used to mark a cache entry as stale.
pub const zero_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

pub const WindowData = struct {
    /// Zeroed rect = stale / not yet computed. The layout engine never
    /// produces a real 0x0 rect, so this sentinel is unambiguous.
    rect: utils.Rect = zero_rect,
    border: u32 = 0,
    hints: SizeHints = .{},

    pub fn hasValidRect(self: WindowData) bool {
        return self.rect.width != 0 and self.rect.height != 0;
    }
};

// WM_NORMAL_HINTS size-constraint cache, populated at map time, evicted on
// unmanage. configureWithHints clamps every rect to these.
pub const CacheMap = std.AutoHashMap(u32, WindowData);

/// Centralizes the get-or-put-with-default pattern for writers that don't
/// distinguish "existing" from "new" (those that do use `getOrPut` directly).
pub fn getOrPutDefault(cache: *CacheMap, win: u32) !*WindowData {
    const gop = try cache.getOrPut(win);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// No-op if every field is zero (nothing declared).
pub fn cacheHints(cache: *CacheMap, win: u32, hints: SizeHints) void {
    if (isEmptySizeHints(hints)) return;
    const wd = getOrPutDefault(cache, win) catch return; // OOM: leave hints uncached.
    wd.hints = hints;
}

/// Canonical signature every layout module's `tileWithOffset` must conform to.
/// The second parameter is always `*tiling.State`, but we use `*anyopaque`
/// here so the type alias lives in layouts.zig without a circular import.
pub const LayoutFn = *const fn (*const LayoutCtx, *anyopaque, []const u32, u16, u16, u16) void;

/// Context passed to every layout module's `tileWithOffset`. Carries the XCB
/// connection and cache by pointer so layouts have no module-level globals.
pub const LayoutCtx = struct {
    conn: core.Connection,
    /// Pointer into tiling.State.cache. Always non-null during a retile.
    cache: *CacheMap,
    /// Focused window (from focus.getFocused()), used by monocle to raise
    /// the right window. Null outside the normal retile path.
    focused_win: ?u32 = null,
    /// If set, this window's configure must be the last one sent this retile
    /// (set by swap_master, to avoid a one-frame gap where its old slot is
    /// empty before the window taking it has moved in). Layout modules never
    /// check this directly; call `emitOrDefer` for every window instead.
    defer_win: ?u32 = null,
    /// Scratch slot `emitOrDefer` writes into when a window matches
    /// `defer_win`; flushed once by `invokeLayout` after the layout returns.
    deferred: *?utils.Rect,
    /// True when this retile targets an off-screen workspace (see
    /// tiling.retileInactiveWorkspace). Layouts that raise a window (e.g.
    /// monocle) must skip the raise here, or the window lands first in the
    /// global stacking order, above the bar and the visible workspace.
    is_background: bool = false,
};

/// Push `win` offscreen for layouts that hide it (monocle's background
/// windows, fibonacci's overflow fallback). Invalidates the cached rect so
/// restoreWorkspaceGeom never replays a stale position; skips the round-trip
/// when the entry is already invalid.
pub inline fn pushWindowOffscreenAndInvalidate(ctx: *const LayoutCtx, win: u32) void {
    if (ctx.cache.getPtr(win)) |wd| {
        if (!wd.hasValidRect()) return;
        wd.rect = zero_rect;
    }
    utils.pushWindowOffscreen(ctx.conn, win);
}

/// Send `rect` for `win` now via configureWithHints, unless `win` is
/// `ctx.defer_win`; then stash it in `ctx.deferred` for `invokeLayout` to
/// send last. Called by every defer_win-aware layout.
pub inline fn emitOrDefer(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    if (ctx.defer_win == win) {
        ctx.deferred.* = rect;
    } else {
        configureWithHints(ctx, win, rect);
    }
}

/// Shrinks `dim` by `margin` (gap/border), floored to `min_dim` so a layout
/// never hands a client a zero or negative size.
pub inline fn shrinkClamped(dim: u16, margin: u16, min_dim: u16) u16 {
    return if (dim > margin) dim - margin else min_dim;
}

/// Work-area rect: the whole screen inset by the outer gap. x/y are i32
/// (some tiling layouts thread i32 coords through their recursion), w/h u16.
pub inline fn outerArea(screen_w: u16, screen_h: u16, y_offset: u16, gap: u16) struct { x: i32, y: i32, w: u16, h: u16 } {
    return .{
        .x = @intCast(gap),
        .y = @intCast(y_offset +| gap),
        .w = screen_w -| gap *| 2,
        .h = screen_h -| gap *| 2,
    };
}

/// Shared body for configureWithHints/configureWithHintsAndRaise. `raise` is
/// comptime so the compiler drops the dead branch.
fn configureWithHintsImpl(comptime raise: bool, ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    const gop = ctx.cache.getOrPut(win) catch {
        debug.err("CacheMap: allocation failed for window 0x{x}", .{win});
        return;
    };
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const effective = applyHintsToRect(rect, gop.value_ptr.hints);

    if (effective.width == 0 or effective.height == 0) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}", .{ win, effective.width, effective.height, effective.x, effective.y });
        if (comptime raise) utils.raiseWindow(ctx.conn, win);
        return;
    }

    const is_rect_changed = !gop.found_existing or !gop.value_ptr.rect.eql(effective);
    if (is_rect_changed) {
        gop.value_ptr.rect = effective;
        if (comptime raise) {
            _ = xcb.xcb_configure_window(ctx.conn, win, xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
                xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{
                utils.toXcbCoord(effective.x),
                utils.toXcbCoord(effective.y),
                effective.width,
                effective.height,
                xcb.XCB_STACK_MODE_ABOVE,
            });
        } else {
            utils.configureWindow(ctx.conn, win, effective);
        }
    } else if (comptime raise) {
        utils.raiseWindow(ctx.conn, win);
    }
}

/// Clamps `rect` to its WM_NORMAL_HINTS and sends it to XCB. Skips the
/// round-trip entirely when the rect is unchanged from the cache.
pub fn configureWithHints(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    configureWithHintsImpl(false, ctx, win, rect);
}

/// Like configureWithHints, but also raises the window atomically with the
/// same request when geometry changes.
pub fn configureWithHintsAndRaise(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    configureWithHintsImpl(true, ctx, win, rect);
}

/// Configure `win` with hints, raising it only when this is not a background
/// retile; there's no viewer off-screen, and raising would leave the window
/// first in the *global* stacking order with nothing to ever lower it again.
/// Shared by the layouts that promote a top window (monocle, fibonacci).
pub inline fn configureWithHintsAndRaiseIfVisible(ctx: *const LayoutCtx, win: u32, rect: utils.Rect) void {
    if (ctx.is_background) {
        configureWithHints(ctx, win, rect);
    } else {
        configureWithHintsAndRaise(ctx, win, rect);
    }
}

/// Prefer `ctx.focused_win` when it appears in `windows`, else `fallback`.
pub fn focusedElse(ctx: *const LayoutCtx, windows: []const u32, fallback: u32) u32 {
    if (ctx.focused_win) |f| if (std.mem.indexOfScalar(u32, windows, f) != null) return f;
    return fallback;
}

/// Raise/configure `top` on-screen and push every other window in `windows`
/// offscreen. Only raises on-screen (respects LayoutCtx.is_background via
/// configureWithHintsAndRaiseIfVisible).
pub fn showOneHideRest(ctx: *const LayoutCtx, windows: []const u32, top: u32, top_rect: utils.Rect) void {
    configureWithHintsAndRaiseIfVisible(ctx, top, top_rect);
    for (windows) |win| {
        if (win == top) continue;
        pushWindowOffscreenAndInvalidate(ctx, win);
    }
}

/// Apply ICCCM §4.1.2.3 hints to a raw rect: increment snap, max-size clamp,
/// then aspect clamp (with a re-snap, since a client may declare both).
/// Declared minimums are intentionally NOT enforced; tiling owns window size,
/// and honouring them would pin the rect and block mod_h/mod_l resizing.
fn applyHintsToRect(rect: utils.Rect, h: SizeHints) utils.Rect {
    if (isEmptySizeHints(h)) return rect;
    var w: u16 = rect.width;
    var ht: u16 = rect.height;

    w = snapDimToIncrement(w, 0, h.inc_width);
    ht = snapDimToIncrement(ht, 0, h.inc_height);

    if (h.max_width > 0) w = @min(w, h.max_width);
    if (h.max_height > 0) ht = @min(ht, h.max_height);

    // min_aspect = h/w lower bound, max_aspect = w/h upper bound (dwm
    // convention); cross-multiplied to avoid FP division per retile.
    //
    // The aspect clamp recomputes from scratch and can land off the increment
    // grid (e.g. PResizeInc + PAspect on a terminal); re-snapping afterward
    // floors to the grid without exceeding max_width/height.
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(ht);
        if (fw > fh * h.max_aspect) {
            w = @intFromFloat(@round(fh * h.max_aspect));
            w = snapDimToIncrement(w, 0, h.inc_width);
            if (h.max_width > 0) w = @min(w, h.max_width);
        } else if (fh > fw * h.min_aspect) {
            ht = @intFromFloat(@round(fw * h.min_aspect));
            ht = snapDimToIncrement(ht, 0, h.inc_height);
            if (h.max_height > 0) ht = @min(ht, h.max_height);
        }
    }

    // Centre the (possibly shrunk) window inside its allocated slot.
    const dx: i16 = @intCast((rect.width - w) / 2);
    const dy: i16 = @intCast((rect.height - ht) / 2);
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = w, .height = ht };
}

/// Snap `dim` down to the nearest multiple of `inc` above `base`.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const excess = dim - base;
    return base + (excess / inc) * inc;
}

inline fn isEmptySizeHints(h: SizeHints) bool {
    return h.max_width == 0 and h.max_height == 0 and
        h.inc_width == 0 and h.inc_height == 0 and
        h.min_aspect == 0.0 and h.max_aspect == 0.0;
}
