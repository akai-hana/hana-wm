//! segment.zig — drop-in template for a hana bar-segment module.
//!
//! COPY ME: the fastest way to start a new segment is
//!
//!     cp dev/plugin-template/segment.zig src/bar/modules/mysegment.zig
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

// ---------------------------------------------------------------------------
// Segment-owned state. Same discipline as every addon: file-scope statics,
// allocation-free, reset by init/deinit (tests init/deinit per fixture).
// ---------------------------------------------------------------------------

var g_active: bool = false;
var g_polls: u32 = 0;

// ---------------------------------------------------------------------------
// REQUIRED lifecycle hooks (bind both).
// ---------------------------------------------------------------------------

/// Lifecycle: reset ALL module state. Called once at boot and at every
/// re-init (restart) through the uniform registry loop.
///
/// `allocator`/`conn` are bar-wide services; `handlers` is the bar's service
/// handle for your segment if you are a chrome-surface overlay like the
/// prompt (`*const segment.BarHandlers` — presentForPrompt/dismissAfterPrompt/
/// isBarWindow). Cast it on this side; leave null-ignored when your
/// segment needs no bar services.
pub fn init(allocator: std.mem.Allocator, conn: core.Connection, handlers: ?*const anyopaque) anyerror!void {
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

// ---------------------------------------------------------------------------
// Bar-frame services (uniform polls). The bar runs these on EVERY registry
// entry every frame, whether or not the segment is configured. Leave `null`
// for a purely passive segment.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Configured-segment hooks. The bar invokes these ONLY on segments present
// in the config's `[bar] segments` list (this template's name is a
// placeholder, so none of these fire until you set a real name and add it to
// a config).
// ---------------------------------------------------------------------------

/// Reserved row width probe (clock's measure string; the bar reserves the
/// measured string's width in the row).
pub fn measureString() []const u8 {
    return ""; // TODO: your display string when reserved at row width.
}

/// Reserved width in the row (`frame` is `*const segment.Frame`, `clock_width`
/// the measured clock width for segments that need it).
pub fn naturalWidth(frame: *const anyopaque, clock_width: u16) u16 {
    _ = frame;
    _ = clock_width;
    return 0; // TODO: your segment's reserved width.
}

/// Draw at `x`, return the advanced x. `ctx` is `*segment.DrawCtx` (bar-built
/// per-frame scratch: dc, config, conn, allocator, width, minimized_api,
/// frame, title snapshots). Draw with the ctx.dc primitives the same way the
/// shipped segments do — the bar only blits what you drew.
pub fn draw(ctx: *anyopaque, x: u16) anyerror!u16 {
    const dctx: *segment.DrawCtx = @ptrCast(@alignCast(ctx));
    _ = dctx;
    return x; // TODO: paint via dctx.dc and return your advanced x.
}

/// Click dispatch for recorded bounds (mirrors the chrome-surface input
/// routing; state/title_click/redraw are bar-provided fn pointers). Return
/// true when the click was consumed.
pub fn onClick(
    offset: u16,
    left: bool,
    right: bool,
    state: *anyopaque,
    title_click: *const fn (*anyopaque, u16) void,
    redraw: *const fn () void,
) bool {
    _ = offset;
    _ = left;
    _ = right;
    _ = title_click;
    _ = redraw;
    _ = state;
    return false; // TODO: your click handling; false = not ours.
}

// ---------------------------------------------------------------------------
// Prompt chrome-surface extras. ONLY the prompt overlay binds these; if you
// bind them, the bar will treat your segment as the chrome-surface input
// provider when the prompt isn't present. Leave them commented out for any
// normal segment.
// ---------------------------------------------------------------------------
//   pub fn handleKeypress(event: *const xcb.xcb_key_press_event_t, bound: ?*const types.Action) bool { ... }
//   pub fn consumeRedrawRequest() bool { ... }
//   pub fn invalidateReloadCaches() void { ... }

// ---------------------------------------------------------------------------
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
// ---------------------------------------------------------------------------
pub const module: @import("contract").Segment = .{
    .name = "template", // TODO: unique config identity, e.g. "clock"
    .init = init,
    .deinit = deinit,
    .pollTimeoutMs = pollTimeoutMs,
    .onPollWakeup = onPollWakeup,
    .secondsElapsed = secondsElapsed,
    .invalidate = invalidate,
    // Configured-segment hooks — bind + add the name to a config when ready:
    //   .measureString = measureString,   // (clock convention) reserved width
    //   .naturalWidth = naturalWidth,
    //   .draw = draw,
    //   .onClick = onClick,
    // Prompt extras — bind only for a chrome-surface overlay:
    //   .handleKeypress = handleKeypress,
    //   .consumeRedrawRequest = consumeRedrawRequest,
    //   .invalidateReloadCaches = invalidateReloadCaches,
};
