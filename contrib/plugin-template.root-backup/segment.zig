//! segment.zig — drop-in template for a hana bar-segment module.
//!
//! COPY ME: the fastest way to start a new segment is
//!
//!     cp contrib/plugin-template/segment.zig src/bar/modules/mysegment.zig
//!
//! then edit the TODO markers and rename the `module` export's fields you
//! don't need. Nothing else needs to change: build.zig's directory scan
//! (`src/<owner>/modules/` -> <owner>_modules registry) picks the file up
//! automatically, wires your `pub const module` into the generated
//! `bar_modules.modules` array, and the bar loops (lifecycle, uniform polls,
//! configured width/draw/click) start calling your hooks — or skip them while
//! `null`.
//!
//! This file is INTENTIONALLY inert. Its `.name` never appears in any shipped
//! config, so the bar never asks it for width or a draw; its hooks are real,
//! copy-pasteable code that neither claims a slot nor paints anything. Drop
//! it into `src/bar/modules/` and `zig build test` stays identical — that is
//! the contract's litmus test. `zig build check` additionally compiles every
//! file here against the real modules (the `check-plugin-template` step in
//! build.zig), so contract drift self-fails.
//!
//! The shared bar vocabulary (Frame, Env, DrawCtx, BarHandlers, title
//! snapshot types) lives in src/bar/segment.zig — import it with
//! `@import("segment")`. Note the names collide on purpose: the template
//! also binds the NAME "segment" in the registry samples below. Mirror the
//! shipped segments (clock.zig is the reference) rather than this template
//! alone.

const std = @import("std");

const core = @import("core");
const segment = @import("segment");
// Contract vocabulary, imported the way every shipped segment imports it
// (clock.zig is the reference). `segment` re-exports only `Frame`; `Painted`
// and `ClickCtx` are read off the contract directly.
const contract = @import("bar_contract");

// Segment-owned state. Same discipline as every addon: file-scope statics,
// allocation-free, reset by init/deinit (tests init/deinit per fixture).

var g_active: bool = false;
var g_polls: u32 = 0;

// REQUIRED lifecycle hooks (bind both).

/// Lifecycle: reset ALL module state. Called once at boot and at every
/// re-init (restart) through the uniform registry loop.
///
/// `allocator`/`conn` are bar-wide services; `handlers` is the bar's service
/// handle for your segment if you are a chrome-surface overlay like the
/// prompt (`*const segment.BarHandlers` — presentForPrompt/dismissAfterPrompt/
/// isBarWindow). Cast it on this side; leave null-ignored when your
/// segment needs no bar services.
/// `conn` is `*const anyopaque`, not `core.Connection`: `bar_contract.zig` is
/// xcb-free so the segment hook can name no X type. Cast it back with
/// `@ptrCast(@constCast(conn))` if you actually need the connection.
pub fn init(allocator: std.mem.Allocator, conn: *const anyopaque, handlers: ?*const anyopaque) anyerror!void {
    _ = conn;
    _ = handlers;
    g_active = false;
    g_polls = 0;
    // TODO: resolve anything your segment needs from core at startup.
    _ = allocator;
}

/// Lifecycle: tear down. Same reset as init(); free OS/allocation handles
/// here if your segment owns any.
pub fn deinit(allocator: std.mem.Allocator) void {
    _ = allocator;
    g_active = false;
    g_polls = 0;
}

// Bar-frame services (uniform polls). The bar runs these on EVERY registry
// entry every frame, whether or not the segment is configured. Leave `null`
// for a purely passive segment.

/// Poll wakeup interval in ms: <= 0 disables wakeups (clock uses this).
pub fn pollTimeoutMs() i32 {
    return -1; // TODO: return your poll period (ms) or -1 for none.
}

/// Called when the bar's poll-wakeup fires (only when pollTimeoutMs > 0).
pub fn onPollWakeup() void {
    g_polls += 1;
}

/// Called each time a whole second elapses (bar's second ticker).
pub fn secondsElapsed(fmt: []const u8) bool {
    // TODO: return true when an invalidation happened (e.g. your display
    // string changed) so the bar redraws.
    _ = fmt;
    g_polls += 1;
    return false;
}

/// Called by the bar whenever a full (non-incremental) redraw runs.
pub fn invalidate() void {
    g_active = true;
}

// Configured-segment hooks. The bar invokes these ONLY on segments present
// in the config's `[bar] segments` list (this template's name is a
// placeholder, so none of these fire until you set a real name and add it to
// a config).

/// Reserved row width probe (clock's measure string; the bar reserves the
/// measured string's width in the row).
pub fn measureString() []const u8 {
    return ""; // TODO: your display string when reserved at row width.
}

/// Reserved width in the row (`frame` is a real `*const segment.Frame`, the
/// live workspace facts the bar passes to every segment; `clock_width` is the
/// measured clock width for segments that need it).
pub fn naturalWidth(frame: *const segment.Frame, clock_width: u16) u16 {
    _ = frame;
    _ = clock_width;
    return 0; // TODO: your segment's reserved width.
}

/// Draw at `x`, return what you painted. `ctx` is `*segment.DrawCtx`
/// (bar-built per-frame scratch: dc, config, conn, allocator, width,
/// minimized_api, frame, title snapshots). Draw with the ctx.dc primitives
/// the same way the shipped segments do — the bar only blits what you drew.
/// The return is the bar's `Painted` record, not an advanced x: `.span(x, x+n)`
/// for content that occupied `n` pixels, or `.nothing(x)` for the valid
/// "drew an empty cell, keep my slot" outcome the bar must tell apart from a
/// caught draw error.
pub fn draw(ctx: *anyopaque, x: u16) anyerror!contract.Painted {
    const dctx: *segment.DrawCtx = @ptrCast(@alignCast(ctx));
    _ = dctx;
    return contract.Painted.nothing(x); // TODO: `.span(x, x + painted_width)`.
}

/// Click dispatch for recorded bounds. Every field arrives NAMED in one
/// `*const contract.ClickCtx` (`offset` from the segment's left edge, the
/// `is_left`/`is_right` button flags, the bar `state` handle, and the
/// `title_click`/`redraw` callbacks) — the positional form this replaced
/// type-checked a transposed pair of bools, and there was no room to add a
/// modifier mask without touching every implementation. Return true when the
/// click was consumed.
pub fn onClick(ctx: *const contract.ClickCtx) bool {
    _ = ctx;
    return false; // TODO: your click handling; false = not ours.
}

/// Scroll-wheel dispatch for recorded bounds (`dir` is +1 for wheel up / -1
/// for wheel down, `redraw` the bar's region-scoped repaint hook). Return true
/// when the scroll was consumed. Declared but deliberately NOT bound in
/// `module` below: the bar routes a wheel event to the FIRST scroll-binding
/// segment at those bounds and stops, so an inert stub would shadow a real
/// one. Bind `.onScroll = onScroll` when your segment actually scrolls —
/// `zig build check-plugin-template` checks this signature either way.
pub fn onScroll(dir: i8, redraw: *const fn () void) bool {
    _ = dir;
    _ = redraw;
    return false;
}

/// Width-report sink: the bar tells you the width it actually painted after
/// every draw, so your reservation follows your content. Only bind it if you
/// remember a painted width — the bar records it for you when you don't.
/// Checked by the template gate either way.
pub fn onPainted(width: u16) void {
    _ = width;
}

// Press-hold scrub dispatch, same first-binder routing as onScroll: declared
// for signature-checking, unbound until your segment really scrubs.
//   pub fn onDragMotion(motion_x: u16, redraw: *const fn () void) bool { ... }
//   pub fn onDragEnd(redraw: *const fn () void) void { ... }

// Prompt chrome-surface extras. ONLY the prompt overlay binds these; if you
// bind them, the bar will treat your segment as the chrome-surface input
// provider when the prompt isn't present. Leave them commented out for any
// normal segment.
//   pub fn handleKeypress(event: *const xcb.xcb_key_press_event_t, bound: ?*const types.Action) bool { ... }
//   pub fn consumeRedrawRequest() bool { ... }
//   pub fn invalidateReloadCaches() void { ... }

// This segment's bar contribution: the build-generated registry reads this
// exact export. Only the fields you set are dispatched. A segment is part of
// the config surface exactly when its `.name` appears in `[bar] segments` (or
// a layout) — an in-flight segment simply ships with a non-empty placeholder
// name and stays out of every shipped config (the prompt is a runtime overlay
// with its own name; everything else is selectable by name).
// Role capabilities (all default to false / .{} / true; set only as needed).
// Both role capabilities are multi-binder -- the bar ticks EVERY self-ticker
// fan-out and splits the center evenly among every center-slot segment,
// left-to-right in config order:
//   .self_ticking = true,          // drive your own refresh cadence (clock)
//   .center_slot = true,           // claim a share of the reserved center (title)
//   .dirty_sources = .{ .focus = true, .frame = true }, // repaint on fact-revs
//   .clickable = false,            // skip click-hit bounds (clock)
//   .needsRepaint = needsRepaint,  // "repaint me every draw while active"
pub const module: @import("bar_contract").Segment = .{
    .name = "template", // TODO: unique config identity, e.g. "clock"
    .init = init,
    .deinit = deinit,
    .pollTimeoutMs = pollTimeoutMs,
    .onPollWakeup = onPollWakeup,
    .secondsElapsed = secondsElapsed,
    .invalidate = invalidate,
    // Configured-segment hooks. Bound here (not left commented) because
    // `zig build check-plugin-template` compiles this file and the generated
    // wrapper only reaches the fields a `module` value actually BINDS: a
    // hook left commented has its signature never checked, so it can silently
    // drift from `bar_contract` — which is what left `draw` returning an
    // advanced x for years while the contract wanted `anyerror!Painted`, and
    // `onClick` positional while every caller passed one `*const ClickCtx`.
    // Binding them makes that class of drift a configure error. A real
    // segment is config-selectable only when its `.name` appears in
    // `[bar] segments`, so binding here changes no shipped behaviour; drop a
    // field you do not want and you are back to the unchecked state.
    .measureString = measureString, // (clock convention) reserved width
    .naturalWidth = naturalWidth,
    .draw = draw,
    .onClick = onClick,
    // Prompt extras — bind only for a chrome-surface overlay:
    //   .handleKeypress = handleKeypress,
    //   .consumeRedrawRequest = consumeRedrawRequest,
    //   .invalidateReloadCaches = invalidateReloadCaches,
};
