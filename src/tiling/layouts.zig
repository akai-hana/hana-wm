/// Common layout interface and utilities

const std   = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const defs  = @import("defs");
const xcb   = defs.xcb;

// WM_NORMAL_HINTS size hint cache ──────────────────────────────────────────
//
// Populated from WM_NORMAL_HINTS during handleMapRequest and evicted on
// unmanage.  configureSafe clamps every rect to the stored minimums so that
// terminals (which stall when given a height smaller than one character row)
// always receive a geometry they can actually render.

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

/// Free the entire size-hints map.  Call once at WM shutdown alongside the
/// other global deinitialisers.  Without this every mapped window that
/// advertised WM_NORMAL_HINTS leaks an entry.
pub fn deinitSizeHintsCache(allocator: std.mem.Allocator) void {
    g_hints.deinit(allocator);
}

// Geometry cache set by tiling.retile before dispatching to layout modules,
// cleared immediately after.  configureSafe checks this to skip redundant
// xcb_configure_window calls for windows whose position/size hasn't changed.

const GeomCacheCtx = struct {
    cache:     *std.AutoHashMapUnmanaged(u32, utils.Rect),
    allocator: std.mem.Allocator,
};

var g_geom_ctx: ?GeomCacheCtx = null;

/// Called by tiling.retile immediately before the layout dispatch.
pub fn armGeomCache(
    cache:     *std.AutoHashMapUnmanaged(u32, utils.Rect),
    allocator: std.mem.Allocator,
) void {
    g_geom_ctx = .{ .cache = cache, .allocator = allocator };
}

/// Called by tiling.retile immediately after the layout dispatch.
pub fn disarmGeomCache() void {
    g_geom_ctx = null;
}

// configureSafe; the single call-site every layout module uses to apply
// geometry.  With the cache armed, calls for unchanged windows are elided.

/// Unified error-handling wrapper for configure operations.
/// When the geometry cache is armed, skips the XCB call for windows whose
/// rect matches what was last applied to the server.
pub inline fn configureSafe(
    conn: *xcb.xcb_connection_t,
    win:  u32,
    rect: utils.Rect,
) void {
    // Clamp to WM_NORMAL_HINTS minimums.  Terminals advertise a min_height
    // equal to one character row; sending anything smaller causes them to stall
    // waiting for a valid geometry.  This is the canonical fix — identical to
    // what dwm does in its resize() function.
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

    if (g_geom_ctx) |ctx| {
        if (ctx.cache.get(win)) |cached| {
            if (cached.x      == effective.x      and
                cached.y      == effective.y      and
                cached.width  == effective.width  and
                cached.height == effective.height)
            {
                return; // geometry unchanged; skip redundant XCB call
            }
        }
        // Store before sending so that any duplicate sub-calls within the
        // same retile pass (e.g. overflow cells) are also deduplicated.
        ctx.cache.put(ctx.allocator, win, effective) catch {};
    }

    utils.configureWindow(conn, win, effective);
}

/// Monocle-specific fast path: all windows share the same rect, so one cache
/// check on the first window determines whether any work needs doing at all.
/// If the geometry is unchanged every window is skipped in O(1).
/// If it changed, we send XCB calls and update the cache for all windows
/// without the per-window hash lookup overhead of calling configureSafe N times.
pub fn testAndApplyMonocleRect(
    conn:    *xcb.xcb_connection_t,
    windows: []const u32,
    rect:    utils.Rect,
) void {
    const ctx = g_geom_ctx orelse {
        // Cache not armed — fall back to a plain configure for every window.
        for (windows) |win| utils.configureWindow(conn, win, rect);
        return;
    };

    // Single cache probe against the first window decides for all.
    if (ctx.cache.get(windows[0])) |cached| {
        if (cached.x      == rect.x     and
            cached.y      == rect.y     and
            cached.width  == rect.width and
            cached.height == rect.height)
        {
            return; // geometry unchanged for every window; nothing to send
        }
    }

    // Geometry changed — configure all windows and update the cache in one pass.
    for (windows) |win| {
        utils.configureWindow(conn, win, rect);
        ctx.cache.put(ctx.allocator, win, rect) catch {};
    }
}
