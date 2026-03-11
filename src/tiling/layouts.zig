//! Common layout interface and utilities.

const std   = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const defs  = @import("defs");
const xcb   = defs.xcb;

// WM_NORMAL_HINTS size hint cache 
//
// Populated from WM_NORMAL_HINTS during handleMapRequest; evicted on unmanage.
// configureSafe clamps every rect to stored minimums so terminals always
// receive a geometry they can render.
//
// TODO(item-4): fold g_hints into tiling.State so it shares the same
// lifetime/ownership as geom_cache and border_cache and is rebuilt cleanly
// on reloadConfig. Requires threading the allocator through evictSizeHints,
// which touches window.zig (not in scope for this edit pass).

pub const SizeHints = struct {
    min_width:  u16 = 0,
    min_height: u16 = 0,
};

var g_hints: std.AutoHashMapUnmanaged(u32, SizeHints) = .{};

pub fn cacheSizeHints(allocator: std.mem.Allocator, win: u32, hints: SizeHints) void {
    if (hints.min_width == 0 and hints.min_height == 0) return;
    g_hints.put(allocator, win, hints) catch |err| {
        debug.err("cacheSizeHints: failed to cache hints for 0x{x}: {}", .{ win, err });
    };
}

pub fn evictSizeHints(win: u32) void {
    _ = g_hints.remove(win);
}

/// Free the entire size-hints map. Call once at WM shutdown.
pub fn deinitSizeHintsCache(allocator: std.mem.Allocator) void {
    g_hints.deinit(allocator);
}

// Per-window combined cache entry 
//
// A single AutoHashMapUnmanaged keyed by window ID, storing both geometry and
// border color. configureSafe writes only `.rect`; tiling.sendBorderColor
// writes only `.border`. Both use getOrPut so a single hash probe handles
// both the "found / skip if unchanged" and "insert" cases.

pub const WindowData = struct {
    rect:   utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    border: u32        = 0,
};

pub const CacheMap = std.AutoHashMapUnmanaged(u32, WindowData);

// Layout context 
//
// Every layout module receives a *const LayoutCtx; configureSafe reads the
// cache from it rather than from a module-level global, making the dependency
// explicit and eliminating hidden call-site ordering requirements.

pub const LayoutCtx = struct {
    conn:      *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache. Non-null during a normal retile pass;
    /// null only when called from a code path that intentionally bypasses dedup
    /// (currently unused — kept as an escape hatch).
    cache:     ?*CacheMap,
    allocator: std.mem.Allocator,
};

/// Returns true if two rects are identical via a single 64-bit comparison.
/// utils.Rect is `extern struct { i16, i16, u16, u16 }` — 8 bytes, no padding.
/// The comptime assert makes the layout assumption explicit and catches any
/// future struct changes that would silently break the bitcast.
pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    comptime std.debug.assert(@sizeOf(utils.Rect) == @sizeOf(u64));
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

/// The single call-site every layout module uses to apply geometry.
/// Clamps to WM_NORMAL_HINTS minimums and, when the cache is non-null,
/// skips the XCB call for windows whose rect matches the last applied value.
pub fn configureSafe(
    ctx:  *const LayoutCtx,
    win:  u32,
    rect: utils.Rect,
) void {
    // Clamp to WM_NORMAL_HINTS minimums.
    const effective: utils.Rect = if (g_hints.get(win)) |h| .{
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
