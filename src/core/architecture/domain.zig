//! Pure vocabulary (no I/O): identifier types, value objects the window state
//! holds, mask/tag vocabulary, layout-parameter records, feature-vocabulary
//! enums, constants, pure helpers, and the generic sorted-key Store re-export.
//! The runtime state that HOLDS this vocabulary (Entry, WsState, Model) and
//! every state operation live beside it in `core/model.zig` — this file is
//! PRIVATE to that facade: only `model` imports it, so nothing else can
//! reach past the facade.
//!
//! Geometry lives here rather than in a `geom` module because it is not a
//! utility: `Rect`/`Margins` are value objects the state holds (`BaseMode.
//! floating`, `Placement`), and the two coordinate helpers exist only to serve
//! them -- `satI16` clamps into `Rect`'s own i16 range, `toXcbCoord` adapts a
//! `Rect` field to the wire. `satI16` is also used by the pure `tiling/` layer,
//! which is why these cannot live on the x11 side. The one adapter that IS
//! genuinely xcb-typed, `rectFromXcb`, stays in `x11/requests.zig`.
//!
//! Layer rule: pure core (no X11, no feature imports). The only imports are
//! `std` and other xcb-free vocabulary, so this file cannot reach the
//! connection in `core.zig` -- that is what keeps the pure side a DAG root.
//! Single-threaded.
const std = @import("std");

const bounded = @import("bounded");

/// Canonical window identifier type (xcb_window_t / uint32_t). `core.WindowId`
/// and `model.WindowId` are aliases of this single definition, so window ids
/// cross the core/state boundary without conversion.
pub const WindowId = u32;

/// Canonical workspace identifier type.
///
/// `core.WorkspaceId` and `model.WSId` are both names for this single
/// struct, so workspace ids cross the core/state boundary without conversion.
/// The type keeps a `.index` member so state code can keep using `ws` values
/// directly as array indices; integer-typed boundaries (wire formats,
/// counters) convert with `fromIndex` / `.index`.
/// `fromIndex` accepts any integer (internal checked `@intCast` to u8), so
/// callers don't scatter `@intCast` wrappers; the u8 field type still keeps
/// indices distinct from unrelated u8 values (counts, layout indices, etc.).
/// Range is a SEPARATE question from representation: `fromIndex` is lenient
/// (config/recovery paths), `fromIndexChecked` asserts (internal paths), and
/// `isValid` is the single definition every fixed-size consumer asks.
/// Lives here (the pure vocabulary root) because every layer -- config,
/// tiling, the hub, the window modules -- needs it; it imports nothing but
/// std and the shared bounded shelf.
pub const WorkspaceId = struct {
    index: u8,

    /// Lenient constructor: accepts any integer, narrowing to u8. This is the
    /// entry point the parser and restore paths use, and it deliberately does
    /// NOT range-check -- an out-of-range value from a user config is
    /// recoverable there (the caller clamps or skips with a warning), and a
    /// panic would turn a typo in a config file into a failed startup. Use
    /// `fromIndexChecked` where the value is internal and must be valid.
    pub fn fromIndex(i: anytype) WorkspaceId {
        return .{ .index = @intCast(i) };
    }

    /// Constructive constructor: asserts the index is a real workspace. Every
    /// INTERNAL site (state, mask, action dispatch) uses this, so a 65th
    /// workspace is a debug failure at the boundary that created it rather
    /// than a silent wrong-mask or an out-of-bounds array read further on.
    pub fn fromIndexChecked(i: anytype) WorkspaceId {
        const ws: WorkspaceId = .{ .index = @intCast(i) };
        std.debug.assert(isValidWorkspaceIndex(ws.index));
        return ws;
    }

    /// True when this id names a workspace the model can hold. A value past
    /// the ceiling can still exist (the lenient `fromIndex` admits it), so
    /// every consumer that indexes a fixed-size array must ask.
    pub fn isValid(self: WorkspaceId) bool {
        return isValidWorkspaceIndex(self.index);
    }

    pub fn eql(self: WorkspaceId, other: WorkspaceId) bool {
        return self.index == other.index;
    }
};

/// State-layer alias of the canonical WorkspaceId. Within the state, `ws`
/// values are read as array indices via `.index`.
pub const WSId = WorkspaceId;

/// The ONE validity notion for a workspace index. Everything that has
/// to decide "is this index in range" -- the mask shift, the state's fixed-size
/// `ws` array, the config lookup tables -- asks here, so a raise of
/// `max_workspaces` cannot leave one of them answering a different question.
pub fn isValidWorkspaceIndex(i: anytype) bool {
    return @as(usize, @intCast(i)) < max_workspaces;
}

/// Hard ceiling on the number of workspaces the WM can meaningfully support.
///
/// Not an arbitrary round number: tiling.zig's geometry-validity cache packs
/// one bit per workspace into a u64 (`workspace_geom_valid_bits`), and
/// workspaces.zig's per-workspace layout/master-count override tables are
/// fixed-size arrays sized to match. Raising this requires widening those
/// first; it is not just a config-side number. config.zig validates parsed
/// workspace numbers against it at parse time so oversized configs warn
/// immediately instead of silently no-oping once workspaces.init() builds its
/// lookup tables.
pub const max_workspaces: usize = 64;

/// Maximum tiled windows on a single workspace (per-workspace tiled_order
/// capacity, applied per workspace). Buffers sized from this are indexed by
/// usize/u16, so raising it only costs memory; keep it a compile-time bound
/// so stack buffers stay stack buffers.
pub const max_tiled_windows: usize = 64;

/// Lower bound on the primary-column width ratio. Config validation and the
/// runtime primary-width adjustment both clamp here.
pub const min_master_width: f32 = 0.05;

/// Primary-column width is capped at 95% so the secondary column always keeps
/// some screen. Single-sourced: config validation, the runtime pixel->ratio
/// conversion, and the primary-width adjustment action all clamp to this same
/// bound.
pub const max_master_width: f32 = 0.95;

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

    /// Geometry only, ignoring `border_width`.
    ///
    /// `eql` and `eqlGeom` exist because a `Rect` carries BOTH geometry and a
    /// border width, but the two are sent by different requests and tracked by
    /// different sent-state (a geometry configure vs the ledger's `bw` field).
    /// Comparing a whole `Rect` to decide "did the geometry move" therefore
    /// reads a field the comparison does not own, so a border-width-only
    /// change reads as a move and buys a spurious configure plus raise. Use
    /// `eql` only when the border width is part of the comparison.
    pub inline fn eqlGeom(self: Rect, other: Rect) bool {
        return self.x == other.x and self.y == other.y and self.width == other.width and
            self.height == other.height;
    }
};

/// Width/height without a position: the resize-while-parked request shape.
///
/// A parked window must be resized OFFSCREEN so its client re-renders before
/// a workspace switch shows it (the bar-toggle pre-resize), which means a
/// configure carrying WIDTH|HEIGHT and NOT X/Y — moving it back on screen
/// would overlay the live workspace. `sink.Configure.size` is the wire shape;
/// this is its vocabulary, kept beside Rect as the other geometry type.
pub const Dims = struct {
    width: u16,
    height: u16,
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

/// Modulo-wraps `idx` by signed `dir` into [0, n); 0 for an empty range.
/// The one modulo-wrap in the tree, powering the round-robin focus and
/// layout-direction cycles, so those callers name the operation instead of
/// reaching into a shared grab bag for it.
pub inline fn wrapIndex(idx: usize, dir: i32, n: usize) usize {
    if (n == 0) return 0;
    return @intCast(@mod(@as(i64, @intCast(idx)) + dir, @as(i64, @intCast(n))));
}

pub const Mask = u64;

/// Mask bit for workspace `ws`.
///
/// Two preconditions, both tied to `max_workspaces` rather than
/// restating its number: the index must name a real workspace, and it must
/// fit the u64 mask. A shift by >= bitSizeOf would silently produce a wrong
/// mask in safe modes, so raising max_workspaces past 64 is a loud build
/// failure rather than a corrupt membership mask.
pub inline fn bit(ws: WSId) Mask {
    std.debug.assert(ws.isValid());
    std.debug.assert(ws.index < @bitSizeOf(Mask));
    return @as(Mask, 1) << @intCast(ws.index);
}

/// Whether `mask` carries the tag bit for `ws`.
pub inline fn maskedOn(mask: Mask, ws: WSId) bool {
    return mask & bit(ws) != 0;
}

pub const ALL_MASK: Mask = ~@as(Mask, 0);

/// Single canonical size-hints record AND the only store: admission threads
/// the parsed WM_NORMAL_HINTS to mapRequest as a parameter (there is no
/// staging copy anywhere). Do NOT import layouts from here (layer rule).
pub const SizeHints = struct {
    /// PMinSize / PBaseSize floor. Policy: TILING deliberately ignores
    /// declared minimums -- the layout engine owns tiled dimensions, and
    /// honouring them would pin the rect and block mod_h/mod_l resizing
    /// (`tiling.applyHints` is the tiled-side delegate). Only the floating
    /// drag-resize path honours this as a user-facing floor.
    min_width: u16 = 0,
    min_height: u16 = 0,
    max_width: u16 = 0, // PMaxSize limit
    max_height: u16 = 0,
    inc_width: u16 = 0, // PResizeInc: w = base_width + N * inc_width
    inc_height: u16 = 0,
    min_aspect: f32 = 0.0, // PAspect (dwm convention)
    max_aspect: f32 = 0.0,

    /// True when every field is zero (no constraints declared).
    pub fn isEmpty(self: SizeHints) bool {
        return self.min_width == 0 and self.min_height == 0 and
            self.max_width == 0 and self.max_height == 0 and
            self.inc_width == 0 and self.inc_height == 0 and
            self.min_aspect == 0.0 and self.max_aspect == 0.0;
    }

    /// Shrink-only PAspect fit: reduces whichever dimension of `w` x `h` is
    /// excess so the result lands inside the declared aspect band (cross-
    /// multiplied, as in the tiling clamp this was extracted from: `w/h` must
    /// satisfy `1/min_aspect <= w/h <= max_aspect`). Never grows, never
    /// violates the bound on either axis; an already in-band size passes
    /// through unchanged.
    ///
    /// BOTH OR NEITHER: the two bounds are the two halves of ONE rule, and a
    /// lone bound is a DIFFERENT constraint, not a weaker one (a max bound
    /// alone clamps the offending DIMENSION, so a 400x50 window under
    /// `max_aspect = 4` gets NARROWER instead of taller -- the client is told
    /// to resize its content rather than given its declared shape). A record
    /// with only one bound set therefore returns the size unchanged.
    ///
    /// Callers clamp the raw size into the PMin/PMax envelope first; the
    /// ratio then wins over a declared minimum on the derived axis (letterbox
    /// freedom is the point of the constraint). A dimension that rounds out
    /// entirely is floored to 1 when its input was positive.
    pub fn aspectFit(self: SizeHints, w: u16, h: u16) struct { width: u16, height: u16 } {
        if (self.min_aspect <= 0.0 or self.max_aspect <= 0.0)
            return .{ .width = w, .height = h };
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        var out_w = w;
        var out_h = h;
        // Cross-multiplied to avoid a per-resize FP division pair. Clamp the
        // product into the u16 range before narrowing so a huge declared ratio
        // caps instead of trapping in ReleaseFast.
        if (fw > fh * self.max_aspect) {
            out_w = @min(roundAspectDim(fh * self.max_aspect), w);
        } else if (fh > fw * self.min_aspect) {
            out_h = @min(roundAspectDim(fw * self.min_aspect), h);
        }
        if (out_w == 0 and w > 0) out_w = 1;
        if (out_h == 0 and h > 0) out_h = 1;
        return .{ .width = out_w, .height = out_h };
    }
};

/// Round a non-negative aspect product to the nearest integer, saturating at
/// the u16 wire limit (the shared shape with the tiling clamp this serves).
inline fn roundAspectDim(product: f32) u16 {
    if (!(product > 0.0)) return 0; // zero or NaN (defensive; ratios are > 0)
    const clamped = std.math.clamp(@round(product), 0.0, @as(f32, std.math.maxInt(u16)));
    return @intFromFloat(clamped);
}

/// Hard ceiling on the number of distinct layouts the cycle ring can hold.
/// The canonical value lives here because it bounds the u8 `kind` registry
/// index (LayoutParams.kind) and the u8 `layout_idx` in workspace layout
/// overrides alike; config side imports it and enforces the cap at parse time
/// (a 256th entry would trap on the config-side `@intCast` in ReleaseFast,
/// so names past the cap warn-and-skip).
pub const max_layouts = 256;

pub const LayoutParams = struct {
    /// Index into the build-generated `tiling_modules` registry (dispatch
    /// order == deterministic scan order). Resolved from config at seed time;
    /// out-of-range values are disambiguated by the registry layer (default
    /// layout fallback). The model stays registry-free: it is a bare index here.
    kind: u8 = 0,
    variant_idx: u8 = 0,
    primary_width: f32 = 0.5,
    primary_count: u8 = 1,
    secondary_balance: f32 = 0,
    /// Viewport state: model-owned so the layout engine stays pure. The
    /// snap-right-on-new-window and clamp duties belong to callers (reconcile_tails/sync).
    viewport_offset: i32 = 0,
    viewport_prev_count: u32 = 0,
};

pub const BaseMode = union(enum) {
    /// Home workspace membership is DERIVED (exactly one `ws`.tiled_order list
    /// holds a tiled window; findHome). Visibility on other tagged workspaces
    /// is a sync-time mask filter (engine stays mask-agnostic).
    tiled,
    floating: Rect,
};

/// Open visibility pattern: `present` (visible/layoutable), `parked` (hidden
/// by an extension), `covering` (owns the screen on a workspace). Enumerates
/// PATTERNS, not features; a parked/covering window keeps its `anchor`/`mask`.
pub const Presence = enum { present, parked, covering };

// Shared vocabulary types.
// Pure vocabulary consumed by both the wire-side feature plugins and wire
// callers; they live in core so nothing needs to import a feature file just
// to reference them.

/// Restore-order target selection over minimized windows on a workspace:
/// `.fifo` = oldest minimize seq, `.lifo` = newest.
pub const RestoreOrder = enum { lifo, fifo };

/// Optional increment of a floating window's geometry honored on
/// configure-request; unset fields leave the current value unchanged.
pub const ConfigureReq = struct {
    x: ?i16 = null,
    y: ?i16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
    border_width: ?u16 = null,
};

/// Outcome of honoring a configure request against a floating window record.
pub const HonorDecision = enum { geometry_applied, border_only, ignored };

/// Bounded sorted-key collection re-exported from the pure shelf; the model's
/// window store and the reconcile ledger share it without either naming core.
pub const Store = bounded.Store;

/// Store and MRU capacities: 128 bounds the sorted-key store (stack-allocated);
/// 16 keeps the per-workspace focus MRU small. Per-workspace tiled membership
/// is bounds from the compile-time caps above. Transitions never allocate (defined capacities).
pub const store_capacity = 128;

/// Primary-column capacity: a sane handful of slots, capped at a quarter of
/// the managed-window ceiling so one workspace can't statically claim the
/// store. The config grammar lets master_count rise to its u8 ceiling (and
/// admits a 0 count for a workspace override), so the config-driven stamps go
/// through `capPrimaryCount`.
pub const max_primary_count = store_capacity / 4;

/// Clamps a configured primary count into [1, max_primary_count] — the model's
/// primary-count invariant, and the one clamp the config-driven seed stamps
/// call. The interactive increment (`adjustPrimaryCount`) clamps the same
/// bounds inline rather than here: its delta arithmetic runs in i32 so a
/// decrement below 1 cannot wrap a u8, and narrowing to u8 first would be the
/// overflow it is avoiding.
pub fn capPrimaryCount(count: u8) u8 {
    return std.math.clamp(count, 1, @as(u8, @intCast(max_primary_count)));
}
pub const mru_capacity = 16;
pub const max_tiled_per_ws = max_tiled_windows;

/// Index (workspace id) of the lowest set bit in `m`, or null for the zero
/// mask (`@ctz(0)` = 64, out of the u64 bit range — see `bit`).
pub fn lowestBit(m: Mask) ?WSId {
    if (m == 0) return null;
    return WSId.fromIndex(@ctz(m));
}
