//! The generic layout port owned by the mandatory core layer.
//!
//! Core, window, bar, and config depend on this port only. A layout subsystem
//! supplies the adapter through the generated `layout_provider` module; when
//! no subsystem is present that module selects `null_provider`, so every
//! caller degrades to floating-only behavior without naming a subsystem type.
//!
//! Pure vocabulary: no X11, no feature imports, no subsystem contract.

const std = @import("std");
const model = @import("model");
const bounded = @import("bounded");

const log = std.log.scoped(.layout);

/// The neutral layout: registry index 0, the fallback for an unresolvable
/// config layout name and for a restored kind that no longer resolves.
pub const default_kind: u8 = 0;

/// Sentinel rect for parked placements.
pub const parked_rect: model.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 };

/// A placement computed for one window (see Request.order).
pub const Placement = struct {
    win: model.WindowId,
    rect: model.Rect,
    visible: bool,
};

/// Zero-allocation placement buffer (one entry per stored window).
pub const List = bounded.BoundedList(Placement, model.store_capacity);

/// Frozen size-hint snapshot: one hint per window in `Request.order`.
pub const HintsView = []const model.SizeHints;

/// Caller-resolved layout environment, one bundled field per generic knob.
/// The variant index is NOT a field here: it is config- and workspace-owned
/// state living in `Request.params.variant_idx`.
pub const Env = struct {
    margins: model.Margins = .{},
    min_dim: u16 = 0,
    primary_on_right: bool = false,
};

/// The layout pass input: model/geometry in, placements out.
pub const Request = struct {
    order: []const model.WindowId,
    params: *const model.LayoutParams,
    workarea: model.Rect,
    hints: HintsView,
    focused: ?model.WindowId,
    env: Env = .{},

    /// Frozen size-hint lookup for one window: a scan over the (small) order
    /// slice, default fallback when absent.
    pub fn hintsFor(self: Request, win: model.WindowId) model.SizeHints {
        std.debug.assert(self.order.len == self.hints.len);
        for (self.order, self.hints) |w, h| {
            if (w == win) return h;
        }
        return .{};
    }
};

/// Generic layout status published by the active provider: the name, bar
/// icon, variant count, and per-variant indicators. `active` is false when
/// the kind does not resolve in the provider's registry (or when no provider
/// is present).
pub const Status = struct {
    active: bool = false,
    name: []const u8 = "",
    icon: ?[]const u8 = null,
    variant_count: u8 = 1,
    variant_indicators: ?[]const []const u8 = null,
};

/// Which window edge a drag-start grab sits on.
pub const SplitEdge = enum { left, right, top, bottom };

/// The split knob an edge-drag adjusts.
pub const SplitKnob = enum { primary, balance };

/// Generic split plan for a tiled edge-drag.
pub const SplitPlan = struct {
    knob: SplitKnob = .primary,
    sign: f32 = 1,
    start: f32 = 0,
    wa_w: f32 = 1,
    wa_h: f32 = 1,
};

/// Generic viewport metadata for layouts that scroll.
pub const Viewport = struct {
    slot_w: i32,
    max_off: i32,
};

/// The port's adapter surface. Every field has an inert default, so
/// `null_provider` is the empty struct literal and an absent subsystem needs
/// no generated vocabulary.
pub const Provider = struct {
    /// Number of registered layouts. Zero means no provider.
    count: usize = 0,
    /// Compute placements for `kind` into `out` (cleared first).
    compute: *const fn (kind: u8, req: *const Request, out: *List) void = noCompute,
    /// Metadata for `kind`; `active` is false when it does not resolve.
    status: *const fn (kind: u8) Status = noStatus,
    /// Resolve a config layout name to its registry index.
    indexByName: *const fn (name: []const u8) ?u8 = noIndex,
    /// Registry name for `kind` ("" when out of range).
    nameFor: *const fn (kind: u8) []const u8 = noName,
    /// Variant count for `kind`.
    variantCount: *const fn (kind: u8) u8 = oneVariant,
    /// Whether `kind` exposes a variant value-string parser.
    hasVariantParse: *const fn (kind: u8) bool = noVariantParse,
    /// Parse a variant value-string for `kind`.
    variantParse: *const fn (kind: u8, value: []const u8) ?u8 = noVariant,
    /// Step `kind` within a config layout-name list.
    cycleKind: *const fn (kind: u8, dir: i32, names: []const []const u8) u8 = sameKind,
    /// Pure pre-reconcile duty; null when the active layout has none.
    preReconcile: *const fn (
        kind: u8,
        params: model.LayoutParams,
        count: usize,
        wa_width: u16,
    ) ?model.LayoutParams = noPreReconcile,
    /// Viewport hooks for `kind`; null when it has none.
    viewport: *const fn (kind: u8, count: usize, wa_width: u16) ?Viewport = noViewport,
    /// Primary-fifo spawn target: the head slot a new window takes, or null.
    spawnHeadSlot: *const fn (*const model.Model, model.WSId) ?usize = noSpawnHead,
    /// Split plan for a tiled edge-drag, or null when no split backs it.
    splitPlan: *const fn (
        *const model.Model,
        model.WindowId,
        SplitEdge,
        model.Rect,
        model.Rect,
        bool,
        u8,
    ) ?SplitPlan = noSplitPlan,
    /// Tiled-order transitions.
    reorderTiled: *const fn (*model.Model, model.WindowId, usize) void = noReorder,
    stepTiled: *const fn (*model.Model, model.WindowId, i32) void = noStep,
    swapFocusedWithPrevious: *const fn (*model.Model) void = noSwap,
    adjustPrimaryWidth: *const fn (*model.Model, f32) void = noAdjust,
};

/// The absent-provider adapter: every field inert.
pub const null_provider: Provider = .{};

/// Resolve a config layout name through `provider`, collapsing to `fallback`
/// when it does not resolve. Loud, never silent: an unresolvable layout name
/// is a config bug.
pub fn kindFallingBack(provider: *const Provider, name: []const u8, fallback: u8) u8 {
    if (provider.indexByName(name)) |k| return k;
    log.warn(
        "Config: layout name '{s}' did not resolve to a registered layout; " ++
            "using layout '{s}'",
        .{ name, provider.nameFor(fallback) },
    );
    return fallback;
}

fn noCompute(_: u8, _: *const Request, _: *List) void {}

fn noStatus(_: u8) Status {
    return .{};
}

fn noIndex(_: []const u8) ?u8 {
    return null;
}

fn noName(_: u8) []const u8 {
    return "";
}

fn oneVariant(_: u8) u8 {
    return 1;
}

fn noVariantParse(_: u8) bool {
    return false;
}

fn noVariant(_: u8, _: []const u8) ?u8 {
    return null;
}

fn sameKind(kind: u8, _: i32, _: []const []const u8) u8 {
    return kind;
}

fn noPreReconcile(_: u8, _: model.LayoutParams, _: usize, _: u16) ?model.LayoutParams {
    return null;
}

fn noViewport(_: u8, _: usize, _: u16) ?Viewport {
    return null;
}

fn noSpawnHead(_: *const model.Model, _: model.WSId) ?usize {
    return null;
}

fn noSplitPlan(
    _: *const model.Model,
    _: model.WindowId,
    _: SplitEdge,
    _: model.Rect,
    _: model.Rect,
    _: bool,
    _: u8,
) ?SplitPlan {
    return null;
}

fn noReorder(_: *model.Model, _: model.WindowId, _: usize) void {}

fn noStep(_: *model.Model, _: model.WindowId, _: i32) void {}

fn noSwap(_: *model.Model) void {}

fn noAdjust(_: *model.Model, _: f32) void {}
