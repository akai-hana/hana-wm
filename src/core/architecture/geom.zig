//! Geometry vocabulary: the rect/margin types the data model owns, plus the
//! coordinate helpers that convert into and out of X's i16-on-the-wire range.
//!
//! X-free by construction and enforced as a build-time pure root (see
//! `assertPureLayerImports` in build.zig): `model.BaseMode.floating` is a
//! `Rect` and the layout engine computes in it, so nothing here may reach the
//! protocol. The one xcb-typed adapter, `rectFromXcb`, therefore lives on the
//! x11 side in `requests.zig`.

const std = @import("std");

/// Position and dimensions of a managed window, relative to the root window
/// (the total display area).
pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16 = 0,

    pub inline fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and self.width == other.width and
            self.height == other.height and self.border_width == other.border_width;
    }
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap: u16 = 0,
    border: u16 = 0,
};

/// Twice the border width (left+right / top+bottom inset).
pub inline fn doubledBorder(m: Margins) u16 {
    return 2 *| m.border;
}

/// Saturating i16 coordinate clamp: narrows an i32 coordinate into the i16
/// `Rect` range, clamping instead of wrapping so a single pathological value
/// can't cross the whole screen in ReleaseFast.
pub inline fn satI16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// Reinterprets a signed X11 coordinate (i16 on the wire) as the u32 value
/// XCB's configure_window value array expects.
pub inline fn toXcbCoord(v: i16) u32 {
    return @bitCast(@as(i32, v));
}
