//! Slider control segments (volume, brightness, ...) -- the package core.
//! Every control sub in this directory is promoted to its OWN bar segment
//! ("volume", "brightness", ...) via `segmentFor(i)`, so each control is
//! selected, ordered, and spaced independently in `[bar.layout.*]` -- there
//! is no aggregate "slider" belt any more.
//!
//! This eponymous file is the package core:
//!   - `Sub` is the surface contract every slider-like control binds.
//!     `Write`/`CommitCost`/`Throttle` are DECLARED by the interaction shell
//!     and re-exported here, so every control, test and the plugin template
//!     keep naming one package (the mode and the latency class are
//!     contract-visible vocabulary; the scheduler that switches on them is
//!     interaction machinery).
//!   - `subs` comes from the generated `slider_subs` registry (file presence +
//!     self-declared role: a sibling without `pub const sub` is a private
//!     implementation file, never a bound addon).
//!   - the pct<->range map (`rawFromPct` / `clampPct` / `pctFromRaw`, plus the
//!     `level.pctFromSlot` re-export the pure test shares).
//!   - `segmentFor(i)` builds the `contract.Segment` the bar places for control
//!     `i`, config identity `subs[i].name`. build.zig emits one entry per
//!     discovered control with a `pub const sub`; its hooks reach into
//!     `shell.zig` below (one-way: core -> shell).
//!
//! Everything that is not contract, map or binding lives beside this file:
//!   - `shell.zig` -- the interaction shell (a click hit-tests the control's
//!     own slot, exclusive press-hold drag, wheel steps, one-shot applies),
//!     the poll loop (per-control cadence + owed-sweep), the commit
//!     scheduler, and the per-segment lifecycle (arm-on-first-draw, poll
//!     deadline, dirty redraw marking, painted-width tracking);
//!   - `bar/spawn_capture.zig` -- the `/bin/sh` racers each control runs its
//!     spawned commands through (allocation-free, inlined);
//!   - `bar/drawing.zig` -- the format walker (`renderLineValue`) and the
//!     `Label` a control renders with.
//! A control keeps its OWN truth (backend handles, cached state, format); the
//! core addresses it through hooks -- `read`/`pct`/`preview`/`commit`/`apply`
//! -- and remembers only per-segment slot geometry, arming, and cadence.

const std = @import("std");
const types = @import("types");
const drawing = @import("drawing");
const contract = @import("contract");
const level = @import("level");
const shell = @import("shell");

/// Public for the unit tests: the registry is build-generated, and a test that
/// hardcoded a control name would break whenever one is added or removed.
pub const subs = @import("slider_subs").subs;

/// The single pct↔range linear map shared by every control backend: maps a
/// raw level on the control's [min..max] scale onto 0-100 percent (and back),
/// nearest-rounding in both directions so a round trip is stable and 50 % of
/// 0..87 lands on 44 (what `amixer set Master 50%` writes). A degenerate
/// (zero-length or inverted) range maps the range floor on write and 0 on
/// read.
pub fn rawFromPct(comptime T: type, pct: u8, min: T, max: T) T {
    if (max <= min) return min;
    const span: i128 = @as(i128, max) - @as(i128, min);
    const lead: i128 = @min(@divTrunc(@as(i128, clampPct(pct)) * span + 50, 100), span);
    return @intCast(@as(i128, min) + lead);
}

/// The one clamp every level passes: 0-100 % is all the backend ever
/// receives. Every commit/write mode MUST go through this function -- the
/// modules used to clamp independently, and when the preview path forgot to,
/// a scroll/drag motion could display a level the backend then refused.
pub fn clampPct(v: u8) u8 {
    return @min(v, 100);
}

/// Inverse of `rawFromPct` (the shared map): raw value onto the 0-100 scale.
pub fn pctFromRaw(comptime T: type, raw: T, min: T, max: T) u8 {
    if (max <= min) return 0;
    const span: i128 = @as(i128, max) - @as(i128, min);
    const off: i128 = std.math.clamp(@as(i128, raw) - @as(i128, min), 0, span);
    const pct: i128 = @divTrunc(off * 100 + @divTrunc(span, 2), span);
    return @intCast(@min(pct, 100));
}

// The slider surface is a closed-core / open-module system, like every
// surface in this tree:
//
//   - The CLOSED CORE is this file: the `Sub` contract, the pct map and the
//     `segmentFor` binding; the generic per-control
//     render/interaction/poll/commit shell sits beside it in `shell.zig`. The
//     core never names a control module; every control is reached through
//     `subs`, the generated registry (see build.zig's
//     `buildSubsRegistryModule`).
//
//   - The OPEN MODULES are the siblings that bind `pub const sub: Sub`.
//     Siblings WITHOUT the binding are private implementation files:
//     importable by stem, never bound.
//     Membership in `subs` -- and therefore a bar segment named after the
//     control -- comes from FILE PRESENCE plus self-declared role, so adding
//     a control is drop a file; deleting one is delete the file.
//
// To add a control: drop `foo.zig` here exporting `pub const sub: Sub`.

pub const Sub = struct {
    /// Config identity ("volume", "brightness", ...): the name its bar
    /// segment is selected by in `[bar.layout.*]`.
    name: []const u8,
    /// Per-control poll cadence.
    read_interval_ms: i64 = 5000,
    /// The control's 0-100 level, or null while it has no answer (the control
    /// then renders nothing: zero-width slot, unclickable). Null HOOK = always
    /// present.
    ///
    /// This is one hook, not the `{bool, u8}` pair it replaced. The two
    /// were always written and always latched together, and a module that
    /// latched one and forgot the other produced a control that reported a
    /// level nobody had or hid a level everybody could see. The absence is now
    /// in the type, so it cannot disagree with the value.
    level: ?*const fn () ?u8 = null,
    /// True while the backend can write; while false interactions no-op but
    /// the level still displays.
    writable: *const fn () bool,
    /// Refresh the control's live state (attach/probe cached inside); returns
    /// true when the displayed state changed this call.
    read: *const fn () bool,
    /// Writes `pct`, or advances only the display -- see `Write`.
    write: *const fn (Write, u8) void,
    /// The latency class of one commit on this control, as a named value (see
    /// `CommitCost`). `immediate` commits are cheap in-process writes and are
    /// never coalesced; `rate_limited` ones pass through the throttle window.
    commit_cost: *const fn () CommitCost,
    /// This control's own spawn-commit window in ms, or null to share the core
    /// default (`throttle_ms`). Per-control so a control whose subprocess is
    /// cheap enough to afford a tighter sweep can say so as data instead of
    /// living with the shared window. Ignored for `immediate` commits.
    commit_window_ms: ?i16 = null,
    /// Renders the idle label into `buf` (control-scoped scratch) from the
    /// control's own state and config, plus the label's numeric region;
    /// valid until the next call.
    label: *const fn (types.BarConfig, []u8) drawing.Label,
    /// Right-click action (volume's mute toggle); null = reserved no-op.
    secondary: ?*const fn () void = null,
    /// Idle width when the control has never laid out (natural-reserve
    /// fallback).
    probeNaturalWidth: u16 = 44,
};

/// Linear slider mapping across a slot. Lifted to `bar/level.zig`: it
/// is not a slider concept -- every horizontal meter needs it -- and the
/// zero-width-slot rule and the far-edge saturation had to be right in
/// whichever module happened to need them first. This re-export keeps the
/// slider's own name working, so the pure test and the core keep the same
/// entry point.
pub const pctFromSlot = level.pctFromSlot;

// Declared by the interaction shell and re-exported here: `Write` and
// `CommitCost` are contract-visible vocabulary (`Sub.write`,
// `Sub.commit_cost`), and `Throttle` is what the controls' commit tests
// drive directly -- the shell OWNS them because it is the machinery that
// switches on them, and the core NAMES them so one package answers
// `slider.Write` for every caller (controls, tests, the plugin template).
pub const Write = shell.Write;
pub const CommitCost = shell.CommitCost;
pub const Throttle = shell.Throttle;

/// Contract queries over one `Sub`, implemented in the shell (which owns the
/// registry elements they read through); wrappers keep the core's `Sub` in
/// the signature so a fake sub still exercises both directions.
pub fn subPresent(sub: Sub) bool {
    return shell.subPresent(sub);
}

pub fn subLevel(sub: Sub) ?u8 {
    return shell.subLevel(sub);
}

pub fn subLevelOrZero(sub: Sub) u8 {
    return shell.subLevelOrZero(sub);
}

/// The bar-module binding for control `i` (comptime so each instantiation is
/// a distinct segment with its own hooks into `subs[i]`'s state). Emitted by
/// build.zig per discovered control with a `pub const sub`, in the same
/// alphabetical order as `subs`.
pub fn segmentFor(comptime i: usize) contract.Segment {
    const Hooks = struct {
        fn poll() i32 {
            return shell.pollDeadlineMsFor(i);
        }
        fn wakeup() void {
            return shell.onPollWakeupFor(i);
        }
        fn redraw() bool {
            return shell.consumeRedrawRequestFor(i);
        }
        fn naturalWidth(_: *const contract.Frame, _: u16) u16 {
            return shell.naturalWidthFor(i);
        }
        fn draw(ctx: *anyopaque, x: u16) anyerror!contract.Painted {
            return shell.drawFor(i, ctx, x);
        }
        fn onPainted(width: u16) void {
            shell.onPaintedFor(i, width);
        }
        fn onClick(ctx: *const contract.ClickCtx) bool {
            return shell.onClickFor(i, ctx);
        }
        fn onScroll(dir: i8, request_redraw: *const fn () void) bool {
            return shell.onScrollFor(i, dir, request_redraw);
        }
        fn onDragMotion(offset: u16, request_redraw: *const fn () void) bool {
            return shell.onDragMotionFor(i, offset, request_redraw);
        }
        fn onDragEnd(request_redraw: *const fn () void) void {
            return shell.onDragEndFor(i, request_redraw);
        }
    };
    return .{
        .name = subs[i].name,
        .clickable = true,
        .pollTimeoutMs = Hooks.poll,
        .onPollWakeup = Hooks.wakeup,
        .consumeRedrawRequest = Hooks.redraw,
        .naturalWidth = Hooks.naturalWidth,
        .draw = Hooks.draw,
        .onPainted = Hooks.onPainted,
        .onClick = Hooks.onClick,
        .onScroll = Hooks.onScroll,
        .onDragMotion = Hooks.onDragMotion,
        .onDragEnd = Hooks.onDragEnd,
    };
}
