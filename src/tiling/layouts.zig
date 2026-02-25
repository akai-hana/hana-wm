// Common layout interface and utilities.

const std   = @import("std");
const utils = @import("utils");
const debug = @import("debug");
const defs  = @import("defs");
const xcb   = defs.xcb;

// WM_NORMAL_HINTS size hint cache.
// Populated from WM_NORMAL_HINTS during handleMapRequest; evicted on unmanage.
// configureSafe clamps every rect to stored minimums so terminals always
// receive a geometry they can render.

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

// Geometry dedup cache: set by tiling.retile before layout dispatch, cleared
// immediately after. configureSafe skips redundant xcb_configure_window calls
// for windows whose rect has not changed since the last retile.

var g_geom_ctx: ?struct {
    cache:     *std.AutoHashMapUnmanaged(u32, utils.Rect),
    allocator: std.mem.Allocator,
} = null;

/// Called by tiling.retile immediately before layout dispatch.
pub fn armGeomCache(
    cache:     *std.AutoHashMapUnmanaged(u32, utils.Rect),
    allocator: std.mem.Allocator,
) void {
    g_geom_ctx = .{ .cache = cache, .allocator = allocator };
}

/// Called by tiling.retile immediately after layout dispatch.
pub fn disarmGeomCache() void {
    g_geom_ctx = null;
}

/// True when all four rect fields are equal. Exported so tiling.zig can reuse
/// the same comparison in restoreWorkspaceGeom without duplicating it.
pub inline fn rectsEqual(a: utils.Rect, b: utils.Rect) bool {
    return a.x == b.x and a.y == b.y and a.width == b.width and a.height == b.height;
}

/// The single call-site every layout module uses to apply geometry.
/// Clamps to WM_NORMAL_HINTS minimums and, when the cache is armed, skips
/// the XCB call for windows whose rect matches the last applied value.
pub inline fn configureSafe(
    conn: *xcb.xcb_connection_t,
    win:  u32,
    rect: utils.Rect,
) void {
    // Clamp to WM_NORMAL_HINTS minimums.
    // Terminals advertise min_height equal to one character row; sending
    // anything smaller causes them to stall.
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
            if (rectsEqual(cached, effective)) return; // geometry unchanged; skip redundant XCB call
        }
        // Store before sending so duplicate sub-calls within the same retile
        // pass (e.g. overflow cells) are also deduplicated.
        ctx.cache.put(ctx.allocator, win, effective) catch {};
    }

    utils.configureWindow(conn, win, effective);
}
