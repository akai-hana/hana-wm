//! Core utilities — FACADE (D6 split).
//!
//! The former grab-bag is split into focused siblings; this file keeps only
//! pure, xcb-free geometry/scaling helpers and re-exports every public decl
//! so existing `utils.X` call sites are unchanged:
//!
//!   bounded.zig   BoundedList                       (xcb-free)
//!   threading.zig Mutex/Condition/CondThread        (xcb-free)
//!   proc.zig      lifecycle flags, wake pipe, pipes  (xcb-free)
//!   time.zig      clock helpers                      (xcb-free)
//!   x11wire.zig   atoms/EWMH/properties/grab/configure shims (xcb-DEPENDENT)
//!
//! Layer note: model/tiling reference only the xcb-free decls here and in
//! this file's own pure section. x11wire exists so the wire primitives have
//! one honest home (check-layers' "wire primitives" allowlist entry).

const std = @import("std");
const constants = @import("constants");

const proc = @import("proc.zig");
const time = @import("time.zig");
const threading = @import("threading.zig");
const bounded = @import("bounded.zig");
const x11wire = @import("x11wire.zig");

// --- process lifecycle (re-exports) --------------------------------------
pub const running = &proc.running;
pub const wake_byte = proc.wake_byte;
pub const setSignalWriteFd = proc.setSignalWriteFd;
pub const quit = proc.quit;
pub const reload = proc.reload;
pub const consumeReload = proc.consumeReload;
pub const makePipe = proc.makePipe;

// --- time (re-exports) ----------------------------------------------------
pub const clockNs = time.clockNs;
pub const monotonicNs = time.monotonicNs;
pub const realtimeNs = time.realtimeNs;

// --- threading (re-exports) ------------------------------------------------
pub const Mutex = threading.Mutex;
pub const Condition = threading.Condition;
pub const CondThread = threading.CondThread;

// --- bounded collections (re-exports) ---------------------------------------
pub const BoundedList = bounded.BoundedList;

// --- X11 wire primitives (re-exports; xcb-dependent live in x11wire.zig) ---
pub const initAtomCache = x11wire.initAtomCache;
pub const getAtomCached = x11wire.getAtomCached;
pub const getAtomOrZero = x11wire.getAtomOrZero;
pub const advertiseEwmhSupport = x11wire.advertiseEwmhSupport;
pub const fetchPropertyToBuffer = x11wire.fetchPropertyToBuffer;
pub const configureWindow = x11wire.configureWindow;
pub const raiseWindow = x11wire.raiseWindow;
pub const pushWindowOffscreen = x11wire.pushWindowOffscreen;
pub const pushWindowOffscreenAndLower = x11wire.pushWindowOffscreenAndLower;
pub const setBorderPixel = x11wire.setBorderPixel;
pub const grab_active = x11wire.grab_active;
pub const isGrabActive = x11wire.isGrabActive;
pub const grabServer = x11wire.grabServer;
pub const ungrabServer = x11wire.ungrabServer;
pub const ungrabAndFlush = x11wire.ungrabAndFlush;
pub const rectFromXcb = x11wire.rectFromXcb;
pub const isOffscreenGeomReply = x11wire.isOffscreenGeomReply;

// ---------------------------------------------------------------------------
// Pure geometry & scaling (xcb-free; safe for model/tiling)

/// Position and dimensions of a managed window, relative to the root window (the total display area).
pub const Rect = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16 = 0,

    pub inline fn eql(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and self.width == other.width and self.height == other.height and self.border_width == other.border_width;
    }
};

/// Gap and border widths applied around a tiled window.
pub const Margins = struct {
    gap: u16,
    border: u16,
};

/// Twice the border width (left+right / top+bottom inset).
pub inline fn doubledBorder(m: Margins) u16 {
    return 2 *| m.border;
}

/// Reinterprets a signed X11 coordinate (i16 on the wire) as the u32 value
/// XCB's configure_window value array expects.
pub inline fn toXcbCoord(v: i16) u32 {
    return @bitCast(@as(i32, v));
}

/// Strips lock-key and pointer-button bits from a raw event modifier state,
/// leaving only the modifier bits the WM uses for keybinding matching.
pub inline fn normalizeModifiers(state: u16) u16 {
    return state & constants.mod_mask_binding;
}

// Canonical scaling formulas: pure functions of a ScalableValue, no DPI
// lookup. scale.zig and config.zig both call into these, so there is exactly
// one formula to maintain.
pub const scaling = struct {
    /// Resolves a ScalableValue to a ratio: `v%` becomes v/100, an absolute
    /// value stays as-is.
    pub inline fn asRatio(value: anytype) f32 {
        return if (value.is_percentage) value.value / 100.0 else value.value;
    }
    /// Resolves a ScalableValue against a reference dimension: `v%` becomes
    /// reference * v/100, an absolute value stays as-is (reference unused).
    pub inline fn scaleToPixels(value: anytype, reference: f32) f32 {
        return if (value.is_percentage) reference * (value.value / 100.0) else value.value;
    }
    /// reference dimension, matching the two-sided inset a border represents.
    pub fn scaleBorderWidth(value: anytype, reference_dimension: u16) u16 {
        const v: f32 = if (value.is_percentage)
            (value.value / 100.0) * 0.5 * @as(f32, @floatFromInt(reference_dimension))
        else
            value.value;
        return roundToU16(v, 0.0);
    }
    /// Rounds `v` to the nearest integer and clamps it into [min, maxInt(u16)].
    pub inline fn roundToU16(v: f32, min: f32) u16 {
        const clamped = std.math.clamp(@round(v), min, @as(f32, std.math.maxInt(u16)));
        return @intFromFloat(clamped);
    }
};
