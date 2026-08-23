//! ICCCM WM_NORMAL_HINTS geometry constraints applied to layout rects.
//! Moved verbatim from the legacy tiling layouts module (WP2 step 2);
//! only the hints type now comes from the model's strangler copy.

const utils = @import("utils");
const model = @import("model");

/// Apply ICCCM §4.1.2.3 hints to a raw rect: increment snap, max-size clamp,
/// then aspect clamp (with a re-snap, since a client may declare both).
/// Declared minimums are intentionally NOT enforced; tiling owns window size,
/// and honouring them would pin the rect and block mod_h/mod_l resizing.
pub fn applyHints(rect: utils.Rect, h: model.SizeHints) utils.Rect {
    if (isEmptySizeHints(h)) return rect;
    var w: u16 = rect.width;
    var ht: u16 = rect.height;

    w = snapDimToIncrement(w, 0, h.inc_width);
    ht = snapDimToIncrement(ht, 0, h.inc_height);

    if (h.max_width > 0) w = @min(w, h.max_width);
    if (h.max_height > 0) ht = @min(ht, h.max_height);

    // min_aspect = h/w lower bound, max_aspect = w/h upper bound (dwm
    // convention); cross-multiplied to avoid FP division per retile.
    //
    // The aspect clamp recomputes from scratch and can land off the increment
    // grid (e.g. PResizeInc + PAspect on a terminal); re-snapping afterward
    // floors to the grid without exceeding max_width/height.
    if (h.min_aspect > 0.0 and h.max_aspect > 0.0) {
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(ht);
        if (fw > fh * h.max_aspect) {
            w = @intFromFloat(@round(fh * h.max_aspect));
            w = snapDimToIncrement(w, 0, h.inc_width);
            if (h.max_width > 0) w = @min(w, h.max_width);
        } else if (fh > fw * h.min_aspect) {
            ht = @intFromFloat(@round(fw * h.min_aspect));
            ht = snapDimToIncrement(ht, 0, h.inc_height);
            if (h.max_height > 0) ht = @min(ht, h.max_height);
        }
    }

    // Centre the (possibly shrunk) window inside its allocated slot.
    const dx: i16 = @intCast((rect.width - w) / 2);
    const dy: i16 = @intCast((rect.height - ht) / 2);
    return .{ .x = rect.x + dx, .y = rect.y + dy, .width = w, .height = ht };
}

/// Snap `dim` down to the nearest multiple of `inc` above `base`.
inline fn snapDimToIncrement(dim: u16, base: u16, inc: u16) u16 {
    if (inc == 0 or dim <= base) return dim;
    const excess = dim - base;
    return base + (excess / inc) * inc;
}

inline fn isEmptySizeHints(h: model.SizeHints) bool {
    return h.max_width == 0 and h.max_height == 0 and
        h.inc_width == 0 and h.inc_height == 0 and
        h.min_aspect == 0.0 and h.max_aspect == 0.0;
}
