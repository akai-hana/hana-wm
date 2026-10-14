//! Title-segment geometry: the pure layout kernel behind both the title
//! module's split-view draw and the bar's click hit-test.
//!
//! It lived in bar/segment.zig next to the shared segment vocabulary, which
//! made that file read as "one thing" while mixing three unrelated concerns:
//! the vocabulary every segment imports, the title's window list and its
//! pixel-perfect tiling, and the registry helpers. None of this needs
//! `DrawCtx`, `BarHandlers` or any X connection -- it is geometry over a
//! snapshot -- so it is split out (21.6) and owned by the title module, which
//! is the only thing that renders it.
//!
//! `segmentBounds` and its inverse are the load-bearing pair: the draw and the
//! hit-test MUST agree on which pixels belong to which window, or a click
//! selects a neighbour. They are here together for that reason -- that pairing
//! is the invariant, and splitting them across files is how it silently rots.
//!
//! A private sibling of `title.zig` in a `modules/` tree, and therefore
//! NOT a segment of its own: it shares neither its directory name nor the
//! binding a registered module declares, so the build registry leaves it
//! alone. `carousel.zig` already sits beside `title.zig` in exactly this
//! arrangement, as an addon rather than a segment.
//!
//! (Build note: that registry is a TEXT scan for the binding spelling, so
//! this file must never quote the binding declaration literally -- not even in
//! a comment. The first draft did, and the build tried to register geom.zig as
//! a segment.)

const std = @import("std");

const segmod = @import("segment");

const max_visible_windows = segmod.max_visible_windows;
const TitleSnapshot = segmod.TitleSnapshot;

pub const WindowInfo = struct {
    window: u32,
    x: i16,
    y: i16,
    title: []const u8,
    minimized: bool,
};

/// Sort order for the split-view segment layout:
///
///   1. Non-minimized windows first (minimized shown last/rightmost, matching
///      their visual demotion in tiling).
///   2. On-screen before off-screen.  Negative-x windows (monocle background)
///      are off-screen; demoting them stops artificial coordinates overriding
///      real spatial ordering.
///   3. Left-to-right by x, then top-to-bottom by y, keeps each window's
///      segment stable across focus changes.
///   4. Tie-break by window ID for deterministic ordering.
///
/// Focus is intentionally NOT a sort key: using it as a tie-break would
/// reorder segments when two windows share coordinates, making the bar jump
/// on focus changes. The focused window is highlighted via accent colour.
fn compareWindows(_: void, a: WindowInfo, b: WindowInfo) bool {
    if (a.minimized != b.minimized) return !a.minimized;
    if ((a.x < 0) != (b.x < 0)) return a.x >= 0;
    if (a.x != b.x) return a.x < b.x;
    if (a.y != b.y) return a.y < b.y;
    return a.window < b.window;
}

/// Caller-frame scratch for the gather phase, shared verbatim by hitTest and
/// the title module's draw. The gather is the method rather than a private fn
/// beside it: it had exactly one caller, and forwarding three arguments just to
/// reach its own field was a second name for a single step.
pub const GatherScratch = struct {
    window_infos: [max_visible_windows]WindowInfo = undefined,

    /// Builds the sorted WindowInfo list for the split view from the
    /// snapshot's per-window entries (id + title + geom). The bar already
    /// resolved both per window id from in-process caches (WM title cache +
    /// sync truth-rect), so nothing here touches the wire and no positional
    /// batch exists to scramble. Windows with an unknown geometry are dropped,
    /// not padded.
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
        std.mem.sort(WindowInfo, window_infos, {}, compareWindows);
        return window_infos;
    }
};

/// A window resolved from a click inside the title segment.
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

/// Inverse of segmentBounds: the segment index under `offset_x` pixels, i.e.
/// `partitionPoint(total_width, offset_x, count)` is the smallest `i` with
/// `segmentBounds(total_width, i, count).x > offset_x`, clamped to `count-1`.
pub fn segmentIndexOfX(total_width: u16, offset_x: u16, count: u32) usize {
    return @intCast(@min(
        count - 1,
        @divFloor(@as(u32, offset_x) * count, @as(u32, total_width)),
    ));
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
