//! Production request sink for sync.zig — the ONLY file under src/sync/
//! allowed to contain raw `xcb_` calls (P3 acceptance gate). Every shim
//! wraps an existing legacy pattern 1:1:
//!   geom          ≙ window.zig configureWindowGeom minus the BW field
//!                   (sync sends border width as its own diffed request)
//!                 / layouts.configureWithHintsImpl's atomic raise variant
//!   borderWidth   ≙ borders.applyWidth's send (dedup lives in LastSent)
//!   borderPixel   ≙ utils.setBorderPixel
//!   park          ≙ utils.pushWindowOffscreenAndLower (X + BELOW merged)
//!   stackOnly     ≙ utils.raiseWindow and its BELOW sibling
//!   flush/grab    ≙ conn.flush / utils.grabServer / ungrabAndFlush

const core = @import("core");
const xcb = core.xcb;
const utils = @import("utils");
const constants = @import("constants");
const sync = @import("sync");

pub const XcbSink = struct {
    conn: core.Connection,

    pub fn sink(self: *XcbSink) sync.Sink {
        return .{ .ptr = self, .vt = &.{ .map = mapShim, .geom = geomShim, .border_width = borderWidthShim, .border_pixel = borderPixelShim, .park = parkShim, .stack_only = stackOnlyShim, .flush = flushShim, .grab_server = grabShim, .ungrab_and_flush = ungrabAndFlushShim } };
    }

    fn mapShim(ptr: *anyopaque, win: u32) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        _ = xcb.xcb_map_window(self.conn, win);
    }

    /// Configure X|Y|W|H, merging a stack mode into the SAME request when
    /// one is requested (never a separate round of requests for geometry+raise).
    fn geomShim(ptr: *anyopaque, win: u32, rect: utils.Rect, stack: ?sync.Stack) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
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
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        _ = xcb.xcb_configure_window(self.conn, win, xcb.XCB_CONFIG_WINDOW_BORDER_WIDTH, &[_]u32{bw});
    }

    fn borderPixelShim(ptr: *anyopaque, win: u32, pixel: u32) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        utils.setBorderPixel(self.conn, win, pixel);
    }

    /// Park = offscreen X + stack BELOW in ONE configure_window (§7.4 step 7).
    fn parkShim(ptr: *anyopaque, win: u32) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        _ = xcb.xcb_configure_window(
            self.conn,
            win,
            xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_STACK_MODE,
            &[_]u32{
                @bitCast(constants.offscreen_x_position),
                xcb.XCB_STACK_MODE_BELOW,
            },
        );
    }

    fn stackOnlyShim(ptr: *anyopaque, win: u32, s: sync.Stack) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        _ = xcb.xcb_configure_window(self.conn, win, xcb.XCB_CONFIG_WINDOW_STACK_MODE, &[_]u32{stackMode(s)});
    }

    fn flushShim(ptr: *anyopaque) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        _ = xcb.xcb_flush(self.conn);
    }

    fn grabShim(ptr: *anyopaque) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        utils.grabServer(self.conn);
    }

    fn ungrabAndFlushShim(ptr: *anyopaque) void {
        const self: *XcbSink = @ptrCast(@alignCast(ptr));
        utils.ungrabAndFlush(self.conn);
    }
};

inline fn stackMode(s: sync.Stack) u32 {
    return switch (s) {
        .above => xcb.XCB_STACK_MODE_ABOVE,
        .below => xcb.XCB_STACK_MODE_BELOW,
    };
}
