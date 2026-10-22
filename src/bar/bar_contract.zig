//! The bar sub-system contract: the `Segment` hook set plus the bar-side
//! shared vocabulary every segment casts to (`Frame`, `ClickCtx`, `Painted`,
//! `BarOverlay`, `DirtySources`, the opaque `KeyPressEvent`). Engine-local —
//! lives beside the bar subsystem. Type-free hooks carry `*anyopaque` so this
//! file stays importable without the bar orchestrator. Pure vocabulary, no
//! X11, no feature imports.

const std = @import("std");
const types = @import("types");
const bar_config = @import("bar_config");
const dispatch = @import("contract_dispatch");

/// The bar-segment hook set. Every module under a bar-owner's `modules/`
/// binds its `pub const module` value to this type, binding only the hooks
/// it owns (everything else stays `null`). build.zig emits a `bar_modules`
/// registry array; the bar orchestrator iterates it with uniform loops, so
/// adding a segment is a drop-in file. Same open-addon contract as
/// `WindowModule`, typed for bar segments. Type-free hooks: hooks that must
/// carry bar-side structs pass `*anyopaque`; the segment casts to the
/// shared bar vocabulary it imports.
pub const DirtySources = packed struct(u2) {
    /// A focus change (focus_rev diff) repaints this segment.
    focus: bool = false,
    /// A frame change (window/workspace scan diff) repaints this segment.
    frame: bool = false,
};

/// A bar-segment runtime overlay value: a segment that owns a slot can
/// bind itself as an overlay provider (the prompt over the title slot),
/// and the slot's core finds it through the generated segment registry.
/// Shares the opaque `*anyopaque` convention of `Segment.draw`.
pub const BarOverlay = struct {
    /// True while the overlay is actively covering the slot.
    is_active: *const fn () bool,
    /// Toggle the overlay open/closed.
    toggle: *const fn () void,
    /// Render the overlay across the slot at `x`, returning the advanced `x`.
    draw: *const fn (ctx: *anyopaque, x: u16) anyerror!u16,
    /// Runtime "repaint me" query, mirroring `Segment.needsRepaint`: true
    /// while the overlay holds visual state (a caret-blink toggle). The
    /// host slot's `needsRepaint` forwards this so the bar repaints just
    /// that slot. The overlay clears the state inside its own draw.
    needsRepaint: *const fn () bool,
};

/// The X key-press event a segment's `handleKeypress` hook receives,
/// opaque. The concrete struct is `core.xcb.xcb_key_press_event_t`; bar.zig
/// casts the real event INTO this opaque type, and the prompt module casts
/// back to read the fields. Keeping it opaque here keeps this file
/// importable by a non-X consumer while consumers still name the real type.
pub const KeyPressEvent = opaque {};

/// The X-free, typed per-frame environment a segment's `draw` reads. The
/// `dc` and `conn` stay OUTSIDE this type, kept opaque at the top of the
/// bar's per-frame scratch, so the contract stays X-free and a headless
/// consumer can assemble the environment without an X server.
pub const DrawEnv = struct {
    /// Bar config snapshot for the frame (theme, widths, cadences).
    config: bar_config.Config,
    /// Bar height in pixels (shared by every segment's draw).
    height: u16,
    /// Segment allocator (per-frame scratch, font probing, etc.).
    allocator: std.mem.Allocator,
    /// Reserved row width for the segment currently being drawn.
    width: u16 = 0,
    /// The configured name of the segment currently being drawn. Set by
    /// the bar from the name it already had in hand, so a module can
    /// resolve its OWN themed colors without a second argument.
    name: []const u8 = "",
    /// Frame snapshot (workspace counts / current workspace / all-view).
    frame: Frame,
};

/// What a segment actually painted, returned rather than inferred.
///
/// The two outcomes are not the same: a readout with nothing to show (no
/// battery, unreadable file) is a SUCCESS that occupies zero width, while
/// a failed draw is a fallback the bar substitutes.
pub const Painted = struct {
    /// x just past the painted content.
    end_x: u16,
    /// The width really occupied, padding included. 0 means "nothing
    /// painted", which is a valid outcome and NOT an error.
    width: u16 = 0,

    /// The common case: painted from `start_x` to `end_x`.
    pub inline fn span(start_x: u16, end_x: u16) Painted {
        return .{ .end_x = end_x, .width = end_x -| start_x };
    }

    /// Painted nothing -- a valid, successful outcome. The row still
    /// advances by the reservation the layout made.
    pub inline fn nothing(start_x: u16) Painted {
        return .{ .end_x = start_x, .width = 0 };
    }
};

/// Live workspace facts every segment's hooks may read. Pure data, no bar
/// types, so it lives HERE rather than in bar/segment.zig: the
/// `naturalWidth` hook takes it as a real `*const Frame`, and a hook
/// signature cannot name a type the contract may not import. bar/segment.zig
/// re-exports this as the name readers use.
pub const Frame = struct {
    workspace_count: u32 = 0,
    current_workspace: u8 = 0,
    is_all_view_active: bool = false,
    workspace_has_windows: []const bool = &.{},
};

/// Everything a segment's click hook needs, by name.
///
/// Every field is named rather than positional: `offset: u16` and the two
/// direction bools are indistinguishable positionally at the call site, so
/// a transposed pair would type-check, and ignored fields become
/// `_ = ctx.redraw` instead of a wall of `_:` parameters.
pub const ClickCtx = struct {
    /// Pixels from the segment's recorded left edge. Compare against the
    /// width the row reserved (`naturalWidth`), not the last painted width.
    offset: u16,
    /// True for button 1. Modules that step a direction read this as the
    /// sign (left = +1, right = -1).
    is_left: bool,
    /// True for button 3.
    is_right: bool,
    /// The bar's segment state, kept opaque so modules do not depend on
    /// `bar.zig`. The title module re-passes it to `title_click`, which is
    /// why the field is a pointer and not a copy.
    state: *anyopaque,
    /// Bar-provided: route a left-click at `offset` into the title segment.
    /// Takes the same `state` pointer, so the two travel together.
    title_click: *const fn (*anyopaque, u16) void,
    /// Bar-provided full redraw, safe to call inside an input grab.
    redraw: *const fn () void,
};

pub const Segment = struct {
    /// The `Segment` hooks whose contract is "at most one segment binds
    /// this". `measureString` supplies THE row's reserved-width probe and
    /// `overlay` the single runtime overlay; both are reached by
    /// first-match lookup, so a second binder would be silently ignored.
    /// Declared on the TYPE so the generated `bar_modules` registry finds
    /// it with `@hasDecl(T, "single_binder_hooks")` and enforces the count.
    ///
    /// `naturalWidth` is deliberately NOT listed: every segment binds its
    /// own (it is that segment's reserved width, not a shared facility), so
    /// listing it would be false and the assert would reject every
    /// two-segment bar.
    pub const single_binder_hooks = [_][]const u8{
        "measureString", "overlay",
    };

    /// Binder probe for the generated registry's at-most-one check (the
    /// uniform shape every element contract provides). A name that is not
    /// a field is a compile error, not a silent false.
    pub fn hookBinds(m: Segment, comptime hook: []const u8) bool {
        if (!@hasField(Segment, hook)) @compileError(
            "Segment has no hook '" ++ hook ++ "'; single_binder_hooks must name real fields",
        );
        return @field(m, hook) != null;
    }
    /// Config identity ("workspaces", "title", "clock", "layout", "variants").
    /// Unique across the registry; config text resolves to the module by name.
    name: []const u8 = "",
    /// Declares the segment drives its own refresh cadence (the wall-clock
    /// segment), so the bar's secondsElapsed ticker targets it.
    /// Multi-binder: every self-ticking segment is ticked fan-out on each
    /// second boundary and receives a region-scoped repaint of its own
    /// slot. A bar with no self-ticking segment skips the whole timer path.
    self_ticking: bool = false,
    /// Declares the segment claims a share of the reserved center slot (the
    /// title segment). A center row's center-slot segments split the
    /// clamped center budget EVENLY, left-to-right in config order. The
    /// first binder additionally owns the title-centric bar behaviors
    /// (click-to-focus, chrome-overlay toggle).
    center_slot: bool = false,
    /// Which core fact-revisions repaint this segment (title: focus+frame;
    /// workspaces/tags: frame; everything else: none).
    dirty_sources: DirtySources = .{},
    /// Runtime "repaint me on every draw" query. A segment whose content
    /// advances on its own cadence (a scrolling marquee) claims this hook
    /// and returns true while that motion is active: the bar repaints it on
    /// every draw submission even when change detection says nothing
    /// changed. Name-free: the segment owns the query's state.
    needsRepaint: ?*const fn () bool = null,
    /// Whether the segment participates in click-hit bounds. Segments opt
    /// out by setting this false.
    clickable: bool = true,
    // Lifecycle. `handlers` is a bar-provided service handle; passed once
    // at init so segments never import the bar orchestrator.
    /// `conn` is the X connection, carried as `*const anyopaque` for the
    /// same reason `KeyPressEvent` is: this file names no X type. The bar
    /// is the only producer, and exactly one segment (the prompt) reads it.
    init: ?*const fn (std.mem.Allocator, *const anyopaque, ?*const anyopaque) anyerror!void = null,
    deinit: ?*const fn (std.mem.Allocator) void = null,
    // Bar-frame services: uniform polls the orchestrator runs each loop,
    // regardless of whether the segment is configured.
    pollTimeoutMs: ?*const fn () i32 = null,
    onPollWakeup: ?*const fn () void = null,
    secondsElapsed: ?*const fn ([]const u8) bool = null,
    invalidate: ?*const fn () void = null,
    // Metrics, draw and click for configured segments.
    /// Reserved row width probe (clock's measure string; bar measures the
    /// string at layout width). At most one module provides it.
    measureString: ?*const fn () []const u8 = null,
    /// Reserved width in the row. `frame` is a real `*const Frame` (above)
    /// and `clock_width` the measured clock width for segments that need it.
    naturalWidth: ?*const fn (*const Frame, u16) u16 = null,
    /// Draw at `x`, return what it painted. `ctx` is `*segment.DrawCtx`
    /// (bar-built scratch shared by every segment draw).
    draw: ?*const fn (*anyopaque, u16) anyerror!Painted = null,
    /// The bar reports back the width the segment ACTUALLY painted, after
    /// every draw, so the reservation can follow the content.
    ///
    /// The bar owns the row reservation, so a segment should not have to
    /// remember to record its own width -- forgetting is silent and locks
    /// the segment onto its startup width. Stays a hook because the width
    /// belongs to the segment: a multi-slot module splits it across slots,
    /// and one with no measured width (clock, layout) leaves this null.
    onPainted: ?*const fn (u16) void = null,
    /// Click dispatch for recorded bounds; mirrors the chrome-surface
    /// input routing. All of it arrives in one named `ClickCtx`.
    onClick: ?*const fn (*const ClickCtx) bool = null,
    /// Scroll-wheel dispatch for recorded bounds (buttons 4/5, positive =
    /// wheel up; the bar maps button 4 -> +1, button 5 -> -1). Receives
    /// the scroll direction and the bar's redraw hook.
    onScroll: ?*const fn (i8, *const fn () void) bool = null,
    /// Press-hold motion dispatch for recorded bounds: a clickable segment
    /// that claims this hook is scrubbed while button 1 is held (the bar
    /// delivers every motion during the press; X's implicit grab covers
    /// motion past the bar's edge). Null for click-only segments.
    onDragMotion: ?*const fn (u16, *const fn () void) bool = null,
    /// Fired when a press-hold scrub ends (button-1 release): lets a
    /// module that defers work during the scrub (the slider sub throttles
    /// its subprocess commits) flush its final value and leave its drag
    /// render mode. Null for click-only segments.
    onDragEnd: ?*const fn (*const fn () void) void = null,
    // Uniformly-polled module -> bar signals: the bar walks every segment
    // through `anyBoolHook`/`runVoidHook` regardless of which module binds
    // them.
    //
    // `KeyPressEvent` is OPAQUE here and the real xcb struct at the cast
    // points (bar.zig produces it, prompt.zig reads it): this file is
    // X-free, so the field cannot name an xcb type. Prompt-only today.
    handleKeypress: ?*const fn (*const KeyPressEvent, ?*const types.Action) bool = null,
    /// Module queued a redraw (width change, subprocess output, blink
    /// tick). Returning true DRAINS the request and forces a whole-bar
    /// redraw in the CURRENT batch: every caller funnels through
    /// `render.foldModuleRedraw`, which marks the bar dirty on a true
    /// return, so no wake path can drop a request or redraw twice.
    consumeRedrawRequest: ?*const fn () bool = null,
    /// Config reload: drop caches built against the old config (prompt
    /// caret geometry, title pivot). Fired once by the reload swap
    /// (bar.zig) before the new bar is created, on failure paths too.
    invalidateReloadCaches: ?*const fn () void = null,
    /// Fired by the bar on every show (map). Lets continuous-motion
    /// segments (the title marquee) resume without teleporting across the
    /// hidden gap.
    onBarShown: ?*const fn () void = null,
    /// Runtime-overlay binding: when set, this segment overlays ANOTHER
    /// segment's slot (the prompt over the title). The slot's core finds
    /// the value through the segment registry and delegates its
    /// draw/click/poll duty to it while `is_active`. At most one module
    /// binds this.
    overlay: ?BarOverlay = null,
};

comptime {
    dispatch.assertListedFields(Segment, "single_binder_hooks", &Segment.single_binder_hooks);
}
