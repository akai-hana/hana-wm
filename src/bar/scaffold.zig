//! Shared scaffolding for bar segment modules: the width-state cache (layout,
//! variants, slider, systatus; tags has its own cell-width math) and the
//! naturalWidth/draw/onClick hook wiring every module builds through,
//! collapsed into a single comptime builder parameterized by an `Opts` struct.
//! The builder is the ONE binding style: every registered segment -- icons,
//! clock, layout/variants, tags, title, prompt -- constructs its
//! `contract.Segment` through `module` below, so no module raw-binds the
//! literal shape anymore (structure audit step 28).

const std = @import("std");
const segmod = @import("segment");
const contract = @import("contract");
const drawing = @import("drawing");
const types = @import("types");

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
            const c = segmod.castDraw(ctx);
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
