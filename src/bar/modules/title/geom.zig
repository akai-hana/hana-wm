//! Title-segment geometry: the pure layout kernel behind both the title
//! module's split-view draw and the bar's click hit-test.
//!
//! None of it needs `DrawCtx`, `BarHandlers` or any X connection -- it is
//! geometry over a snapshot -- so it is owned by the title module, the only
//! thing that renders it, rather than sharing bar/segment.zig's vocabulary.
//!
//! `segmentBounds` and its inverse are the load-bearing pair: the draw and
//! the hit-test MUST agree on which pixels belong to which window, or a
//! click selects a neighbour. They are here together for that reason --
//! splitting them across files is how the pairing silently rots.
//!
//! A private sibling of `title.zig` in a `modules/` tree, and therefore NOT
//! a segment of its own (like `carousel.zig` beside it): it shares neither
//! its directory name nor the registered binding, so the registry leaves it
//! alone.
//!
//! (Build note: that registry is a TEXT scan for the binding spelling, so
//! this file must never quote the binding declaration literally -- not even
//! in a comment. The first draft did, and the build tried to register
//! geom.zig as a segment.)

const std = @import("std");

const segmod = @import("segment");
const vocab = @import("vocab");

const max_visible_windows = segmod.max_visible_windows;
const TitleSnapshot = vocab.TitleSnapshot;

const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
    minimized: bool,
};

/// Sort order for the split-view: non-minimized first, on-screen (x>=0)
/// before off-screen, then LTR-by-x then TTB-by-y, tie-break by window ID.
/// Focus is NOT a sort key: a focus tie-break would reorder shared-coordinate
/// segments and make the bar jump; the focused window is accent-coloured.
fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    if ((a.x < 0) != (b.x < 0)) return a.x >= 0;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}

/// Caller-frame scratch for the gather phase, shared by hitTest and draw.
pub const GatherScratch = struct {
    window_infos: [max_visible_windows]WindowInfo = undefined,

    /// Builds the sorted WindowInfo list from the snapshot's per-window
    /// entries. Nothing here touches the wire; unknown geometries are dropped.
    pub fn gather(
        self: *GatherScratch,
        snapshot: TitleSnapshot,
    ) ?[]WindowInfo {
        var info_count: usize = 0;
        for (snapshot.entries[0..@min(snapshot.entries.len, max_visible_windows)]) |entry| {
            const wgeom = entry.geom orelse continue;
            self.window_infos[info_count] = .{
                .window = entry.window,
                .x = wgeom.x,
                .y = wgeom.y,
                .title = entry.title,
                .minimized = snapshot.minimized_set.contains(entry.window),
            };
            info_count += 1;
        }
        if (info_count == 0) return null;
        const window_infos = self.window_infos[0..info_count];
        std.sort.heap(WindowInfo, window_infos, {}, compareWindows);
        return window_infos;
    }
};

/// A window resolved from a click inside the title segment: the hit-tested
/// window and whether the snapshot has it minimized. Public because it rides
/// `hitTest`'s return into the bar's click trampoline.
pub const ClickTarget = struct {
    window: u32,
    minimized: bool,
};

/// Pixel-perfect equal tiling shared by the title render and hit-testing:
/// segment `i` of `count` spans [i*W/count, (i+1)*W/count). The tile width
/// x-bounds sum exactly to `total_width` with no fractional residue.
pub fn segmentBounds(total_width: u16, i: usize, count: u32) struct { x: u16, w: u16 } {
    const x0: u16 = @intCast(@divFloor(@as(u32, @intCast(i)) * total_width, count));
    const x1: u16 = @intCast(@divFloor(@as(u32, @intCast(i + 1)) * total_width, count));
    return .{ .x = x0, .w = x1 - x0 };
}

/// Inverse of segmentBounds: the index of the tile containing `offset_x`.
/// The unique `i` whose `[x, x+w)` span covers `offset_x` — not
/// `floor(offset_x * count / total_width)`, which at a tile boundary (any row
/// width not divisible into the count) rounds down into the LEFT neighbour
/// even though the draw already placed the next tile there. Clicking the
/// first pixel of a tile must select that tile's window, or a click selects
/// a neighbour. An `offset_x` past the right edge clamps to `count-1`.
pub fn segmentIndexOfX(total_width: u16, offset_x: u16, count: u32) usize {
    // ceil((offset_x + 1) * count / total_width) - 1, in integer math.
    const num = (@as(u32, offset_x) + 1) * count + total_width - 1;
    return @intCast(@min(count - 1, @divFloor(num, total_width) - 1));
}

/// Resolves which window (if any) is displayed at `offset_x` pixels into the
/// title segment, whose reserved width is `width` (the segment's on-screen box).
/// Pure in-process hit-testing: titles/geoms come from the snapshot's cached
/// per-window values, so it never touches the wire.
///
/// One window, many windows, and the minimized bit are all resolved once, at
/// the end: both layouts name a window, and `minimized` is the same
/// `minimized_set` lookup either way -- in the split view `WindowInfo.minimized`
/// was set by that very expression during the gather.
pub fn hitTest(snapshot: TitleSnapshot, width: u16, offset_x: u16) ?ClickTarget {
    const entries = snapshot.entries;
    if (entries.len == 0) return null;

    const win = if (entries.len == 1) entries[0].window else blk: {
        // Only the split view needs a width to divide into; a lone window is
        // the whole slot whatever the reservation measured.
        if (width == 0) return null;
        var scratch: GatherScratch = .{};
        const sorted = scratch.gather(snapshot) orelse return null;
        break :blk sorted[segmentIndexOfX(width, offset_x, @intCast(sorted.len))].window;
    };
    return .{ .window = win, .minimized = snapshot.minimized_set.contains(win) };
}
