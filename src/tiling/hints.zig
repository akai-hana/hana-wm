//! ICCCM WM_NORMAL_HINTS geometry constraints on tiled windows.
//! Applies increment snap, max-size clamp, and aspect clamp to a layout rect.

const std = @import("std");
const utils = @import("utils");
const model = @import("model");

/// Apply ICCCM section 4.1.2.3 hints to a raw rect: increment snap, max-size
/// clamp, then aspect clamp (with a re-snap, since a client may declare both).
/// Declared minimums are intentionally NOT enforced; tiling owns window size,
/// and honouring them would pin the rect and block mod_h/mod_l resizing.
pub fn applyHints(rect: utils.Rect, h: model.SizeHints) utils.Rect {
    if (h.isEmpty()) return rect;
    var width: u16 = rect.width;
    var height: u16 = rect.height;

    width = snapDimToIncrement(width, 0, h.inc_width);
    height = snapDimToIncrement(height, 0, h.inc_height);

    if (h.max_width > 0) width = @min(width, h.max_width);
    if (h.max_height > 0) height = @min(height, h.max_height);

    // min_aspect = h/w lower bound, max_aspect = w/h upper bound (dwm
    // convention); cross-multiplied to avoid FP division per retile.
    //
    // The aspect clamp recomputes from scratch and can land off the increment
    // grid (e.g. PResizeInc + PAspect on a terminal); re-snapping afterward
    // floors to the grid without exceeding max_width/height.
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(width);
        const fh: f32 = @floatFromInt(height);
        if (fw > fh * h.max_aspect) {
            // Clamp the float-derived dimension to u16 range before the
            // narrowing cast: a misbehaving client can declare a huge
            // max_aspect (e.g. 1e6), and @intFromFloat out of range would
            // panic/UB instead of being capped by the later max_width min.
            const aspect_w: u16 = @intFromFloat(@min(@round(fh * h.max_aspect), @as(f32, std.math.maxInt(u16))));
            width = snapDimToIncrement(aspect_w, 0, h.inc_width);
            if (h.max_width > 0) width = @min(width, h.max_width);
        } else if (fh > fw * h.min_aspect) {
            const aspect_h: u16 = @intFromFloat(@min(@round(fw * h.min_aspect), @as(f32, std.math.maxInt(u16))));
            height = snapDimToIncrement(aspect_h, 0, h.inc_height);
            if (h.max_height > 0) height = @min(height, h.max_height);
        }
    }

    // Centre the (possibly shrunk) window inside its allocated slot.
    // Saturating: every clamp above only shrinks, but a future path that
    // lets w exceed the slot must degrade to dx=0, not panic in release-safe
    // (identical for all current flows).
    const dx: i16 = @intCast((rect.width -| width) / 2);
    const dy: i16 = @intCast((rect.height -| height) / 2);
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = width, .height = height };
}

/// Snap `dim` down to the nearest multiple of `inc` above `base`.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const excess = dim - base;
    return base + (excess / inc) * inc;
}
