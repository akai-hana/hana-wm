//! Pure. Reads model types; emits Placements. No xcb.
const std = @import("std");
const utils = @import("utils");
const model = @import("model");

pub const hints = @import("hints");
const applyHints = hints.applyHints;

pub const Placement = struct {
    win: model.WindowId,
    rect: utils.Rect,
    visible: bool,
};

/// Sentinel rect for parked placements (≙ legacy layouts.zero_rect). The
/// sync layer derives parked geometry from its own policy, never from this.
pub const parked_rect: utils.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// Frozen size-hint snapshot aligned index-for-index with View.order.
/// The caller materializes one hint per ordered window; lookup is a scan
/// over the (small) order slice only.
///
/// Why not a sorted/binary-search or hash-map optimization:
///   - The order slice is bounded by `max_tiled_windows` (200), making the
///     worst-case O(n²) across all emit() calls 40 K comparisons — negligible.
///   - HintsView is rebuilt from stack-allocated buffers each layout pass
///     (sync.zig), so there is no persistent data to index.
///   - The struct uses only slices (no allocator); adding a map would break
///     the zero-allocation compute() path.
///   - `forWin` is only called from emit() and master.zig:windowMaxHeight,
///     both per-window within a single layout pass.
pub const HintsView = struct {
    order: []const model.WindowId,
    hints: []const model.SizeHints,

    /// Returns hints BY VALUE with a default fallback.
    pub fn forWin(self: *const HintsView, win: model.WindowId) model.SizeHints {
        std.debug.assert(self.order.len == self.hints.len);
        for (self.order, self.hints) |w, h| {
            if (w == win) return h;
        }
        return .{};
    }
};

/// Caller-resolved environment (one bundled field instead of five per-layout
/// booleans/params that each new layout would grow). Resolved from config by
/// sync's caller; sync.Env aliases this type.
pub const Env = struct {
    margins: utils.Margins = .{ .gap = 0, .border = 0 },
    min_dim: u16 = 0,
    master_on_right: bool = false,
    grid_relaxed: bool = false,
    monocle_gaps: bool = false,
};

pub const View = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: utils.Rect,
    hints: *const HintsView,
    focused: ?model.WindowId,
    // Environment resolved by the CALLER from config.
    env: Env = .{},
};

/// Zero-allocation placement buffer (std.ArrayList lost its managed form in
/// Zig 0.16 and an allocator parameter would break the frozen compute()
/// signature / P2 purity). Capacity bounds one placement per stored window.
pub const List = utils.BoundedList(Placement, model.store_capacity);

/// Prefer `v.focused` when it appears in `windows`, else `fallback`
/// (verbatim port of layouts.focusedElse).
pub fn focusedElse(v: *const View, windows: []const model.WindowId, fallback: model.WindowId) model.WindowId {
    if (v.focused) |f| if (std.mem.indexOfScalar(model.WindowId, windows, f) != null) return f;
    return fallback;
}

/// Shrinks `dim` by `margin` (gap/border), floored to `min_dim` so a layout
/// never hands a client a zero or negative size (verbatim port).
pub inline fn shrinkClamped(dim: u16, margin: u16, min_dim: u16) u16 {
    return if (dim > margin) dim - margin else min_dim;
}

/// Work-area rect inset by the outer gap (verbatim port of layouts.outerArea).
/// x/y are i32 (some tiling layouts thread i32 coords through their recursion),
/// w/h u16.
pub inline fn outerArea(wa: utils.Rect, gap: u16) struct { x: i32, y: i32, w: u16, h: u16 } {
    return .{
        .x = @intCast(gap),
        .y = @intCast(@as(u16, @intCast(@max(wa.y, 0))) +| gap),
        .w = wa.width -| gap *| 2,
        .h = wa.height -| gap *| 2,
    };
}

/// Work-area origin y clamped to >= 0, as u16 (legacy `y_offset` threading:
/// every layout positioned windows relative to the screen top, not the root).
pub inline fn waY(v: *const View) u16 {
    return @intCast(@max(v.workarea.y, 0));
}

/// Emit a placement with the window's size hints applied to `rect`.
inline fn emit(v: *const View, out: *List, win: model.WindowId, rect: utils.Rect, visible: bool) void {
    _ = out.append(.{
        .win = win,
        .rect = if (visible) applyHints(rect, v.hints.forWin(win)) else parked_rect,
        .visible = visible,
    });
}

/// Emit a parked placement (≙ pushWindowOffscreenAndInvalidate transform).
inline fn emitParked(out: *List, win: model.WindowId) void {
    _ = out.append(.{ .win = win, .rect = parked_rect, .visible = false });
}

pub fn compute(kind: model.LayoutKind, v: View, out: *List) void {
    out.clear();
    switch (kind) {
        .master => @import("master").compute(v, out),
        .monocle => @import("monocle").compute(v, out),
        .fibonacci => @import("fibonacci").compute(v, out),
        .grid => @import("grid").compute(v, out),
        .leaf => @import("leaf").compute(v, out),
        .scroll => @import("scroll").compute(v, out),
    }
}

// Algo modules share this file's private emit helpers via pub re-exports.
pub const emitView = emit;
pub const emitHidden = emitParked;
