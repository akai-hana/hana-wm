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
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(width);
        const fh: f32 = @floatFromInt(height);
        // Clamp to u16 range before narrowing so a huge aspect ratio caps.
        if (fw > fh * h.max_aspect) {
            width = clampAspectDim(fh, h.max_aspect, h.inc_width, h.max_width);
        } else if (fh > fw * h.min_aspect) {
            height = clampAspectDim(fw, h.min_aspect, h.inc_height, h.max_height);
        }
    }

    // Centre the (possibly shrunk) window inside its allocated slot.
    const dx: i16 = @intCast((rect.width -| width) / 2);
    const dy: i16 = @intCast((rect.height -| height) / 2);
    return .{
        .x = rect.x + dx,
        .y = rect.y + dy,
        .width = width,
        .height = height,
    };
}

/// Clamp `other * ratio` (a cross-multiplied aspect product) into u16 range,
/// snap down to the increment, then cap at `max_dim`.
inline fn clampAspectDim(other: f32, ratio: f32, inc: u16, max_dim: u16) u16 {
    const aspect: u16 = @intFromFloat(
        @min(@round(other * ratio), @as(f32, std.math.maxInt(u16))),
    );
    var dim = snapDimToIncrement(aspect, 0, inc);
    if (max_dim > 0) dim = @min(dim, max_dim);
    return dim;
}

/// Snap `dim` down to the nearest multiple of `inc` above `base`.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const excess = dim - base;
    return base + (excess / inc) * inc;
}
