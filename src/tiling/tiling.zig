//! Dispatch engine for the tiling sub-system.
//! Reads model types and emits placements; no XCB and no allocation.

const std = @import("std");
const utils = @import("utils");
const model = @import("model");
const build_options = @import("build_options");

const plugin = @import("plugin");

/// ICCCM section 4.1.2.3 size-hint application: increment snap, max-size
/// clamp, then aspect clamp (with a re-snap, since a client may declare both).
/// Declared minimums are intentionally NOT enforced; tiling owns window size,
/// and honouring them would pin the rect and block mod_h/mod_l resizing.
pub fn applyHints(rect: utils.Rect, h: model.SizeHints) utils.Rect {
    if (h.isEmpty()) return rect;
    var width: u16 = rect.width;
    var height: u16 = rect.height;

    width = snapDimToIncrement(width, h.inc_width);
    height = snapDimToIncrement(height, h.inc_height);

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
    const aspect = utils.scaling.roundToU16(other * ratio, 0.0);
    var dim = snapDimToIncrement(aspect, inc);
    if (max_dim > 0) dim = @min(dim, max_dim);
    return dim;
}

/// Snap `dim` down to the nearest multiple of `inc`.
inline fn snapDimToIncrement(dim: u16, inc: u16) u16 {
    if (inc == 0) return dim;
    return (dim / inc) * inc;
}

// The layout interchange vocabulary lives on the tiling CONTRACT (plugin.zig)
// so the always-compiled reconciler can name it even without this tiling engine;
// here we only re-export it so modules keep referring to `tiling.List` etc.
pub const Placement = plugin.Placement;
pub const parked_rect = plugin.parked_rect;
pub const HintsView = plugin.HintsView;
pub const Env = plugin.Env;
pub const View = plugin.View;
pub const List = plugin.List;
pub const LayoutCtx = struct {
    v: *const View,
    out: *List,
    m: utils.Margins,
    min_dim: u16,
};

/// Prefer `v.focused` when it appears in `windows`, else `fallback`
/// (verbatim port of layouts.focusedElse).
pub fn focusedElse(
    v: *const View,
    windows: []const model.WindowId,
    fallback: model.WindowId,
) model.WindowId {
    const f = v.focused orelse return fallback;
    if (std.mem.indexOfScalar(model.WindowId, windows, f) == null) return fallback;
    return f;
}

/// Pane-inset total: the outer gap on both sides plus both border widths,
/// saturating. The single source of the "2×gap + 2×border" shrink used by
/// master, monocle, and scroll.
pub inline fn totalInset(gap_amount: u16, m: utils.Margins) u16 {
    return gap_amount *| 2 +| utils.doubledBorder(m);
}

/// Per-axis inset for a client window, read from a Margins value (scroll and
/// any layout that needs the full shrink in one expression).
pub inline fn fullInset(m: anytype) u16 {
    return totalInset(m.gap, m);
}

/// Shrinks `dim` by `margin` (gap/border), floored to `min_dim` so a layout
/// never hands a client a zero or negative size (verbatim port).
pub inline fn shrinkClamped(dim: u16, margin: u16, min_dim: u16) u16 {
    return if (dim > margin) dim - margin else min_dim;
}

/// Full-rect inset by `margin` (shrinkClamped width/height at fixed origin).
pub inline fn insetRect(x: i32, y: i32, w: u16, h: u16, margin: u16, min_dim: u16) utils.Rect {
    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = shrinkClamped(w, margin, min_dim),
        .height = shrinkClamped(h, margin, min_dim),
    };
}

/// Clamp a signed y coordinate to a non-negative u16.
inline fn clampYToU16(y: i32) u16 {
    return @intCast(@max(y, 0));
}

/// A two-dimensional screen region in tiling coordinates (x/y are i32, w/h
/// u16). The shared shape for outerArea and the layout modules' recursion.
pub const Region = struct {
    x: i32,
    y: i32,
    w: u16,
    h: u16,
};

/// Work-area rect inset by the outer gap; x/y are i32, w/h u16
/// (threaded through some layouts' recursion).
pub inline fn outerArea(wa: utils.Rect, gap: u16) Region {
    return .{
        .x = @intCast(gap),
        .y = clampYToU16(wa.y) +| gap,
        .w = wa.width -| gap *| 2,
        .h = wa.height -| gap *| 2,
    };
}

/// Work-area origin y clamped to >= 0, as u16.
pub inline fn waY(v: *const View) u16 {
    return clampYToU16(v.workarea.y);
}

/// Append one placement (shared append + overflow-assert tail of every emit).
inline fn appendPlacement(out: *List, win: model.WindowId, rect: utils.Rect, visible: bool) void {
    std.debug.assert(out.append(.{ .win = win, .rect = rect, .visible = visible }));
}

/// Emit a placement with the window's size hints applied to `rect`.
inline fn emit(
    v: *const View,
    out: *List,
    win: model.WindowId,
    rect: utils.Rect,
    visible: bool,
) void {
    appendPlacement(out, win, if (visible) applyHints(rect, v.hints.forWin(win)) else parked_rect, visible);
}

/// Emit a parked placement (the pushWindowOffscreenAndInvalidate transform).
inline fn emitParked(out: *List, win: model.WindowId) void {
    appendPlacement(out, win, parked_rect, false);
}

/// Emit every window in `windows` parked except `top` (raised by the caller):
/// the monocle "show one, hide the rest" and fibonacci overflow-share shapes.
pub inline fn showOneHideRest(out: *List, windows: []const model.WindowId, top: model.WindowId) void {
    for (windows) |w| {
        if (w == top) continue;
        emitParked(out, w);
    }
}

/// Dispatch registry (build-generated, alphabetical stems). The active layout
/// is a `u8` index into this table; the engine never owns a closed enum.
const tiling_mods = @import("tiling_modules").modules;

/// Resolve a config layout name (case-insensitive) to its registry index.
/// Names are canonicalized at the config boundary, so this is an exact
/// lowercased match on module names.
pub fn layoutByName(name: []const u8) ?usize {
    if (name.len > 64) return null;
    for (tiling_mods, 0..) |m, i| if (std.ascii.eqlIgnoreCase(name, m.name)) return i;
    return null;
}

/// Neutral last-resort default layout: the first registered module (index 0).
/// The effective default is config-driven (cfg.tiling.layout resolves at every
/// seeding site); this only stands in when that name fails to resolve (a
/// removed/unknown module), keeping dispatch ids always resolvable.
pub fn defaultKind() u8 {
    return 0;
}

/// The registry module name for `kind` ("" when out of range).
pub fn moduleName(kind: u8) []const u8 {
    if (kind >= tiling_mods.len) return "";
    return tiling_mods[kind].name;
}

/// Variant count for `kind` (cycle_variant actions/mod bar). Registry-driven.
pub fn variantCount(kind: u8) u8 {
    if (kind >= tiling_mods.len) return 1;
    return tiling_mods[kind].variant_count;
}

/// Step a layout within the config layout-name list (config order is the
/// cycle order). Each name resolves to a registry index (unresolvable names
/// are skipped); `cur`'s position steps by `dir` and wraps modulo the list.
/// When `cur` is not in the list (safety net — defaults/overrides always come
/// from config names) it lands on the first/last edge by direction.
pub fn cycleKind(cur: u8, dir: i32, names: []const []const u8) u8 {
    var indices: [256]u8 = undefined;
    var n: usize = 0;
    for (names) |nm| if (layoutByName(nm)) |idx| {
        if (n < indices.len) {
            indices[n] = @intCast(idx);
            n += 1;
        }
    };
    if (n == 0) return cur;
    for (indices[0..n], 0..) |idx, i| if (idx == cur) {
        return indices[@intCast(@mod(@as(i32, @intCast(i)) + dir, @as(i32, @intCast(n))))];
    };
    return indices[if (dir >= 0) 0 else n - 1];
}

/// Compute `kind`'s layout into `out` (cleared first). Each layout module
/// binds its `compute` hook to the module's placement function and must
/// append exactly one placement per window in `v.order` (off-viewport/hidden
/// windows are parked via emitHidden).
pub fn compute(kind: u8, v: View, out: *List) void {
    out.clear();
    if (kind >= tiling_mods.len) return;
    if (v.order.len == 0) return;
    if (tiling_mods[kind].compute) |f| f(&v, out);
}

// Algo modules share this file's private emit helpers via pub re-exports.
pub const emitView = emit;
pub const emitHidden = emitParked;

/// Parses a layout variant VALUE-STRING into its ordinal slot: the index of
/// the first exact-case match in `names`, or null when unmatched. Shared by
/// every layout module that exposes named variants.
pub fn variantParse(comptime names: []const []const u8) fn ([]const u8) ?u8 {
    return struct {
        fn parse(str: []const u8) ?u8 {
            for (names, 0..) |name, i| {
                if (std.mem.eql(u8, str, name)) return @intCast(i);
            }
            return null;
        }
    }.parse;
}

pub fn layoutModule(comptime name: []const u8, comptime icon: []const u8, comptime f: anytype, comptime extra: plugin.Layout) plugin.Layout {
    var m = extra;
    m.name = name;
    m.icon = icon;
    m.compute = f;
    return m;
}
