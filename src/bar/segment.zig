//! Shared bar vocabulary for the segment modules.
//!
//! This is NOT a bar segment module: it holds the shared vocabulary every
//! segment module (and bar.zig) imports -- `Frame` (live workspace visitability;
//! an alias for architecture/contract.zig's Frame, so the `naturalWidth` hook
//! can type its frame parameter), `DrawCtx` (the per-frame scratch bar builds
//! for each segment's draw), the shared title constants, and the prompt
//! service-handle struct. The title render/snapshot TYPES live with the title
//! module in `modules/title/vocab.zig` (Phase 4 step 25).
//!
//! It is also the bar's feature-probe surface: the registry-resolved
//! capability helpers (`segId`, `isRole`, `roleIndexOf`,
//! `hasRegisteredSegments`, and the role id-sets such as `self_ticking_ids`)
//! computed against the generated `bar_modules` array, so the bar and its
//! modules locate each other by NAME without importing each other directly.
//!
//! Segments are discovered under the bar's `modules/` directory and register
//! into the build-generated `bar_modules.modules` array; the bar orchestrator
//! iterates that array with uniform loops. This file sits beside them (not
//! inside the scanned dir) so it is never itself registered.
//!
//! Rendering uses per-segment dirty tracking: only dirty segments are
//! repainted on each frame, and the dirty set is registry-sized.
//!
//! It ALSO holds the segment-binding builder (the former scaffold.zig,
//! merged back 2026-10-09): the width-state cache, the comptime `module`
//! builder every registered segment constructs its `contract.Segment`
//! through (the ONE binding style, structure audit step 28), and the
//! pure `finishDraw`/`drawAndStore` helpers. The two halves are separated
//! by a banner below; the vocabulary half stays first because the builder
//! types its hooks against it.

const std = @import("std");
const core = @import("core");
const constants = @import("constants");

const drawing = @import("drawing");
const vocab = @import("vocab");
const types = @import("types");
const contract = @import("contract");
const model = @import("model");

/// Service handles the bar passes into mechanism segments (the prompt) at
/// init. Passed once so segments never import the bar orchestrator;
/// one-way bar -> segment only.
pub const BarHandlers = struct {
    /// Force the bar visible + top-of-stack while the prompt is active.
    presentForPrompt: *const fn () void,
    /// Return the bar to whatever pre-prompt state it was actually in.
    dismissAfterPrompt: *const fn () void,
    /// True when `win` is the bar window.
    isBarWindow: *const fn (u32) bool,
};

/// The bar's per-frame workspace facts, collected fresh by bar.zig every
/// draw -- the only segment-visible slice of WM state (besides what a segment
/// reads directly from core). The DEFINITION lives in
/// architecture/contract.zig so the `naturalWidth` hook can type its first
/// parameter as a real `*const Frame`; this alias keeps `segmod.Frame` as the
/// name every reader already uses.
pub const Frame = contract.Frame;

/// Minimized-state service the title addon exposes to the bar through the
/// shared DrawCtx. The title segment owns all minimized-window
/// knowledge (gated on `build_options.has_minimize`); the bar invokes these
/// hooks through the registry-dispatched DrawCtx so bar.zig never names a
/// window addon. `m` is the live model passed as `*const anyopaque`
/// (type-free contract); the title segment casts back.
pub const MinimizedApi = struct {
    /// Synthesize the full minimized-window set into `set` (bar's title shot).
    collect: ?*const fn (
        m: *const anyopaque,
        set: *std.AutoHashMapUnmanaged(u32, void),
        allocator: std.mem.Allocator,
    ) void = null,
};

/// Type-free cast of the bar-built `*anyopaque` back into `*DrawCtx`.
/// Every segment's draw adapter performs this identical cast, so it lives
/// here once instead of being copy-pasted per module.
pub inline fn castDraw(ctx: *anyopaque) *DrawCtx {
    return @ptrCast(@alignCast(ctx));
}

/// Per-frame scratch shared by every segment's `draw(ctx, x)` call. Built once
/// per frame by the bar; `width` is the segment's reserved row width, set by
/// the bar immediately before invoking each segment's draw hook (needed by the
/// title renderer to return its advanced x and by nothing else). The title
/// snapshot slots below are filled by the bar each frame from in-process
/// caches.
pub const DrawCtx = struct {
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    conn: core.Connection,
    allocator: std.mem.Allocator,

    /// Reserved row width for the segment currently being drawn.
    width: u16 = 0,

    /// The configured name of the segment currently being drawn, e.g. "cpu" or
    /// "volume". Set by bar.drawSegment from the name it already had in hand,
    /// so a module can resolve its OWN themed colors without a second argument
    /// threaded through the registry draw hook (which is shared by every
    /// segment). Empty when a caller builds a DrawCtx without drawing a
    /// specific segment.
    name: []const u8 = "",

    /// Title addon's minimized-state service (registered each draw). The
    /// bar caches it into State so it can invoke the synthesis on every scan.
    minimized_api: MinimizedApi = .{},

    frame: Frame,

    // Title snapshot (filled by bar each frame)
    focused_window: ?u32 = null,
    focused_title: []const u8 = "",
    minimized_title: []const u8 = "",
    current_ws_entries: []const vocab.TitleEntry = &.{},
    minimized_set: *const std.AutoHashMapUnmanaged(u32, void) = &.{},

    /// The title renderer's stable per-frame context (dc/config/height/
    /// start_x/width/conn). The start_x/width are the segment's on-screen box.
    pub fn titleRenderContext(self: *const DrawCtx, start_x: u16, width: u16) vocab.TitleRenderContext {
        return .{
            .dc = self.dc,
            .config = self.config,
            .height = self.height,
            .start_x = start_x,
            .width = width,
        };
    }

    /// The title renderer's per-frame snapshot, built from the bar-filled slots.
    pub fn titleSnapshot(self: *const DrawCtx) vocab.TitleSnapshot {
        return .{
            .focused_window = self.focused_window,
            .focused_title = self.focused_title,
            .minimized_title = self.minimized_title,
            .entries = self.current_ws_entries,
            .minimized_set = self.minimized_set,
        };
    }
};

// Title render/snapshot machinery (moved here from the title module so the bar
// can reach it without naming the title segment).

/// Minimum reserved row width for the title segment.
pub const title_min_width: u16 = 100;

/// Maximum number of windows rendered in split-view; the single bar-wide cap
/// (whole batch, per-window scratch, and title gather all bound to it).
pub const max_visible_windows = constants.max_tiled_windows;

/// Off-screen sentinel: sorts last in position, drawing is skipped.
pub const offscreen_rect: model.Rect = .{
    .x = std.math.maxInt(i16),
    .y = std.math.maxInt(i16),
    .width = 0,
    .height = 0,
};

/// Which core fact-revision to mark-dirty with: the field names of
/// `contract.DirtySources` itself, so a rename there cannot drift from this
/// enum. The bar calls `markDirtySource(src)` and every module whose
/// `dirty_sources` declares that bit gets repainted.
pub const DirtySourcesSource = std.meta.FieldEnum(contract.DirtySources);

/// True when `sources` has the `source` bit set.
pub fn hasSource(sources: contract.DirtySources, source: DirtySourcesSource) bool {
    return switch (source) {
        inline else => |s| @field(sources, @tagName(s)),
    };
}

/// Resolves a configured segment name to its registry index, or null when no
/// module with that name is compiled in (segment removed or unknown).
fn idByName(modules: []const contract.Segment, name: []const u8) ?usize {
    for (modules, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) return i;
    }
    return null;
}

/// The bar's own registry (the build-generated `bar_modules`
/// array), named here once so the registry-index helpers below
/// serve every consumer -- bar.zig and center_row.zig used to
/// each carry a private copy (review 05-input round 2).
const bar_mods = @import("bar_modules").modules;

/// Registry index for `name` in the bar's own registry, or null
/// when absent (also when the registry is empty: `bar_mods` is
/// then a zero-length array and idByName finds nothing).
pub inline fn segId(name: []const u8) ?usize {
    return idByName(&bar_mods, name);
}

/// True in builds with at least one registered bar segment, false
/// in segment-less builds. Guards every registry index: indexing
/// a zero-length array is a compile error even under a runtime
/// guard, so the empty build drops the whole body before it is
/// analyzed (the `segAt` pattern from bar.zig).
pub inline fn hasRegisteredSegments() bool {
    return comptime bar_mods.len != 0;
}

/// Resolves the registry index of every module whose capability field `name`
/// is set, in registry order. Used by the bar as its ROLE SET: capabilities
/// with multiple binders (self_ticking, center_slot) fan out / split evenly
/// over the whole set rather than first-match wins.
///
/// `name` is a FIELD, not a string: it is typed `std.meta.FieldEnum(Segment)`
/// so a renamed or removed capability is a compile error at every call site.
/// The string form made a typo silently resolve the empty set, which is the
/// same shape as "this role has no binders" -- the failure mode that reads as
/// a working bar with one segment missing.
///
/// Comptime-friendly: when `modules` is comptime-known (a generated registry)
/// the returned slice is a comptime value, so empty-set guards
/// (`.len == 0`) dead-code-eliminate.
pub fn findAllByCapability(
    modules: []const contract.Segment,
    comptime name: std.meta.FieldEnum(contract.Segment),
) []const usize {
    var result: []const usize = &.{};
    for (modules, 0..) |m, idx| {
        if (@field(m, @tagName(name))) {
            result = result ++ [_]usize{idx};
        }
    }
    return result;
}

/// Registry capability sets (comptime, from the generated registry): the
/// center-slot segments that share the center-row budget, and the
/// self-ticking segments whose merged display width IS that budget's clock
/// reservation. The single home of the sets -- state.zig and center_row.zig
/// each used to resolve their own copy.
pub const center_slot_ids: []const usize = findAllByCapability(&bar_mods, .center_slot);
pub const self_ticking_ids: []const usize = findAllByCapability(&bar_mods, .self_ticking);

/// Index of the registry id `id` within the role set `comptime ids` (the
/// self-ticking and center-slot capability sets today), or null when it is
/// not a member. Name-free: membership is by declared capability, and the set
/// is resolved from the generated registry. A name that does not resolve
/// (null) is a member of nothing.
pub fn roleIndexOf(id: ?usize, comptime ids: []const usize) ?usize {
    const i = id orelse return null;
    inline for (ids, 0..) |rid, j| {
        if (i == rid) return j;
    }
    return null;
}

/// True when the registry id `id` is in the registry role set `ids`.
pub fn isRole(id: ?usize, comptime ids: []const usize) bool {
    return roleIndexOf(id, ids) != null;
}

/// A segment's natural (reserved) width via its uniform naturalWidth hook,
/// or 0 for an unknown/removed segment name (null id, or an empty registry).
/// `clock_width` is the merged clock width the hook receives as its fallback
/// reservation; the hook takes a real `*const contract.Frame`
/// (`segmod.Frame` is an alias for exactly that), so the frame passes
/// through with no cast.
pub fn naturalWidthOf(id: ?usize, frame: *const Frame, clock_width: u16) u16 {
    if (comptime !hasRegisteredSegments()) return 0;
    const i = id orelse return 0;
    if (bar_mods[i].naturalWidth) |nw| return nw(frame, clock_width);
    return 0;
}
/// The whole bar registry as a slice: the ONE way consumers reach the
/// generated array. Every raw `bar_modules` import outside this file routes
/// through here or the helpers above (Phase 4 step 26), so the registry has
/// a single home.
pub inline fn all() []const contract.Segment {
    return &bar_mods;
}

/// Registry entry at a resolved `id`. Callers reach this only after a
/// registry capability/role lookup matched a name; a match is impossible
/// when the registry is empty (guarded like every other index: a zero-length
/// array is a comptime error to index even under a runtime check).
pub inline fn segmentAt(id: usize) *const contract.Segment {
    if (comptime !hasRegisteredSegments()) unreachable;
    return &bar_mods[id];
}

/// Runs the void hook `hook` over every registered segment (the
/// init/teardown/notification family).
pub fn runVoidHook(comptime hook: std.meta.FieldEnum(contract.Segment)) void {
    contract.callAll(contract.Segment, bar_mods[0..], hook, .{});
}

/// True when ANY registered segment's `hook` returns true (short-circuiting
/// walk; the predicate family: keypress routing, elapsed-seconds fan-out,
/// redraw-request folding).
pub fn anyBoolHook(comptime hook: std.meta.FieldEnum(contract.Segment), args: anytype) bool {
    for (bar_mods) |seg| if (@field(seg, @tagName(hook))) |f| if (@call(.auto, f, args)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Segment-binding builder (formerly scaffold.zig): width-state cache, the
// comptime `module` builder (the ONE binding style), finishDraw/drawAndStore.
// ---------------------------------------------------------------------------

/// Per-module width cache: the ACTUAL drawn width from the last render, read
/// by the default naturalWidth for the row reservation (0 until the first
/// draw), invalidated on config reload. The comptime `tag` must differ per
/// module so each call site gets its own instantiation (and thus its own
/// state).
pub fn widthState(comptime tag: []const u8) type {
    return struct {
        var cached: u16 = 0;
        var redraw_pending: bool = false;
        const _ = tag;

        pub fn consumeRedrawRequest() bool {
            const pending = redraw_pending;
            redraw_pending = false;
            return pending;
        }
        /// Records the measured width; when it differs from last frame the
        /// collapse/expand redraw request fires (layout.zig's width only
        /// changes on reload, variants' changes on layout transitions).
        pub fn store(new_width: u16) void {
            if (new_width != cached) redraw_pending = true;
            cached = new_width;
        }
        /// Default naturalWidth: the last drawn width.
        pub fn naturalWidth(_: *const contract.Frame, _: u16) u16 {
            return cached;
        }
        /// The width to reserve: the measured one, or `probe` until there IS
        /// a measurement.
        ///
        /// `cached == 0` means "never painted", not "zero pixels wide" -- a
        /// segment that has not drawn yet has no measured width, and reserving
        /// 0 for it collapses the row on the very first layout pass. The
        /// slider module had this rule hand-rolled against its own `slot_w`
        /// and got it wrong once: the click hit-test rejected presses while
        /// `slot_w` was 0, so the first click on a freshly laid-out slider did
        /// nothing, while the drag denominator and the row reservation fell
        /// back to DIFFERENT values in the same frame. One definition, used by
        /// every consumer, is what keeps the hit-test, the drag range and the
        /// reservation agreeing from frame one.
        pub fn resolved(probe: u16) u16 {
            return if (cached != 0) cached else probe;
        }
        /// The raw last-painted width, 0 when never painted. For callers that
        /// genuinely need to distinguish the two (not the reservation).
        pub fn measured() u16 {
            return cached;
        }
    };
}

/// The bar's post-draw step for one segment, as a pure function: hand the
/// painted width back to the segment that owns the measurement, and say
/// whether the row advances by the paint or by the reservation.
///
/// It lives here, not inline in the bar's draw loop, because the loop needs a
/// live `DrawContext` and an X connection -- which is exactly why this policy
/// went untested for so long. As a function over a `Segment` and a `Painted`,
/// both halves are reachable from a unit test: a segment that forgets its own
/// width, or a row that advances on a draw that painted nothing, are both
/// silent in production and obvious here.
///
/// Returns true when the segment painted something. A zero width is a valid
/// successful outcome (an absent readout) and, like a caught draw error, still
/// leaves the caller to consume the full reserved width.
pub fn finishDraw(seg: *const contract.Segment, painted: contract.Painted) bool {
    if (seg.onPainted) |sink| sink(painted.width);
    return painted.width != 0;
}

/// Draws one padded segment for `name` and reports what it painted (the
/// shared draw body of the icon-ish modules that are exactly "padded segment
/// plus a measured width").
///
/// Empty `text` draws nothing and reports a 0-width reservation instead, so
/// segments that may have nothing to show (variants without an indicator) keep
/// the row layout honest without a per-module guard.
///
/// It does NOT record the width: the bar feeds the painted width back through
/// the segment's `onPainted` hook, so "the reservation must follow the
/// painted content" is one rule in one place rather than an obligation every
/// drawing helper has to remember.
pub fn drawAndStore(
    comptime name: []const u8,
    dc: *drawing.DrawContext,
    config: types.BarConfig,
    height: u16,
    start_x: u16,
    text: []const u8,
) !contract.Painted {
    var end_x = start_x;
    if (text.len != 0) {
        end_x = try drawing.drawPaddedSegment(dc, config, height, start_x, name, text, null, config.segmentProps(name));
    }
    // Empty text lands on `span` with end_x == start_x, i.e. Painted.nothing:
    // a SUCCESSFUL zero-width draw, not a failure.
    return contract.Painted.span(start_x, end_x);
}

const NaturalWidth = *const fn (*const contract.Frame, u16) u16;
const OnClick = *const fn (*const contract.ClickCtx) bool;

/// How one slot's WIDTH behaves over its lifetime -- the shapes a bar segment
/// can actually have, named by the SlotMode enum below.
const SlotMode = enum {
    /// Measured width reported to the width state, and a width change raises a
    /// re-layout request. For a segment that can change shape DURING a frame:
    /// variants collapses to zero width on a layout transition and must re-lay
    /// the row in the SAME batch, before the end-of-batch flush, or the gap it
    /// left never closes.
    measured_relayout,
    /// Measured width reported to the width state, but no re-layout request.
    /// Right for a segment whose width only changes on a config reload: the
    /// bar re-lays out for that anyway, so a request would be a duplicate.
    measured_no_relayout,
    /// The module measures its OWN width, on its own cadence, and wants
    /// neither a report nor a request. The clock: its reservation is a
    /// deliberate per-mode text measurement, refreshed when the mode changes,
    /// not the width that happened to paint -- and a painted-width report
    /// would be measuring the wrong thing.
    self_measured,
    /// No width participation at all: no reservation probe unless one is
    /// supplied explicitly, no paint report, no redraw request. The prompt's
    /// shape -- an overlay-first segment whose row draw exists but whose
    /// width the bar never measures or derives.
    unmeasured,
};

/// Optional bindings for the segment: one field per contract.Segment hook a
/// module can set. Unset fields keep the contract defaults (the builder only
/// ever fills them in).
const Opts = struct {
    /// How this slot's width behaves; see SlotMode. Defaults to the safest
    /// measured shape.
    mode: SlotMode = .measured_no_relayout,
    self_ticking: bool = false,
    center_slot: bool = false,
    /// Which core fact-revisions repaint this segment (title: focus+frame;
    /// tags: frame).
    dirty_sources: contract.DirtySources = .{},
    needsRepaint: ?*const fn () bool = null,
    clickable: bool = true,
    init: ?*const fn (std.mem.Allocator, *const anyopaque, ?*const anyopaque) anyerror!void = null,
    deinit: ?*const fn (std.mem.Allocator) void = null,
    pollTimeoutMs: ?*const fn () i32 = null,
    onPollWakeup: ?*const fn () void = null,
    secondsElapsed: ?*const fn ([]const u8) bool = null,
    onBarShown: ?*const fn () void = null,
    /// Cleared via the uniform invalidate hook on bar (re)creation. Segments
    /// without a real invalidate (layout/variants) keep their last measured
    /// width as the row reservation: zeroing it would make the first measure
    /// after a reload reserve a 0-width slot and push downstream segments out
    /// of place for a frame.
    invalidate: ?*const fn () void = null,
    /// Clears per-module caches on config reload (font/padding may change).
    invalidateReloadCaches: ?*const fn () void = null,
    /// Raw redraw-request walker; wins over the mode-derived one (the prompt
    /// folds its own pending requests).
    consumeRedrawRequest: ?*const fn () bool = null,
    handleKeypress: ?*const fn (*const contract.KeyPressEvent, ?*const types.Action) bool = null,
    measureString: ?*const fn () []const u8 = null,
    /// Reserved row width probe; defaults to the measure-string passthrough
    /// (clock) when `measureString` is set, else the cached drawn width.
    natural_width: ?NaturalWidth = null,
    on_click: ?OnClick = null,
    overlay: ?contract.BarOverlay = null,
};

/// The draw wiring: adapts a module's draw function to the contract hook.
/// Three shapes, picked at comptime from the function's signature --
/// `(*anyopaque, x)` is already contract-shaped and passes through (title,
/// prompt), `(*DrawCtx, x)` gets the scratch pointer cast (tags), and
/// `(dc, config, height, x)` gets the unpacked icon-module form.
fn drawHook(comptime draw: anytype) *const fn (*anyopaque, u16) anyerror!contract.Painted {
    const info = @typeInfo(@TypeOf(draw)).@"fn";
    return struct {
        fn f(ctx: *anyopaque, x: u16) !contract.Painted {
            const c = castDraw(ctx);
            if (comptime info.params.len == 4) return draw(c.dc, c.config, c.height, x);
            if (comptime info.params[0].type.? == *anyopaque) return draw(ctx, x);
            return draw(c, x);
        }
    }.f;
}

/// The icon modules' click action: step the integer direction, then force a
/// redraw. The clock supplies its own `on_click`, so modules reaching this
/// adapter always carry a real direction step.
fn clickHook(comptime action: anytype) OnClick {
    return struct {
        fn f(ctx: *const contract.ClickCtx) bool {
            action(if (ctx.is_left) 1 else -1);
            ctx.redraw();
            return true;
        }
    }.f;
}

/// The default naturalWidth for a module that binds a measureString: reserve
/// the bar's clock budget (the `clock_width` argument, the merged self-ticker
/// measurement) itself, rather than a cached drawn width. This is the clock's
/// reservation path -- its width store lives in State.Clock.width, re-derived
/// by the bar, so the hook only forwards.
fn passthroughWidth(_: *const contract.Frame, clock_width: u16) u16 {
    return clock_width;
}

/// The Segment binding for a bar segment module: cached-width draw +
/// optional direction-click action + every raw capability the Opts carry.
/// `opts.mode` additionally wires the width-state/redraw-request path.
pub fn module(
    comptime name: []const u8,
    comptime draw: anytype,
    comptime action: anytype,
    comptime opts: Opts,
) contract.Segment {
    const W = widthState(name);
    return .{
        .name = name,
        .self_ticking = opts.self_ticking,
        .center_slot = opts.center_slot,
        .dirty_sources = opts.dirty_sources,
        .needsRepaint = opts.needsRepaint,
        .clickable = opts.clickable,
        .init = opts.init,
        .deinit = opts.deinit,
        .pollTimeoutMs = opts.pollTimeoutMs,
        .onPollWakeup = opts.onPollWakeup,
        .secondsElapsed = opts.secondsElapsed,
        .onBarShown = opts.onBarShown,
        .invalidate = opts.invalidate,
        .invalidateReloadCaches = opts.invalidateReloadCaches,
        // A raw redraw-request walker wins over the mode-derived one (the
        // prompt folds its own pending requests; the measured layout slots
        // raise theirs from the width store).
        .consumeRedrawRequest = if (opts.consumeRedrawRequest) |c| c else switch (opts.mode) {
            .measured_relayout => W.consumeRedrawRequest,
            else => null,
        },
        .handleKeypress = opts.handleKeypress,
        .measureString = opts.measureString,
        .naturalWidth = switch (opts.mode) {
            // Out of the width economy: the reservation probe stays whatever
            // was supplied explicitly (normally nothing).
            .unmeasured => opts.natural_width,
            else => opts.natural_width orelse (if (opts.measureString != null) passthroughWidth else W.naturalWidth),
        },
        .draw = drawHook(draw),
        // The bar's post-draw width report lands in this module's own width
        // state, so the reservation the naturalWidth hook reads back is
        // written from exactly one call site.
        .onPainted = switch (opts.mode) {
            .measured_relayout, .measured_no_relayout => W.store,
            .self_measured, .unmeasured => null,
        },
        .overlay = opts.overlay,
        // Comptime-nested: an explicit on_click wins; otherwise the
        // direction-step adapter, but only when a step action was actually
        // passed (a `null` action -- clock/prompt/title -- leaves the field
        // null, and the pruned branch keeps clickHook off a null call).
        .onClick = if (opts.on_click) |oc| oc else if (@TypeOf(action) == @TypeOf(null)) null else clickHook(action),
    };
}
