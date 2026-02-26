// Common layout interface and utilities.

const std   = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const defs  = @import("defs");
const xcb   = defs.xcb;

// ── WM_NORMAL_HINTS size hint cache ──────────────────────────────────────────
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
    g_hints.put(allocator, win, hints) catch {};
}

pub fn evictSizeHints(win: u32) void {
    _ = g_hints.remove(win);
}

/// Free the entire size-hints map. Call once at WM shutdown.
pub fn deinitSizeHintsCache(allocator: std.mem.Allocator) void {
    g_hints.deinit(allocator);
}

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
    cache:     ?*CacheMap,
    allocator: std.mem.Allocator,
};

// ── Rect comparison ───────────────────────────────────────────────────────────
//
// Four-field equality used in configureSafe and restoreWorkspaceGeom.
// If utils.Rect is declared as a packed struct (or has no internal padding),
// this can be replaced with a single 64-bit integer compare:
//   @as(u64, @bitCast(a)) == @as(u64, @bitCast(b))
// That optimisation is left as a follow-up once Rect's layout is confirmed.

pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
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
