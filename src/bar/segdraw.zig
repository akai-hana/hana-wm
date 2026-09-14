//! Shared scaffolding for the icon-ish bar segment modules (layout, variants,
//! clock, tags).
//! Collapses the duplicated cached-width tracking, redraw-request flag, and
//! the naturalWidth/draw/onClick hook wiring into a single comptime builder
//! parameterized by an `Opts` struct.

const segmod = @import("segment");
const plugin = @import("plugin");

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

        pub fn get() u16 {
            return cached;
        }
        pub fn invalidate() void {
            // Keep the last measured width as the row reservation instead of
            // zeroing it: zero would make the FIRST measure after a reload
            // (which runs before this segment's draw re-primes the cache)
            // reserve a 0-width slot and push downstream segments out of place
            // for a frame. The reload's own full redraw re-measures the width
            // (store) immediately afterward.
        }
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
        pub fn naturalWidth(_: *const anyopaque, _: u16) u16 {
            return cached;
        }
    };
}

const NaturalWidth = *const fn (*const anyopaque, u16) u16;
const OnClick = *const fn (
    u16,
    bool,
    bool,
    *anyopaque,
    *const fn (*anyopaque, u16) void,
    *const fn () void,
) bool;

/// Optional bindings for the segment, one field per plugin.Segment hook the
/// icon-ish modules can set. Unset fields keep the builder defaults.
pub const Opts = struct {
    /// Wires the collapse/expand redraw-request path (variants collapses to
    /// zero width on a layout transition and must re-lay the row that batch).
    with_collapse: bool = false,
    self_ticking: bool = false,
    center_slot: bool = false,
    clickable: bool = true,
    dirty_sources: plugin.DirtySources = .{},
    needsRepaint: ?*const fn () bool = null,
    pollTimeoutMs: ?*const fn () i32 = null,
    onPollWakeup: ?*const fn () void = null,
    secondsElapsed: ?*const fn ([]const u8) bool = null,
    invalidate: ?*const fn () void = null,
    measureString: ?*const fn () []const u8 = null,
    /// Reserved row width probe; defaults to the measure-string passthrough
    /// (clock) when `measureString` is set, else the cached drawn width.
    natural_width: ?NaturalWidth = null,
    on_click: ?OnClick = null,
};

/// The width-state naturalWidth/draw/onClick wiring, one adapter per hook.
fn drawHook(comptime draw: anytype) *const fn (*anyopaque, u16) anyerror!u16 {
    return struct {
        fn f(ctx: *anyopaque, x: u16) !u16 {
            const c = segmod.castDraw(ctx);
            return draw(c.dc, c.config, c.height, x);
        }
    }.f;
}

/// The icon modules' click action: step the integer direction, then force a
/// redraw. Null action => no click binding (clock).
fn clickHook(comptime action: anytype) ?OnClick {
    // `null` is passed for modules with no click action (clock, workspaces).
    if (comptime @TypeOf(action) == @TypeOf(null)) return null;
    return struct {
        fn f(_: u16, left: bool, _: bool, _: *anyopaque, _: *const fn (*anyopaque, u16) void, redraw: *const fn () void) bool {
            action(if (left) 1 else -1);
            redraw();
            return true;
        }
    }.f;
}

/// The clock's naturalWidth: reserve the measured clock width itself.
fn passthroughWidth(_: *const anyopaque, clock_width: u16) u16 {
    return clock_width;
}

/// The Segment binding for an icon-ish module with a cached-width draw +
/// optional direction-click action. `opts.with_collapse` additionally wires
/// the redraw-request path.
pub fn module(
    comptime name: []const u8,
    comptime draw: anytype,
    comptime action: anytype,
    comptime opts: Opts,
) plugin.Segment {
    const W = widthState(name);
    return .{
        .name = name,
        .self_ticking = opts.self_ticking,
        .center_slot = opts.center_slot,
        .clickable = opts.clickable,
        .dirty_sources = opts.dirty_sources,
        .needsRepaint = opts.needsRepaint,
        .pollTimeoutMs = opts.pollTimeoutMs,
        .onPollWakeup = opts.onPollWakeup,
        .secondsElapsed = opts.secondsElapsed,
        .invalidate = opts.invalidate orelse W.invalidate,
        .consumeRedrawRequest = if (opts.with_collapse) W.consumeRedrawRequest else null,
        .measureString = opts.measureString,
        .naturalWidth = opts.natural_width orelse (if (opts.measureString != null) passthroughWidth else W.naturalWidth),
        .draw = drawHook(draw),
        .onClick = opts.on_click orelse clickHook(action),
    };
}
