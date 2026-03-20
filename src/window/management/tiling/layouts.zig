//! Common layout interface and utilities shared by all layout modules.

const std = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const core = @import("core");
const xcb = core.xcb;

// WM_NORMAL_HINTS size hint cache
//
// Populated from WM_NORMAL_HINTS during handleMapRequest; evicted on unmanage.
// configureSafe clamps every rect to stored minimums so terminals always
// receive a geometry they can render.
//
// g_hints lives here as a module global rather than in tiling.State because
// threading the allocator through evictSizeHints would require changes to
// window.zig. The trade-off is that this map is not rebuilt on reloadConfig,
// so cached hints persist across reloads (harmless in practice: hints are
// window-level properties that do not change with config).

pub const SizeHints = struct {
    min_width: u16 = 0,
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

pub const CacheMap = std.AutoHashMapUnmanaged(u32, WindowData);

// Layout context
//
// Every layout module receives a *const LayoutCtx; configureSafe reads the
// cache from it rather than from a module-level global, making the dependency
// explicit and eliminating hidden call-site ordering requirements.

pub const LayoutCtx = struct {
    conn: *xcb.xcb_connection_t,
    /// Pointer into tiling.State.cache. Always non-null during a retile pass.
    cache: *CacheMap,
    allocator: std.mem.Allocator,
};

/// Returns true if two rects are identical via a single 64-bit comparison.
/// utils.Rect is `extern struct { i16, i16, u16, u16 }` — 8 bytes, no padding.
/// A single 64-bit comparison compiles to one instruction on all targets versus
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
    // Clamp to WM_NORMAL_HINTS minimums.
    const effective: utils.Rect = if (g_hints.get(win)) |h| .{
        .x = rect.x,
        .y = rect.y,
        .width = @max(rect.width, h.min_width),
        .height = @max(rect.height, h.min_height),
    } else rect;

    if (!effective.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}",
            .{ win, effective.width, effective.height, effective.x, effective.y });
        return;
    }

    const gop = ctx.cache.getOrPut(ctx.allocator, win) catch {
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
    utils.configureWindow(ctx.conn, win, effective);
}
