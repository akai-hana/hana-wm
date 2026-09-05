//! Shared scaffolding for the icon-ish bar segment modules (layout, variants).
//! Collapses the duplicated cached-width tracking, redraw-request flag, and
//! the naturalWidth/draw/onClick hook wiring into comptime builders.

const segmod = @import("segment");
const plugin = @import("plugin");

/// Per-module width cache: the ACTUAL drawn width from the last render, read
/// by segment.naturalWidth for the row reservation (0 until the first draw),
/// invalidated on config reload. The comptime `tag` must differ per module
/// so each call site gets its own instantiation (and thus its own state).
pub fn widthState(comptime tag: []const u8) type {
    return struct {
        var cached: u16 = 0;
        var redraw_pending: bool = false;
        const _ = tag;

        pub fn get() u16 {
            return cached;
        }
        pub fn invalidate() void {
            cached = 0;
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
    };
}

/// The naturalWidth/draw/onClick hook trio, parameterized by the module's
/// width state, `draw` fn, and direction-click `action`.
pub fn hooks(
    comptime W: type,
    comptime draw: anytype,
    comptime action: anytype,
) type {
    return struct {
        pub fn naturalWidth(_: *const anyopaque, _: u16) u16 {
            return W.get();
        }
        pub fn drawHook(ctx: *anyopaque, x: u16) !u16 {
            const c = segmod.castDraw(ctx);
            return draw(c.dc, c.config, c.height, x);
        }
        pub fn onClickHook(
            _: u16,
            left: bool,
            _: bool,
            _: *anyopaque,
            _: *const fn (*anyopaque, u16) void,
            redraw: *const fn () void,
        ) bool {
            action(if (left) 1 else -1);
            redraw();
            return true;
        }
    };
}

/// The Segment binding for a module with a cached-width icon draw + direction
/// click action. `with_collapse` additionally wires the redraw request path.
pub fn module(
    comptime name: []const u8,
    comptime draw: anytype,
    comptime action: anytype,
    comptime with_collapse: bool,
) plugin.Segment {
    const W = widthState(name);
    const H = hooks(W, draw, action);
    return .{
        .name = name,
        .invalidate = W.invalidate,
        .consumeRedrawRequest = if (with_collapse) W.consumeRedrawRequest else null,
        .naturalWidth = H.naturalWidth,
        .draw = H.drawHook,
        .onClick = H.onClickHook,
    };
}