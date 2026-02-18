/// Common layout interface and utilities

const std   = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const defs  = @import("defs");
const xcb   = defs.xcb;

// ---------------------------------------------------------------------------
// Geometry cache — set by tiling.retile before dispatching to layout modules,
// cleared immediately after.  configureSafe checks this to skip redundant
// xcb_configure_window calls for windows whose position/size hasn't changed.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// configureSafe — the single call-site every layout module uses to apply
// geometry.  With the cache armed, calls for unchanged windows are elided.
// ---------------------------------------------------------------------------

/// Unified error-handling wrapper for configure operations.
/// When the geometry cache is armed, skips the XCB call for windows whose
/// rect matches what was last applied to the server.
pub inline fn configureSafe(
    conn: *xcb.xcb_connection_t,
    win:  u32,
    rect: utils.Rect,
) void {
    if (!rect.isValid()) {
        debug.err("Invalid rect for window 0x{x}: {}x{} at {},{}", 
            .{ win, rect.width, rect.height, rect.x, rect.y });
        return;
    }

    if (g_geom_ctx) |ctx| {
        if (ctx.cache.get(win)) |cached| {
            if (cached.x      == rect.x      and
                cached.y      == rect.y      and
                cached.width  == rect.width  and
                cached.height == rect.height)
            {
                return; // geometry unchanged — skip redundant XCB call
            }
        }
        // Store before sending so that any duplicate sub-calls within the
        // same retile pass (e.g. overflow cells) are also deduplicated.
        ctx.cache.put(ctx.allocator, win, rect) catch {};
    }

    utils.configureWindow(conn, win, rect);
}
