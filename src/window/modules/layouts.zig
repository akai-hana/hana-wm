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

/// Axis-aligned screen region used by layout modules to partition space without
/// duplicating gap/border arithmetic at every call site.
///
/// All coordinates use the same i32/u16 conventions as `utils.Rect`: `x` and
/// `y` are signed (windows can be positioned off-screen), `width` and `height`
/// are unsigned (a region with zero area is degenerate and should not be split).
///
/// Layout modules should:
///   1. Call `Region.fromScreen` once to get the outer region.
///   2. Call `inset` to strip the outer gap margin.
///   3. Call `splitH` / `splitV` / `halve` to partition, passing the gap so
///      seam spacing is consistent and DRY.
///   4. At each leaf, call `toRect` and hand it to `configureWithHints`.
///
/// The `halve` functions distribute the remainder pixel to the *second* half
/// so that the first half is always ≤ the second — consistent with the
/// existing master-stack convention.
pub const Region = struct {
    x: i32,
    y: i32,
    w: u16,
    h: u16,

    /// Build the initial region from screen dimensions and a y-offset (bar height).
    pub inline fn fromScreen(screen_w: u16, screen_h: u16, y_offset: u16) Region {
        return .{ .x = 0, .y = @intCast(y_offset), .w = screen_w, .h = screen_h -| y_offset };
    }

    /// Strip `margin` pixels from all four sides.  Saturating: a margin larger
    /// than the region produces a zero-size region rather than wrapping.
    pub inline fn inset(r: Region, margin: u16) Region {
        const m2 = margin *| 2;
        return .{
            .x = r.x + @as(i32, @intCast(margin)),
            .y = r.y + @as(i32, @intCast(margin)),
            .w = r.w -| m2,
            .h = r.h -| m2,
        };
    }

    /// Shared partition loop for `splitH` and `splitV`.
    ///
    /// When `horiz` is true the region is sliced along the Y axis (rows);
    /// when false along the X axis (columns).  The comptime parameter means
    /// the compiler sees two fully specialised copies with no runtime branching.
    fn splitAxis(comptime horiz: bool, r: Region, n: u16, gap: u16, buf: []Region) void {
        std.debug.assert(buf.len >= n);
        if (n == 0) return;
        const total_gap = gap *| (n -| 1);
        const avail: u16 = (if (horiz) r.h else r.w) -| total_gap;
        var pos: i32 = if (horiz) r.y else r.x;
        for (0..n) |i| {
            const idx: u16 = @intCast(i);
            // Distribute remainder pixel by using the cumulative-slice formula:
            // slice_i = floor((i+1)*avail/n) - floor(i*avail/n)
            const dim: u16 = ((idx + 1) * avail / n) -| (idx * avail / n);
            buf[i] = if (horiz)
                .{ .x = r.x, .y = pos, .w = r.w, .h = dim }
            else
                .{ .x = pos, .y = r.y, .w = dim, .h = r.h };
            pos += @intCast(dim + gap);
        }
    }

    /// Split `r` horizontally into `n` equal rows separated by `gap` pixels.
    /// Returns a stack-allocated array of `n` regions; caller supplies the
    /// buffer.  `buf.len` must be >= `n`.
    pub fn splitH(r: Region, n: u16, gap: u16, buf: []Region) void {
        splitAxis(true, r, n, gap, buf);
    }

    /// Split `r` vertically into `n` equal columns separated by `gap` pixels.
    pub fn splitV(r: Region, n: u16, gap: u16, buf: []Region) void {
        splitAxis(false, r, n, gap, buf);
    }

    /// Split `r` into left and right halves with `gap` between them.
    /// The remainder pixel (odd width) goes to the right half.
    pub inline fn halveH(r: Region, gap: u16) struct { left: Region, right: Region } {
        const left_w: u16 = if (r.w > gap) (r.w - gap) / 2 else 0;
        const right_w: u16 = r.w -| left_w -| gap;
        return .{
            .left = .{ .x = r.x, .y = r.y, .w = left_w, .h = r.h },
            .right = .{ .x = r.x + @as(i32, @intCast(left_w +| gap)), .y = r.y, .w = right_w, .h = r.h },
        };
    }

    /// Split `r` into top and bottom halves with `gap` between them.
    /// The remainder pixel (odd height) goes to the bottom half.
    pub inline fn halveV(r: Region, gap: u16) struct { top: Region, bottom: Region } {
        const top_h: u16 = if (r.h > gap) (r.h - gap) / 2 else 0;
        const bottom_h: u16 = r.h -| top_h -| gap;
        return .{
            .top = .{ .x = r.x, .y = r.y, .w = r.w, .h = top_h },
            .bottom = .{ .x = r.x, .y = r.y + @as(i32, @intCast(top_h +| gap)), .w = r.w, .h = bottom_h },
        };
    }

    /// Convert to a `utils.Rect` for use with `configureWithHints`, subtracting
    /// border*2 from both dimensions.  Falls back to `constants.MIN_WINDOW_DIM`
    /// on underflow so the X server never receives a zero-size window.
    pub inline fn toRect(r: Region, border: u16) utils.Rect {
        const b2 = border *| 2;
        return .{
            .x = r.x,
            .y = r.y,
            .width = if (r.w > b2) r.w - b2 else constants.MIN_WINDOW_DIM,
            .height = if (r.h > b2) r.h - b2 else constants.MIN_WINDOW_DIM,
        };
    }
};

/// Context passed into every layout module's `tileWithOffset` call.
///
/// Carries the XCB connection and geometry cache by pointer so layout modules
/// do not depend on module-level globals, making their dependencies explicit
/// and their behaviour independently verifiable.
///
/// Border-color updates are no longer threaded through this struct: colors
/// are refreshed in a dedicated pass after the layout runs (see `tiling.zig`'s
/// `updateBorders`). `border_width` is gone too — reloadConfig now sends it
/// as an explicit, separate XCB request rather than smuggling it through here.
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
    /// wallpaper gap. Layout modules check this directly with a plain `if`
    /// at their configure call site instead of going through a shared
    /// capture/emit/flush abstraction — there is exactly one window to defer,
    /// so the inline check is simpler than the type it replaces.
    defer_win: ?u32 = null,
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
/// Skips the XCB round-trip when the rect is unchanged. Border color is no
/// longer updated here — call `tiling.zig`'s border-refresh pass after the
/// layout has run.
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
/// snap to whole character cells; the base is 0 rather than min_width since
/// we are no longer enforcing the declared minimum.
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