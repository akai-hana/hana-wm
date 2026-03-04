//! Common layout interface and utilities.

const std   = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const defs  = @import("defs");
const xcb   = defs.xcb;

// ── WM_NORMAL_HINTS size hint cache ──────────────────────────────────────────
//
// Per-window minimum size constraints, populated from WM_NORMAL_HINTS at map
// time and evicted on unmanage. Owned by tiling.State so it shares the same
// lifetime as the geometry cache and is never stale after a reloadConfig.
// configureSafe reads the cache via ctx.size_hints.

pub const SizeHints = struct {
    min_width:  u16 = 0,
    min_height: u16 = 0,
};

// ── Per-window combined cache entry ──────────────────────────────────────────
//
// Merges the previous pair of separate geom_cache and border_cache maps into a
// single AutoHashMapUnmanaged, halving hash lookups on the hot retile and
// border-update paths and improving cache-line locality.
//
// configureSafe writes only `.rect`; tiling.sendBorderColor writes only
// `.border`. Both use getOrPut so a single hash probe handles both the
// "found / skip if unchanged" and "insert" cases.

pub const WindowData = struct {
    rect:   utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    border: u32        = 0,
};

pub const CacheMap = std.AutoHashMapUnmanaged(u32, WindowData);

// ── Layout context ────────────────────────────────────────────────────────────
//
// Replaces the previous arm/disarm global pointer (g_geom_ctx). Every layout
// module receives a *const LayoutCtx; configureSafe reads the cache from it
// rather than from a module-level global. This makes the dependency explicit,
// eliminates hidden call-site ordering requirements, and lets the compiler see
// the null-cache case statically.

pub const LayoutCtx = struct {
    conn:      *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache. Non-null during a normal retile pass;
    /// null only when called from a code path that intentionally bypasses dedup
    /// (currently unused — kept as an escape hatch).
    cache:      ?*CacheMap,
    /// Pointer into tiling.State.size_hints.  configureSafe reads min-size
    /// constraints from here rather than from a module-level global.
    size_hints: *const std.AutoHashMapUnmanaged(u32, SizeHints),
    allocator: std.mem.Allocator,
};

// ── Rect comparison ───────────────────────────────────────────────────────────
//
// utils.Rect is `extern struct { i16, i16, u16, u16 }` — 8 bytes, no padding.
// A single 64-bit integer comparison replaces the original four 16-bit ones.
// The comptime assert makes the layout assumption explicit and catches any
// future struct changes that would silently break the bitcast.

pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    comptime std.debug.assert(@sizeOf(utils.Rect) == @sizeOf(u64));
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

// ── configureSafe ─────────────────────────────────────────────────────────────

/// The single call-site every layout module uses to apply geometry.
/// Clamps to WM_NORMAL_HINTS minimums and, when the cache is non-null,
/// skips the XCB call for windows whose rect matches the last applied value.
pub inline fn configureSafe(
    ctx:  *const LayoutCtx,
    win:  u32,
    rect: utils.Rect,
) void {
    // Clamp to WM_NORMAL_HINTS minimums.
    const effective: utils.Rect = if (ctx.size_hints.get(win)) |h| .{
        .x      = rect.x,
        .y      = rect.y,
        .width  = @max(rect.width,  h.min_width),
        .height = @max(rect.height, h.min_height),
    } else rect;

    if (!effective.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}",
            .{ win, effective.width, effective.height, effective.x, effective.y });
        return;
    }

    if (ctx.cache) |cache| {
        // getOrPut: single hash probe covers both the "already exists" (dedup)
        // and "new entry" (insert) paths.
        const gop = cache.getOrPut(ctx.allocator, win) catch {
            // Allocation failure: send the XCB call without caching.
            utils.configureWindow(ctx.conn, win, effective);
            return;
        };
        if (gop.found_existing) {
            if (rectsEqual(gop.value_ptr.rect, effective)) return; // geometry unchanged
            gop.value_ptr.rect = effective; // update rect; preserve existing border
        } else {
            gop.value_ptr.* = .{ .rect = effective, .border = 0 };
        }
    }

    utils.configureWindow(ctx.conn, win, effective);
}
