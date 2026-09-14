//! Production request sink for sync, the ONLY module allowed to contain raw
//! `xcb_` calls. Every shim wraps the exact request
//! pattern it consolidates here:
//!   geom          ~ utils.configureWindow (plus the atomic raise variant
//!                   that merges a stack mode into the same request)
//!   borderWidth   ~ borders.applyWidth's send (dedup lives in LastSent)
//!   borderPixel   ~ utils.setBorderPixel
//!   park          ~ X-offscreen + BELOW merged into one request
//!   stackOnly     ~ utils.raiseWindow and its BELOW sibling
//!   setEwmhFullscreen ~ xcb_change_property (_NET_WM_STATE_FULLSCREEN)
//!   flush/grab    ~ conn.flush / utils.grabServer / ungrabAndFlush

const std = @import("std");
const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");
const sync = @import("sync");

pub const XcbSink = struct {
    conn: core.Connection,

    pub fn sink(self: *XcbSink) sync.Sink {
        return .{
            .ptr = self,
            .vt = &xcb_vtable,
        };
    }

    inline fn fromPtr(ptr: *anyopaque) *XcbSink {
        return @ptrCast(@alignCast(ptr));
    }

    fn mapShim(ptr: *anyopaque, win: u32) void {
        _ = xcb.xcb_map_window(XcbSink.fromPtr(ptr).conn, win);
    }

    /// Configure X|Y|W|H, merging a stack mode into the SAME request when
    /// one is requested (never a separate round of requests for geometry+raise).
    fn geomShim(ptr: *anyopaque, win: u32, rect: utils.Rect, stack: ?sync.Stack) void {
        utils.configureWindow(
            XcbSink.fromPtr(ptr).conn,
            win,
            rect,
            if (stack) |s| stackMode(s) else null,
        );
    }

    fn borderWidthShim(ptr: *anyopaque, win: u32, bw: u16) void {
        _ = xcb.xcb_configure_window(
            XcbSink.fromPtr(ptr).conn,
            win,
            xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH,
            &[_]u32{bw},
        );
    }

    fn borderPixelShim(ptr: *anyopaque, win: u32, pixel: u32) void {
        utils.setBorderPixel(XcbSink.fromPtr(ptr).conn, win, pixel);
    }

    /// Park = offscreen X + stack BELOW in ONE configure_window.
    fn parkShim(ptr: *anyopaque, win: u32) void {
        _ = xcb.xcb_configure_window(
            XcbSink.fromPtr(ptr).conn,
            win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{
                @bitCast(constants.offscreen_x_position),
                xcb.XCB_STACK_MODE_BELOW,
            },
        );
    }

    fn stackOnlyShim(ptr: *anyopaque, win: u32, s: sync.Stack) void {
        _ = s;
        utils.raiseWindow(XcbSink.fromPtr(ptr).conn, win);
    }

    /// Set/clear `fs_atom` in the `_NET_WM_STATE` list on `win` while PRESERVING
    /// any other atoms already listed (a REPLACE that writes only the fullscreen
    /// atom would nuke e.g. _NET_WM_STATE_ABOVE/_STICKY the client set). One
    /// blocking get_property round-trip then one replace-mode change_property;
    /// only reachable from a fullscreen toggle, so the round-trip is acceptable.
    fn setEwmhFullscreenShim(
        ptr: *anyopaque,
        win: u32,
        state_atom: u32,
        fs_atom: u32,
        is_fullscreen: bool,
    ) void {
        const conn = XcbSink.fromPtr(ptr).conn;

        var atoms: [32]u32 = undefined;
        var count: usize = 0;
        const get_cookie = xcb.xcb_get_property(conn, 0, win, state_atom, xcb.XCB_ATOM_ATOM, 0, atoms.len);
        if (xcb.xcb_get_property_reply(conn, get_cookie, null)) |reply| {
            defer std.c.free(reply);
            if (reply.*.format == 32 and reply.*.type == xcb.XCB_ATOM_ATOM) {
                const raw = xcb.xcb_get_property_value(reply) orelse return;
                const n: usize = @intCast(reply.*.value_len);
                const existing = @as([*]const u32, @ptrCast(@alignCast(raw)))[0..@min(n, atoms.len)];
                for (existing) |a| {
                    if (a == fs_atom or a == 0) continue;
                    atoms[count] = a;
                    count += 1;
                }
            }
        }
        if (is_fullscreen) {
            atoms[count] = fs_atom;
            count += 1;
        }

        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            win,
            state_atom,
            xcb.XCB_ATOM_ATOM,
            32,
            @intCast(count),
            if (count > 0) &atoms else null,
        );
    }

    fn flushShim(ptr: *anyopaque) void {
        _ = xcb.xcb_flush(XcbSink.fromPtr(ptr).conn);
    }

    fn grabShim(ptr: *anyopaque) void {
        utils.grabServer(XcbSink.fromPtr(ptr).conn);
    }

    fn ungrabAndFlushShim(ptr: *anyopaque) void {
        utils.ungrabAndFlush(XcbSink.fromPtr(ptr).conn);
    }
};

/// Shared vtable for the production sink: one const instead of re-inlining the
/// shim table in every XcbSink::sink() call.
const xcb_vtable: sync.Sink.VTable = .{
    .map = XcbSink.mapShim,
    .geom = XcbSink.geomShim,
    .border_width = XcbSink.borderWidthShim,
    .border_pixel = XcbSink.borderPixelShim,
    .park = XcbSink.parkShim,
    .stack_only = XcbSink.stackOnlyShim,
    .set_ewmh_fullscreen = XcbSink.setEwmhFullscreenShim,
    .flush = XcbSink.flushShim,
    .grab_server = XcbSink.grabShim,
    .ungrab_and_flush = XcbSink.ungrabAndFlushShim,
};

inline fn stackMode(s: sync.Stack) u32 {
    return switch (s) {
        .above => xcb.XCB_STACK_MODE_ABOVE,
    };
}
