//! Per-window border/hints cache.
//! Dedupes border color/width for sync and bridges WM_NORMAL_HINTS into the
//! model; geometry lives in the model/sync ledger instead.

const std = @import("std");

const core = @import("core");
const utils = @import("utils");
const model_mod = @import("model");

/// Single logical type: the model's SizeHints. The former layouts.SizeHints
/// copy (with its comptime shape guard) is gone -- caching stores model
/// entries directly, so the actions.mapRequest bridge needs no conversion.
pub const SizeHints = model_mod.SizeHints;

pub const WindowData = struct {
    border: u32 = 0,
    hints: SizeHints = .{},
    /// Last BORDER_WIDTH value sent for this window; null until first sent.
    /// The optional matters: 0 is a legitimate configured width, and treating
    /// it as "never sent" would re-issue the configure forever, while treating
    /// "never sent" as 0 could skip the first send and leave a client-created
    /// non-zero width standing.
    applied_border_width: ?u16 = null,
};

pub const CacheMap = std.AutoHashMap(u32, WindowData);

/// Hard upper bound on cached windows.  A normal desktop never exceeds a
/// few dozen managed windows; 512 is a generous ceiling that prevents
/// unbounded heap growth from a runaway client without impacting
/// legitimate use.
const max_entries = 512;

// Module-level singleton

// Null before init(), non-null for the rest of the process lifetime.
var cache: ?CacheMap = null;

/// Returns a pointer to the live cache. Panics in all build modes when
/// called before init(); never silent UB.
inline fn live() *CacheMap {
    if (cache) |*c| return c;
    @panic("wincache: accessed before init()");
}

/// Safe pre-init query; returns null only during the narrow startup window
/// before init().
pub inline fn getOpt() ?*CacheMap {
    return if (cache) |*c| c else null;
}

pub fn init(alloc: std.mem.Allocator) void {
    cache = CacheMap.init(alloc);
}

pub fn deinit() void {
    if (cache) |*c| c.deinit();
    cache = null;
}

/// Centralizes the get-or-put-with-default pattern for writers that don't
/// distinguish "existing" from "new".  Returns `error.CacheFull` when the
/// cache has reached `max_entries`, which callers treat like OOM (skip the
/// update gracefully).
fn getOrPutDefault(win: u32) !*WindowData {
    const c = live();
    if (c.count() >= max_entries) return error.CacheFull;
    const gop = try c.getOrPut(win);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// No-op if every field is zero (nothing declared).
pub fn cacheSizeHints(win: u32, hints: SizeHints) void {
    if (hints.isEmpty()) return;
    const wd = getOrPutDefault(win) catch return; // OOM: leave hints uncached.
    wd.hints = hints;
}

/// PIPELINE bridge: read-back accessor so actions can copy cached hints into
/// the model entry at registration time. Defaults when absent.
pub fn peekHints(win: u32) SizeHints {
    if (getOpt()) |c| {
        if (c.get(win)) |wd| return wd.hints;
    }
    return .{};
}

/// Record `w` as the BORDER_WIDTH last sent to `win`. Returns true when the
/// entry already held exactly that value, letting callers skip a redundant
/// configure_window. Windows without a cache entry always report "changed"
/// (and gain one) so the first apply after registration is never skipped.
pub fn cacheBorderWidth(win: u32, w: u16) bool {
    _ = getOpt() orelse return false;
    const wd = getOrPutDefault(win) catch return false;
    if (wd.applied_border_width) |applied| {
        if (applied == w) return true;
    }
    wd.applied_border_width = w;
    return false;
}

/// Evict a window's entire cache entry: geometry, border dedup data AND the
/// embedded WM_NORMAL_HINTS in one operation. No-op when never cached.
pub fn removeWindow(window_id: u32) void {
    _ = live().remove(window_id);
}

fn updateBorderColor(
    conn: core.Connection,
    win: u32,
    color: u32,
    comptime create_if_missing: bool,
) bool {
    if (create_if_missing) {
        // Bounded by max_entries like every other writer: refuse to grow past
        // the ceiling so WM-churn of distinct windows can't bloat the cache
        // (the caller falls back to an unconditional send in that case).
        const wd = getOrPutDefault(win) catch return false;
        if (wd.border == color) return true;
        wd.border = color;
        utils.setBorderPixel(conn, win, color);
        return true;
    }
    const wd = live().getPtr(win) orelse return false;
    if (wd.border == color) return true;
    wd.border = color;
    utils.setBorderPixel(conn, win, color);
    return true;
}

/// Sends the border-pixel change for `win` unless the cache already shows
/// that exact color as applied, and RECORDS the color either way. The
/// recording is load-bearing, not just an optimization: values forced
/// outside this function (fullscreen's pixel 0) must end up in the cache,
/// or the next real color change dedups against a stale value and is
/// silently skipped -- the un-fullscreen "lost borders" bug. Returns false
/// only when the cache is unavailable (not initialized); callers then fall
/// back to an unconditional send.
pub fn sendBorderColorIfChanged(win: u32, color: u32) bool {
    const conn = core.getState().conn;
    return updateBorderColor(conn, win, color, true);
}
