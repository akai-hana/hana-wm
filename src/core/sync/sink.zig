//! Production request sink for sync.zig, the ONLY file under src/core/sync/
//! allowed to contain raw `xcb_` calls. Every shim wraps the exact request
//! pattern it consolidates here:
//!   geom          ~ utils.configureWindow (plus the atomic raise variant
//!                   that merges a stack mode into the same request)
//!   borderWidth   ~ borders.applyWidth's send (dedup lives in LastSent)
//!   borderPixel   ~ utils.setBorderPixel
//!   park          ~ X-offscreen + BELOW merged into one request
//!   stackOnly     ~ utils.raiseWindow and its BELOW sibling
//!   setEwmhFullscreen ~ xcb_change_property (_NET_WM_STATE_FULLSCREEN)
//!   flush/grab    ~ conn.flush / utils.grabServer / ungrabAndFlush

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");
const sync = @import("sync");

pub const XcbSink = struct {
    conn: core.Connection,

    pub fn sink(self: *XcbSink) sync.Sink {
        return .{ .ptr = self, .vt = &.{ .map = mapShim, .geom = geomShim, .border_width = borderWidthShim, .border_pixel = borderPixelShim, .park = parkShim, .stack_only = stackOnlyShim, .set_ewmh_fullscreen = setEwmhFullscreenShim, .flush = flushShim, .grab_server = grabShim, .ungrab_and_flush = ungrabAndFlushShim } };
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
        const self = XcbSink.fromPtr(ptr);
        if (stack) |s| {
            _ = xcb.xcb_configure_window(
                self.conn,
                win,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y |
                    xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT |
                    xcb.XCB_CONFIG_WINDOW_STACK_MODE,
                &[_]u32{
                    utils.toXcbCoord(rect.x),
                    utils.toXcbCoord(rect.y),
                    rect.width,
                    rect.height,
                    stackMode(s),
                },
            );
        } else {
            utils.configureWindow(self.conn, win, rect);
        }
    }

    fn borderWidthShim(ptr: *anyopaque, win: u32, bw: u16) void {
        _ = xcb.xcb_configure_window(XcbSink.fromPtr(ptr).conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{bw});
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
        _ = xcb.xcb_configure_window(XcbSink.fromPtr(ptr).conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{stackMode(s)});
    }

    /// Set/clear an EWMH atom property (used for _NET_WM_STATE_FULLSCREEN).
    /// state_atom is the property (e.g. _NET_WM_STATE), fs_atom the value
    /// (e.g. _NET_WM_STATE_FULLSCREEN); `is_fullscreen` selects REPLACE with
    /// that value or an empty one.
    fn setEwmhFullscreenShim(ptr: *anyopaque, win: u32, state_atom: u32, fs_atom: u32, is_fullscreen: bool) void {
        const count: u32 = if (is_fullscreen) 1 else 0;
        _ = xcb.xcb_change_property(
            XcbSink.fromPtr(ptr).conn,
            xcb.XCB_PROP_MODE_REPLACE,
            win,
            state_atom,
            xcb.XCB_ATOM_ATOM,
            32,
            count,
            if (is_fullscreen) &fs_atom else null,
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

inline fn stackMode(s: sync.Stack) u32 {
    return switch (s) {
        .above => xcb.XCB_STACK_MODE_ABOVE,
    };
}
