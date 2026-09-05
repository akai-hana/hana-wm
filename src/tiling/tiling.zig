//! Dispatch engine for the tiling sub-system.
//! Reads model types and emits placements; no XCB and no allocation.

const std = @import("std");
const utils = @import("utils");
const model = @import("model");
const build_options = @import("build_options");

pub const hints = @import("hints");
const applyHints = hints.applyHints;
const plugin = @import("plugin");

// The layout interchange vocabulary lives on the tiling CONTRACT (plugin.zig)
// so the always-compiled reconciler can name it even without this tiling engine;
// here we only re-export it so modules keep referring to `tiling.List` etc.
pub const Placement = plugin.Placement;
pub const parked_rect = plugin.parked_rect;
pub const HintsView = plugin.HintsView;
pub const Env = plugin.Env;
pub const View = plugin.View;
pub const List = plugin.List;

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

/// Work-area rect inset by the outer gap; x/y are i32, w/h u16
/// (threaded through some layouts' recursion).
pub inline fn outerArea(wa: utils.Rect, gap: u16) struct { x: i32, y: i32, w: u16, h: u16 } {
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
    const ok = out.append(.{
        .win = win,
        .rect = rect,
        .visible = visible,
    });
    if (std.debug.runtime_safety) {
        std.debug.assert(ok);
    }
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

/// Lowercased-name lookup over the registry (exact match on module names).
fn indexOfName(lower: []const u8) ?usize {
    for (tiling_mods, 0..) |m, i| {
        if (std.mem.eql(u8, lower, m.name)) return i;
    }
    return null;
}

/// Resolve a config layout name (case-insensitive) to its registry index.
/// Names are canonicalized at the config boundary, so this is an exact
/// lowercased match on module names.
pub fn layoutByName(name: []const u8) ?usize {
    if (name.len > 64) return null;
    var buf: [64]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..name.len], name);
    return indexOfName(lower);
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
    for (names) |nm| {
        if (layoutByName(nm)) |idx| {
            if (n < indices.len) {
                indices[n] = @intCast(idx);
                n += 1;
            }
        }
    }
    if (n == 0) return cur;
    var pos: usize = 0;
    var found = false;
    for (indices[0..n], 0..) |idx, i| {
        if (idx == cur) {
            pos = i;
            found = true;
            break;
        }
    }
    if (found) {
        return indices[@intCast(@mod(@as(i32, @intCast(pos)) + dir, @as(i32, @intCast(n))))];
    }
    return indices[if (dir >= 0) 0 else n - 1];
}

/// Compute `kind`'s layout into `out` (cleared first). Each layout module
/// binds its `compute` hook to the module's placement function and must
/// append exactly one placement per window in `v.order` (off-viewport/hidden
/// windows are parked via emitHidden). The caller sorts afterwards, so
/// layout emission order is only pinned by tests, not by sync.
pub fn compute(kind: u8, v: View, out: *List) void {
    out.clear();
    if (kind >= tiling_mods.len) return;
    // Empty workspace emits nothing; layouts assume a non-empty order (grid
    // divides by its shape, monocle indexes order[len - 1]), and sync's
    // per-reconcile compute runs on an empty one, so it is a supported input
    // short-circuited here once for every module.
    if (v.order.len == 0) return;
    if (tiling_mods[kind].compute) |f| f(&v, out);
}

// Algo modules share this file's private emit helpers via pub re-exports.
pub const emitView = emit;
pub const emitHidden = emitParked;

/// Builds a type-free `compute` hook that casts the opaque plugin seam to
/// `View`/`List` and calls the given layout's typed `compute`. Shared by every
/// layout module, which binds `.compute = tiling.computeHook(compute)`.
pub fn computeHook(comptime F: anytype) fn (*const anyopaque, *anyopaque) void {
    return struct {
        fn hook(view: *const anyopaque, out: *anyopaque) void {
            const v: *const View = @ptrCast(@alignCast(view));
            const o: *List = @ptrCast(@alignCast(out));
            F(v.*, o);
        }
    }.hook;
}

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
